"""Self-test for rescore.py. No GPU, no Docker, no model -- run it before trusting a table.

The suite this repo carries has now produced twelve believable wrong numbers, and at least three of
them came from scoring logic that nobody re-read because it looked obviously right. `defines()` and
the turn-selection rule are exactly that kind of code, so they get a test with the failure shapes
written out explicitly.

The first version of this test FAILED and the test was what was wrong: it built a "final turn is a
fragment" case while marking the turn `fragment: False`, so the code correctly kept it. That is
recorded here because it is the same trap the harness fell into -- asserting on what you meant
rather than on what you wrote.

    python evals/test-rescore.py
"""
import importlib.util, pathlib, sys

_spec = importlib.util.spec_from_file_location("rs", pathlib.Path(__file__).with_name("rescore.py"))
rs = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(rs)

FAILURES = 0


def check_defines(code, entry, want, why):
    global FAILURES
    got = rs.defines(code, entry)
    ok = got == want
    FAILURES += not ok
    print(f"  {'ok  ' if ok else 'FAIL'} defines={str(got):5s} want={str(want):5s}  {why}")


def check_score(name, turns, entry, exp, total=37):
    """exp = (strict, rescued, best)."""
    global FAILURES
    r = rs.rescore_task("__no_transcripts__", "hard_where", {"final_total": total, "turns": turns}, entry)
    got = (r["strict"], r["rescued"], r["best"])
    ok = got == exp
    FAILURES += not ok
    print(f"  {'ok  ' if ok else 'FAIL'} {name:38s} strict={got[0]:3d} rescued={got[1]:3d} best={got[2]:3d}"
          + ("" if ok else f"   WANT {exp}"))


print("defines() -- a mention is not a definition (bug 12):")
# The exact line that defeated the old substring check.
check_defines("ver = Version(v) if isinstance(v, str) else v", "Version", False,
              "calls but does not define  <- THE BUG")
check_defines("class Version:\n    pass", "Version", True, "class")
check_defines("def evaluate(expr, row):\n    return True", "evaluate", True, "def")
check_defines("async def evaluate(x):\n    pass", "evaluate", True, "async def")
check_defines("Version = _make_version(...)", "Version", True, "assignment is a definition too")
check_defines("from _impl import Version, Range", "Version", True, "re-export is a definition too")
check_defines("# Version handling below\nx = 1", "Version", False, "comment only")
check_defines("class VersionRange:\n    pass", "Version", False, "prefix must not match")
check_defines("anything at all", None, True, "no entry symbol declared -> cannot be a fragment")

print("\nturn selection -- strict / rescued / best across failure shapes:")
# The case that matters most: peaks mid-run, regresses, then hands back a fragment. If rescued and
# best cannot diverge here, one of the two columns is dead weight in a published table.
check_score("non-monotonic, final turn a fragment",
            [{"passed": 14, "total": 14}, {"passed": 22, "total": 30},
             {"passed": 18, "total": 30}, {"passed": 0, "total": 37, "fragment": True}],
            "evaluate", (0, 18, 22))
# A real zero must NOT be rescued away -- that is bug 8, and rescuing everything is how the
# four-way tie was manufactured.
check_score("final turn legitimately scores 0",
            [{"passed": 14, "total": 14}, {"passed": 22, "total": 30},
             {"passed": 0, "total": 37, "fragment": False}],
            "evaluate", (0, 0, 22))
check_score("final turn truncated",
            [{"passed": 14, "total": 14}, {"passed": 20, "total": 30},
             {"passed": 3, "total": 37, "truncated": True}],
            "evaluate", (3, 20, 20))
# An environment failure is the box breaking, not the model answering.
check_score("final turn env failure",
            [{"passed": 14, "total": 14}, {"passed": 20, "total": 30},
             {"passed": 0, "total": 0, "env": True}],
            "evaluate", (20, 20, 20))
check_score("all turns fragments -> invent nothing",
            [{"passed": 0, "total": 14, "fragment": True},
             {"passed": 0, "total": 30, "fragment": True}],
            "evaluate", (0, 0, 0))
check_score("single clean turn",
            [{"passed": 14, "total": 14}], "evaluate", (14, 14, 14))

print(f"\n{'ALL PASS' if not FAILURES else f'{FAILURES} FAILURE(S)'}")
sys.exit(1 if FAILURES else 0)
