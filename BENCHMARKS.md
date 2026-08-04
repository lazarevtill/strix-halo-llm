# Benchmarking on this box — what, how, and how to read it

Two different questions, two different tools. Do not mix them up:

| question | tool | unit |
|---|---|---|
| **How fast is it?** | `bench-big.ps1`, `bench-spec.ps1` | tokens/sec (pp and tg, separately) |
| **How good is it?** | `evals\run-guarded.ps1` | pass rate on private suites |

Speed is cheap to measure and easy to trust. Quality is expensive to measure and *very* easy to get
wrong — five separate harness bugs produced five believable-but-false quality numbers on
2026-08-03/04. Everything below exists because of that.

---

## 1. Speed

### What is measured

**Two numbers, never one.** A single "tok/s" is not a result:

- **pp (prompt processing / prefill)** — how fast it ingests your context. Compute-bound. This is
  what you wait on when an agent sends a 30K-token conversation.
- **tg (token generation / decode)** — how fast it writes the answer. **Bandwidth-bound on *active*
  params**, which is why an A3B model at 35B total beats an A13B model at 120B total here.

A result is only meaningful with four attributes: **context depth, quant, backend, build**.

### Depth matters more than anything

`llama-bench` defaults to depth 0 — an empty KV cache. That number is a fiction for agentic work.
`bench-big.ps1` uses `-d` to measure at real depths, because tg degrades as the cache fills.

```powershell
.\bench-big.ps1                      # sweep the models it finds, at real depths
.\bench-spec.ps1 -Model .\models\X.gguf -Spec draft-mtp    # A/B speculative decoding
```

### How to read it

- **Compare against the previous run for the same task**, not against a vendor's number.
- **If a run is worse, say so.** Numbers move between llama.cpp builds and driver versions — record
  both.
- `medMs`/`genTps` in the eval output compare *configurations* (ctx, spec-type, quant), not models.
  Do not quote them as a model property.

### Speed facts already established here (don't re-derive)

| finding | number |
|---|---|
| Vulkan vs Ollama-ROCm, same model | **71.7 vs 40.2 t/s → 1.79x** — use Vulkan |
| Ornith Q5_K_M vs bf16 | **58 vs 11.17 t/s** — bf16 is 5.6x SLOWER, and pp collapses too (698 → 241) |
| pp sweet spot on gfx1151 | `-b 2048 -ub 1024` |
| tg from 89 GB → 109 GB of weights | **flat** — spilling past the carve-out costs nothing on this UMA APU |
| `--cache-reuse` | **no-op** on these MoEs; prefix caching already works |
| speculative decoding | `draft-mtp` helps Qwen; `ngram-mod` measured **neutral** (14.34/14.07 vs 14.17 baseline) |

---

## 2. Quality

### What is measured

Two private suites in `evals\`, written for this fleet and published nowhere — so no model has
trained on them. That matters: decontaminated **SWE-rebench scores A3B-class models ~4x below**
their self-reported SWE-bench numbers.

**Tool calling** (29 cases) — a real OpenAI `tools` array → `message.tool_calls`, in a multi-turn
agent loop with tool results fed back. Categories: `select`, `args`, `enum`, `multi`, `chain`,
`abstain`, `hard`. *Abstain is the one most models fail* — a model that calls a tool for "thanks,
that's all" will thrash in an agent loop, so it is weighted equally on purpose.

**Agentic coding** (4 tasks × 3 turns) — write code, get told what failed, revise. Scored against
hidden pytest suites in a locked-down Docker sandbox (no network, 512 MB, 1 CPU, read-only mount).
**Every turn is scored**, so a model that breaks working code on turn 3 is visible.

### One-time setup: the sandbox image

The coding eval runs model-written code in a disposable container, so the image must exist first.
Without it `smoke.py` fails immediately with `unable to find image` / `DOCKER_NOT_FOUND` — build it
before anything else on a fresh box or after a Docker reset:

```powershell
docker build -f evals\code\Dockerfile.sandbox -t llm-eval-sandbox evals\code
```

Registry and package index are build ARGs, **public by default so the image builds anywhere**.
Behind a private mirror — which also avoids docker.io/pypi.org rate limits when rebuilding on a new
box — pass them explicitly:

```powershell
docker build -f evals\code\Dockerfile.sandbox -t llm-eval-sandbox evals\code `
  --build-arg BASE_IMAGE=<registry>/proxy/python:3.12-slim `
  --build-arg PIP_INDEX_URL=https://<nexus-host>/repository/pypi-proxy/simple
```

### How to run

```powershell
# Everything, all models, smoke-gated and respawn-proof
.\evals\run-guarded.ps1 -Models ornith-q5,laguna,qwen122b

# One model, one suite
.\evals\run-guarded.ps1 -Models ornith-q5 -SkipCode
.\evals\run-guarded.ps1 -Models qwen122b -SkipTools -Tasks quant_pick   # finish an interrupted run

# Prove the harness itself works (~30s) -- run-guarded does this automatically and REFUSES to
# start a multi-hour sweep if it fails
python evals\code\smoke.py
```

Results append to `evals\results-tools.jsonl` and `evals\code\results-code.jsonl`, each row carrying
timestamp, script mtime, model, and server args.

### How to read it — the part that matters

**1. A percentage without a confidence interval is not a result.**
The suite prints Wilson 95% CIs. With n=29, `28/29` is `[82.8%, 99.4%]` and `27/29` is
`[78.0%, 98.1%]`. Those overlap almost entirely. McNemar exact on the paired cases gives **p = 1.0**.

**2. This suite cannot rank models that are close.** It can tell you a model is *bad*. It cannot
tell you which of three good models is best. The coding suite's effective **n is 4 tasks, not 70
tests** — tests cluster inside tasks, so "70/70" implies far more evidence than exists. A single
test flipped between two *identical* temperature-0 runs; that is the noise floor.

Separating a true 95%-vs-85% pair at 80% power needs **~100+ paired cases**. To rank frontier-tier
models this suite would need ~100 tool cases and ~10 coding tasks.

**3. Read the flags, not just the score.**

| flag | meaning | do NOT treat as |
|---|---|---|
| `ENVIRONMENT` | the box failed (500, dead server, Docker down) | model quality |
| `TRUNC` | turn hit `max_tokens` | a wrong answer |
| `FRAG` | partial edit — code missing its entry symbol | broken code |
| `PARTIAL RUN` | a task never completed | a valid score |

**4. Properties reported separately from the score** — they are real, but they are not "wrong":
`parallel-batching` (does it emit ≥2 tool calls in one response, or sequence them?), truncation
count, median turns used.

### Measured results (2026-08-04)

| | tool calling | 95% CI | coding | turn 1 | trunc | tg |
|---|---|---|---|---|---|---|
| **Ornith-1.0-35B Q5_K_M** | 28/29 = 96.6% | [82.8, 99.4] | **70/70** | 45/45 | 1 | **~58 t/s** |
| Qwen3.5-122B-A10B Q4_K_XL | 28/29 = 96.6% | [82.8, 99.4] | **70/70** | 45/45 | 3 | ~34 t/s |
| Laguna-S-2.1 Q4_K_M | 27/29 = 93.1% | [78.0, 98.1] | **70/70** | 45/45 | 1 | ~14 t/s |

**A three-way tie.** All models: 4/4 tasks, zero regressions, perfect turn 1. So **choose on cost** —
Ornith gives the same measured quality at a quarter the size and 4x the speed. The only durable
difference is verbosity: Qwen truncated 3 turns to the others' 1.

---

## 3. Running a trustworthy benchmark — the checklist

Learned the hard way. Each item corresponds to a wrong number that was actually published.

1. **Smoke-test the harness first.** `run-guarded.ps1` gates on `smoke.py`, which proves the sandbox
   discriminates good code from bad, that prose is not mistaken for code, and that **every task
   prompt is satisfiable by a reference solution**. That last check is what exposed a turn-3 prompt
   that contradicted its own hidden tests — it asked for a spend to succeed while the test asserted
   it fails, so it rewarded *ignoring the user*. Any model engaging with it scored 0.

2. **Demand solo occupancy, and measure it with `Total Committed`.** Not `Dedicated Usage` — WDDM
   trims an idle model's dedicated bytes to ~0 while it still holds the reservation, so two resident
   servers under-reported by **42.5 GiB** and the box silently blew past its ~109 GiB ceiling.
   `run-model-suite.ps1` refuses to start if anything else holds GPU memory.

3. **A failed request is never a pass.** Abstain cases expect zero tool calls, and a 500 produces
   zero tool calls — a completely broken run once scored **5/29 = 17.2%** and looked real.

4. **Never let the denominator shrink.** A task that never ran contributed `0/0` and vanished
   (`"34/34 = 100%"` with half the tasks unrun). Skipped tests left the total. A turn whose code
   fails to import reports `0/1`, not `0/20` — shrinking the denominator *precisely when the model
   did worst* (`47/51 = 92.2%` where the truth was `47/70 = 67.1%`). Denominators are now
   **calibrated** by scoring the reference solution at each turn.

5. **Grade only what was asked for.** Hidden suites are sectioned by turn; scoring turn 1 against
   turn-2/3 tests measures the *test file's composition*, not the model. All three models returned
   byte-identical first-turn scores because they could not do otherwise. Correctly scoped: 45/45.

6. **A truncated turn is not an answer.** Scoring truncations as zeros manufactured a
   95.7 / 74.3 / 72.9 spread between models that are identical. Score the last complete artifact and
   report truncation rate separately.

7. **Keep the raw output.** Extraction returning `""` once wrote empty transcripts — destroying the
   evidence that revealed that very bug. Raw `content` + `reasoning_content` are always saved.

8. **Never let PowerShell write a file another tool must read.** `ConvertTo-Json` re-wraps arrays as
   `{"value":[...],"Count":n}`; `Set-Content -Encoding UTF8` and `Add-Content -Encoding UTF8` add a
   **BOM** that makes `json.load` fail. Both cost a run. Use `[IO.File]::WriteAllText` with
   `UTF8Encoding($false)`.

9. **Record provenance on every row.** Three harness vintages once landed in one results file and
   the numbers were unattributable afterwards. Timestamp, script mtime, model, server args.

See `evals\README.md` for the full bug list with the fake number each one produced.
