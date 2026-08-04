# Private evals

Two suites, both written for this fleet and published nowhere, so no model has trained on them.
That matters: the sweep found public agentic benchmarks are contaminated — decontaminated
SWE-rebench scores A3B-class models roughly 4x below their self-reported SWE-bench numbers.

| suite | what it measures | entry point |
|---|---|---|
| tool-calling | native `tools` array → `message.tool_calls`: right tool, right args, right enum, knows when NOT to call | `run-tools-eval.ps1` |
| agentic coding | 3-turn tasks scored against hidden pytest suites, **every turn** scored so regressions show | `code\run-code-eval.py` |

```powershell
.\run-tools-eval.ps1 -Endpoint http://127.0.0.1:8080/v1 -Label laguna-q4
python code\run-code-eval.py --endpoint http://127.0.0.1:8080/v1 --label laguna-q4
```

The coding sandbox image is built from `code\Dockerfile.sandbox` (base image and pip both via the
internal Harbor/Nexus mirrors):

```powershell
docker build -f code\Dockerfile.sandbox -t llm-eval-sandbox code
```

## Harness bugs found on 2026-08-03, and why they matter

Every one of these produced a *plausible-looking number* rather than an obvious crash. That is the
dangerous failure mode for an eval: a wrong score gets written down and believed.

**1. PowerShell re-wrapped the tools array.** `ConvertTo-Json` on a collection that came from
`ConvertFrom-Json` emits `{"value":[...],"Count":n}`, so llama-server answered every request with
`500 Failed to parse tools`. Fix: keep `tools.json` as raw text and splice it into the body.

**2. A failed request scored as a PASS.** The abstain cases expect *zero* tool calls, and a 500
produces zero tool calls. A completely broken run reported **5/29 = 17.2%** — high enough to look
like a real signal. Fix: an errored request is unconditionally a FAIL.

**3. Argument pairing did not consume.** For every expectation the scorer took
`@($got | Where-Object name -eq $e.name)[0]` — the *first* call of that name. Any case expecting the
same tool twice with different arguments (`get_host_metrics` on box-1 **and** box-2) compared both
expectations against the first call and reported `expected 'box-2' got 'box-1'` no matter what the
model did. This manufactured 2 of Laguna's 9 failures; the model had answered both correctly.
Fix: each expectation claims the best-matching *unconsumed* call.

**4. The runner was single-turn.** It demanded that every expected call arrive in one response. For
a chain case — *"deploy X to box-1, then benchmark it"* — a correct agent deploys, reads the result,
then benchmarks; it cannot know the deploy succeeded otherwise. Scoring that single-turn marked
correct sequential behaviour as failure. Fix: a real agent loop feeding synthetic (deliberately
uninformative) tool results back, accumulating calls across turns.

Consequence of 3 and 4: **parallel batching is now reported separately from correctness.** Whether a
model emits several calls in one response or one per turn is a real property that harnesses depend
on, but it is not a wrong answer and must not be folded into the pass rate.

**5. The denominator kept shrinking, three separate ways.** Each one flattered the model, and each
looked like a normal result:

| symptom | fake number | true number |
|---|---|---|
| a task that never ran contributed `final_total = 0` and vanished from the sum | `34/34 = 100%` | 2 of 4 tasks had not run at all |
| `skipped` was never parsed, so skipped tests left the total | first-shot `67.2%` | `64.3%` |
| a turn whose code fails to import reports `1 error`, i.e. `0/1`, not `0/20` | `47/51 = 92.2%` | `47/70 = 67.1%` |

The third is the nastiest: the denominator shrank *precisely when the model did worst*, so a task
that produced unimportable garbage cost almost nothing. Static counting cannot fix it either —
`token_budget` has 18 `def test_` but 20 tests, two being parametrized. The fix is to take the
largest total any turn observed as the task's denominator, since a healthy turn collects them all.

**6. Turn 1 was graded on features the prompt had not asked for yet.** The hidden suites are written
in `# ---- turn N additions ----` sections, but every turn was scored against *all* tests. So turn 1
could only ever score the turn-1 test count — 12/8/14/11 for the four tasks. Laguna, Ornith and
Qwen returned **byte-identical** first-turn scores on every run, because the number was a property
of the test file, not of any model. "First-shot 64.3%" was arithmetic on the suite's composition;
scored correctly all three are **45/45 = 100%**. Turns are now deselected past `max_turn`, and the
per-turn denominators are *calibrated* by scoring the reference solution at each turn — the only
method that survives parametrized tests (`token_budget` turn 1 is 12 tests from 10 `def test_`) and
that cannot shrink when a model does badly.

**7. A task can be unsatisfiable, and then it measures obedience instead of skill.** `token_budget`
turn 3 asked for `spend('a', 80)` to succeed while the hidden test asserts it returns `False`, and
its stated arithmetic (`reserve_remaining() == 5` after spending the whole budget) is impossible.
A model that faithfully fixed the reported bug failed the suite; a model that ignored the user
passed. One model burned 40 KB of reasoning looping on the contradiction and scored 0. Always
verify a debug turn against a reference implementation — `smoke.py` now does exactly this.

**8. Scoring a truncated turn as the model's answer invented a ranking.** Each of the three models
truncated exactly once on turn 3. Counting those as zeros produced 95.7% / 74.3% / 72.9% for models
that are otherwise identical; scored on the last *complete* answer they are 70/70, 70/70, 69/70.
A cut-off response is not an answer — mark the turn invalid, score the last valid artifact, and
report truncation rate separately.

**9. Environment failures were indistinguishable from model failures.** Two ways the box takes a run
down, both observed the same afternoon:

- a foreign `llama-server` appears and pushes past the ~109 GiB ceiling → every later request 500s;
- something restarts the old bench stack, which kills the server under test → every later request
  refuses the connection (this produced a clean **0/29**).

The runner now records the server PID and foreign GPU commit at start, re-checks both on every
failure, and labels the case `ENVIRONMENT` instead of scoring it as quality.

> Read **`Total Committed`**, never `Dedicated Usage`. WDDM trims an idle model's dedicated bytes to
> ~0 while it still holds the reservation, so the dedicated counter under-reported two resident
> servers by 42.5 GiB — which is exactly how the box hit its ceiling while the console showed plenty
> of headroom.
