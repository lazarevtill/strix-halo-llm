# The public example suite

**This is not a benchmark. Never report a score from it.**

The measured suites in this repo are withheld on purpose: a published benchmark stops measuring
anything the moment models train on it, and on decontaminated SWE-rebench, A3B-class models score
roughly **4× below** their self-reported SWE-bench figures. That gap is benchmark leakage, and it is
what the private cases exist to avoid. See [../../../docs/PUBLISHING.md](../../../docs/PUBLISHING.md).

That created a problem nobody intended. `run-code-eval.py` read `tasks.json` at import, so on a
fresh clone `python smoke.py` — the script the README offers as *the reason to trust any number
here* — died with a `FileNotFoundError` traceback for every reader who was not the author. A harness
whose self-test cannot run is asking to be taken on faith, which is the one thing this repo refuses
to ask for.

So when `evals/code/tasks.json` is absent, the harness falls back to this directory and says so,
loudly, in its first five lines of output.

## What it is

One task, `example_stack`, in the same three-turn shape as the real ones — implement, extend, then
debug a stated failing case:

| turn | prompt asks for | tests |
|---|---|---:|
| 1 | `Stack` with `push`/`pop`/`peek`/`__len__`, raising `IndexError` when empty | 5 |
| 2 | `min()` in O(1) | 8 |
| 3 | fix duplicate-minimum tracking, add a `capacity` that raises `OverflowError` | 13 |

It is deliberately a textbook exercise that every model has already memorised. **That is the point.**
Publishing it teaches models nothing they do not already know, so it costs nothing to leak, while
still exercising every part of the machinery the real suites depend on:

- multi-turn prompting, and whether turn 2 breaks turn 1;
- `# ---- turn N additions ----` sections, so a turn is graded only on features already asked for;
- **parametrized tests** — turn 1 has 4 `def test_` but **5** tests, which is exactly why per-turn
  denominators are calibrated against the reference rather than counted statically (bug 6);
- fragment detection via the `entry` symbol (bug 12);
- reference calibration (bug 7) and the Docker sandbox.

Every model worth serving scores 100% here. It cannot rank anything, and a suite that everyone
passes measures the tasks, not the models — which is the whole finding behind the hard tier.

## Running it

```bash
docker build -f evals/code/Dockerfile.sandbox -t llm-eval-sandbox evals/code
python evals/code/smoke.py
```

`smoke.py` exits **0** when the harness checks out, **1** when a check genuinely failed, and **2**
when the sandbox could not be reached at all — because "we could not check" and "we checked and it
is broken" are different claims, and collapsing them is how an environment fault gets written down
as a quality result (bug 9).

To score a model against it, point the runner at any OpenAI-compatible endpoint:

```bash
python evals/code/run-code-eval.py --endpoint http://127.0.0.1:8080/v1 --label demo
```

## Writing your own

Three files, and `smoke.py` will refuse to let you get them wrong:

```
tasks.json                 {"tasks": [{"id", "entry", "tier", "turns": [t1, t2, t3]}]}
tests/test_<id>.py         pytest, sectioned by  # ---- turn N additions ----
reference/<id>.py          a known-good WHOLE FILE that passes every turn
```

The reference has to be a whole file because the harness overwrites `solution.py` wholesale — a
reply containing only the new method loses every earlier turn and fails on import. `smoke.py` scores
your reference at every turn and **fails loudly if any turn prompt is not satisfiable by it**. That
check is not optional: a turn-3 prompt here once asked for a spend to succeed while its own hidden
test asserted it fails, so it silently rewarded *ignoring the user*, and any model that engaged with
the contradiction scored 0 (bug 7).
