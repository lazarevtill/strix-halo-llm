"""Multi-turn coding-agent eval over local models on the Vulkan server.
For each model: start llama-server, run the turns.json sequence as a chat session
(KV-prefix reused across turns), save transcript, extract final class, score it.
Usage:  python run_eval.py model1.gguf model2.gguf ...
"""
import json, subprocess as sp, sys, time, re, pathlib, urllib.request

BASE = pathlib.Path(r"D:\llamacpp-vulkan")
E = BASE / "coding-eval"
BIN = BASE / "bin" / "llama-server.exe"
PORT = 8080
CHAT = f"http://127.0.0.1:{PORT}/v1/chat/completions"
HEALTH = f"http://127.0.0.1:{PORT}/v1/models"
for d in ("out", "sol", "res"):
    (E / d).mkdir(exist_ok=True)

turns = json.loads((E / "turns.json").read_text(encoding="utf-8"))
models = sys.argv[1:]


def wait_ready(timeout=200):
    t0 = time.time()
    while time.time() - t0 < timeout:
        try:
            urllib.request.urlopen(HEALTH, timeout=3); return True
        except Exception:
            time.sleep(2)
    return False


def chat(messages):
    # 4096 budget so thinking models can reason AND still emit the code;
    # fall back to reasoning_content if the server split it out.
    body = json.dumps({"messages": messages, "temperature": 0, "seed": 42,
                       "max_tokens": 4096}).encode()
    req = urllib.request.Request(CHAT, body, {"Content-Type": "application/json"})
    j = json.loads(urllib.request.urlopen(req, timeout=1200).read())
    msg = j["choices"][0]["message"]
    content = msg.get("content") or msg.get("reasoning_content") or ""
    tps = round(j.get("timings", {}).get("predicted_per_second", 0), 1)
    return content, tps


def extract(raw):
    blocks = re.findall(r"```(?:python|py)?\s*\n(.*?)```", raw, re.S)
    code = next((b for b in blocks if "class LRUCache" in b), "")
    if not code and blocks:
        code = max(blocks, key=len)
    if not code:
        m = re.search(r"(class\s+LRUCache\b.*)", raw, re.S)
        code = m.group(1) if m else raw
    code = re.split(r"\n\[\s*Prompt:", code)[0]
    for j in ("[end of text]", "</s>", "<|im_end|>", "<|endoftext|>", "<|return|>"):
        code = code.replace(j, "")
    return code.rstrip()


rows = []
for f in models:
    mp = BASE / "models" / f
    name = f[:-5] if f.endswith(".gguf") else f
    if not mp.exists():
        print("MISSING", f); rows.append([name, "missing", 0, 0]); continue
    print(f"\n===== {name} =====", flush=True)
    args = [str(BIN), "-m", str(mp), "--no-mmap", "-ngl", "999", "--ctx-size", "16384",
            "--batch-size", "256", "-fa", "on", "--host", "127.0.0.1", "--port", str(PORT),
            "--jinja", "--cache-reuse", "256"]
    srv = sp.Popen(args, stdout=sp.DEVNULL, stderr=sp.DEVNULL)
    tpss = []
    try:
        if not wait_ready():
            print("  server not ready"); rows.append([name, "server-fail", 0, 0]); continue
        msgs, transcript = [], []
        for i, t in enumerate(turns, 1):
            msgs.append({"role": "user", "content": t})
            print(f"  turn {i}/{len(turns)}...", end="", flush=True)
            resp, tps = chat(msgs)
            msgs.append({"role": "assistant", "content": resp})
            transcript.append({"turn": i, "tps": tps, "assistant": resp}); tpss.append(tps)
            print(f" {tps} tok/s", flush=True)
        (E / "out" / f"{name}.json").write_text(json.dumps(transcript, indent=2), encoding="utf-8")
        (E / "sol" / f"{name}.py").write_text(extract(transcript[-1]["assistant"]), encoding="utf-8")
    finally:
        srv.terminate()
        try:
            srv.wait(20)
        except Exception:
            srv.kill()
        time.sleep(3)
    # score — INSIDE a disposable sandbox (no network, capped mem/cpu, read-only FS)
    (E / "solution.py").write_text((E / "sol" / f"{name}.py").read_text(encoding="utf-8"), encoding="utf-8")
    docker_cmd = [
        "docker", "run", "--rm", "--network", "none", "--memory", "512m", "--cpus", "1",
        "--pids-limit", "128", "--read-only", "--tmpfs", "/tmp",
        "-e", "PYTHONDONTWRITEBYTECODE=1",
        "-v", f"{E}:/work:ro", "-w", "/work", "llm-eval-sandbox",
        "python", "score.py",
    ]
    try:
        r = sp.run(docker_cmd, capture_output=True, text=True, timeout=180)
        summary = (r.stdout + r.stderr).strip()
    except sp.TimeoutExpired:
        summary = "0/12 SANDBOX_TIMEOUT"
    (E / "res" / f"{name}.txt").write_text(summary, encoding="utf-8")
    m = re.match(r"(\d+)/(\d+)", summary)
    passed = int(m.group(1)) if m else 0
    avgtps = round(sum(tpss) / len(tpss), 1) if tpss else 0
    rows.append([name, "ok", passed, avgtps]);
    print(f"  -> {summary.splitlines()[0] if summary else '?'}  | avg {avgtps} tok/s", flush=True)

with open(E / "leaderboard.csv", "w", encoding="utf-8") as fo:
    fo.write("model,status,tests_passed_of_12,avg_gen_tok_s\n")
    for r in rows:
        fo.write(",".join(str(x) for x in r) + "\n")
print("\n=== LEADERBOARD ===")
for r in rows:
    print(r)
