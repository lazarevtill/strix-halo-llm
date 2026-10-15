#!/usr/bin/env python3
"""images-router.py -- one HTTP endpoint, many image and video models.

stable-diffusion.cpp's sd-server holds ONE model per process. This router is the image-side
equivalent of llama.cpp's router mode: it serves the Image Studio page, starts an sd-server
backend per model on demand (127.0.0.1), keeps several resident within a GPU-memory budget
(LRU eviction of idle, unpinned backends), and routes every request to the right one:

  GET  /                          Image Studio (ui/index.html + ui/studio.css + ui/studio.js, re-read per request,
                                  served under a strict Content-Security-Policy: no inline script or style)
  GET  /studio/models             registry + live state of every model
  POST /studio/models/load        {"model": id}  start a backend (async; poll /studio/models)
  POST /studio/models/unload      {"model": id}
  POST /studio/models/stop        {"model": id}  kill it even mid-job (sd-server cannot interrupt a running
                                  generation); it restarts on the next request
  POST /studio/models/pin         {"model": id, "pin": bool}  pinned models are never evicted, and load at start
  *    /sdcpp/v1/...              native async API; img_gen and vid_gen take an extra "model" field (and an optional
                                  "studio" object of UI metadata, kept with the saved output, never forwarded).
                                  Job ids are returned as "<model>~<backend id>": two backends number jobs alike.
  GET  /v1/models                 OpenAI-style list of the registry's models
  POST /v1/images/generations     OpenAI; routed by the "model" field
  POST /v1/images/edits           OpenAI multipart; routed by its "model" part. Requests that embed
                                  <sd_cpp_extra_args> are REJECTED: on sd-server master-967 that
                                  input aborts the whole backend process (measured 2026-10-15).
  *    /sdapi/v1/...              A1111-style API, current model
  GET  /studio/gallery            saved outputs, newest first (?offset=&limit=&model=&kind=)
  GET  /outputs/<day>/<file>      a saved output;  POST /studio/gallery/delete {"file": "<day>/<file>"}
  POST /studio/gallery/import     {"image": data URL, "meta": {...}}  (moves a browser's old local history in)
  GET  /health                    router liveness
  POST /studio/remote/inspect     {"url": huggingface.co | civitai.com | civitai.red link} -> what it is, its
                                  sd.cpp family, files, licence, what adding it would download
  POST /studio/remote/add         {"url", "file", "family", "id", "label"} -> a download job; when it finishes the
                                  model joins the LOCAL registry (<models>/image-models.local.json) or the LoRA dir
  GET  /studio/remote/jobs        download progress          POST /studio/remote/cancel {"id"}
  POST /studio/remote/remove      {"kind": "model"|"lora", "id", "delete_files"} (remote-added entries only)

Every finished job's images / video are written to <outputs>/<YYYY-MM-DD>/ with a .json sidecar of the
request (prompt, seed, sampler...), whether or not a browser was still watching.

Security (no auth; LAN): no CORS grant, so other web pages cannot read responses; a cross-origin POST is
refused (CSRF); the Host header must be an IP, a LAN name or --allow-host (DNS rebinding); bodies are
capped; LoRA paths are reduced to a file name inside the LoRA dir.

Stdlib only. Run with `python -I`. Backends run inside a Windows job object, so they die with the
router instead of lingering as orphans that hold GPU memory. A monitor thread kills a backend that
stops answering (a frozen process never exits, so nothing else would notice).
"""
import argparse
import base64
import ctypes
import http.client
import http.server
import importlib.util
import ipaddress
import json
import os
import re
import socket
import subprocess
import sys
import threading
import time
import urllib.parse

TERMINAL = {"completed", "failed", "cancelled"}
HOP = {"connection", "keep-alive", "proxy-authenticate", "proxy-authorization", "te", "trailers",
       "transfer-encoding", "upgrade", "content-length", "content-encoding", "expect"}
MAX_BODY = 192 << 20          # 3 reference images at 2048^2 as PNG data URLs fit with room to spare
SEP = "~"                     # namespaced job id: "<model>~<backend job id>"
LAN_SUFFIXES = (".local", ".lan", ".home", ".internal", ".home.arpa", ".localdomain")
VIDEO_FAMILIES = {"wan22-5b": {"label": "Wan 2.2 TI2V 5B", "group": "wan22-5b"},
                  "wan22-a14b": {"label": "Wan 2.2 A14B", "group": "wan22-a14b"}}
UI_TYPES = {"css": "text/css; charset=utf-8", "js": "text/javascript; charset=utf-8", "svg": "image/svg+xml",
            "png": "image/png", "ico": "image/x-icon", "html": "text/html; charset=utf-8"}
CSP = ("default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' data: blob:; media-src 'self' data: blob:; "
       "connect-src 'self'; worker-src 'self' blob:; object-src 'none'; base-uri 'none'; frame-ancestors 'none'; form-action 'none'")


def log(msg):
    sys.stdout.write("%s  %s\n" % (time.strftime("%Y-%m-%dT%H:%M:%S"), msg))
    sys.stdout.flush()


def _load_sibling(name):
    # `python -I` keeps this directory off sys.path; load the sibling module by its path instead
    spec = importlib.util.spec_from_file_location(name, os.path.join(os.path.dirname(os.path.abspath(__file__)), name + ".py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


REMOTE = _load_sibling("images_remote")


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
        self.jobs = {}          # backend job id -> submit time (non-terminal jobs)
        self.inflight = 0       # requests between ensure() and their answer (claims): blocks eviction
        self.last_used, self.started_at = 0.0, 0.0
        self.strikes = 0        # consecutive failed health checks
        self.log_base = None
        self.lk = threading.Lock()
        self.cond = threading.Condition()

    @property
    def reserve_gb(self):
        # compute headroom: the registry default (sized for ~1 MP images) unless the model sets its own --
        # video activations (dozens of frames) need far more than an image does
        return float(self.spec.get("vram_gb", 20)) + float(self.spec.get("compute_gb", ROUTER.compute_gb))

    def claim(self):
        with self.lk:
            self.inflight += 1

    def release(self):
        with self.lk:
            self.inflight = max(0, self.inflight - 1)
        self.last_used = time.time()

    def busy(self):
        with self.lk:
            return self.inflight > 0 or bool(self.jobs)

    def alive(self):
        return bool(self.proc) and self.proc.poll() is None


class Router:
    def __init__(self, a):
        self.a = a
        self.lock = threading.RLock()
        self.job = KillOnCloseJob()
        self.job_map = {}       # namespaced job id -> backend id
        self.pins = set()
        # must exist BEFORE any backend starts: _start only passes --lora-model-dir for an existing dir,
        # and sd-server then rescans it live (a LoRA dropped in later shows up without a restart)
        os.makedirs(a.lora_dir, exist_ok=True)
        self.outputs = Outputs(a.outputs_dir) if a.outputs_dir else None
        self.remote = None
        self.remote = REMOTE.Remote(a.models_dir, a.lora_dir, a.local_registry, log, self.load_registry,
                                    ids=lambda: set(self.backends))
        self.load_registry()
        self.current = self.default
        threading.Thread(target=self._monitor, daemon=True).start()

    def load_registry(self):
        with self.lock:
            self._load_registry()

    def _load_registry(self):
        with open(self.a.registry, encoding="utf-8") as f:
            reg = json.load(f)
        tracked = {m["id"] for m in reg["models"]}
        local = self.remote.read() if self.remote else {"models": []}
        for m in local["models"]:
            if m.get("id") in tracked:
                log("local model %s ignored: that id belongs to the tracked registry" % m.get("id"))
                continue
            m["user"] = True
            reg["models"].append(m)
        self.pins = set(local.get("pins") or [])
        self.default = reg["default"]
        self.compute_gb = float(reg.get("compute_gb", 8))
        old = getattr(self, "backends", {})
        ids = {m["id"] for m in reg["models"]}
        for b in old.values():
            if b.id not in ids and b.alive():
                log("%s left the registry; stopping its backend" % b.id)
                self._stop(b)
        # A kept backend keeps its port (it may be running on it); a NEW model gets the lowest port no kept
        # backend holds. Numbering by list position instead handed a model inserted mid-list the port of a
        # live backend further down, so its health check and requests would have reached THAT model.
        taken = {old[m["id"]].port for m in reg["models"] if m["id"] in old}
        fresh = {}
        for m in reg["models"]:
            b = old.get(m["id"])
            if b is None:
                port = self.a.backend_port
                while port in taken:
                    port += 1
                taken.add(port)
                b = Backend(m, port)
            b.spec = m
            fresh[m["id"]] = b
        self.backends = fresh       # one assignment: a concurrent status() never sees a half-built dict

    def set_pin(self, mid, on):
        with self.lock:
            d = self.remote.read()
            pins = set(d.get("pins") or [])
            (pins.add if on else pins.discard)(mid)
            d["pins"] = sorted(pins)
            self.remote.write(d)
            self.pins = pins

    def missing_files(self, spec):
        return [f for f in spec["files"].values() if not os.path.exists(os.path.join(self.a.models_dir, f))]

    def used_gb(self, exclude=None):
        return sum(b.reserve_gb for b in list(self.backends.values()) if b.state in ("loading", "ready") and b.id != exclude)

    def referenced_files(self, exclude=None):
        return {f for b in list(self.backends.values()) if b.id != exclude for f in b.spec.get("files", {}).values()}

    # -- lifecycle --
    def ensure(self, mid, wait=True, timeout=900, claim=False):
        """Start the model if needed. claim=True marks it in use ATOMICALLY with the ready check, so an
        eviction cannot slip in between this call and the request it guards (release() when done)."""
        b = self.backends.get(mid)
        if b is None:
            raise KeyError(mid)
        end = time.time() + timeout
        while True:
            with self.lock:
                b = self.backends.get(mid) or b
                if b.state == "ready" and not b.alive():
                    log("backend %s died (exit %s); restarting" % (mid, b.proc.returncode if b.proc else "?"))
                    self._stop(b)
                if b.state in ("stopped", "failed"):
                    self._start(b)
                if b.state == "ready":
                    if claim:
                        b.claim()
                    b.last_used = time.time()
                    return b
                if b.state == "failed":
                    raise RuntimeError("model %s failed to start: %s" % (mid, b.error))
            if not wait:
                return b
            with b.cond:
                while b.state == "loading" and time.time() < end:
                    b.cond.wait(2)
            if b.state == "loading":
                raise RuntimeError("model %s is still loading after %d s" % (mid, timeout))

    def _start(self, b):
        miss = self.missing_files(b.spec)
        if miss:
            b.state, b.error = "failed", "missing files: " + ", ".join(miss)
            return
        # make room: evict idle, unpinned backends, least recently used first
        need = b.reserve_gb
        if self.used_gb(exclude=b.id) + need > self.a.budget_gb:
            for o in sorted((o for o in self.backends.values() if o.state == "ready" and o.id != b.id),
                            key=lambda o: (o.id in self.pins, o.last_used)):
                if self.used_gb(exclude=b.id) + need <= self.a.budget_gb:
                    break
                if o.busy() or o.id in self.pins:
                    continue
                log("evicting %s to make room for %s" % (o.id, b.id))
                self._stop(o)
        if self.used_gb(exclude=b.id) + need > self.a.budget_gb:
            held = [o.id for o in self.backends.values() if o.state in ("loading", "ready") and o.id != b.id]
            b.state, b.error = "failed", ("not enough GPU budget (%.0f GB): %s %s busy or pinned -- unload one" %
                                          (self.a.budget_gb, ", ".join(held), "is" if len(held) == 1 else "are"))
            return
        if _port_in_use(b.port):    # something else (an orphan, another app) listens there: take a free port
            used = {o.port for o in self.backends.values() if o is not b}
            port = self.a.backend_port
            while port in used or _port_in_use(port):
                port += 1
            log("port %d is in use by something else; %s moves to %d" % (b.port, b.id, port))
            b.port = port
        # a model may need a newer engine than the rest (e.g. FLUX.3 arrived one sd.cpp commit after master-967):
        # "engine" is a path relative to the repo root, so only that model moves to the new build
        exe = os.path.join(self.a.root, b.spec["engine"]) if b.spec.get("engine") else self.a.sd_server
        if not os.path.isfile(exe):
            b.state, b.error = "failed", "engine not found: %s (fetch-llamacpp-style: unzip the sd.cpp release there)" % exe
            return
        args = [exe]
        for flag, fname in b.spec["files"].items():
            args += ["--" + flag, os.path.join(self.a.models_dir, fname)]
        args += ["--backend", "vulkan0", "--params-backend", "vulkan0", "--eager-load",
                 "--flash-attn", "auto", "--vae-tiling", "--max-vram", str(int(b.reserve_gb + 2)),
                 "--listen-ip", "127.0.0.1", "--listen-port", str(b.port)]
        if self.a.lora_dir and os.path.isdir(self.a.lora_dir):
            args += ["--lora-model-dir", self.a.lora_dir]
        args += b.spec.get("args", [])     # later flags win: a model may override the defaults above
        stamp = time.strftime("%Y%m%d-%H%M%S")
        base = os.path.join(self.a.log_dir, "images-%s-%s" % (b.id, stamp))
        b.log_base = base
        self._prune_logs(b.id)
        b.state, b.error, b.started_at, b.strikes = "loading", "", time.time(), 0
        flags = 0x08000000 if os.name == "nt" else 0  # CREATE_NO_WINDOW
        with open(base + ".out", "wb") as out, open(base + ".err", "wb") as err:   # the child keeps its own handles
            b.proc = subprocess.Popen(args, stdout=out, stderr=err, stdin=subprocess.DEVNULL, creationflags=flags)
        self.job.add(b.proc.pid)
        log("starting %s on :%d (pid %d, reserve %.1f GB, budget used %.1f/%.0f GB)" %
            (b.id, b.port, b.proc.pid, b.reserve_gb, self.used_gb(), self.a.budget_gb))
        threading.Thread(target=self._wait_ready, args=(b, b.proc), daemon=True).start()

    def _wait_ready(self, b, proc):
        ok = False
        while time.time() - b.started_at < 900:
            if proc.poll() is not None:
                b.error = "exited during load (code %s) -- see logs\\images-%s-*.err" % (proc.returncode, b.id)
                break
            if b.proc is not proc:          # stopped/restarted meanwhile
                return
            try:
                c = http.client.HTTPConnection("127.0.0.1", b.port, timeout=5)
                c.request("GET", "/sdcpp/v1/capabilities")
                if c.getresponse().status == 200:
                    ok = True
                    break
            except OSError:
                pass
            time.sleep(1.5)
        if ok:
            self._measure(b)
        with b.cond:
            if b.proc is proc:
                b.state = "ready" if ok else "failed"
                if not ok and not b.error:
                    b.error = "did not come up within 15 min"
            b.cond.notify_all()
        log("%s %s after %.0f s %s" % (b.id, b.state, time.time() - b.started_at, b.error))

    def _measure(self, b):
        """Replace a model's reserve with what sd-server reports it loaded (persisted for remote-added models)."""
        try:
            with open(b.log_base + ".out", encoding="utf-8", errors="replace") as f:
                m = re.search(r"total params memory size = ([\d.]+)MB", f.read())
            if not m:
                return
            gb = round(float(m.group(1)) / 1000, 1)
            if b.spec.get("user") and not b.spec.get("vram_measured"):
                b.spec["vram_gb"], b.spec["vram_measured"] = gb, True
                self.remote.update_model(b.id, vram_gb=gb, vram_measured=True)
                log("%s: measured %.1f GB of weights; saved to the local registry" % (b.id, gb))
            elif abs(gb - float(b.spec.get("vram_gb", 0))) > 0.5:
                log("%s: loaded %.1f GB of weights but the registry says %s GB" % (b.id, gb, b.spec.get("vram_gb")))
        except (OSError, ValueError, AttributeError) as e:
            log("%s: could not read the weight size from its log (%s)" % (b.id, e))

    def _stop(self, b, state="stopped", error=""):
        proc = b.proc
        if proc and proc.poll() is None:
            proc.kill()
            try:
                proc.wait(20)
            except Exception:
                pass
        with b.cond:
            b.state, b.proc, b.error = state, None, error
            b.cond.notify_all()
        with b.lk:
            b.jobs.clear()
        with self.lock:
            for j in [j for j, m in list(self.job_map.items()) if m == b.id]:
                self.job_map.pop(j, None)

    def stop(self, mid, force=False):
        with self.lock:
            b = self.backends[mid]
            if b.busy() and not force:
                raise RuntimeError("%s has work in progress" % mid)
            if force and b.busy():
                log("%s stopped by request with work in progress" % mid)
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

    # -- monitor: freezes, crashes, jobs no client polled to the end --
    def _monitor(self):
        while True:
            time.sleep(20)
            for b in list(self.backends.values()):
                try:
                    self._check(b)
                except Exception as e:  # noqa: BLE001 -- the monitor must never die
                    log("monitor: %s: %r" % (b.id, e))

    def _check(self, b):
        if b.state != "ready":
            return
        if not b.alive():
            log("%s exited (code %s); it restarts on the next request" % (b.id, b.proc.returncode if b.proc else "?"))
            self._stop(b)
            return
        try:
            c = http.client.HTTPConnection("127.0.0.1", b.port, timeout=10)
            c.request("GET", "/sdcpp/v1/capabilities")      # answers in ms even mid-generation (measured)
            c.getresponse().read()
            b.strikes = 0
        except OSError:
            b.strikes += 1
            log("%s did not answer a health check (%d/3)" % (b.id, b.strikes))
            if b.strikes >= 3:
                log("%s is frozen; killing it (it restarts on the next request)" % b.id)
                self._stop(b, "failed", "stopped answering for a minute (frozen) -- killed; it restarts on the next request")
            return
        # reap jobs nobody polled to the end (closed tab): they pin the model against eviction; save their output
        now = time.time()
        with b.lk:
            stale = [j for j, t in b.jobs.items() if now - t > 30]
        for raw in stale:
            try:
                c = http.client.HTTPConnection("127.0.0.1", b.port, timeout=30)
                c.request("GET", "/sdcpp/v1/jobs/%s" % raw)
                r = c.getresponse()
                data = r.read()
                if r.status in (404, 410):
                    gone = True
                else:
                    js = json.loads(data)
                    gone = js.get("status") in TERMINAL
                    if gone and self.outputs:
                        self.outputs.save_job(b.id + SEP + raw, js)
                if gone:
                    with b.lk:
                        b.jobs.pop(raw, None)
            except (OSError, ValueError):
                pass

    def status(self):
        out = []
        for b in list(self.backends.values()):
            s = {k: b.spec.get(k) for k in ("id", "label", "description", "licence", "nsfw", "vram_gb", "ui")}
            s["kind"] = b.spec.get("kind", "image")
            s.update(state=b.state, error=b.error, busy=b.busy(), port=b.port, user=bool(b.spec.get("user")),
                     family=b.spec.get("family"), pinned=b.id in self.pins, missing=self.missing_files(b.spec),
                     files=list(b.spec.get("files", {}).values()),
                     last_used=b.last_used)
            out.append(s)
        return {"default": self.default, "current": self.current, "budget_gb": self.a.budget_gb,
                "used_gb": round(self.used_gb(), 1), "models": out, "loras": self.remote.read()["loras"],
                "tokens": REMOTE.token_status(),
                "families": dict({k: {"label": v["label"], "group": v["group"]} for k, v in REMOTE.FAMILIES.items()}, **VIDEO_FAMILIES),
                "downloads": sum(1 for j in self.remote.views() if j["state"] in ("queued", "downloading", "verifying"))}


def _port_in_use(port):
    try:
        with socket.create_connection(("127.0.0.1", port), timeout=0.3):
            return True
    except OSError:
        return False


def sweep_orphans(base, n):
    """Kill sd-server processes left on OUR backend ports by a previous router (e.g. hard-killed)."""
    if os.name != "nt":
        return
    rng = "|".join(str(base + i) for i in range(n + 16))
    ps = ("Get-CimInstance Win32_Process -Filter \"Name='sd-server.exe'\" | Where-Object { $_.CommandLine -match "
          "'--listen-port (%s)\\b' } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force; $_.ProcessId }" % rng)
    try:
        r = subprocess.run(["powershell", "-NoProfile", "-Command", ps], capture_output=True, text=True, timeout=60)
        if r.stdout.strip():
            log("swept orphan backends: " + " ".join(r.stdout.split()))
    except Exception as e:
        log("orphan sweep skipped: %s" % e)


# ---- saved outputs ---------------------------------------------------------------------------------
class Outputs:
    """Every finished image/video goes to <root>/<YYYY-MM-DD>/ with a .json sidecar of its request."""
    EXT = {"png": "png", "jpeg": "jpg", "jpg": "jpg", "webp": "webp", "webm": "webm", "avi": "avi"}
    MIME = {"png": "image/png", "jpg": "image/jpeg", "webp": "image/webp", "webm": "video/webm", "avi": "video/x-msvideo"}

    def __init__(self, root):
        self.root = root
        os.makedirs(root, exist_ok=True)
        self.lock = threading.Lock()
        self.meta, self.saved = {}, set()

    def remember(self, nsid, mid, req, studio):
        m = {k: v for k, v in req.items() if k not in ("init_image", "end_image", "ref_images", "mask_image", "control_image",
                                                     "control_frames", "extra_images")}
        if req.get("ref_images"):
            mode = "edit"
        elif req.get("mask_image"):
            mode = "inpaint"
        elif req.get("init_image"):
            mode = "i2v" if "video_frames" in req else "img2img"
        else:
            mode = "t2v" if "video_frames" in req else "gen"
        m.update(model=mid, mode=mode, studio=studio or {}, submitted=time.strftime("%Y-%m-%dT%H:%M:%S"))
        with self.lock:
            self.meta[nsid] = m
            while len(self.meta) > 500:
                self.meta.pop(next(iter(self.meta)))

    def save_job(self, nsid, js):
        res = js.get("result") or {}
        if js.get("status") != "completed" or not res:
            return
        with self.lock:
            if nsid in self.saved:
                return
            self.saved.add(nsid)
            if len(self.saved) > 2000:
                self.saved = set(list(self.saved)[-1000:])
            meta = dict(self.meta.get(nsid) or {"model": nsid.split(SEP)[0], "mode": "?"})
        blobs = []
        if res.get("images"):
            fmt = self.EXT.get(res.get("output_format") or "png", "png")
            blobs = [(im.get("b64_json"), fmt) for im in res["images"]]
        elif res.get("b64_json"):
            fmt = self.EXT.get(res.get("output_format") or "webm", "webm")
            blobs = [(res["b64_json"], fmt)]
            meta.update(fps=res.get("fps"), frame_count=res.get("frame_count"))
        self._write(meta, blobs, nsid)

    def save_sync(self, mid, req, payload):
        try:
            data = json.loads(payload).get("data") or []
        except ValueError:
            return
        fmt = self.EXT.get(str(req.get("output_format") or "png"), "png")
        meta = {"model": mid, "mode": "openai", "prompt": req.get("prompt"), "size": req.get("size"),
                "submitted": time.strftime("%Y-%m-%dT%H:%M:%S")}
        self._write(meta, [(d.get("b64_json"), fmt) for d in data if d.get("b64_json")], None)

    def _write(self, meta, blobs, nsid):
        day = time.strftime("%Y-%m-%d")
        folder = os.path.join(self.root, day)
        os.makedirs(folder, exist_ok=True)
        stem = "%s-%s-%s" % (time.strftime("%H%M%S"), re.sub(r"[^a-z0-9.-]+", "-", str(meta.get("model", "x")).lower())[:40],
                             meta.get("seed", "x") if meta.get("seed") is not None else "x")
        for i, (b64, ext) in enumerate(blobs):
            if not b64:
                continue
            name = "%s-%d.%s" % (stem, i, ext)
            try:
                with open(os.path.join(folder, name), "wb") as f:
                    f.write(base64.b64decode(b64))
                m = dict(meta, file="%s/%s" % (day, name), index=i, job=nsid,
                         seed=(meta.get("seed") + i) if isinstance(meta.get("seed"), int) else meta.get("seed"))
                with open(os.path.join(folder, name + ".json"), "w", encoding="utf-8") as f:
                    json.dump(m, f, ensure_ascii=False)
            except (OSError, ValueError) as e:
                log("could not save output %s: %s" % (name, e))

    def safe(self, rel):
        rel = (rel or "").replace("\\", "/").lstrip("/")
        if not re.match(r"^\d{4}-\d{2}-\d{2}/[A-Za-z0-9._-]+$", rel):
            return None
        path = os.path.normpath(os.path.join(self.root, rel))
        return path if path.startswith(os.path.normpath(self.root) + os.sep) else None

    def listing(self, offset=0, limit=60, model=None, kind=None):
        items = []
        try:
            days = sorted((d for d in os.listdir(self.root) if re.match(r"^\d{4}-\d{2}-\d{2}$", d)), reverse=True)
        except OSError:
            days = []
        for d in days:
            try:
                names = sorted((n for n in os.listdir(os.path.join(self.root, d)) if n.endswith(".json")), reverse=True)
            except OSError:
                continue
            for n in names:
                try:
                    with open(os.path.join(self.root, d, n), encoding="utf-8") as f:
                        m = json.load(f)
                except (OSError, ValueError):
                    continue
                if not os.path.exists(os.path.join(self.root, d, n[:-5])):
                    continue
                is_video = m.get("file", "").rsplit(".", 1)[-1] in ("webm", "avi") or bool(m.get("frame_count"))
                if model and m.get("model") != model:
                    continue
                if kind and (kind == "video") != is_video:
                    continue
                m["url"] = "/outputs/" + m["file"]
                m["video"] = is_video
                items.append(m)
        return {"total": len(items), "items": items[offset:offset + limit]}


# ---- HTTP ----------------------------------------------------------------------------------------
class BackendGone(Exception):
    """The backend process died before we could hand it the request; safe to restart and retry once."""


class Server(http.server.ThreadingHTTPServer):
    daemon_threads = True

    def handle_error(self, request, client_address):
        # A browser that reloads or closes mid-request resets its socket: routine, not worth a traceback.
        if isinstance(sys.exc_info()[1], (ConnectionError, BrokenPipeError)):
            return
        super().handle_error(request, client_address)


def _ns(mid, raw):
    return "%s%s%s" % (mid, SEP, raw)


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
        self.end_headers()
        self.wfile.write(data)

    def err(self, code, msg):
        self.send_json(code, {"error": {"message": msg, "code": code}})

    def send_bytes(self, code, data, ctype, cache=None, csp=False):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        if csp:
            self.send_header("Content-Security-Policy", CSP)
            self.send_header("X-Content-Type-Options", "nosniff")
            self.send_header("Referrer-Policy", "no-referrer")
        self.send_header("Content-Length", str(len(data)))
        if cache:
            self.send_header("Cache-Control", cache)
        self.end_headers()
        self.wfile.write(data)

    def proxy(self, b, path, data=None, headers=None, rewrite=None):
        """Forward to the backend. A failure BEFORE the request reached a dead backend is retryable
        (BackendGone); a crash WHILE it handled the request is not -- the same input may crash it again."""
        hdrs = {k: v for k, v in self.headers.items() if k.lower() not in HOP and k.lower() not in ("host", "origin", "referer")}
        if headers:
            hdrs.update(headers)
        if data is not None:
            hdrs["Content-Length"] = str(len(data))
        c = http.client.HTTPConnection("127.0.0.1", b.port, timeout=ROUTER.a.upstream_timeout)
        try:
            c.request(self.command, path, body=data, headers=hdrs)
        except OSError as e:
            for _ in range(15):
                if not b.alive():
                    with ROUTER.lock:
                        ROUTER._stop(b)
                    raise BackendGone(b.id)
                time.sleep(0.2)
            self.err(502, "backend %s unreachable: %s" % (b.id, e))
            return None, None
        try:
            r = c.getresponse()
            payload = r.read()
        except OSError as e:
            time.sleep(1)
            if not b.alive():
                with ROUTER.lock:
                    ROUTER._stop(b)
                self.err(502, "the %s backend crashed while handling this request (not retried: the same input may crash "
                              "it again) -- see logs\\images-%s-*.err" % (b.id, b.id))
            else:
                self.err(502, "backend %s failed: %s" % (b.id, e))
            return None, None
        if rewrite:
            payload = rewrite(r.status, payload)
        self.send_response(r.status)
        for k, v in r.getheaders():
            kl = k.lower()
            if kl not in HOP and not kl.startswith("access-control-"):
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

    # -- guards --
    def host_ok(self):
        host = (self.headers.get("Host") or "").strip().lower()
        if not host:
            return True                 # HTTP/1.0-style client without Host: not a browser
        name = host.rsplit(":", 1)[0].strip("[]") if not host.startswith("[") else host[1:host.index("]")]
        try:
            ipaddress.ip_address(name)
            return True
        except ValueError:
            pass
        if name in ROUTER.allow_hosts or "." not in name or name.endswith(LAN_SUFFIXES):
            return True
        return False

    def origin_ok(self):
        """A browser POST from another site carries its Origin: refuse it (no CSRF from a page you visit)."""
        o = self.headers.get("Origin")
        if not o or o == "null" and self.command == "GET":
            return True
        try:
            return urllib.parse.urlsplit(o).netloc.lower() == (self.headers.get("Host") or "").lower()
        except ValueError:
            return False

    # verbs
    def do_OPTIONS(self):
        # No CORS grant: Image Studio is same-origin; another site's preflight gets nothing to work with.
        self.send_response(204)
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
        if not self.host_ok():
            return self.err(403, "Host %r is not allowed (DNS-rebinding guard). Use the box's IP or LAN name, or start "
                                 "the router with --allow-host %s (or set IMAGES_ALLOW_HOSTS)." %
                            (self.headers.get("Host"), (self.headers.get("Host") or "").rsplit(":", 1)[0]))
        if self.command != "GET" and not self.origin_ok():
            return self.err(403, "cross-site request refused")
        try:
            n = int(self.headers.get("Content-Length") or 0)
        except ValueError:
            n = 0
        if n > MAX_BODY:
            return self.err(413, "request body over %d MB" % (MAX_BODY >> 20))
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
                with open(os.path.join(ROUTER.a.ui_dir, "index.html"), "rb") as f:
                    return self.send_bytes(200, f.read(), "text/html; charset=utf-8", "no-store", csp=True)
            mu = re.match(r"^/ui/([a-z0-9][a-z0-9._-]*)\.(css|js|svg|png|ico)$", p)
            if mu and self.command == "GET":
                path = os.path.join(ROUTER.a.ui_dir, "%s.%s" % mu.groups())
                if not os.path.isfile(path):
                    return self.err(404, "no such file")
                with open(path, "rb") as f:
                    return self.send_bytes(200, f.read(), UI_TYPES[mu.group(2)], "no-cache", csp=True)
            if p == "/health":
                return self.send_json(200, {"status": "ok"})
            if p.startswith("/studio/"):
                return self.studio(p, q)
            if p.startswith("/outputs/") and self.command == "GET" and ROUTER.outputs:
                path = ROUTER.outputs.safe(urllib.parse.unquote(p[len("/outputs/"):]))
                if not path or not os.path.isfile(path):
                    return self.err(404, "no such output")
                with open(path, "rb") as f:
                    ext = path.rsplit(".", 1)[-1].lower()
                    return self.send_bytes(200, f.read(), Outputs.MIME.get(ext, "application/octet-stream"),
                                           "public, max-age=31536000, immutable")

            # ---- native API ----
            if p in ("/sdcpp/v1/img_gen", "/sdcpp/v1/vid_gen") and self.command == "POST":
                return self.submit(p)
            m = re.match(r"^/sdcpp/v1/jobs/([^/]+?)(/cancel)?$", p)
            if m:
                return self.job(m.group(1), bool(m.group(2)))
            if p.startswith("/sdcpp/v1/"):
                mid = self.model_for((q.get("model") or [None])[0] or self.headers.get("X-Model"))
                if self.command == "GET" and ROUTER.backends[mid].state != "ready":
                    return self.err(409, "model %s is not loaded (GETs never start a model; POST /studio/models/load)" % mid)
                b = ROUTER.ensure(mid, claim=True)
                try:
                    self.proxy(b, self.path, self.body() if self.command == "POST" else None)
                finally:
                    b.release()
                return

            # ---- OpenAI ----
            if p == "/v1/models":
                data = [{"id": i, "object": "model", "owned_by": "local", "ready": b.state == "ready",
                         "kind": b.spec.get("kind", "image")}
                        for i, b in ROUTER.backends.items() if not ROUTER.missing_files(b.spec)]
                return self.send_json(200, {"object": "list", "data": data})
            if p == "/v1/images/generations" and self.command == "POST":
                raw = self.body()
                req = json.loads(raw or b"{}")
                mid = self.model_for(req.get("model"))
                return self.sync(mid, raw, save=req)
            if p == "/v1/images/edits" and self.command == "POST":
                raw = self.body()
                if b"<sd_cpp_extra_args>" in raw:
                    return self.err(400, "sd_cpp_extra_args is not accepted on /v1/images/edits: on this sd-server "
                                         "build it crashes the backend. Use /sdcpp/v1/img_gen with ref_images instead.")
                mm = re.search(rb'name="model"\r\n\r\n([^\r\n]+)\r\n', raw)
                pm = re.search(rb'name="prompt"\r\n\r\n([^\r\n]*)\r\n', raw)
                mid = self.model_for(mm.group(1).decode() if mm else None)
                return self.sync(mid, raw, save={"prompt": pm.group(1).decode("utf-8", "replace") if pm else None})

            # ---- A1111-style API: the current model ----
            if p.startswith("/sdapi/"):
                b = ROUTER.ensure(ROUTER.current)
                return self.sync(b.id, self.body() if self.command == "POST" else None, path=self.path)
            return self.err(404, "not found")
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

    # -- native jobs --
    def submit(self, p):
        req = json.loads(self.body() or b"{}")
        mid = self.model_for(req.pop("model", None))
        studio = req.pop("studio", None)                  # UI metadata: saved with the output, not forwarded
        for lo in req.get("lora") or []:                  # a LoRA is a file NAME inside the LoRA dir, nothing else
            if isinstance(lo, dict) and lo.get("path"):
                lo["path"] = os.path.basename(str(lo["path"]).replace("\\", "/"))
        b = ROUTER.ensure(mid, claim=True)
        try:
            def rewrite(status, payload):
                if not 200 <= status < 300:
                    return payload
                try:
                    js = json.loads(payload)
                except ValueError:
                    return payload
                raw = js.get("id")
                if raw:
                    nsid = _ns(mid, raw)
                    with ROUTER.lock:
                        ROUTER.job_map[nsid] = mid
                    with b.lk:
                        b.jobs[raw] = time.time()
                    if ROUTER.outputs:
                        ROUTER.outputs.remember(nsid, mid, req, studio)
                    js["id"] = nsid
                    if js.get("poll_url"):
                        js["poll_url"] = "/sdcpp/v1/jobs/%s" % nsid
                return json.dumps(js).encode()
            self.proxy(b, p, json.dumps(req).encode(), {"Content-Type": "application/json"}, rewrite=rewrite)
        finally:
            b.release()

    def job(self, nsid, cancel):
        if SEP in nsid:
            mid, raw = nsid.split(SEP, 1)
        else:                                   # a bare backend id from an older client
            raw = nsid
            mid = next((m for j, m in list(ROUTER.job_map.items()) if j.split(SEP, 1)[-1] == raw), None)
            nsid = _ns(mid, raw) if mid else nsid
        if not mid or mid not in ROUTER.backends:
            return self.err(410, "unknown or expired job %s (its model may have been unloaded)" % nsid)
        b = ROUTER.backends[mid]
        if b.state != "ready":
            return self.err(410, "job %s belonged to %s, which is %s" % (nsid, mid, b.state))

        def rewrite(status, payload):
            if status in (404, 410):
                with b.lk:
                    b.jobs.pop(raw, None)
                return payload
            if status != 200 or cancel:
                return payload
            try:
                js = json.loads(payload)
            except ValueError:
                return payload
            if js.get("status") in TERMINAL:
                with b.lk:
                    b.jobs.pop(raw, None)
                if ROUTER.outputs:
                    ROUTER.outputs.save_job(nsid, js)
            if js.get("id") == raw:
                js["id"] = nsid
            return json.dumps(js).encode()
        b.claim()
        try:
            self.proxy(b, "/sdcpp/v1/jobs/%s%s" % (raw, "/cancel" if cancel else ""),
                       self.body() if self.command == "POST" else None, rewrite=rewrite)
        finally:
            b.release()

    # -- /studio --
    def studio(self, p, q):
        if p == "/studio/models" and self.command == "GET":
            return self.send_json(200, ROUTER.status())
        if p == "/studio/gallery" and self.command == "GET":
            if not ROUTER.outputs:
                return self.send_json(200, {"total": 0, "items": []})
            g = lambda k, d=None: (q.get(k) or [d])[0]
            return self.send_json(200, ROUTER.outputs.listing(int(g("offset", 0)), min(200, int(g("limit", 60))),
                                                              g("model"), g("kind")))
        if p == "/studio/remote/jobs" and self.command == "GET":
            return self.remote_api(p, {})
        if self.command != "POST":
            return self.err(405, "POST only")
        req = json.loads(self.body() or b"{}")
        if p in ("/studio/models/load", "/studio/models/unload", "/studio/models/stop", "/studio/models/pin"):
            mid = req.get("model")
            if mid not in ROUTER.backends:
                return self.err(404, "unknown model %r" % mid)
            if p.endswith("/load"):
                ROUTER.current = mid
                ROUTER.ensure(mid, wait=False)
            elif p.endswith("/unload"):
                ROUTER.stop(mid)
            elif p.endswith("/stop"):
                ROUTER.stop(mid, force=True)
            else:
                ROUTER.set_pin(mid, bool(req.get("pin", True)))
            return self.send_json(202, ROUTER.status())
        if p == "/studio/reload-registry":
            ROUTER.load_registry()
            return self.send_json(200, ROUTER.status())
        if p == "/studio/gallery/import" and ROUTER.outputs:
            mm = re.match(r"^data:image/(png|jpeg|webp);base64,(.+)$", req.get("image") or "", re.S)
            if not mm:
                return self.err(400, "image must be a PNG/JPEG/WebP data URL")
            meta = req.get("meta") if isinstance(req.get("meta"), dict) else {}
            meta = {k: v for k, v in meta.items() if isinstance(v, (str, int, float, bool, type(None), dict, list))}
            meta.setdefault("model", "imported")
            meta["imported"] = time.strftime("%Y-%m-%dT%H:%M:%S")
            ROUTER.outputs._write(meta, [(mm.group(2), Outputs.EXT[mm.group(1)])], None)
            return self.send_json(200, {"imported": True})
        if p == "/studio/gallery/delete":
            path = ROUTER.outputs.safe(req.get("file")) if ROUTER.outputs else None
            if not path:
                return self.err(400, "bad file")
            for f in (path, path + ".json"):
                try:
                    os.remove(f)
                except OSError:
                    pass
            return self.send_json(200, {"deleted": req.get("file")})
        if p.startswith("/studio/remote/"):
            return self.remote_api(p, req)
        return self.err(404, "not found")

    def remote_api(self, p, req):
        rm = ROUTER.remote
        try:
            if p == "/studio/remote/jobs":
                return self.send_json(200, {"jobs": rm.views(), "tokens": REMOTE.token_status()})
            if p == "/studio/remote/inspect":
                info = REMOTE.inspect(req.get("url"), req.get("file"))
                fam = req.get("family") or info["family"]
                info["plan"] = rm.plan(info, fam if fam in REMOTE.FAMILIES else None)[0]
                info["families"], info["tokens"] = REMOTE.family_list(), REMOTE.token_status()
                sel = next((f for f in info["files"] if f["key"] == info["file"]), {})
                name = REMOTE.safe_filename(sel.get("name", "x.safetensors"))
                if info["kind"] == "lora":
                    info["already"] = name if os.path.exists(os.path.join(ROUTER.a.lora_dir, name)) else None
                else:
                    info["already"] = next((b.spec.get("label") or b.id for b in list(ROUTER.backends.values())
                                            if name in b.spec.get("files", {}).values()), None)
                return self.send_json(200, info)
            if p == "/studio/remote/add":
                job = rm.add(req.get("url"), req.get("file"), req.get("family"), req.get("id"), req.get("label"),
                             set(ROUTER.backends))
                return self.send_json(202, job)
            if p == "/studio/remote/cancel":
                return self.send_json(200, {"cancelled": rm.cancel(req.get("id"))})
            if p == "/studio/remote/remove":
                kind, ident = req.get("kind"), req.get("id")
                if kind == "model":
                    b = ROUTER.backends.get(ident)
                    if b and b.spec.get("user"):
                        ROUTER.stop(ident)          # raises if it has work in progress
                protected = ROUTER.referenced_files(exclude=ident if kind == "model" else None)
                return self.send_json(200, rm.remove(kind, ident, bool(req.get("delete_files")), protected))
            return self.err(404, "unknown remote call")
        except REMOTE.RemoteError as e:
            return self.err(400, str(e))
        except (OSError, ValueError) as e:
            return self.err(502, "could not reach the model site: %s" % e)

    def sync(self, mid, raw, path=None, save=None):
        b = ROUTER.ensure(mid, claim=True)
        try:
            status, payload = self.proxy(b, path or self.path, raw)
            if save is not None and status == 200 and payload and ROUTER.outputs:
                ROUTER.outputs.save_sync(mid, save, payload)
        finally:
            b.release()


ROUTER = None


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    root = os.path.dirname(os.path.dirname(here))
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--port", type=int, default=8080)
    ap.add_argument("--bind", default="0.0.0.0")
    ap.add_argument("--backend-port", type=int, default=18200, help="first backend port (127.0.0.1)")
    ap.add_argument("--registry", default=os.path.join(here, "image-models.json"))
    ap.add_argument("--ui-dir", default=os.path.join(here, "ui"), help="Image Studio: index.html, studio.css, studio.js")
    ap.add_argument("--sd-server", default=os.path.join(root, "bin-sd-master-967-e47426c", "sd-server.exe"))
    ap.add_argument("--models-dir", default=os.environ.get("MODELS_DIR") or os.path.join(root, "models"))
    ap.add_argument("--lora-dir", default=None, help="default: <models-dir>/loras")
    ap.add_argument("--local-registry", default=None,
                    help="remote-added models; default <models-dir>/image-models.local.json (never the tracked file)")
    ap.add_argument("--outputs-dir", default=os.path.join(root, "outputs"), help="saved results ('' = don't save)")
    ap.add_argument("--allow-host", action="append", default=[],
                    help="extra Host names to accept (besides IPs and LAN names); also IMAGES_ALLOW_HOSTS=a,b")
    ap.add_argument("--log-dir", default=os.path.join(root, "logs"))
    ap.add_argument("--budget-gb", type=float, default=88, help="GPU memory the router may reserve for backends")
    ap.add_argument("--upstream-timeout", type=float, default=3600)
    ap.add_argument("--preload", default="default",
                    help="model(s) to start at launch: 'default', 'none', or ids separated by commas (pinned ones always load)")
    a = ap.parse_args()
    a.root = root
    a.lora_dir = a.lora_dir or os.path.join(a.models_dir, "loras")
    a.local_registry = a.local_registry or os.path.join(a.models_dir, "image-models.local.json")
    os.makedirs(a.log_dir, exist_ok=True)
    global ROUTER
    ROUTER = Router(a)
    names = {socket.gethostname().lower(), socket.getfqdn().lower(), "localhost"}
    names |= {h.strip().lower() for h in a.allow_host + os.environ.get("IMAGES_ALLOW_HOSTS", "").split(",") if h.strip()}
    ROUTER.allow_hosts = names
    sweep_orphans(a.backend_port, len(ROUTER.backends))
    want = [] if a.preload == "none" else [ROUTER.default] if a.preload == "default" else \
        [m.strip() for m in a.preload.split(",") if m.strip()]
    want += [m for m in sorted(ROUTER.pins) if m not in want]
    for mid in want:
        if mid in ROUTER.backends:
            ROUTER.ensure(mid, wait=False)
    if want and want[0] in ROUTER.backends:
        ROUTER.current = want[0]
    srv = Server((a.bind, a.port), Handler)
    log("images-router on http://%s:%d  (%d models, budget %.0f GB, outputs %s, sd-server %s)" %
        (a.bind, a.port, len(ROUTER.backends), a.budget_gb, a.outputs_dir or "off", a.sd_server))
    try:
        srv.serve_forever()
    finally:
        for b in ROUTER.backends.values():
            ROUTER._stop(b)


if __name__ == "__main__":
    main()
