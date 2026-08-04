"""Run the canonical suite against solution.py. Designed to run INSIDE a sandboxed
Linux container (no network, read-only FS, capped mem/cpu). Per-test SIGALRM timeout
so a model's infinite loop kills only that test, not the whole run.
Prints: '<passed>/<total>  FAIL:<name> ...'  (or '0/12 IMPORT_ERROR ...').
"""
import sys, signal

PER_TEST_TIMEOUT = 5  # seconds


class _Timeout(Exception):
    pass


if hasattr(signal, "SIGALRM"):
    signal.signal(signal.SIGALRM, lambda *_: (_ for _ in ()).throw(_Timeout()))

try:
    import test_lru
except Exception as e:                        # solution.py syntax / import / infinite-loop-at-import
    print(f"0/12 IMPORT_ERROR {type(e).__name__}: {e}")
    sys.exit(0)

tests = sorted(n for n in dir(test_lru) if n.startswith("test_"))
passed, fails = 0, []
for n in tests:
    if hasattr(signal, "SIGALRM"):
        signal.alarm(PER_TEST_TIMEOUT)
    try:
        getattr(test_lru, n)()
        passed += 1
    except _Timeout:
        fails.append(f"{n}(timeout)")
    except Exception as e:
        fails.append(f"{n}({type(e).__name__})")
    finally:
        if hasattr(signal, "SIGALRM"):
            signal.alarm(0)
print(f"{passed}/{len(tests)}  " + " ".join("FAIL:" + f for f in fails))
