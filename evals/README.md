# Private evals

Two suites, both written for this fleet and published nowhere, so no model has trained on them.
That matters: the sweep found public agentic benchmarks are contaminated — decontaminated
SWE-rebench scores A3B-class models roughly 4x below their self-reported SWE-bench numbers.

| suite | what it measures | entry point |
|---|---|---|
| tool-calling | native `tools` array → `message.tool_calls`: right tool, right args, right enum, knows when NOT to call | `run-tools-eval.ps1` |
| agentic coding | multi-turn tasks scored against hidden pytest suites, **every turn** scored so regressions show | `code\run-code-eval.py` |

```powershell
.\run-tools-eval.ps1 -Endpoint http://127.0.0.1:8080/v1 -Label laguna-q4
python code\run-code-eval.py --endpoint http://127.0.0.1:8080/v1 --label laguna-q4

.\run-full-bench.ps1                     # everything: speed, then hard tier, then easy + tools
python summarize-bench.py                # a completed run -> the published table
```

## Two tiers, and why the easy one is not enough

| tier | tasks | hidden tests | turns | state |
|---|---|---|---|---|
| easy | 4 | 70 | 3 | **saturated** — every model measured returns 70/70 |
| **hard** | 3 | 89 | 4 | discriminates: 55% and 28% for the first two models — but see bugs 12 and 13 before reading that as a ranking |

A benchmark everyone passes measures the tasks, not the models. The hard tier exists because four
models spanning 16.7 GB to 89 GB all returned 70/70 on the easy one. Its hidden tests probe what
each spec *implies* rather than what it states — a token bucket that must stay correct under clock
skew and sub-millisecond refill, semver range semantics including prerelease exclusion, and a SQL
`WHERE` evaluator in full three-valued logic.

**The tiers are scored and reported separately.** A combined percentage is dominated by the tests
that separate nothing, and drags every model toward the same number.

## Reading a result

Every task reports its score **twice**:

- **rescued** — the last turn that did not lose work to truncation;
- **strict** — the last turn that reached the sandbox, taken at face value.

If they agree, the rescue rule did nothing. If they diverge, that divergence *is* the finding —
see bug 10 below for what happened when only the rescued number was reported.

Before any run, `calibrate()` scores every reference solution against its own hidden suite at every
turn. If a reference cannot pass its own tests, that turn's prompt is unsatisfiable and every model
score on it is noise (bug 7). All 7 tasks currently calibrate at 100%.

The coding sandbox image is built from `code\Dockerfile.sandbox`. Registry and package index are
build ARGs, public by default, so it builds anywhere:

```powershell
docker build -f code\Dockerfile.sandbox -t llm-eval-sandbox code
```

Behind a private mirror, add
`--build-arg BASE_IMAGE=<registry>/proxy/python:3.12-slim --build-arg PIP_INDEX_URL=<index-url>`.

**Run `python code\smoke.py` before trusting any number** — it gates every run via
`run-guarded.ps1` and refuses to start a multi-hour sweep on a harness that cannot score itself.
What exactly the suites contain (category counts, what each isolates, what each coding task is) is
documented in `..\docs\BENCHMARKS.md`; the cases themselves are withheld — see `..\docs\PUBLISHING.md`.

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

> ⚠️ **This fix was itself the problem.** Read bug 10 before adopting it. The rule is right in
> principle and was applied far too broadly: it also rescued turns where the model emitted
> *nothing*, which is what produced the fake tie. The current version only excludes a truncated
> turn when truncation actually **cost** work, and reports the unrescued score alongside so the
> rule can never again be the thing that produced the ranking.

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

## The one found on 2026-08-15 — and it invalidated everything above it

**10. Greedy decoding produced empty answers, and the fix for bug 8 hid them.** Both suites ran at
`temperature 0`, chosen for reproducibility: same input, same output, no sampling noise between
models. For thinking models that is measurably wrong.

Auditing the retained transcripts found that **every truncated turn was a repetition loop that
emitted no answer at all — 9 of 9, across all four models.** One line repeated up to 439 times
until the token budget ran out; `content` was empty in every case.

```
laguna    window_merge    t3   439x repeat   166 KB   no answer
qwen122b  quant_pick      t2   160x repeat    54 KB   no answer
ornith    hard_ratelimit  t3   134x repeat   175 KB   no answer
```

Qwen ships the warning on its own model cards: *"We do NOT recommend using greedy decoding, as it
can lead to performance degradation and endless repetitions."*

The reason it went unnoticed for two weeks is bug 8's fix. Excluding truncated turns silently
rescued every one of those turns — so four very different models all reported 70/70. Re-scoring the
same transcripts without the rescue: qwen122b's 70/70 contains a raw **0/20** and **0/18**;
qwen38's contains **3/18**; laguna's contains a turn that emitted no code at all.

**The lesson is not "temperature 0 is bad".** It is that a rule which discards inconvenient data
must report what it discarded. A scoring rule that decides its own audit is not an audit.

Fixed: `TEMP = 0.3` with temp and seed written into every result row; truncation exclusion now
requires that truncation actually cost work; and every task reports rescued **and** strict scores.
`max_tokens` also moved to 32768 in a single call rather than 16384-with-retry — at a fixed seed the
retry re-derived the same prefix, so it only ever bought room, at ~16 minutes per turn.

**11. A saturated benchmark looks exactly like a set of tied models.** Even with the sampler fixed,
70/70 across four models spanning 16.7 GB to 89 GB says nothing about ranking. A hard tier was added
in response (3 tasks, 89 tests, 4 turns). The first model through it — which scores 70/70 on the
easy tier — scored **16/89**, passing every first-turn test and then collapsing when asked to extend
its own code. If your benchmark has no failures in it, it has no information in it either.

> ⚠️ **That 16/89 is itself mostly an artifact — see bug 12, found 2026-08-15 while the sweep was
> still running.** The collapse is real in the sense that the models did produce unusable final
> files; it is *not* evidence that they cannot write the code.

**12. Fragment detection used substring containment, so partial answers scored as broken code.**
Multi-turn prompts say *"Add a `Range` class"*, and models reasonably reply with **only the new
code**. The harness overwrites `solution.py` wholesale, so a partial reply loses everything from
earlier turns and fails on import. That case was anticipated — turns are flagged `FRAGMENT` and kept
out of the "regressed" claim — but the check was:

```python
fragment = bool(code) and task.get("entry") and task["entry"] not in code   # WRONG
```

`"Version" not in code` is a **substring** test. A fragment that merely *calls* the entry symbol
(`ver = Version(v) if isinstance(v, str) else v`) contains the string, so it was classified as a
complete solution and scored **0** — indistinguishable from a model that wrote garbage. Detection
has to ask whether the symbol is **defined**:

```python
re.search(rf"^(class|def)\s+{re.escape(entry)}\b", code, re.M)
```

**7 of the 19 graded hard-tier turns were misclassified this way**, and every single zero in the
first model's hard-tier run traces to it. Rescored on the best turn each task reached rather than
the final one, that model goes from **16/89 (18%)** to **49/89 (55%)**.

Two lessons, and the second is the uncomfortable one:

- A cheap approximation inside a *safeguard* is worse than no safeguard, because the safeguard's
  existence is what stops anyone looking again.
- **There is no system prompt telling the model to return the complete file**, and no turn prompt
  says it either. The harness requires it; nothing communicates it. Scoring a model down for that is
  measuring an unstated requirement, not coding ability. The reference solutions pass 100% at every
  turn precisely because they were *written* as whole files — calibration could never have caught
  this, which is why it didn't.

**13. Raising the temperature did not stop the looping, and a turn-1 loop now costs the whole
task.** Bug 10 blamed greedy decoding for models emitting no answer, and the fix was `temp 0.3`.
The second model through the hard tier looped anyway, twice, in two different ways — both burning
the full 32,768-token budget inside `reasoning_content` and returning **empty `content`**:

| task | turn 1 | what the transcript contains |
|---|---|---|
| `hard_semver` | `finish_reason: length`, no code | a **13,422-character run of the digit `0`** — degenerate character collapse |
| `hard_where` | `finish_reason: length`, no code | the same reasoning block (`"Good. Ok. Need maybe think about if expression has…"`) repeated **26+ times** — a semantic loop that never terminates |

A character-repetition loop and a reasoning loop are different failures, and a temperature that
suppresses one need not touch the other.

**The multi-turn structure then multiplies the damage.** Turn 1 establishes the file every later
turn edits. When turn 1 emits nothing, turns 2-4 are diffs against a file that does not exist, so
they are all fragments and the task scores **0/27 and 0/37** — 64 of 89 tests lost to two sampler
events. That model scored **25/25, a clean sweep, on the one hard task where it did not loop**,
beating the model that "won" the tier at 16/25.

So the tier is currently measuring **"does this model loop on turn 1"** at least as much as it
measures coding ability, and the two are not correlated. Open, and deliberately not fixed
mid-sweep: a turn that emits **no code at all** is a sampler pathology, not an answer, and should
probably be retried on a different seed before the task is written off — the same reasoning that
made `env` failures distinguishable from wrong answers in bug 9.
