"""Re-run selected coding tasks with anti-repetition sampling. One controlled variable.

WHY (bug 13)
------------
qwen38 scored 0/27 on `hard_semver` and 0/37 on `hard_where`, and neither zero was a coding
failure. Turn 1 of each burned all 32,768 tokens inside `reasoning_content` and returned empty
`content`: one transcript is a 13,422-character run of the digit `0`, the other repeats a single
reasoning block 26+ times. Turn 1 establishes the file that later turns edit, so an empty turn 1
made turns 2-4 diffs against nothing -- 64 of 89 tests lost to two sampler events.

The harness sends ONLY temperature, seed and max_tokens. No repetition penalty, no min_p, no DRY --
nothing configured to suppress the exact failure observed. So the published 28% may be measuring our
sampler configuration rather than the model. This script tests that, and nothing else.

THE CONTROL ALREADY EXISTS. The sweep ran these same tasks, same seed (42), same temperature (0.3),
same server flags. Do not re-run a control arm -- compare against `qwen38-hard` in
results-code.jsonl. That is what makes this an hour rather than three.

WHY DRY RATHER THAN repeat_penalty
----------------------------------
`repeat_penalty` penalises tokens by identity, and CODE LEGITIMATELY REPEATS -- indentation,
`self.`, identifiers, closing brackets. Turning it up to break a loop degrades ordinary code
generation, which would confound the very thing being measured. DRY penalises repeated SEQUENCES
longer than `dry_allowed_length`, so normal code patterns pass and a 13k-character verbatim loop
does not. Default allowed_length is 8 here rather than the usual 2, deliberately, to stay clear of
legitimate boilerplate. Everything is a flag; change one thing at a time.

THIS FILE DOES NOT MODIFY run-code-eval.py. It imports it, so scoring, calibration, code extraction
and the sandbox are bit-identical to the sweep. Results go to their own file and their own
transcript labels; nothing existing is overwritten.

    python evals/rerun-sampler.py --endpoint http://127.0.0.1:8099/v1 \
        --label qwen38-drytest --tasks hard_semver,hard_where
"""
import argparse, importlib.util, json, pathlib, sys, time
import datetime as _dt

E = pathlib.Path(__file__).resolve().parent

# Import the live harness WITHOUT editing it. Module-level code runs on import: it loads tasks.json
# and sets WORK to a pid-scoped directory, so this cannot collide with a sweep running alongside.
_spec = importlib.util.spec_from_file_location("rce", E / "code" / "run-code-eval.py")
rce = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(rce)

# Corrected fragment detection (bug 12). The harness still has the substring version; this run gets
# the right one, and both flags are recorded so the two can never be silently conflated.
_rspec = importlib.util.spec_from_file_location("rs", E / "rescore.py")
rs = importlib.util.module_from_spec(_rspec)
_rspec.loader.exec_module(rs)

OUT = E / "code" / "results-sampler.jsonl"
TRANS = E / "code" / "transcripts"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--endpoint", required=True)
    ap.add_argument("--label", required=True, help="must be NEW -- transcripts are keyed on it")
    ap.add_argument("--tasks", required=True, help="comma-separated task ids")
    ap.add_argument("--temp", type=float, default=rce.TEMP)
    ap.add_argument("--seed", type=int, default=rce.SEED)
    ap.add_argument("--max-tokens", type=int, default=rce.MAX_TOKENS)
    # Anti-repetition. DRY on, classic penalties off, so exactly one thing differs from the sweep.
    ap.add_argument("--dry-multiplier", type=float, default=0.8)
    ap.add_argument("--dry-base", type=float, default=1.75)
    ap.add_argument("--dry-allowed-length", type=int, default=8)
    ap.add_argument("--dry-penalty-last-n", type=int, default=2048)
    ap.add_argument("--repeat-penalty", type=float, default=1.0)
    ap.add_argument("--repeat-last-n", type=int, default=64)
    ap.add_argument("--min-p", type=float, default=None)
    a = ap.parse_args()

    want = [t.strip() for t in a.tasks.split(",") if t.strip()]
    tasks = [t for t in rce.TASKS if t["id"] in want]
    missing = set(want) - {t["id"] for t in tasks}
    if missing:
        sys.exit(f"unknown task id(s): {', '.join(sorted(missing))}")

    # Refuse to clobber. Transcripts are the evidence; overwriting the control would destroy the
    # only thing this run is measured against.
    clash = sorted(p.name for p in TRANS.glob(f"{a.label}-*"))
    if clash:
        sys.exit(f"label '{a.label}' already has {len(clash)} transcript(s), e.g. {clash[0]}.\n"
                 f"Pick a new --label; this script will not overwrite evidence.")

    sampler = {"dry_multiplier": a.dry_multiplier, "dry_base": a.dry_base,
               "dry_allowed_length": a.dry_allowed_length,
               "dry_penalty_last_n": a.dry_penalty_last_n,
               "repeat_penalty": a.repeat_penalty, "repeat_last_n": a.repeat_last_n}
    if a.min_p is not None:
        sampler["min_p"] = a.min_p

    print(f"label   : {a.label}")
    print(f"tasks   : {', '.join(t['id'] for t in tasks)}")
    print(f"sampler : temp={a.temp} seed={a.seed} max_tokens={a.max_tokens}")
    print(f"          {json.dumps(sampler)}")
    print("control : qwen38-hard in results-code.jsonl (same seed/temp/flags, no anti-repetition)\n")

    print("calibrating against reference solutions...", flush=True)
    CAL = rce.calibrate(tasks)

    rows, t0 = [], time.time()
    for task in tasks:
        tid = task["id"]
        print(f"\n--- {a.label} / {tid} ---", flush=True)
        msgs, per_turn = [], []
        for ti, prompt in enumerate(task["turns"], 1):
            msgs.append({"role": "user", "content": prompt})
            body = {"messages": msgs, "temperature": a.temp, "seed": a.seed,
                    "max_tokens": a.max_tokens, **sampler}
            try:
                j = rce.http_json(f"{a.endpoint}/chat/completions", body)
                m = j["choices"][0]["message"]
            except Exception as ex:
                print(f"  turn {ti}: ENVIRONMENT request failed: {ex}", flush=True)
                per_turn.append({"turn": ti, "passed": 0, "total": 0, "env": True,
                                 "note": f"ENVIRONMENT request failed: {ex}"})
                break
            reasoning = m.get("reasoning_content") or ""
            content = m.get("content") or ""
            truncated = (j["choices"][0].get("finish_reason") == "length")
            msgs.append({"role": "assistant", "content": content,
                         **({"reasoning_content": reasoning} if reasoning else {})})

            code, how = rce.extract_code(content or reasoning)
            (TRANS / f"{a.label}-{tid}-t{ti}.raw.txt").write_text(
                f"=== finish_reason: {j['choices'][0].get('finish_reason')} | extract: {how} ===\n"
                f"--- reasoning_content ---\n{reasoning}\n\n--- content ---\n{content}\n",
                encoding="utf-8")
            (TRANS / f"{a.label}-{tid}-t{ti}.py").write_text(code or "", encoding="utf-8")

            entry = task.get("entry")
            fragment = bool(code) and not rs.defines(code, entry)
            if how == "none":
                p, t = 0, 0
                note = "NO CODE EMITTED (truncated)" if truncated else "NO CODE EMITTED (prose only)"
            else:
                p, t, note = rce.score_in_sandbox(tid, code, max_turn=ti)
                if fragment:
                    note = f"FRAGMENT (missing def of '{entry}'); " + note
            tot = CAL.get((tid, ti), t)
            per_turn.append({"turn": ti, "passed": p, "total": tot, "truncated": truncated,
                             "fragment": fragment, "note": note,
                             "reason_chars": len(reasoning), "answer_chars": len(content)})
            flags = " ".join(f for f, on in (("TRUNC", truncated), ("FRAG", fragment)) if on)
            print(f"  turn {ti}: {p}/{tot} {flags}  ({len(reasoning)} reasoning chars) {note[:70]}",
                  flush=True)

        task_total = max([x.get("total", 0) for x in per_turn] + [CAL.get((tid, len(task['turns'])), 0)])
        usable = [x for x in per_turn if not x.get("env") and not x.get("fragment")
                  and not x.get("truncated")]
        rows.append({"task": tid, "total": task_total,
                     "strict": (per_turn[-1].get("passed", 0) if per_turn else 0),
                     "rescued": (usable[-1]["passed"] if usable else 0),
                     "best": max([x["passed"] for x in usable], default=0),
                     "turns": per_turn})

    rec = {"ts": _dt.datetime.now().astimezone().isoformat(), "label": a.label,
           "endpoint": a.endpoint, "temp": a.temp, "seed": a.seed, "max_tokens": a.max_tokens,
           "sampler": sampler, "elapsed_s": round(time.time() - t0), "detail": rows}
    with OUT.open("a", encoding="utf-8") as f:
        f.write(json.dumps(rec) + "\n")

    print(f"\n{'task':16s} {'strict':>8s} {'rescued':>8s} {'best':>8s}   control (sweep)")
    print("-" * 62)
    ctl = {}
    for line in (E / "code" / "results-code.jsonl").read_text(encoding="utf-8").splitlines():
        if line.strip():
            r = json.loads(line)
            for d in r.get("detail", []):
                ctl[(r["label"], d["task"])] = d
    for r in rows:
        c = ctl.get(("qwen38-hard", r["task"]))
        cs = f"{c['final_passed']}/{c['final_total']}" if c else "n/a"
        print(f"{r['task']:16s} {r['strict']:8d} {r['rescued']:8d} {r['best']:8d}   {cs}")
    print(f"\nwrote {OUT}  ({rec['elapsed_s']}s)")
    print("A turn that still shows TRUNC with ~32k reasoning chars means the sampler did NOT fix it.")


if __name__ == "__main__":
    main()
