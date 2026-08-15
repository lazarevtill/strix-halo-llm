# Going faster

Making **Qwen3.8-27B** (and hybrid linear-attention models generally) faster on this box —
Strix Halo / Radeon 8060S / gfx1151, llama.cpp Vulkan, Windows.

New here? Read **[EXPLAIN.md](EXPLAIN.md)** first — it defines every term used below.

All numbers MEASURED on this machine, 2026-08-14, llama.cpp b10431.

---

## 1. Just tell me the settings

```
--model Qwen3.8-27B-UD-Q4_K_XL.gguf -ngl 99 -fa on
--spec-type draft-mtp --spec-draft-n-max 3
-b 2048 -ub 256
-ctk q8_0 -ctv q8_0
-c 262144
```

Leave `reasoning_effort` at its default.

| setting | gain | notes |
|---|---|---|
| `--spec-type draft-mtp --spec-draft-n-max 3` | **+79%** | 11.33 → 20.27 t/s |
| `-ub 256` | **+29% prefill** | vs `-ub 1024`; `-b` is irrelevant |
| `-fa on` | +14% | |
| `-ctk/-ctv q8_0` | free | halves KV cache |
| `-c 262144` | costs 3% | full context is nearly free on this architecture |
| `UD-Q4_K_XL` | — | fastest *and* highest quality of the quants tested |

---

## 2. Do not do these (each measured, each costs you)

| tempting change | actual result |
|---|---|
| `--spec-draft-n-max` 4 or 5 | 16.53 / **7.73** t/s — depth 5 is worse than no speculation |
| `--spec-type draft-mtp,ngram-mod` | 17.97 — stacking speculators loses |
| `-ub` 512 / 1024 / 2048 | 159.0 / 129.5 / 107.8 — bigger is worse |
| smaller quant (IQ4_XS, Q3_K_XL) | 19.63 / 18.17 — **smaller is slower** |
| `-ctk/-ctv q4_0` | 18.99 — 5% worse than q8_0, no benefit |
| `-fa off` | 17.62 |
| `reasoning_effort: low` | **74% slower** on hard tasks |
| porting the chunked GDN kernel | worth <1% of prefill — see §4 |

Two of these deserve a sentence of explanation, because the intuition is strong:

**Smaller quants are slower** because unpacking `IQ4_XS`/`Q3_K` costs more arithmetic than the
bandwidth it saves. Below ~`Q4_K` you spend compute to save bandwidth you were not short of.

**`reasoning_effort: low` is slower** because the setting swaps instruction text rather than
capping a budget, and it governs *answer* length more than thinking length. On a hard task `low`
produced 623 chars of thinking and 3045 of answer; `xhigh` produced 723 and only 1384.

---

## 3. What is left, ranked

1. **Prompt-cache persistence.** A 44k-token prefill costs ~4.5 minutes. *Not repeating it* is
   worth more than making it faster. See llama.cpp PRs
   [#26004](https://github.com/ggml-org/llama.cpp/pull/26004) and
   [#24785](https://github.com/ggml-org/llama.cpp/pull/24785) (recurrent-state prompt cache).
2. **Quality evals on the chosen quant.** Speed without a quality number is half an answer.
3. **ROCm head-to-head at long context.** This repo's "Vulkan beats ROCm" verdict predates
   b10431's ROCm 7.14 build. Third-party numbers put them close, with ROCm reportedly stronger
   at 32K+ context — exactly where this model hurts. One measurement, could go either way.
4. **`ik_llama.cpp`** ([repo](https://github.com/ikawrakow/ik_llama.cpp)) — SOTA quant types, but
   its gains are CPU/CUDA-focused and Vulkan support is thinner than upstream. Measurable
   experiment, not a known win.
5. **BIOS memory split** (currently 32/96). Deferred by the owner; everything here is software-only.

---

## 4. Why there is no kernel rewrite on that list

Roughly **half of prefill is irreducible arithmetic**: a 27.8B dense model needs ~2.45 PFLOP for a
44k prompt, and `MUL_MAT` on q4_K measures **10.83 TFLOPS** — near what this hardware can do. No
flag, fork or kernel changes that.

All three kernel candidates were priced and all three are closed:

| candidate | measurement | verdict |
|---|---|---|
| Gated DeltaNet prefill | <1% of total prefill time | not worth touching |
| weight matmul (`MUL_MAT` q4_K) | 10.83 TFLOPS at prefill batch | near hardware ceiling |
| flash attention | flat 6.3–7.1 TFLOPS across kv 4k→32k | no defect to fix |

**Attention is not penalised by this model's unusual `head_dim = 256`** — it matches `head_dim 128`
within ~5% at prefill batch. Upstream's perf suite covers neither `hsk=256` nor a prefill-sized
`nb`, so this needed 8 added cases in `tests/test-backend-ops.cpp` (kept in the local
`llama.cpp-gdn` checkout, worth offering upstream). Beware the stock suite's `nb=1` rows: those are
**decode**, where throughput does fall with KV depth — reading them as prefill numbers is what made
attention look broken in the first place.

The one kernel that looked worth rewriting was the Gated DeltaNet prefill path: its Vulkan shader
walks tokens strictly serially, and upstream wrote a chunked tensor-core version for CUDA only
([PR #26001](https://github.com/ggml-org/llama.cpp/pull/26001)). Pricing it settled the question:

```
test-backend-ops perf -o GATED_DELTA_NET -b Vulkan0
```

≈1 µs per token per layer × 48 layers × 44,000 tokens ≈ **2–3 seconds of a 452-second prefill**.
Under 1%. It is also already moot — `cparams.fused_gdn_ch` chunks the operation at the graph level
by default.

---

## 5. The method

```
test-backend-ops perf -o <OP> -b Vulkan0
```

prices any single kernel in about a minute, on a live box, **without stopping the server**.

Before optimising anything: price the op, multiply by how often the model invokes it, and compare
against total measured time. Reading a kernel and finding it inefficient proves only that the
kernel is inefficient — not that it matters. That one command refuted a multi-week plan here.

For end-to-end attribution, `GGML_VK_PERF_LOGGER=1 llama-bench -m <model> -ngl 99 -p 4096,16384 -n 0`
dumps per-operation accumulated milliseconds for a real prefill.
