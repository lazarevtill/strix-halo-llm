# Going faster — every avenue, ranked by evidence and effort

Scope: making **Qwen3.8-27B** (and hybrid linear-attention models generally) faster on this
box — Strix Halo / Radeon 8060S / gfx1151, llama.cpp Vulkan, Windows.

Written 2026-08-14 against llama.cpp **b10431**. Everything is labelled MEASURED (ran here),
EVIDENCED (someone else's number or upstream source code), or UNTESTED.

Baseline to beat, all MEASURED here:

| | number |
|---|---|
| generation, no speculation | 11.33 t/s |
| generation, `draft-mtp` n=3 | **20.27 t/s** |
| prefill, instantaneous at 44k depth | **~64 t/s** (≈7.5 min to ingest 44k) |

**Generation is in decent shape. Prefill is the problem**, and §3.1 explains why at the
source-code level.

---

## 1. Free wins already banked

| change | effect | status |
|---|---|---|
| `--spec-type draft-mtp --spec-draft-n-max 3` | **+79%** (11.33 → 20.27) | MEASURED, in use |
| `-ctk q8_0 -ctv q8_0` | speed-neutral, **halves KV** to ~32 KiB/tok | MEASURED |
| `-c 262144` | costs only ~3% | MEASURED |

And three anti-wins — changes that look like optimisations and are not:

- `--spec-draft-n-max 5` → **7.73 t/s**, worse than no speculation.
- `--spec-type draft-mtp,ngram-mod` → 17.97, worse than `draft-mtp` alone.
- MTP under 3-way concurrency → 20.85 aggregate vs 23.82 with speculation **off**.

---

## 2. Cheap, untested, worth a maintenance window

### 2.1 `--load-mode mlock` may be actively harmful here — EVIDENCED

Community guidance for Strix Halo states that `--mlock` is counterproductive on unified
memory, because the memory controller pins natively and mlock only adds bookkeeping. Round 1
used `--load-mode mlock` for **every** row, so the comparisons are internally valid but the
absolute numbers may all be depressed. `bench-qwen38-opt.ps1` Phase C tests `mmap` against it.

> Source: [Strix Halo local-LLM guide](https://hogeheer499-commits.github.io/strix-halo-guide/)

### 2.2 `-b` / `-ub` are tuned for the wrong architecture — UNTESTED

`docs/BENCHMARKS.md` records `-b 2048 -ub 1024` as the gfx1151 sweet spot, but that was
measured on **MoE** models. This is a dense hybrid where 48 of 64 layers are recurrent. There
is no reason the optimum transfers. Phase A of `bench-qwen38-opt.ps1` sweeps five combinations.

### 2.3 ❌ "Smaller quant = faster on a dense model" — REFUTED BY MEASUREMENT

The reasoning was: dense means every token reads every weight, so `tg ~ 1/filesize`, so shrink the
quant. Projections from the measured 20.27 t/s at UD-Q4_K_XL were IQ4_XS ~23 and UD-Q3_K_XL ~27 t/s.

MEASURED 2026-08-14, solo window, greedy, `draft-mtp` n=3, all three sanity-gated 3/3:

| quant | GiB | projected | **measured tg** |
|---|---:|---:|---:|
| **UD-Q4_K_XL** | 16.69 | 20.27 | **20.06** |
| IQ4_XS | 14.63 | ~23 | 19.63 |
| UD-Q3_K_XL | 12.52 | ~27 | 18.17 |

**Speed runs BACKWARDS from size.** The largest quant is the fastest; the projections were wrong by
17% and 33%, and in the wrong direction.

Why: generation here is not purely bandwidth-bound. **Dequantisation ALU cost outweighs the
bandwidth saved.** `Q4_K` unpacks cheaply; `IQ4_XS` and `Q3_K` use more elaborate codebooks and cost
more VALU work per weight. Below roughly Q4_K there is nothing to win on this hardware — you spend
compute to save bandwidth you were not short of. (Consistent with the round-1 finding that the
current kernel is VALU-bound or co-bound, not VMEM-bound.)

**Practical consequence: do not change quant.** UD-Q4_K_XL is simultaneously the highest quality of
the three and the fastest. Do not download smaller quants expecting speed.

⚠️ The sanity gate (arithmetic, factual recall, sequence) is a *disqualifier*, not a quality eval.
It says a quant is not obviously broken; it does not say it is good.

### 2.4 ⚠️ `reasoning_effort` — a big lever, pointing the OPPOSITE way. MEASURED, and the
### default is already optimal

MEASURED 2026-08-14, greedy, UD-Q4_K_XL + `draft-mtp` n=3, one sample per cell:

| task | `low` | `medium` | **`xhigh`** (default) |
|---|---|---|---|
| easy | 19 tok / 2.9 s | 30 / 3.3 s | 27 / 4.0 s |
| mid | 249 / 11.7 s | 234 / 10.8 s | **158 / 8.9 s** |
| hard | 1132 / 46.7 s | 1370 / 55.8 s | **577 / 26.9 s** |

**On the hard task `xhigh` is 1.7x FASTER than `low` and emits half the tokens.** Setting
`reasoning_effort=low` to save time makes hard requests **74% slower**.

Why the intuition fails: the setting does not cap a thinking budget, it swaps INSTRUCTION TEXT into
the system prompt. And thinking was never the dominant cost — on the hard task `low` produced
623 chars of thinking but **3045 chars of answer**, while `xhigh` produced 723 thinking and only
**1384 answer**. `low` says "move directly to the conclusion without unnecessary elaboration" and
yields rambling; `xhigh` says "prioritize correctness, consistency, and clarity" and yields a tight
answer. The knob mostly governs ANSWER length, in the counterintuitive direction.

⚠️ n=1 per cell, and **quality is unmeasured** — a shorter answer is not necessarily a better one.
The direction is consistent across both non-trivial tasks, but do not read this as a quality result.

**Leave it at the default. Do not "optimise" it to `low`.**

### 2.4b Original hypothesis (kept — it was wrong in an instructive way)

The chat template defaults to **`reasoning_effort: 'xhigh'`**. For a waiting user, latency is
`(thinking tokens + answer tokens) / tg` — so if xhigh triples the token count it outweighs
every flag in this document. Tunable per request (`low` / `medium` / `xhigh`), and
`enable_thinking: false` disables it outright. **Measure this before optimising anything else**:
it is free, it is per-request, and it may dwarf a 20% kernel win.

---

## 3. Fork territory

### 3.1 ❌ Port the chunked Gated DeltaNet kernel to Vulkan — REFUTED BY MEASUREMENT

**An earlier revision of this document called this "the highest-value change available". That was
wrong, and the correction is kept here because the reasoning error is instructive.**

The premise looked airtight: the Vulkan GDN shader really does walk tokens serially, upstream really
did write a chunked CUDA kernel to fix exactly that, and it really is NVIDIA-gated. Every fact was
true. The conclusion still did not follow, because nobody had measured *how much of prefill GDN
actually accounts for*.

MEASURED 2026-08-14 with `test-backend-ops perf -o GATED_DELTA_NET -b Vulkan0` on b10431:

| n_tokens (head_count=32, head_size=128) | time | per token |
|---:|---:|---:|
| 64 | 66.4 us | 1.04 us |
| 256 | 240.1 us | 0.94 us |
| 1024 | 1087.4 us | 1.06 us |

Cost is **perfectly linear in tokens** — the serial loop is confirmed, exactly as the source implies.
But scale it to this model: ~1 us per token per layer x 48 GDN layers x 44,000 tokens ≈ **2-3 seconds**.
The measured 44k prefill took **452 seconds**. GDN is **under 1%** of it.

Porting an 800-line tensor-core kernel to win back 2 seconds out of 7.5 minutes is not an
optimisation, it is a hobby. **Do not do this.**

The lesson, which generalises: *"I found a serial loop in a hot-sounding kernel"* is a hypothesis,
not a diagnosis. `test-backend-ops perf` prices any single op in about a minute and needs no
maintenance window — price the op before planning the rewrite.

### 3.1b Where prefill time ACTUALLY goes

Same tool, same session:

- **`MUL_MAT` q4_K at prefill batch (n=512): 10.83 TFLOPS.** A 27.8B dense model needs
  `2 x 27.8e9 x 44000 ≈ 2.45 PFLOP` for a 44k prefill → **~226 s of pure weight matmul**, about half
  the observed 452 s. That is close to what this hardware can do; there is no large win hiding here.
- **`FLASH_ATTN_EXT` numbers from the stock perf suite look alarming but are being misread.**
  The stock sweep is `for kv in {4096,8192,16384} / hs in {64,128} / nr in {1,4}` with **`nb = 1`**:

  | KV (nh=8, hsk=128, nb=1) | GFLOPS |
  |---:|---:|
  | 4096 | 561 |
  | 8192 | 649 |
  | 16384 | 198 |

  ⚠️ **`nb=1` is DECODE, not prefill** — one token attending over the whole KV cache. It says
  nothing about ingesting a long prompt, and quoting it as a prefill finding (an earlier revision
  of this document did) is a category error. The apparent 3.3x cliff is a generation-path number.

- **Two real gaps in upstream perf coverage**, both fixed locally in
  `tests/test-backend-ops.cpp` (see the "Qwen3.8-27B prefill shape" block):
  1. the perf sweep covers only `hs` 64 and 128. This model uses **`head_dim = 256`**
     (24 Q heads / 4 KV heads, GQA 6). `hsk=256` IS exercised for **correctness** — it appears in
     the `{40,64,72,80,96,128,192,256,320,512,576}` loop — but it is never **benchmarked**, so a
     slow path there would be invisible.
  2. nothing in the sweep uses a prefill-sized `nb`.

  The local block sweeps `hs` 128 vs 256 at `nb` 1 vs 512 across kv 4k-32k, which isolates both:
  a 256-specific penalty appears as a gap between the two `hs` rows at matched kv/nb.

**Fork target, if one is wanted:** decide it from the numbers that block produces, not from the
stock suite. Adding the missing coverage is hours of work; committing to a kernel rewrite on the
strength of a misread decode benchmark is how the GDN mistake in §3.1 happened.

The Vulkan GDN shader
([`gated_delta_net.comp`](https://github.com/ggml-org/llama.cpp/blob/master/ggml/src/ggml-vulkan/vulkan-shaders/gated_delta_net.comp))
processes tokens **strictly serially**:

```glsl
for (uint t = 0; t < n_tokens; t++) {
    ...
    s_shard[r] = g_exp[r] * s_shard[r] + k_reg[r] * delta_col;   // recurrent state update
}
```

Parallelism exists across heads, sequences and the state dimension — **never across tokens**,
because the recurrence is inherently sequential. So prefilling N tokens costs
**48 layers × N serial iterations**, using no matrix cores whatsoever. For a 44,000-token
prompt that is ~2.1M serial steps, and it is why prefill decays from ~144 t/s at 4k to ~64 t/s
at 44k while *generation* at 262k context stays nearly free.

Upstream has already solved this — **for CUDA only**.
[PR #26001](https://github.com/ggml-org/llama.cpp/pull/26001) ("CUDA: Support of GDN chunked
kernel for prefill", open since 2026-07-22, 939 lines) reformulates the recurrence into
chunk-wise matmuls on tensor cores, with a three-stage pipeline (FP32 WY inverse → BF16 WMMA
masked attention → WMMA state update). Its author reports near-lossless accuracy
(perplexity 5.5201 vs 5.5052; top-1 agreement 96.8%). It gates on **NVIDIA Ampere+ BF16 tensor
cores** and falls back to the recurrent kernel everywhere else — which is every AMD GPU.

**There is no Vulkan equivalent, not even proposed.**

- **Feasibility:** good in principle. gfx1151 supports `KHR_coopmat`, the Vulkan analogue of
  WMMA, and this build already uses coopmat paths for ordinary matmul. The maths is
  backend-agnostic; the CUDA PR is a working reference implementation and a correctness oracle.
- **Effort:** large. ~800 lines of tensor-core CUDA to re-express in GLSL compute, with
  numerically delicate parts (FP32 prefix sums over log-decays, clamping to avoid FP16
  saturation, FP32 state across chunks). Realistically weeks, not a weekend.
- **Payoff:** the CUDA PR reports large prefill gains for ≥128 tokens. If it transfers, the
  7.5-minute 44k ingest is the thing that shrinks.
- **Cheaper first step:** subscribe to #26001. If it merges, a Vulkan port becomes a
  port-not-invent job, and upstream may do it. Check whether the chunked path can be expressed
  with plain `mul_mat` calls before writing a bespoke coopmat shader — slower than the CUDA
  version, still far better than a serial token loop.

### 3.2 ik_llama.cpp — SOTA quants, but check the backend first

[ikawrakow/ik_llama.cpp](https://github.com/ikawrakow/ik_llama.cpp) (3,033 stars, active as of
2026-08-14) is a llama.cpp fork with additional quant types (`IQ*_KS`) and prompt-processing
optimisations. `ubergarm/Qwen3.8-27B-GGUF` already publishes ik-format quants for this model.

⚠️ Its headline gains are **CPU and CUDA**; its Vulkan support is thinner than upstream's, and
this box is Vulkan-bound. Reported results are also mixed and quant-specific — one comparison
found ik faster with IQ4_NL but *slower* than llama.cpp with Unsloth's UD-Q4_K_XL, i.e. exactly
the quant family in use here. Treat as a measurable experiment, not a known win.

> Sources: [ik_llama.cpp](https://github.com/ikawrakow/ik_llama.cpp) ·
> [llama.cpp vs ik_llama.cpp benchmark](https://www.hardware-corner.net/guides/llama-cpp-vs-ik_llama-cpp/)

### 3.3 Backport open Vulkan matmul PRs

[PR #26595](https://github.com/ggml-org/llama.cpp/pull/26595) ("vulkan: keep p021/nc mat-vec
paths for large row counts (chunked dispatch), add GQA shared…") touches the mat-vec paths that
dominate *generation*. Low effort (cherry-pick onto a local build), unknown payoff on gfx1151.

---

## 4. Backend and platform

### 4.1 Re-test ROCm — this repo's "Vulkan wins" verdict is stale

`docs/BENCHMARKS.md` records **Vulkan 71.7 vs Ollama-ROCm 40.2 t/s**, and the local-model-bench
skill says "Vulkan beats ROCm on this part". That measurement is old, and b10431 now ships
`llama-b10431-bin-win-rocm-7.14-x64.zip`.

Recent third-party numbers put them much closer — RADV 1080 vs ROCm 1047 t/s prefill (+3% Vulkan),
RADV 64.85 vs ROCm 54.67 tg (+19% Vulkan) — **but note ROCm's reported advantage is hipBLASLt and
rocWMMA at 32K+ context, which is exactly where this model hurts.** Worth one head-to-head at
long context specifically, not at short.

> Source: [Strix Halo guide](https://hogeheer499-commits.github.io/strix-halo-guide/)

### 4.2 Prompt caching across restarts

[PR #26004](https://github.com/ggml-org/llama.cpp/pull/26004) (server: preserve context
checkpoints across slot save/restore) and
[#24785](https://github.com/ggml-org/llama.cpp/pull/24785) (recurrent state shrink/expand for
prompt cache) matter disproportionately here: if prefill costs minutes, *not re-doing it* is
worth more than making it faster. Especially relevant for recurrent models, whose state does not
slice like a normal KV cache.

### 4.3 Hardware / system — deferred by the owner

- **BIOS memory split.** Currently 32/96. Deferred on purpose; software-only so far.
- **GPU driver.** Vulkan performance on RDNA3.5 moves between Adrenalin releases; record the
  driver version alongside any number worth keeping.
- **Windows power plan / GPU scheduling.** Cheap to check, rarely decisive.

---

## 5. Suggested order

1. **`reasoning_effort`** — free, per-request, possibly the largest real-world win. (§2.4)
2. **Round 2 sweep** — `-b`/`-ub`, quant, `fa`, KV q4_0, mlock-vs-mmap. One window. (§2.1–2.3)
3. **Quality suites on the winning quant** — a fast wrong answer is not a win.
4. **ROCm head-to-head at long context** — cheap, and it targets the weak spot. (§4.1)
5. **Price `hsk=256` flash attention** — add the missing `test-backend-ops` case, no window
   needed. If it is slow, that is the fork worth doing. (§3.1b)

**Do not port the chunked GDN kernel.** §3.1 explains why the obvious-looking target is worth
under 1% of prefill.

## 6. The method that matters more than any item above

`test-backend-ops perf -o <OP> -b Vulkan0` prices any individual kernel in about a minute, on a
live box, **without stopping the server**. It refuted a weeks-long plan here in one command.

Before optimising anything: price the op, multiply by how many times the model actually invokes it,
and compare against total measured time. Reading a kernel and finding it inefficient proves only
that the kernel is inefficient — not that it matters.
