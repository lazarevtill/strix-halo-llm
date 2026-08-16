"""Private multi-turn agentic-coding eval for local GGUFs.

WHY NOT THE EXISTING coding-eval/: that one is a single LRU-cache task. LRU cache is THE classic
interview problem -- every model has memorised it, so it measures recall, not coding. The sweep
found decontaminated SWE-rebench scores A3B-class models ~4x below their self-reported SWE-bench
numbers, so contamination is the dominant error term. These tasks are novel, in this fleet's own
domain, and the hidden tests probe what each spec IMPLIES.

SHAPE: 3 turns per task -- implement -> extend -> debug a stated failing case. That is how an agent
actually works, and it separates "can emit a plausible function" from "can revise its own code".

Scoring is per-turn: the artifact after EVERY turn is tested, so you see whether turn 2 broke turn 1
(regression) and whether turn 3 actually fixed the reported failure. Tests run in a locked-down
Docker sandbox: no network, 512 MB, 1 CPU, read-only mount.

Usage:
  python run-code-eval.py --endpoint http://127.0.0.1:8080/v1 --label ornith-q5
  python run-code-eval.py --model D:\\llamacpp-vulkan\\models\\laguna-s-2.1-Q4_K_M.gguf --label laguna
"""
import argparse, json, re, subprocess as sp, sys, time, pathlib, urllib.request, shutil, os
import datetime as _dt

E = pathlib.Path(__file__).resolve().parent
BIN = pathlib.Path(r"D:\llamacpp-vulkan\bin\llama-server.exe")
TASKS = json.loads((E / "tasks.json").read_text(encoding="utf-8"))["tasks"]
# Per-process work dir. A single shared `_work` is a silent cross-contamination path: two eval runs
# interleave rmtree / write solution.py / docker run, and model A gets scored on model B's code with
# no error anywhere.
WORK = E / f"_work-{os.getpid()}"
REFDIR = E / "reference"
SANDBOX_IMAGE = "llm-eval-sandbox"


def http_json(url, payload=None, timeout=1800):
    data = json.dumps(payload).encode("utf-8") if payload is not None else None
    hdrs = {"Content-Type": "application/json; charset=utf-8"} if data else {}
    req = urllib.request.Request(url, data, hdrs)
    return json.loads(urllib.request.urlopen(req, timeout=timeout).read())


def wait_ready(port, timeout=600):
    t0 = time.time()
    while time.time() - t0 < timeout:
        try:
            if http_json(f"http://127.0.0.1:{port}/health", timeout=5).get("status") == "ok":
                return True
        except Exception:
            pass
        time.sleep(3)   # was inside the except: a 200 with non-"ok" status busy-spun the CPU
    return False


def extract_code(raw: str):
    """Pull the python block. Returns (code, how) where how is fenced|unfenced|none.

    NEVER FALL BACK TO THE RAW RESPONSE. The old version returned `raw` when it found no code at
    all, so a turn that spent its whole token budget on reasoning got 29 KB of English prose written
    to solution.py. pytest then reported "1 error" (collection failure) and the task scored 0 --
    indistinguishable from a model that emitted broken code. On 2026-08-03 that alone accounted for
    most of qwen122b's apparent collapse to 44.3%. If there is no code, say so.
    """
    blocks = re.findall(r"```(?:python|py)?\s*\n(.*?)```", raw, re.S)
    if blocks:
        defs = [b for b in blocks if re.search(r"^\s*(class|def)\s+", b, re.M)]
        code, how = max(defs or blocks, key=len), "fenced"
    else:
        # An unfenced reply is only usable if it STARTS as code -- anything else is prose.
        m = re.match(r"\s*(?:from|import|class|def|@|#)\s", raw)
        if m:
            code, how = raw, "unfenced"
        else:
            return "", "none"
    for junk in ("[end of text]", "</s>", "<|im_end|>", "<|endoftext|>", "<|return|>"):
        code = code.replace(junk, "")
    return code.strip() + "\n", how


# ============================================================================================
# SAMPLER. Was temperature 0.0 / seed 42 until 2026-08-15, chosen for reproducibility: same input,
# same output, no sampling noise between models.
#
# That choice was measurably wrong for thinking models. Auditing the retained transcripts found
# EVERY truncated turn was a repetition loop that emitted no answer at all -- 9 of 9, across all
# four models, with one line repeated up to 439 times until the token budget ran out. The
# truncation-exclusion rule in score_task() was silently rescuing those turns, which is why four
# very different models all appeared to tie at 70/70.
#
# Qwen ships the same warning on its model cards: "We do NOT recommend using greedy decoding, as
# it can lead to performance degradation and endless repetitions."
#
# 0.3 is a compromise, not a vendor recommendation. It breaks the loops while staying close enough
# to greedy that a fixed seed keeps runs broadly repeatable. Both values are written into every
# result row: numbers produced under different samplers are NOT comparable, and the row has to say
# which regime it came from.
#
# Both are OVERRIDABLE per run (--temp / --seed) so the same model can be sampled k times at
# different seeds. One draw from a stochastic process is not a measurement: with an effective
# n of 7 tasks, a few points between two models is indistinguishable from sampler noise. Any
# ranking claim needs repeats, and the seed has to be in the row that supports it.
TEMP = 0.3
SEED = 42

# One generation at the real ceiling, not two at half of it.
#
# This was 16384 with a retry at 32768 on truncation. Measured on the hard tier, that is the
# single largest cost in the whole sweep and most of it is wasted: ornith hit the cap at 16384,
# retried, and hit it AGAIN at 32768 -- 49k tokens burned per turn, ~16 minutes at 58 t/s, for
# one scored artifact. The retry could never have helped either, since at fixed temp and seed the
# second call re-derives the same prefix; its only contribution was more room, which asking for
# the room up front supplies in one call.
#
# Turns that finish early are unaffected -- they stop on their own and cost exactly what they did
# before. Truncation is still recorded per turn and reported as its own rate: a model that cannot
# finish inside 32k tokens of reasoning is telling you something real about itself, and that
# belongs in the results rather than being retried away.
MAX_TOKENS = 32768


def tests_by_turn(task_id: str) -> dict:
    """Map test function name -> the turn that introduced its feature.

    The hidden suites are written in `# ---- turn N additions ----` sections. Scoring turn 1 against
    ALL of them means grading a model on features the prompt has not asked for yet, so every model
    scores exactly the turn-1 test count and no more -- which is why laguna, ornith and qwen all
    returned byte-identical first-turn scores (12/8/14/11) on every run. That metric measured the
    test file, not the models.
    """
    src = (E / "tests" / f"test_{task_id}.py").read_text(encoding="utf-8")
    turn, out = 1, {}
    for line in src.splitlines():
        m = re.match(r"\s*#\s*-*\s*turn\s*(\d)", line, re.I)
        if m:
            turn = int(m.group(1))
        m = re.match(r"\s*def (test_\w+)", line)
        if m:
            out[m.group(1)] = turn
    return out


def score_in_sandbox(task_id: str, code: str, max_turn: int = 99) -> tuple[int, int, str]:
    """Write solution.py + the hidden test, run pytest inside a disposable container."""
    if WORK.exists():
        shutil.rmtree(WORK, ignore_errors=True)
    WORK.mkdir(parents=True, exist_ok=True)
    (WORK / "solution.py").write_text(code, encoding="utf-8")
    test_src = E / "tests" / f"test_{task_id}.py"
    if not test_src.exists():
        return 0, 0, f"NO_TESTS for {task_id}"
    shutil.copy(test_src, WORK / f"test_{task_id}.py")

    cmd = ["docker", "run", "--rm", "--network", "none", "--memory", "512m", "--cpus", "1",
           "--pids-limit", "128", "--read-only", "--tmpfs", "/tmp",
           "-e", "PYTHONDONTWRITEBYTECODE=1",
           "-v", f"{WORK}:/work:ro", "-w", "/work", SANDBOX_IMAGE,
           "python", "-m", "pytest", "-q", "--no-header", "--tb=no", "-p", "no:cacheprovider"]
    # Grade only the features requested so far.
    for name, t in tests_by_turn(task_id).items():
        if t > max_turn:
            cmd += ["--deselect", f"test_{task_id}.py::{name}"]
    try:
        r = sp.run(cmd, capture_output=True, text=True, timeout=300)
        out = (r.stdout + r.stderr).strip()
    except sp.TimeoutExpired:
        return 0, 0, "SANDBOX_TIMEOUT"
    except FileNotFoundError:
        return 0, 0, "ENVIRONMENT DOCKER_NOT_FOUND"

    # The sandbox itself failing is an ENVIRONMENT fault, not a coding failure. pytest exits 0 (all
    # pass), 1 (tests failed) or 5 (none collected); anything else -- and any docker-level error --
    # means we never got a verdict. Previously returncode was ignored entirely, so a stopped Docker
    # daemon scored every task 0 and looked exactly like a model that cannot code.
    # rc 0/1/2/5 are all legitimate pytest verdicts -- 2 is what it returns when COLLECTION is
    # interrupted, i.e. the model's code has a syntax error. Treating 2 as ENVIRONMENT (as the first
    # version did) mislabels a model defect as a box problem. Only docker-level failures qualify.
    docker_broke = (r.returncode in (125, 126, 127)
                    or "error during connect" in out
                    or "cannot connect to the docker daemon" in out.lower()
                    or "unable to find image" in out.lower())
    if docker_broke or r.returncode in (3, 4):
        return 0, 0, f"ENVIRONMENT sandbox rc={r.returncode}: {out.splitlines()[-1][:160] if out else 'no output'}"

    passed = failed = 0
    m = re.search(r"(\d+) passed", out)
    if m: passed = int(m.group(1))
    m = re.search(r"(\d+) failed", out)
    if m: failed = int(m.group(1))
    m = re.search(r"(\d+) error", out)
    if m: failed += int(m.group(1))
    # SKIPPED COUNTS AGAINST THE TOTAL. The hidden test count per task is fixed, so the denominator
    # must not move between turns. Without this, quant_pick turn 1 ("11 passed, 4 failed, 3 skipped")
    # scored 11/15 while turns 2-3 scored 18/18 -- the first-shot rate was computed against a
    # denominator that had quietly shrunk, reading 67.2% instead of the true 64.3%. A skipped test
    # is not a passed test.
    m = re.search(r"(\d+) skipped", out)
    if m: failed += int(m.group(1))
    if passed == 0 and failed == 0:
        return 0, 0, (out.splitlines() or ["no pytest output"])[-1][:200]
    return passed, passed + failed, out.splitlines()[-1][:200] if out else ""


def calibrate(tasks):
    """Authoritative test count per (task, turn), measured by scoring the reference solution.

    Cannot be counted statically: token_budget has 10 `def test_` in its turn-1 section but 12
    tests, because two are parametrized. And it cannot be taken from the model's own run, because a
    turn whose code fails to import collects 0 tests -- the denominator would shrink exactly when
    the model did worst. Running the known-good reference at each max_turn settles it in ~10s.
    """
    cal = {}
    for task in tasks:
        tid = task["id"]
        ref = REFDIR / f"{tid}.py"
        if not ref.exists():
            print(f"  !! no reference for {tid}; falling back to observed totals", flush=True)
            continue
        src = ref.read_text(encoding="utf-8")
        for ti in range(1, len(task["turns"]) + 1):
            p, t, _ = score_in_sandbox(tid, src, max_turn=ti)
            cal[(tid, ti)] = t
            if p != t:
                print(f"  !! reference for {tid} fails {t-p} of {t} tests at turn {ti} "
                      f"-- the prompt for that turn may be unsatisfiable", flush=True)
    return cal


def run_model(label, endpoint, transcript_dir):
    print("calibrating test counts against reference solutions...", flush=True)
    CAL = calibrate(TASKS)
    rows = []
    for task in TASKS:
        tid = task["id"]
        print(f"\n--- {label} / {tid} ---", flush=True)
        msgs, per_turn = [], []
        for ti, prompt in enumerate(task["turns"], 1):
            msgs.append({"role": "user", "content": prompt})
            # 16384. On a thinking model the reasoning is billed against the SAME budget as the
            # answer, so a tight cap gets consumed before any code is emitted. 3072 was hopeless;
            # 8192 was still not enough for qwen122b, which burned the whole budget reasoning about
            # token_budget and got cut off mid-sentence -- scoring 0 for what was a harness limit,
            # not a coding failure. Truncation is now detected explicitly (finish_reason) too.
            body = {"messages": msgs, "temperature": TEMP, "seed": SEED, "max_tokens": MAX_TOKENS}
            try:
                j = http_json(f"{endpoint}/chat/completions", body)
                m = j["choices"][0]["message"]
                reasoning = m.get("reasoning_content") or ""
                # Keep the two fields APART. Code is extracted from content, falling back to the
                # reasoning only when the model emitted nothing else -- but history must carry them
                # as separate fields, or a thinking model sees its own scratchpad as its answer.
                content = m.get("content") or ""
                code_src = content or reasoning
                # A turn cut off at the token cap is a HARNESS limit, not a wrong answer. Record it
                # so it can never be silently scored as a coding failure.
                truncated = (j["choices"][0].get("finish_reason") == "length")
                tps = round((j.get("timings") or {}).get("predicted_per_second", 0) or 0, 1)
            except Exception as ex:
                # ENVIRONMENT, NOT QUALITY. This box has repeatedly 500'd mid-run from memory
                # pressure and killed the server outright. Marking the turn `env` keeps the stable
                # denominator from scoring an HTTP failure as 0/20 of coding ability -- the tools
                # eval has made this distinction since the first time it burned us.
                print(f"  turn {ti}: ENVIRONMENT request failed: {ex}", flush=True)
                per_turn.append({"turn": ti, "passed": 0, "total": 0,
                                 "note": f"ENVIRONMENT request failed: {ex}", "env": True})
                break
            # Echo reasoning_content back. poolside recommend preserving reasoning across turns for
            # Laguna agentic work, and llama-server's --reasoning-preserve only has an effect if the
            # client actually returns it -- otherwise the flag is set but never exercised.
            asst = {"role": "assistant", "content": content}
            if reasoning:
                asst["reasoning_content"] = reasoning
            msgs.append(asst)
            code, how = extract_code(code_src)

            # No truncation retry -- the budget is asked for up front instead. See MAX_TOKENS.

            # FRAGMENT vs BROKEN. Models sometimes reply with just the changed method instead of the
            # full file. That is an instruction-following miss, not "it broke the code" -- but the
            # harness overwrites solution.py wholesale, so a partial edit crashes on import and
            # scores identically to garbage. Flag it, and keep it out of the "regressed" claim.
            fragment = bool(code) and task.get("entry") and task["entry"] not in code
            if fragment:
                note_prefix = f"FRAGMENT (missing '{task['entry']}'); "
            else:
                note_prefix = ""

            if how == "none":
                p, t = 0, 0
                note = "NO CODE EMITTED (truncated)" if truncated else "NO CODE EMITTED (prose only)"
            else:
                # max_turn=ti: grade only what has been asked for by this turn.
                p, t, note = score_in_sandbox(tid, code, max_turn=ti)
                note = note_prefix + note
                if truncated:
                    note = "TRUNCATED @max_tokens; " + note
            # `in`, not startswith: the note may already carry a "TRUNCATED @max_tokens; " prefix,
            # which silently defeated the env check and let an infrastructure failure be scored as
            # a 0 for coding ability.
            is_env = "ENVIRONMENT" in note
            # Calibrated denominator wins over whatever pytest happened to collect this turn.
            t = CAL.get((tid, ti), t)
            per_turn.append({"turn": ti, "passed": p, "total": t, "tps": tps,
                             "note": note, "extract": how, "truncated": truncated,
                             "fragment": fragment,
                             **({"env": True} if is_env else {})})
            pct = f"{100*p/t:.0f}%" if t else "n/a"
            print(f"  turn {ti}: {p}/{t} ({pct})  {tps} t/s   [{how}]{' TRUNC' if truncated else ''}   {note[:80]}", flush=True)
            (transcript_dir / f"{label}-{tid}-t{ti}.py").write_text(code, encoding="utf-8")
            # ALWAYS keep the raw reply. extract_code returning "" for prose-only turns meant the
            # transcript was an empty file -- destroying the very evidence that revealed the
            # prose-as-code bug in the first place. Never make a claim unauditable.
            (transcript_dir / f"{label}-{tid}-t{ti}.raw.txt").write_text(
                f"=== finish_reason: {'length' if truncated else 'stop'} | extract: {how} ===\n"
                f"--- reasoning_content ---\n{reasoning}\n\n--- content ---\n{content}\n",
                encoding="utf-8")

        # STABLE DENOMINATOR. The hidden test count for a task is fixed, but pytest only reports the
        # tests it actually COLLECTED -- so a turn whose code fails to import reports "1 error",
        # i.e. 0/1, and a turn with skips reported fewer still. Taking those at face value shrinks
        # the denominator exactly when the model did WORST, which is backwards: ornith-q5 turn 3 on
        # token_budget scored 0/1 instead of 0/20 and the run printed 47/51 = 92.2% when the true
        # figure was 47/70 = 67.1%. Static counting cannot fix this either (token_budget has 18
        # `def test_` but 20 tests, two being parametrized), so use the largest total any turn
        # observed -- a healthy turn collects them all.
        # The task's denominator is the FULL suite (final turn's calibrated count). Per-turn totals
        # stay as they are -- turn 1 is graded out of the turn-1 tests only, so "12/12" reads as the
        # perfect score it is rather than the misleading "12/20".
        task_total = CAL.get((tid, len(task["turns"])), max((x.get("total", 0) for x in per_turn), default=0))
        # Score the last VALID artifact -- a turn that was cut off at the token cap, or died on
        # infrastructure, is not the model's answer. This matters enormously: in the 2026-08-04
        # sweep the ONLY differences between the three models' final scores were turn-3 truncations
        # (laguna 18->0 on window_merge, qwen 18->0 on quant_pick, ornith 18->15). Scoring those
        # zeroes as coding ability produced a 95.7 / 74.3 / 72.9 spread between models that are
        # otherwise identical. Truncation rate is reported on its own instead.
        # 2026-08-15: exclusion used to key on the `truncated` FLAG alone. That over-corrects.
        # Ornith passed token_budget 20/20 at turns 2 AND 3, both flagged truncated because the
        # response envelope closed after the code was complete -- and the old rule fell back to
        # turn 1, reporting 12/20 for a task it demonstrably passed 20/20. Truncation is only
        # disqualifying when it actually cost work, so keep a truncated turn that scored at least
        # as well as the last complete one.
        valid = []
        for x in per_turn:
            if x.get("env"):
                continue
            if x.get("truncated"):
                prev = valid[-1].get("passed", 0) if valid else 0
                if x.get("passed", 0) < max(prev, 1):
                    continue          # genuinely lost work -- drop it
            valid.append(x)
        final_passed = valid[-1].get("passed", 0) if valid else 0
        if not valid and per_turn:
            task_total = 0   # nothing scorable at all -> task drops out of the denominator

        # STRICT SCORE -- the same task with NO truncation rescue at all: whatever the last turn
        # that actually reached the sandbox scored, taken at face value. The rescue above is
        # defensible, but a rescue is exactly what hid the 2026-08-04 contamination, and a rule
        # that decides its own audit is not an audit. Reporting both forecloses the question: if
        # the two agree the rescue did no work, and if they diverge THAT is the finding.
        # `env` turns are still skipped -- an HTTP 500 from memory pressure is this box failing,
        # not the model, and that distinction is not the one under suspicion.
        scored = [x for x in per_turn if not x.get("env")]
        strict_passed = scored[-1].get("passed", 0) if scored else 0

        # regression check: did turn 2/3 break what turn 1 passed?
        best = max((x.get("passed", 0) for x in per_turn), default=0)
        rows.append({"task": tid, "tier": task.get("tier", "easy"),
                     "final_passed": final_passed, "strict_passed": strict_passed,
                     "final_total": task_total, "best_passed": best,
                     "regressed": best > final_passed, "turns": per_turn})
    return rows


def main():
    # Declared up front, not next to the assignments: Python rejects `global X` that appears after
    # X has already been read in the same scope, and SEED/TEMP are read below as argparse defaults.
    global TEMP, SEED, TASKS
    ap = argparse.ArgumentParser()
    ap.add_argument("--endpoint")
    ap.add_argument("--model")
    ap.add_argument("--label", required=True)
    ap.add_argument("--port", type=int, default=8096)
    ap.add_argument("--ctx", type=int, default=32768)
    # Comma-separated task ids, for re-running just the ones a contaminated run could not finish.
    ap.add_argument("--tasks", default="")
    # Repeats. `--seed 43` re-samples the same model under a different draw; three such runs give
    # a mean and a range, which is the difference between "A beat B" and "A beat B by more than
    # this bench's own noise". Defaults keep every existing invocation byte-identical.
    ap.add_argument("--seed", type=int, default=SEED)
    ap.add_argument("--temp", type=float, default=TEMP)
    a = ap.parse_args()
    TEMP, SEED = a.temp, a.seed

    if a.tasks:
        want = {t.strip() for t in a.tasks.split(",") if t.strip()}
        TASKS = [t for t in TASKS if t["id"] in want]
        missing = want - {t["id"] for t in TASKS}
        if missing:
            sys.exit(f"unknown task id(s): {', '.join(sorted(missing))}")

    tdir = E / "transcripts"; tdir.mkdir(exist_ok=True)
    srv = None
    endpoint = a.endpoint
    if not endpoint:
        if not a.model:
            sys.exit("need --endpoint or --model")
        # These now match run-model-suite.ps1 exactly. They did not, and both differences were
        # silent losses rather than errors:
        #   --ubatch-size was 1024, which is 29% slower at prefill than the measured 256 on
        #     gfx1151. Prefill time only, so no score moved -- but every medMs recorded through
        #     this path before 2026-08-16 is inflated and is not comparable with a 256 run.
        #   --no-mmap was DEPRECATED in b10182 in favour of --load-mode, WHICH DEFAULTS TO MMAP.
        #     A deprecated flag that still parses today is exactly how this box ends up pinning a
        #     ~21 GB host file-cache mirror in RAM again without anything appearing to change.
        args = [str(BIN), "-m", a.model, "-ngl", "999", "--ctx-size", str(a.ctx),
                "--batch-size", "2048", "--ubatch-size", "256", "-fa", "on",
                "--cache-type-k", "q8_0", "--cache-type-v", "q8_0", "-lm", "none", "--jinja",
                "--parallel", "1", "--host", "127.0.0.1", "--port", str(a.port), "--no-warmup"]
        print("launching:", a.model, flush=True)
        srv = sp.Popen(args, stdout=sp.DEVNULL, stderr=sp.DEVNULL)
        if not wait_ready(a.port):
            srv.terminate(); sys.exit("server did not become healthy")
        endpoint = f"http://127.0.0.1:{a.port}/v1"

    try:
        rows = run_model(a.label, endpoint, tdir)
    finally:
        if srv:
            srv.terminate()
            try: srv.wait(30)
            except Exception: srv.kill()

    tot_p = sum(r["final_passed"] for r in rows)
    tot_s = sum(r["strict_passed"] for r in rows)
    tot_t = sum(r["final_total"] for r in rows)
    regr = sum(1 for r in rows if r["regressed"])

    # A TASK THAT NEVER RAN MUST NOT VANISH FROM THE DENOMINATOR. final_total is 0 when every turn
    # failed, so summing it silently drops the task: on 2026-08-03 two of four tasks 500'd out
    # (the box was over its memory ceiling) and this line still printed "34/34 (100.0%)". Same trap
    # as the tool eval scoring failed requests as abstain passes -- a broken run has to LOOK broken.
    incomplete = [r["task"] for r in rows if r["final_total"] == 0]
    ran = len(rows) - len(incomplete)
    head = "PARTIAL RUN -- " if incomplete else ""
    print(f"\n=== {head}{a.label}: {tot_p}/{tot_t} hidden tests passed "
          f"({100*tot_p/tot_t if tot_t else 0:.1f}%) across {ran}/{len(rows)} tasks, "
          f"{regr} task(s) regressed across turns ===")
    print(f"    strict (no truncation rescue): {tot_s}/{tot_t} "
          f"({100*tot_s/tot_t if tot_t else 0:.1f}%)"
          + ("   <-- rescue is doing work; read the transcripts" if tot_s != tot_p else "   (identical -- rescue changed nothing)"))
    print(f"    sampler: temp={TEMP} seed={SEED}")
    # PER TIER. The easy tier is known saturated -- every model measured has returned 70/70 on it,
    # so a combined percentage is dominated by tests that discriminate nothing and drags every
    # model toward the same number. The hard tier is the whole reason this run exists; it gets its
    # own line, and any ranking claim has to be made from that line alone.
    for tier in ("easy", "hard"):
        tr = [r for r in rows if r.get("tier", "easy") == tier]
        if not tr:
            continue
        p = sum(x["final_passed"] for x in tr); t = sum(x["final_total"] for x in tr)
        s = sum(x["strict_passed"] for x in tr)
        print(f"    {tier:5s} tier: {p}/{t} ({100*p/t if t else 0:.1f}%)  strict {s}/{t} "
              f"({100*s/t if t else 0:.1f}%)  over {len(tr)} task(s)")
    if incomplete:
        print(f"!! {len(incomplete)} task(s) NEVER COMPLETED: {', '.join(incomplete)}")
        print("!! The percentage above covers only the tasks that ran. Re-run before quoting it.")

    # Per-task outcomes, not just a test-level percentage. Tests cluster inside tasks, so the
    # effective sample size is 4, not 70 -- quoting "70/70" implies far more evidence than exists.
    print("\n  per-task (effective n = %d, NOT %d):" % (len(rows), tot_t))
    for r in rows:
        flags = []
        if any(x.get("truncated") for x in r["turns"]): flags.append("TRUNC")
        if any(x.get("fragment") for x in r["turns"]):  flags.append("FRAG")
        if any(x.get("env") for x in r["turns"]):       flags.append("ENV")
        first = r["turns"][0].get("passed", 0) if r["turns"] else 0
        print("    %-15s first %2d -> final %2d / %2d  %s" %
              (r["task"], first, r["final_passed"], r["final_total"], " ".join(flags)))

    res = E / "results-code.jsonl"
    with res.open("a", encoding="utf-8") as f:
        f.write(json.dumps({
            "ts": _dt.datetime.now().astimezone().isoformat(),
            "label": a.label, "passed": tot_p, "strict_passed": tot_s, "total": tot_t,
            "by_tier": {tier: {
                "passed": sum(x["final_passed"] for x in rows if x.get("tier", "easy") == tier),
                "strict": sum(x["strict_passed"] for x in rows if x.get("tier", "easy") == tier),
                "total":  sum(x["final_total"] for x in rows if x.get("tier", "easy") == tier),
                "tasks":  sum(1 for x in rows if x.get("tier", "easy") == tier),
            } for tier in ("easy", "hard") if any(x.get("tier", "easy") == tier for x in rows)},
            "tasks_ran": ran, "tasks_total": len(rows), "incomplete": incomplete,
            "regressed_tasks": regr,
            "truncated_turns": sum(1 for r in rows for x in r["turns"] if x.get("truncated")),
            "fragment_turns":  sum(1 for r in rows for x in r["turns"] if x.get("fragment")),
            "env_turns":       sum(1 for r in rows for x in r["turns"] if x.get("env")),
            # PROVENANCE -- see the tools eval. Three harness vintages in one file made every
            # earlier number unattributable after the fact.
            "harness_mtime": _dt.datetime.fromtimestamp(pathlib.Path(__file__).stat().st_mtime).isoformat(),
            "tasks_mtime": _dt.datetime.fromtimestamp((E / "tasks.json").stat().st_mtime).isoformat(),
            "endpoint": endpoint, "max_tokens": MAX_TOKENS, "temperature": TEMP, "seed": SEED,
            "detail": rows}) + "\n")
    print("appended ->", res)


if __name__ == "__main__":
    main()
