"""Prove the harness works BEFORE spending hours on a model run.

Every bug found on 2026-08-03 was discovered *after* a run had produced a number that looked real:
a broken tools array read 17.2%, a dead server read 0/29, a shrinking denominator read 92.2% and
100%, prose-in-solution.py read as a coding failure, and a self-contradictory task prompt read as
"qwen cannot code". All of them were cheap to detect up front and expensive to detect afterwards.

This asserts three things, in ~30s:

  1. SANDBOX DISCRIMINATES -- a known-good solution passes its hidden suite 100%, a known-bad one
     does not, and prose scores as NO CODE rather than as a coding failure.
  2. TASK PROMPTS ARE SATISFIABLE -- for every task, the reference solution passes ALL hidden tests.
     A turn-3 prompt that contradicts its own tests (as token_budget's did: it asked for
     spend('a',80) to succeed while the test asserts it returns False) cannot be satisfied by any
     model, so it measures obedience-vs-spec instead of debugging.
  3. EXTRACTION IS SANE -- fenced, unfenced and prose replies classify correctly.

Usage:  python smoke.py            # exits non-zero if the harness is not trustworthy
"""
import json, pathlib, subprocess as sp, sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import importlib.util

E = pathlib.Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("rce", E / "run-code-eval.py")
rce = importlib.util.module_from_spec(spec)
spec.loader.exec_module(rce)

# Resolved by run-code-eval.py: the private suite when it is present, the public example suite
# otherwise. smoke.py has to work in BOTH cases -- a self-test only the author can run is not
# evidence anyone else can act on.
REF = rce.REFDIR
fails = []


def check(name, cond, detail=""):
    print(f"  [{'PASS' if cond else 'FAIL'}] {name}{'' if cond else '  -- ' + detail}")
    if not cond:
        fails.append(name)


def sandbox_available():
    """Is the Docker sandbox usable at all? Returns (ok, why_not).

    Bug 9 in evals/README.md is that an environment failure and a model failure looked identical,
    so the runner learned to tell them apart -- and then this script went on conflating them. With
    no Docker every sandbox check returns 0/0 and smoke.py printed "HARNESS NOT TRUSTWORTHY",
    accusing the harness of a defect when the truth is that nothing was measured at all. The first
    thing a stranger runs should not misreport what it found.
    """
    try:
        r = sp.run(["docker", "image", "inspect", rce.SANDBOX_IMAGE],
                   capture_output=True, text=True, timeout=60)
    except FileNotFoundError:
        return False, "docker is not installed or not on PATH"
    except sp.TimeoutExpired:
        return False, "docker did not respond within 60s (daemon not running?)"
    if r.returncode == 0:
        return True, ""
    lines = (r.stderr or r.stdout).strip().splitlines()
    tail = lines[-1][:160] if lines else f"rc={r.returncode}"
    if "no such image" in tail.lower():
        return False, (f"sandbox image '{rce.SANDBOX_IMAGE}' is not built -- run: "
                       f"docker build -f evals/code/Dockerfile.sandbox -t {rce.SANDBOX_IMAGE} evals/code")
    return False, f"docker present but not usable: {tail}"


print("1. extraction")
for raw, want in [
    ("here you go\n```python\nclass A:\n    pass\n```\n", "fenced"),
    ("import os\nclass A:\n    pass\n", "unfenced"),
    ("Thinking Process:\n1. First I should consider whether the reserve...\n", "none"),
    ("", "none"),
]:
    code, how = rce.extract_code(raw)
    check(f"extract({raw[:24]!r}...) -> {want}", how == want, f"got {how}")

SANDBOX_OK, SANDBOX_WHY = sandbox_available()

print("\n2. sandbox discriminates")
if not SANDBOX_OK:
    print(f"  [SKIP] {SANDBOX_WHY}")
else:
    good = "def add(a, b):\n    return a + b\n"
    bad = "def add(a, b):\n    return a - b\n"
    broken = "this is not python at all ((("
    rce.TESTDIR.mkdir(parents=True, exist_ok=True)
    probe = rce.TESTDIR / "test__smoke.py"
    probe.write_text("from solution import add\n\ndef test_a():\n    assert add(2, 3) == 5\n\ndef test_b():\n    assert add(0, 0) == 0\n", encoding="utf-8")
    try:
        p, t, note = rce.score_in_sandbox("_smoke", good)
        check("known-good solution passes 2/2", (p, t) == (2, 2), f"got {p}/{t} ({note})")
        p, t, note = rce.score_in_sandbox("_smoke", bad)
        check("known-bad solution does not pass", p < t and t > 0, f"got {p}/{t} ({note})")
        p, t, note = rce.score_in_sandbox("_smoke", broken)
        check("unparsable code scores 0, not a crash", p == 0, f"got {p}/{t} ({note})")
    finally:
        probe.unlink(missing_ok=True)

print("\n3. task prompts are satisfiable by the reference solution")
if not SANDBOX_OK:
    print(f"  [SKIP] {SANDBOX_WHY}")
tasks = [] if not SANDBOX_OK else rce.TASKS
for task in tasks:
    tid = task["id"]
    ref = REF / f"{tid}.py"
    if not ref.exists():
        check(f"{tid}: reference solution present", False,
              f"missing {ref} -- cannot prove the prompts are satisfiable")
        continue
    p, t, note = rce.score_in_sandbox(tid, ref.read_text(encoding="utf-8"))
    check(f"{tid}: reference passes all {t} hidden tests", t > 0 and p == t, f"got {p}/{t} ({note})")

print()
if fails:
    print(f"HARNESS NOT TRUSTWORTHY -- {len(fails)} check(s) failed: {', '.join(fails)}")
    sys.exit(1)
if not SANDBOX_OK:
    # Exit 2, not 0 and not 1. Callers must still refuse to start a multi-hour sweep -- nothing was
    # scored -- but "we could not check" is a different claim from "we checked and it is broken",
    # and collapsing the two is how an environment fault gets written down as a quality result.
    print(f"CANNOT VERIFY -- extraction is sane, but the sandbox could not be reached: {SANDBOX_WHY}")
    print("Nothing was scored. This is an environment gap, NOT evidence that the harness is wrong.")
    sys.exit(2)
if rce.USING_EXAMPLES:
    print("harness OK -- verified against the PUBLIC EXAMPLE SUITE. It proves the machinery works;")
    print("it says nothing about any model. The measured suites are private (docs/PUBLISHING.md).")
    sys.exit(0)
print("harness OK")
