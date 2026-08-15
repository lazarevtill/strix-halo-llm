"""Re-derive coding scores from stored runs, with fragment detection that actually works.

WHY THIS EXISTS (bug 12, evals/README.md)
-----------------------------------------
Multi-turn prompts say "Add a `Range` class", so models reply with only the new code. The harness
overwrites solution.py wholesale, so a partial reply loses every earlier turn and fails on import.
run-code-eval.py anticipated that and flags such turns FRAGMENT -- but tested `entry not in code`,
a SUBSTRING match. A fragment that merely *calls* the entry symbol contains the string, so it was
graded as a complete solution and scored 0, indistinguishable from a model that wrote garbage.

7 of the first 19 graded hard-tier turns were misclassified. Every zero in ornith's hard run was
one of them.

NO SANDBOX RUNS HAPPEN HERE, and that is the point. The per-turn pass counts in results-code.jsonl
are what pytest actually said and were never in doubt. What was wrong is the SELECTION RULE -- which
turn is treated as the model's answer. So this re-derives from stored data plus the stored
transcripts, costs no GPU and no Docker, and can be re-run freely as the harness changes.

THREE NUMBERS, ALWAYS TOGETHER
------------------------------
  strict   the final turn, whatever it was. Punishes losing your work at the handoff.
  rescued  the last turn that actually delivered a whole file. Punishes bad code.
  best     the high-water mark across turns. What the model demonstrably got working at least once.

Quoting one alone is how this suite has gone wrong twice. `strict` alone reads as "it cannot code";
`best` alone reads as "it is fine" while hiding that the artifact you would ship is broken. The gap
between them IS the finding.

Usage:  python evals/rescore.py [--tier hard] [--label ornith-hard]
"""
import argparse, json, pathlib, re, sys

E = pathlib.Path(__file__).resolve().parent
RESULTS = E / "code" / "results-code.jsonl"
TRANSCRIPTS = E / "code" / "transcripts"
TASKS_JSON = E / "code" / "tasks.json"


def entry_symbols() -> dict:
    """task id -> the symbol whose DEFINITION makes a reply a whole file rather than a diff."""
    raw = json.loads(TASKS_JSON.read_text(encoding="utf-8"))["tasks"]
    return {t["id"]: t.get("entry") for t in raw}


def defines(code: str, entry: str) -> bool:
    """True when `entry` is DEFINED here, not merely mentioned.

    This is the whole bug. `"Version" in code` is satisfied by `Version(v)` on the right-hand side
    of an assignment inside a fragment that defines nothing at all.

    Deliberately a regex and not an AST parse: a fragment with a syntax error still needs a verdict,
    and ast.parse raises on exactly the inputs that matter most here.
    """
    if not entry:
        return True
    pat = rf"^\s*(?:async\s+def|def|class)\s+{re.escape(entry)}\b"
    if re.search(pat, code, re.M):
        return True
    # `Version = _make_version(...)` and `from x import Version` are legitimate definitions too.
    if re.search(rf"^\s*{re.escape(entry)}\s*=", code, re.M):
        return True
    if re.search(rf"^\s*from\s+\S+\s+import\s+.*\b{re.escape(entry)}\b", code, re.M):
        return True
    return False


def turn_code(label: str, task_id: str, turn: int) -> str | None:
    p = TRANSCRIPTS / f"{label}-{task_id}-t{turn}.py"
    if not p.exists():
        return None
    return p.read_text(encoding="utf-8", errors="replace")


def rescore_task(label: str, task_id: str, detail: dict, entry: str) -> dict:
    """Re-apply the selection rule with corrected fragment flags."""
    total = detail["final_total"]
    turns, fixed = detail.get("turns", []), []
    for i, t in enumerate(turns, 1):
        code = turn_code(label, task_id, i)
        # Missing transcript: fall back to what the harness recorded rather than guessing. Older
        # runs predate transcript dumping, and silently treating those as fragments would invent
        # a correction that the evidence does not support.
        if code is None:
            frag, why = bool(t.get("fragment")), "stored"
        elif not code.strip():
            frag, why = True, "empty"
        else:
            frag, why = (not defines(code, entry)), "recomputed"
        fixed.append({
            "turn": i,
            "passed": t.get("passed", 0) or 0,
            "total": t.get("total", 0) or 0,
            "truncated": bool(t.get("truncated")),
            "env": bool(t.get("env")),
            "fragment_was": bool(t.get("fragment")),
            "fragment_now": frag,
            "source": why,
            "flipped": bool(t.get("fragment")) != frag,
        })

    # A turn counts as a real answer only if it ran, delivered a whole file, and was not cut off.
    usable = [t for t in fixed if not t["env"] and not t["fragment_now"] and not t["truncated"]]
    scored = [t for t in fixed if not t["env"]]

    return {
        "task": task_id,
        "total": total,
        "strict": (scored[-1]["passed"] if scored else 0),
        "rescued": (usable[-1]["passed"] if usable else 0),
        "best": max([t["passed"] for t in usable], default=0),
        "flips": sum(1 for t in fixed if t["flipped"]),
        "turns": fixed,
    }


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--tier", default="hard", help="hard | easy | all")
    ap.add_argument("--label", default=None, help="only this run label")
    ap.add_argument("--json", action="store_true", help="dump the full structure")
    ap.add_argument("--include-legacy", action="store_true",
                    help="also rescore pre-2026-08-15 runs (see the warning this prints)")
    a = ap.parse_args()

    if not RESULTS.exists():
        sys.exit(f"no results file at {RESULTS}")
    ent = entry_symbols()

    # Rows are appended forever and earlier rows are a different harness vintage; keep the last per
    # label rather than averaging vintages together.
    runs = {}
    for line in RESULTS.read_text(encoding="utf-8").splitlines():
        if line.strip():
            r = json.loads(line)
            runs[r["label"]] = r

    # VINTAGE GATE. Runs predating 2026-08-15 have no `by_tier` key, no per-task `tier`, and -- the
    # part that matters -- were produced at temperature 0, the contamination of bug 10. Rescoring
    # them yields a "corrected" figure for a run that was invalid for an unrelated reason, which is
    # precisely the kind of number that escapes into a table. Their detail rows also lack `tier`, so
    # they would fall through to the filename heuristic and land in `easy` uninvited.
    legacy = [k for k, r in runs.items() if not r.get("by_tier")]
    if legacy and not a.include_legacy:
        print(f"skipping {len(legacy)} pre-2026-08-15 run(s): {', '.join(sorted(legacy))}")
        print("  they ran at temperature 0 (bug 10) -- rescoring cannot make them valid.")
        print("  --include-legacy overrides this.\n")
        runs = {k: r for k, r in runs.items() if k not in legacy}

    out, any_rows = [], False
    for label, run in runs.items():
        if a.label and label != a.label:
            continue
        rows = [d for d in run.get("detail", [])
                if a.tier == "all" or (d.get("tier") or run.get("tier") or
                                       ("hard" if d["task"].startswith("hard_") else "easy")) == a.tier]
        if not rows:
            continue
        any_rows = True
        res = [rescore_task(label, d["task"], d, ent.get(d["task"])) for d in rows]
        out.append({"label": label, "ts": run.get("ts"), "tasks": res})

    if not any_rows:
        print(f"no {a.tier}-tier rows yet"
              + (f" for {a.label}" if a.label else "")
              + " -- the sweep may not have reached them.")
        return

    if a.json:
        print(json.dumps(out, indent=2))
        return

    incomplete = []
    print(f"\n{'run':16s} {'strict':>12s} {'rescued':>12s} {'best':>12s}  "
          f"{'cov':>5s} {'frag':>6s} {'noCode':>6s} {'flips':>5s} {'stored':>6s}")
    print("-" * 94)
    for r in out:
        tot = sum(t["total"] for t in r["tasks"])
        s = sum(t["strict"] for t in r["tasks"])
        g = sum(t["rescued"] for t in r["tasks"])
        b = sum(t["best"] for t in r["tasks"])
        f = sum(t["flips"] for t in r["tasks"])
        # WHOLE-FILE DISCIPLINE, and it explains more of the ranking than the score does.
        # A model that re-emits the complete file every turn survives a bad turn; one that replies
        # with diffs turns a single failure into a zeroed task. Reported next to the score so nobody
        # has to infer it from the per-task dump.
        nturn = sum(len(t["turns"]) for t in r["tasks"])
        nfrag = sum(1 for t in r["tasks"] for x in t["turns"] if x["fragment_now"])
        # Turns that emitted nothing at all: the sampler pathology of bug 13, not an answer.
        nnone = sum(1 for t in r["tasks"] for x in t["turns"]
                    if x["truncated"] and x["passed"] == 0)
        # COVERAGE. A task that died on an environment fault contributes 0/0 and VANISHES from the
        # denominator, so a run that completed 1 of 3 tasks prints the best percentage in the sweep.
        # That is bug 5 verbatim, reappearing in the tool written to correct bug 12. The percentage
        # is not wrong for what it covers -- it is wrong to put it in a column beside runs that
        # covered everything, so incomplete runs are marked and never rank.
        ndone = sum(1 for t in r["tasks"] if t["total"] > 0)
        ntask = len(r["tasks"])
        partial = ndone < ntask
        # Turns with no transcript on disk keep the OLD (broken) fragment flag. Surfacing that in
        # the table, not just the JSON, so a partially-corrected row can never read as fully
        # corrected.
        st = sum(1 for t in r["tasks"] for x in t["turns"] if x["source"] == "stored")
        mark = "*" if partial else " "
        pct = lambda v: (f"{v:3d}/{tot:<3d}{100*v/tot:3.0f}%{mark}" if tot else "  --      ")
        print(f"{r['label']:16s} {pct(s):>12s} {pct(g):>12s} {pct(b):>12s}  "
              f"{f'{ndone}/{ntask}':>5s} {f'{nfrag}/{nturn}':>6s} {nnone:6d} {f:5d} {st:6d}")
        if partial:
            dead = [t["task"] for t in r["tasks"] if t["total"] == 0]
            incomplete.append((r["label"], ndone, ntask, dead))
    for label, ndone, ntask, dead in incomplete:
        print(f"\n!! {label} is marked * -- it scored {ndone} of {ntask} tasks. "
              f"Aborted: {', '.join(dead)}.")
        print("   Its percentage is computed over the tasks that RAN, so it is NOT comparable")
        print("   with the complete runs above and must not be ranked against them.")
    if any(x["source"] == "stored" for r in out for t in r["tasks"] for x in t["turns"]):
        print("\n!! 'stored' counts turns with no transcript on disk -- those keep the ORIGINAL,")
        print("   broken fragment flag. Those rows are NOT fully corrected.")

    print("\nper task:")
    for r in out:
        print(f"\n  {r['label']}")
        for t in r["tasks"]:
            print(f"    {t['task']:16s} strict={t['strict']:3d}  rescued={t['rescued']:3d}  "
                  f"best={t['best']:3d}   of {t['total']}")
            for x in t["turns"]:
                flags = " ".join(fl for fl, on in (
                    ("TRUNC", x["truncated"]), ("ENV", x["env"]),
                    ("FRAG", x["fragment_now"]), ("<-was not FRAG", x["flipped"])) if on)
                print(f"       t{x['turn']}: {x['passed']:3d}/{x['total']:<3d} {flags}")

    flips = sum(t["flips"] for r in out for t in r["tasks"])
    # ASCII only. This prints to a PowerShell 5.1 console at cp1252, where a middot arrives as a
    # replacement char and makes correct output look like a bug.
    print(f"\n{flips} turn(s) reclassified by definition-checking the entry symbol (bug 12).")
    print("strict = final turn | rescued = last whole-file turn | best = high-water mark.")
    print("Quote all three. The gap between them is the finding, not a detail.")


if __name__ == "__main__":
    main()
