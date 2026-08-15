"""Turn a full-bench run into the table that gets published.

Reads the speed JSONs and results-code.jsonl written by run-full-bench.ps1 and prints one
row per model. Deliberately opinionated about what it will and will not report:

  * the HARD tier is quoted on its own, because the easy tier is saturated and mixing the
    two drags every model toward the same number;
  * every score is shown twice, rescued and strict, so the truncation rule can never again
    be the thing that produced the ranking;
  * effective n is the TASK count, not the test count. Tests cluster inside tasks; "89/89"
    implies far more evidence than 3 tasks provide, and that overclaim is how the last
    comparison went wrong.

Usage:  python summarize-bench.py [--stamp 20260815-1630]
"""
import argparse, json, pathlib, re, sys

E = pathlib.Path(__file__).resolve().parent
RES = E / "results"


def load_speed(stamp):
    """llama-bench JSON, minus the backend chatter PowerShell folds into the same file."""
    out = {}
    for f in RES.glob(f"speed-*-{stamp}.json"):
        label = f.name[len("speed-"):-len(f"-{stamp}.json")]
        # Decode by BOM, not by assumption. PowerShell 5.1's Tee-Object writes UTF-16LE, so
        # reading these as UTF-8 yields a NUL between every character -- no line ever equals "[",
        # and every file reports as unparseable for a reason that looks nothing like an encoding
        # problem.
        raw = f.read_bytes()
        for bom, enc in ((b"\xff\xfe", "utf-16-le"), (b"\xfe\xff", "utf-16-be"),
                         (b"\xef\xbb\xbf", "utf-8-sig")):
            if raw.startswith(bom):
                txt = raw.decode(enc, errors="replace")
                break
        else:
            txt = raw.decode("utf-8", errors="replace")
        # Find the line that IS the opening bracket, not the first '[' character. llama-bench
        # writes its backend banner to stderr, and PowerShell wraps that in a NativeCommandError
        # block containing the literal "[], RemoteException" -- so scanning for the first '['
        # lands inside the error text and every file reads as unparseable.
        lines = txt.splitlines()
        start = next((n for n, l in enumerate(lines) if l.strip() == "["), None)
        if start is None:
            print(f"  !! {f.name}: no JSON array found", file=sys.stderr)
            continue
        try:
            rows = json.loads("\n".join(lines[start:]))
        except json.JSONDecodeError as ex:
            print(f"  !! {f.name}: unparseable ({ex})", file=sys.stderr)
            continue
        rec = {}
        for r in rows:
            if r.get("n_prompt"):
                rec["pp"] = r["avg_ts"]; rec["pp_sd"] = r.get("stddev_ts", 0)
            elif r.get("n_gen"):
                rec["tg"] = r["avg_ts"]; rec["tg_sd"] = r.get("stddev_ts", 0)
            rec["size_gb"] = r.get("model_size", 0) / 1e9
            rec["build"] = r.get("build_number")
        out[label] = rec
    return out


def load_quality():
    """Last run per label from results-code.jsonl. Rows are appended forever; earlier rows are
    a different harness vintage and must not be averaged with the current one."""
    p = E / "code" / "results-code.jsonl"
    out = {}
    for line in p.read_text(encoding="utf-8").splitlines():
        if not line.strip():
            continue
        r = json.loads(line)
        out[r["label"]] = r          # later rows overwrite earlier ones
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--stamp", default="20260815-1630")
    a = ap.parse_args()

    speed = load_speed(a.stamp)
    qual = load_quality()

    order = ["ornith", "qwen38", "qwen122b", "laguna", "deepseek"]
    labels = [l for l in order if l in speed or any(k.startswith(l + "-") for k in qual)]

    print(f"\n{'model':10s} {'GB':>6s} {'pp t/s':>9s} {'tg t/s':>9s} "
          f"{'HARD':>11s} {'strict':>11s} {'easy':>11s} {'trunc':>6s}")
    print("-" * 82)
    for l in labels:
        s = speed.get(l, {})
        h = qual.get(f"{l}-hard", {})
        e = qual.get(f"{l}-easy", {})

        def tier(row, name):
            bt = (row.get("by_tier") or {}).get(name)
            if not bt or not bt.get("total"):
                return "  --      ", "  --      ", 0
            p, st, t = bt["passed"], bt["strict"], bt["total"]
            return (f"{p:3d}/{t:<3d}{100*p/t:4.0f}%", f"{st:3d}/{t:<3d}{100*st/t:4.0f}%", t)

        hp, hs, _ = tier(h, "hard")
        ep, _, _ = tier(e, "easy")
        trunc = (h.get("truncated_turns", 0) or 0) + (e.get("truncated_turns", 0) or 0)
        print(f"{l:10s} {s.get('size_gb',0):6.1f} "
              f"{s.get('pp',0):9.1f} {s.get('tg',0):9.1f} "
              f"{hp:>11s} {hs:>11s} {ep:>11s} {trunc:6d}")

    print("\nper-task, hard tier (effective n = 3 tasks, NOT 89 tests):")
    for l in labels:
        h = qual.get(f"{l}-hard")
        if not h:
            continue
        bits = []
        for d in h.get("detail", []):
            flag = ""
            if d["final_passed"] != d.get("strict_passed", d["final_passed"]):
                flag = "*"          # the rescue moved this number
            if d.get("regressed"):
                flag += "R"
            bits.append(f"{d['task']}={d['final_passed']}/{d['final_total']}{flag}")
        print(f"  {l:10s} " + "  ".join(bits))
    print("\n  * rescued (a later turn truncated and lost work)   R regressed across turns")

    missing = [l for l in labels if f"{l}-hard" not in qual]
    if missing:
        print(f"\n!! no hard-tier result yet for: {', '.join(missing)} -- run incomplete")


if __name__ == "__main__":
    main()
