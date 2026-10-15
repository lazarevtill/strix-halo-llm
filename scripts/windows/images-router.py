#!/usr/bin/env python3
"""images-router.py -- one HTTP endpoint, many image models.

stable-diffusion.cpp's sd-server holds ONE model per process. This router is the image-side
equivalent of llama.cpp's router mode: it serves the Image Studio page, starts an sd-server
backend per model on demand (127.0.0.1, fixed ports), keeps several resident within a GPU-memory
budget (LRU eviction of idle backends), and routes every request to the right one:

  GET  /                          Image Studio (images-ui.html, re-read per request)
  GET  /studio/models             registry + live state of every model
  POST /studio/models/load        {"model": id}  start a backend (async; poll /studio/models)
  POST /studio/models/unload      {"model": id}
  *    /sdcpp/v1/...              native async API; img_gen takes an extra "model" field,
                                  job ids are mapped back to the backend that owns them
  GET  /v1/models                 OpenAI-style list of the registry's models
  POST /v1/images/generations     OpenAI; routed by the "model" field
  POST /v1/images/edits           OpenAI multipart; routed by its "model" part. Requests that embed
                                  <sd_cpp_extra_args> are REJECTED: on sd-server master-967 that
                                  input aborts the whole backend process (measured 2026-10-15).
  *    /sdapi/v1/...              A1111-style API, current model
  GET  /health                    router liveness

Stdlib only. Run with `python -I`. Backends run inside a Windows job object, so they die with the
router instead of lingering as orphans that hold GPU memory.
"""
import argparse
import ctypes
import http.client
import http.server
import json
import os
import re
import subprocess
import sys
import threading
import time
import urllib.parse

TERMINAL = {"completed", "failed", "cancelled"}
HOP = {"connection", "keep-alive", "proxy-authenticate", "proxy-authorization", "te", "trailers",
       "transfer-encoding", "upgrade", "content-length", "content-encoding", "expect"}


def log(msg):
    sys.stdout.write("%s  %s\n" % (time.strftime("%Y-%m-%dT%H:%M:%S"), msg))
    sys.stdout.flush()


# ---- Windows job object: children die with the router ------------------------------------------
class KillOnCloseJob:
    def __init__(self):
        self.h = None
        if os.name != "nt":
            return
        try:
            k32 = ctypes.windll.kernel32
            self.k32 = k32
            self.h = k32.CreateJobObjectW(None, None)

            class IO_COUNTERS(ctypes.Structure):
                _fields_ = [(n, ctypes.c_ulonglong) for n in
                            ("r", "w", "o", "rb", "wb", "ob")]

            class BASIC(ctypes.Structure):
                _fields_ = [("PerProcessUserTimeLimit", ctypes.c_longlong), ("PerJobUserTimeLimit", ctypes.c_longlong),
                            ("LimitFlags", ctypes.c_uint32), ("MinimumWorkingSetSize", ctypes.c_size_t),
                            ("MaximumWorkingSetSize", ctypes.c_size_t), ("ActiveProcessLimit", ctypes.c_uint32),
                            ("Affinity", ctypes.c_size_t), ("PriorityClass", ctypes.c_uint32), ("SchedulingClass", ctypes.c_uint32)]

            class EXT(ctypes.Structure):
                _fields_ = [("Basic", BASIC), ("Io", IO_COUNTERS), ("ProcessMemoryLimit", ctypes.c_size_t),
                            ("JobMemoryLimit", ctypes.c_size_t), ("PeakProcessMemoryUsed", ctypes.c_size_t),
                            ("PeakJobMemoryUsed", ctypes.c_size_t)]
            info = EXT()
            info.Basic.LimitFlags = 0x2000  # JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
            k32.SetInformationJobObject(self.h, 9, ctypes.byref(info), ctypes.sizeof(info))
        except Exception as e:  # never fatal: the startup sweep below is the fallback
            log("job object unavailable (%s); relying on the startup sweep" % e)
            self.h = None

    def add(self, pid):
        if not self.h:
            return
        hp = self.k32.OpenProcess(0x1F0FFF, False, pid)
        if hp:
            self.k32.AssignProcessToJobObject(self.h, hp)
            self.k32.CloseHandle(hp)


# ---- one backend = one sd-server process for one model -------------------------------------------
class Backend:
    def __init__(self, spec, port):
        self.spec, self.id, self.port = spec, spec["id"], port
        self.proc, self.state, self.error = None, "stopped", ""
        self.jobs = {}          # job id -> submit time (non-terminal jobs)
        self.inflight = 0       # synchronous requests (OpenAI / sdapi) in progress
        self.last_used, self.started_at = 0.0, 0.0
        self.cond = threading.Condition()

    @property
    def reserve_gb(self):
        return float(self.spec.get("vram_gb", 20)) + ROUTER.compute_gb

    def busy(self):
        now = time.time()
        for j, t in list(self.jobs.items()):   # a job we never saw finish expires after an hour
            if now - t > 3600:
                self.jobs.pop(j, None)
        return self.inflight > 0 or bool(self.jobs)


class Router:
    def __init__(self, a):
        self.a = a
        self.lock = threading.RLock()
        self.job = KillOnCloseJob()
        self.load_registry()
        self.job_map = {}       # job id -> backend id
        self.current = self.default

    def load_registry(self):
        with open(self.a.registry, encoding="utf-8") as f:
            reg = json.load(f)
        self.default = reg["default"]
        self.compute_gb = float(reg.get("compute_gb", 8))
        old = getattr(self, "backends", {})
        self.backends = {}
        for i, m in enumerate(reg["models"]):
            b = old.get(m["id"]) or Backend(m, self.a.backend_port + i)
            b.spec = m
            self.backends[m["id"]] = b

    def missing_files(self, spec):
        return [f for f in spec["files"].values() if not os.path.exists(os.path.join(self.a.models_dir, f))]

    def used_gb(self, exclude=None):
        return sum(b.reserve_gb for b in self.backends.values() if b.state in ("loading", "ready") and b.id != exclude)

    # -- lifecycle --
    def ensure(self, mid, wait=True, timeout=600):
        b = self.backends.get(mid)
        if b is None:
            raise KeyError(mid)
        with self.lock:
            if b.state == "ready" and b.proc and b.proc.poll() is not None:
                log("backend %s died (exit %s); restarting" % (mid, b.proc.returncode))
                b.state = "stopped"
            if b.state in ("stopped", "failed"):
                self._start(b)
        if wait:
            with b.cond:
                end = time.time() + timeout
                while b.state == "loading" and time.time() < end:
                    b.cond.wait(2)
            if b.state != "ready":
                raise RuntimeError("model %s is not ready (%s) %s" % (mid, b.state, b.error))
        b.last_used = time.time()
        return b

    def _start(self, b):
        miss = self.missing_files(b.spec)
        if miss:
            b.state, b.error = "failed", "missing files: " + ", ".join(miss)
            return
        # make room: evict idle backends, least recently used first
        need = b.reserve_gb
        if self.used_gb(exclude=b.id) + need > self.a.budget_gb:
            for o in sorted((o for o in self.backends.values() if o.state == "ready" and o.id != b.id),
                            key=lambda o: o.last_used):
                if self.used_gb(exclude=b.id) + need <= self.a.budget_gb:
                    break
                if o.busy():
                    continue
                log("evicting %s to make room for %s" % (o.id, b.id))
                self._stop(o)
        if self.used_gb(exclude=b.id) + need > self.a.budget_gb:
            busy = [o.id for o in self.backends.values() if o.state in ("loading", "ready") and o.id != b.id]
            b.state, b.error = "failed", ("not enough GPU budget (%.0f GB) while %s %s busy" %
                                          (self.a.budget_gb, ", ".join(busy), "is" if len(busy) == 1 else "are"))
            return
        args = [self.a.sd_server]
        for flag, fname in b.spec["files"].items():
            args += ["--" + flag, os.path.join(self.a.models_dir, fname)]
        args += ["--backend", "vulkan0", "--params-backend", "vulkan0", "--eager-load",
                 "--flash-attn", "auto", "--vae-tiling", "--max-vram", str(int(b.reserve_gb + 2)),
                 "--listen-ip", "127.0.0.1", "--listen-port", str(b.port)]
        if self.a.lora_dir and os.path.isdir(self.a.lora_dir):
            args += ["--lora-model-dir", self.a.lora_dir]
        args += b.spec.get("args", [])
        stamp = time.strftime("%Y%m%d-%H%M%S")
        base = os.path.join(self.a.log_dir, "images-%s-%s" % (b.id, stamp))
        self._prune_logs(b.id)
        b.state, b.error, b.started_at = "loading", "", time.time()
        out, err = open(base + ".out", "wb"), open(base + ".err", "wb")
        flags = 0x08000000 if os.name == "nt" else 0  # CREATE_NO_WINDOW
        b.proc = subprocess.Popen(args, stdout=out, stderr=err, stdin=subprocess.DEVNULL, creationflags=flags)
        self.job.add(b.proc.pid)
        log("starting %s on :%d (pid %d, reserve %.1f GB, budget used %.1f/%.0f GB)" %
            (b.id, b.port, b.proc.pid, b.reserve_gb, self.used_gb(), self.a.budget_gb))
        threading.Thread(target=self._wait_ready, args=(b,), daemon=True).start()

    def _wait_ready(self, b):
        ok = False
        while time.time() - b.started_at < 900:
            if b.proc.poll() is not None:
                b.error = "exited during load (code %s) -- see logs\\images-%s-*.err" % (b.proc.returncode, b.id)
                break
            try:
                c = http.client.HTTPConnection("127.0.0.1", b.port, timeout=5)
                c.request("GET", "/sdcpp/v1/capabilities")
                if c.getresponse().status == 200:
                    ok = True
                    break
            except OSError:
                pass
            time.sleep(1.5)
        with b.cond:
            b.state = "ready" if ok else "failed"
            if not ok and not b.error:
                b.error = "did not come up within 15 min"
            b.cond.notify_all()
        log("%s %s after %.0f s %s" % (b.id, b.state, time.time() - b.started_at, b.error))

    def _stop(self, b):
        if b.proc and b.proc.poll() is None:
            b.proc.kill()
            try:
                b.proc.wait(20)
            except Exception:
                pass
        b.state, b.proc = "stopped", None
        b.jobs.clear()
        for j in [j for j, m in self.job_map.items() if m == b.id]:
            self.job_map.pop(j, None)

    def stop(self, mid):
        with self.lock:
            b = self.backends[mid]
            if b.busy():
                raise RuntimeError("%s has work in progress" % mid)
            self._stop(b)

    def _prune_logs(self, mid, keep=6):
        try:
            fs = sorted((f for f in os.listdir(self.a.log_dir) if f.startswith("images-%s-" % mid) and f.endswith(".err")), reverse=True)
            for f in fs[keep:]:
                for ext in (".err", ".out"):
                    try:
                        os.remove(os.path.join(self.a.log_dir, f[:-4] + ext))
                    except OSError:
                        pass
        except OSError:
            pass

    def status(self):
        out = []
        for b in self.backends.values():
            s = {k: b.spec.get(k) for k in ("id", "label", "description", "licence", "nsfw", "vram_gb", "ui")}
            s.update(state=b.state, error=b.error, busy=b.busy(), port=b.port,
                     missing=self.missing_files(b.spec), last_used=b.last_used)
            out.append(s)
        return {"default": self.default, "current": self.current, "budget_gb": self.a.budget_gb,
                "used_gb": round(self.used_gb(), 1), "models": out}


def sweep_orphans(base, n):
    """Kill sd-server processes left on OUR backend ports by a previous router (e.g. hard-killed)."""
    if os.name != "nt":
        return
    rng = "|".join(str(base + i) for i in range(n))
    ps = ("Get-CimInstance Win32_Process -Filter \"Name='sd-server.exe'\" | Where-Object { $_.CommandLine -match "
          "'--listen-port (%s)\\b' } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force; $_.ProcessId }" % rng)
    try:
        r = subprocess.run(["powershell", "-NoProfile", "-Command", ps], capture_output=True, text=True, timeout=60)
        if r.stdout.strip():
            log("swept orphan backends: " + " ".join(r.stdout.split()))
    except Exception as e:
        log("orphan sweep skipped: %s" % e)


# ---- HTTP ----------------------------------------------------------------------------------------
class BackendGone(Exception):
    """The backend process died before/while we talked to it; safe to restart and retry once."""


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "images-router"

    def log_message(self, fmt, *args):
        pass

    # helpers

    def send_json(self, code, obj):
        data = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Access-Control-Allow-Origin", "*")
        self.end_headers()
        self.wfile.write(data)

    def err(self, code, msg):
        self.send_json(code, {"error": {"message": msg, "code": code}})

    def proxy(self, b, path, data=None, headers=None):
        hdrs = {k: v for k, v in self.headers.items() if k.lower() not in HOP and k.lower() != "host"}
        if headers:
            hdrs.update(headers)
        if data is not None:
            hdrs["Content-Length"] = str(len(data))
        c = http.client.HTTPConnection("127.0.0.1", b.port, timeout=ROUTER.a.upstream_timeout)
        try:
            c.request(self.command, path, body=data, headers=hdrs)
            r = c.getresponse()
            payload = r.read()
        except OSError as e:
            # Distinguish "the process is gone" (restart + retry is safe: nothing was accepted) from a
            # live backend that failed the request. A just-killed process can take a moment to report exit.
            for _ in range(15):
                if not b.proc or b.proc.poll() is not None:
                    b.state = "stopped"
                    raise BackendGone(b.id)
                time.sleep(0.2)
            self.err(502, "backend %s unreachable: %s" % (b.id, e))
            return None, None
        self.send_response(r.status)
        for k, v in r.getheaders():
            if k.lower() not in HOP:
                self.send_header(k, v)
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)
        return r.status, payload

    def model_for(self, mid):
        mid = mid or ROUTER.current
        if mid not in ROUTER.backends:
            raise KeyError(mid)
        return mid

    # verbs
    def do_OPTIONS(self):
        self.send_response(204)
        self.send_header("Access-Control-Allow-Origin", self.headers.get("Origin", "*"))
        self.send_header("Access-Control-Allow-Methods", "*")
        self.send_header("Access-Control-Allow-Headers", "*")
        self.send_header("Content-Length", "0")
        self.end_headers()

    def do_GET(self):
        self.route()

    def do_POST(self):
        self.route()

    def do_DELETE(self):
        self.route()

    def route(self):
        self._raw = None
        try:
            return self._route()
        except BackendGone as g:
            log("backend %s was gone; restarting it and retrying %s %s once" % (g, self.command, self.path))
            try:
                return self._route()
            except BackendGone:
                self.err(503, "backend %s keeps exiting -- see logs\\images-%s-*.err" % (g, g))

    def body(self):
        # Read once; a retry after BackendGone must reuse the same bytes.
        if self._raw is None:
            n = int(self.headers.get("Content-Length") or 0)
            self._raw = self.rfile.read(n) if n else b""
        return self._raw

    def _route(self):
        u = urllib.parse.urlsplit(self.path)
        p, q = u.path, urllib.parse.parse_qs(u.query)
        try:
            if p in ("/", "/index.html") and self.command == "GET":
                with open(ROUTER.a.ui, "rb") as f:
                    data = f.read()
                self.send_response(200)
                self.send_header("Content-Type", "text/html; charset=utf-8")
                self.send_header("Cache-Control", "no-store")
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                self.wfile.write(data)
                return
            if p == "/health":
                return self.send_json(200, {"status": "ok"})
            if p == "/studio/models" and self.command == "GET":
                return self.send_json(200, ROUTER.status())
            if p in ("/studio/models/load", "/studio/models/unload") and self.command == "POST":
                mid = json.loads(self.body() or b"{}").get("model")
                if mid not in ROUTER.backends:
                    return self.err(404, "unknown model %r" % mid)
                if p.endswith("/load"):
                    ROUTER.current = mid
                    ROUTER.ensure(mid, wait=False)
                else:
                    ROUTER.stop(mid)
                return self.send_json(202, ROUTER.status())
            if p == "/studio/reload-registry" and self.command == "POST":
                ROUTER.load_registry()
                return self.send_json(200, ROUTER.status())

            # ---- native API ----
            if p == "/sdcpp/v1/img_gen" and self.command == "POST":
                req = json.loads(self.body() or b"{}")
                mid = self.model_for(req.pop("model", None))
                b = ROUTER.ensure(mid)
                status, payload = self.proxy(b, p, json.dumps(req).encode(), {"Content-Type": "application/json"})
                if status and 200 <= status < 300:
                    jid = json.loads(payload).get("id")
                    if jid:
                        ROUTER.job_map[jid] = mid
                        b.jobs[jid] = time.time()
                return
            m = re.match(r"^/sdcpp/v1/jobs/([^/]+)(/cancel)?$", p)
            if m:
                jid = m.group(1)
                mid = ROUTER.job_map.get(jid)
                if not mid:
                    return self.err(410, "unknown or expired job %s (its model may have been unloaded)" % jid)
                b = ROUTER.backends[mid]
                if b.state != "ready":
                    return self.err(410, "job %s belonged to %s, which is %s" % (jid, mid, b.state))
                status, payload = self.proxy(b, p, self.body() if self.command == "POST" else None)
                if status == 200 and not m.group(2):
                    try:
                        if json.loads(payload).get("status") in TERMINAL:
                            b.jobs.pop(jid, None)
                    except ValueError:
                        pass
                elif status in (404, 410):
                    b.jobs.pop(jid, None)
                return
            if p.startswith("/sdcpp/v1/"):
                mid = self.model_for((q.get("model") or [None])[0] or self.headers.get("X-Model"))
                b = ROUTER.ensure(mid)
                self.proxy(b, self.path, self.body() if self.command == "POST" else None)
                return

            # ---- OpenAI ----
            if p == "/v1/models":
                data = [{"id": i, "object": "model", "owned_by": "local", "ready": b.state == "ready"}
                        for i, b in ROUTER.backends.items() if not ROUTER.missing_files(b.spec)]
                return self.send_json(200, {"object": "list", "data": data})
            if p == "/v1/images/generations" and self.command == "POST":
                raw = self.body()
                mid = self.model_for(json.loads(raw or b"{}").get("model"))
                return self.sync(mid, raw)
            if p == "/v1/images/edits" and self.command == "POST":
                raw = self.body()
                if b"<sd_cpp_extra_args>" in raw:
                    return self.err(400, "sd_cpp_extra_args is not accepted on /v1/images/edits: on this sd-server "
                                         "build it crashes the backend. Use /sdcpp/v1/img_gen with ref_images instead.")
                mm = re.search(rb'name="model"\r\n\r\n([^\r\n]+)\r\n', raw)
                mid = self.model_for(mm.group(1).decode() if mm else None)
                return self.sync(mid, raw)

            # ---- everything else (sdapi, built-in assets): current model ----
            b = ROUTER.ensure(ROUTER.current)
            self.sync(b.id, self.body() if self.command == "POST" else None, path=self.path)
        except KeyError as e:
            self.err(404, "unknown model %s" % e)
        except RuntimeError as e:
            self.err(503, str(e))
        except (ConnectionError, BrokenPipeError):
            pass
        except BackendGone:
            raise
        except Exception as e:  # never let one request take the router down
            log("error on %s %s: %r" % (self.command, self.path, e))
            try:
                self.err(500, "router error: %s" % e)
            except Exception:
                pass

    def sync(self, mid, raw, path=None):
        b = ROUTER.ensure(mid)
        b.inflight += 1
        try:
            self.proxy(b, path or self.path, raw)
        finally:
            b.inflight -= 1
            b.last_used = time.time()


ROUTER = None


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    root = os.path.dirname(os.path.dirname(here))
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--port", type=int, default=8080)
    ap.add_argument("--bind", default="0.0.0.0")
    ap.add_argument("--backend-port", type=int, default=18200, help="first backend port (127.0.0.1)")
    ap.add_argument("--registry", default=os.path.join(here, "image-models.json"))
    ap.add_argument("--ui", default=os.path.join(here, "images-ui.html"))
    ap.add_argument("--sd-server", default=os.path.join(root, "bin-sd-master-967-e47426c", "sd-server.exe"))
    ap.add_argument("--models-dir", default=os.environ.get("MODELS_DIR") or os.path.join(root, "models"))
    ap.add_argument("--lora-dir", default=os.path.join(root, "models", "loras"))
    ap.add_argument("--log-dir", default=os.path.join(root, "logs"))
    ap.add_argument("--budget-gb", type=float, default=88, help="GPU memory the router may reserve for backends")
    ap.add_argument("--upstream-timeout", type=float, default=3600)
    ap.add_argument("--preload", default="default", help="model to start at launch ('default', an id, or 'none')")
    a = ap.parse_args()
    os.makedirs(a.log_dir, exist_ok=True)
    global ROUTER
    ROUTER = Router(a)
    sweep_orphans(a.backend_port, len(ROUTER.backends))
    if a.preload != "none":
        mid = ROUTER.default if a.preload == "default" else a.preload
        ROUTER.current = mid
        ROUTER.ensure(mid, wait=False)
    srv = http.server.ThreadingHTTPServer((a.bind, a.port), Handler)
    srv.daemon_threads = True
    log("images-router on http://%s:%d  (%d models in registry, budget %.0f GB, sd-server %s)" %
        (a.bind, a.port, len(ROUTER.backends), a.budget_gb, a.sd_server))
    try:
        srv.serve_forever()
    finally:
        for b in ROUTER.backends.values():
            ROUTER._stop(b)


if __name__ == "__main__":
    main()
