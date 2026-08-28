# Next-gen models — staged, pending engine support

Two 2026 frontier-preview models are **downloaded / tracked but not yet runnable** on this box:
their architectures are so new that no build in this repo can load them yet. This page records the
exact gate for each so the status is honest — the repo's rule is to publish the claim *and* the
thing blocking it, not a promise. (Status refreshed 2026-08-28: **Flash-Next** is now
engine-ready — b10665 carries `qwen4exp` and its GGUF is staged — leaving only Vulkan-correctness;
**GLM** moved draft → ready-for-review but is still unmerged and absent from every build. The emergent
blocker for both is the **Vulkan** gate — see below.)

Everything runnable today is in [RESULTS.md](RESULTS.md); this is the "not yet" list.

## Why they can't run yet

The Strix Halo stack is **llama.cpp Vulkan** and needs **GGUF** with an architecture the engine
recognises. A brand-new model needs *three* upstream things to line up:

1. a **GGUF** build published (FP8 / safetensors do not load in llama.cpp),
2. **architecture support** merged into llama.cpp and shipped in a release, and
3. that support **actually working on the Vulkan backend** — new arches land CUDA/Metal-first and
   Vulkan correctness lags. A merge is necessary but *not sufficient* for this gfx1151 box: e.g. the
   DFlash2 speculative path merged ([#27342](https://github.com/ggml-org/llama.cpp/pull/27342)) but a
   Vulkan graph-optimizer bug ([#27805](https://github.com/ggml-org/llama.cpp/issues/27805), open)
   makes its verifier silently accept wrong tokens — so its Vulkan numbers are invalid until fixed.

Until all three land, a download is just staged bytes.

## Qwen3.8-Flash-Next  (arch `qwen4exp`)

- **What:** Qwen's "Qwen4 architecture preview" — 180 B, MoE + hybrid SSM/attention, natively
  multimodal, 1 M context. Base + FP8 are safetensors (won't load); community GGUFs exist.
- **GGUF:** [unsloth/Qwen3.8-Flash-Next-GGUF](https://huggingface.co/unsloth/Qwen3.8-Flash-Next-GGUF)
  — full quant ladder from `UD-IQ1_S` (67.6 GB) to `UD-Q4_K_XL` (103.7 GB). Fetchable via the
  `flashnext` / `flashnext-iq1` registry keys (see `fetch-models`).
  **Recommended fit for the ~109 GB ceiling: `UD-IQ4_XS` (87.2 GB)** — best quality that still
  leaves ~22 GB for KV/compute; `UD-Q4_K_XL` (103.7 GB) is weights-alone near the ceiling and
  likely too tight to serve with usable context.
- **Engine gate: CLEARED.** llama.cpp **[PR #27742](https://github.com/ggml-org/llama.cpp/pull/27742)**
  ("model: add Qwen3.8-Flash-Next (qwen4exp)") **MERGED 2026-08-27**, and build **b10665** (2026-08-28)
  is verified to carry the arch (`qwen4exp` present in `llama.dll`, compiled `models/qwen4exp.cpp`).
  The pinned `b10431` predates it, so b10665 is staged in a *separate* `bin-b10665\`. GGUF `UD-IQ4_XS`
  (87.2 GB) is already downloaded. **What remains is gate 3 — Vulkan *correctness*, not merge:** the
  qwen4exp graph is a hybrid **SSM** model (view-aliased state), exactly what bug
  [#27805](https://github.com/ggml-org/llama.cpp/issues/27805) can silently corrupt on Vulkan.
- **Plan:** test-load `UD-IQ4_XS` on b10665 on an **isolated port (:8099)**, then run the **Vulkan
  correctness check that is actually feasible here** — a full CPU reference is impossible (87 GB GGUF
  vs ~32 GB system RAM), so instead **repeat one fixed-seed, temp-0 raw completion N≥10× and diff the
  outputs**: byte-identical = safe; any divergence = #27805 corruption (this is the exact signature,
  and it's how draft-mtp on the live router was cleared — 6/6 identical). The test needs the router
  **stopped** (87 GB can't co-reside with the ~55 GB router under the 109 GB ceiling), so it is a
  human-approved, router-down operation — the proven `b10431` engine and `:8080` router stay untouched
  until then. This is the closest of the two to runnable.

## GLM-5.3-Flash  (arch `glm5_next`)

- **What:** Z.ai's first multimodal GLM-5 — **320 B-A18B**, MIT, sparse+linear hybrid attention,
  1 M context ([zai-org/GLM-5.3-Flash](https://huggingface.co/zai-org/GLM-5.3-Flash)). Weights are
  safetensors; an [FP8 build](https://huggingface.co/unsloth/GLM-5.3-Flash-FP8) exists — neither
  loads in llama.cpp.
- **GGUF:** **now published** (as of 2026-08-28) — [unsloth/GLM-5.3-Flash-GGUF](https://huggingface.co/unsloth/GLM-5.3-Flash-GGUF)
  has a real quant ladder. But at **320 B-A18B** only the smallest quants fit the ~109 GB ceiling:

  | quant | size | fit under ~109 GB |
  |---|---|---|
  | `UD-IQ1_S`  | 93.1 GB | ✅ tight (~16 GB left for KV/compute) |
  | `UD-IQ1_M`  | 97.6 GB | ⚠️ very tight (~11 GB left) |
  | `UD-Q2_K_XL`| 109 GB  | ❌ weights alone = the whole ceiling |
  | `UD-IQ3_XXS` → `UD-Q4_K_XL` | 120–200 GB | ❌ over the ceiling |

  So the only *servable* quants are **1-bit** — a harsh cut on a 320 B MoE; quality is dubious and
  unmeasured. **Don't fetch the 93 GB `UD-IQ1_S` until the engine gate clears and 1-bit is judged
  worth it** (recall bigger-quant / bf16 lost badly here; 1-bit is a much deeper cut).
- **Engine gate:** llama.cpp **[PR #27752](https://github.com/ggml-org/llama.cpp/pull/27752)**
  ("model: add GLM-5.3-Flash (glm5next)") — now **ready-for-review (2026-08-28), not yet merged**
  (needs 2 code-owner approvals; MTP head not numerically validated; text-only, no vision). Confirmed
  **absent from b10665** (`glm5_next` not in `llama.dll`), so no engine can load it yet. **Vulkan
  untested** (gate 3) — and being a hybrid model it faces the same #27805 risk.
- **Plan:** the GGUF gate is clear; wait for #27752 to **merge + ship in a release with Vulkan
  working**, then weigh whether 1-bit GLM (the sole fitting quant) actually beats the models already
  runnable on this box before downloading 90 GB+. Fetchable via the `glm53-flash` registry key once
  it's worth it.

## Also drafting: DFlash2 (a speed lever, not a model)

[`incoai/dflash-2`](https://huggingface.co/collections/incoai/dflash-2) ships **2–3 B block-diffusion
*draft* models** for speculative decoding, including one purpose-built for **Qwen3.8-27B**
([GGUF](https://huggingface.co/incoai/Qwen3.8-27B-DFlash2-GGUF); Q4_K_M just 1.14 GB). Support merged
in llama.cpp ([#27342](https://github.com/ggml-org/llama.cpp/pull/27342), 2026-08-27) as
`--spec-type draft-dflash`. **But it's blocked on Vulkan** by [#27805](https://github.com/ggml-org/llama.cpp/issues/27805)
(above), and in llama.cpp its ~1.8× decode ≈ our existing `draft-mtp` (1.79×) anyway — the headline
3.43× is vLLM/SGLang + FlashAttention-3 on datacenter GPUs, which doesn't transfer here. Revisit only
after #27805 lands; expect draft-mtp-level gains, not 3.43×.

## Watching

Public upstream signals you can check yourself:

- **[#27742](https://github.com/ggml-org/llama.cpp/pull/27742) `qwen4exp`** — MERGED; engine (b10665)
  and GGUF both ready. Only a **Vulkan correctness** test remains (router-down, human-approved).
- **[#27752](https://github.com/ggml-org/llama.cpp/pull/27752) `glm5next`** — **ready-for-review**, not
  merged; absent from every build. GGUFs exist, so only the engine merge + a fitting-quant/Vulkan
  decision remain.
- **[#27805](https://github.com/ggml-org/llama.cpp/issues/27805)** — the Vulkan `ggml_vk_graph_optimize`
  correctness bug. It's the bellwether for whether these hybrid/SSM arches (and DFlash2) run
  **correctly** on gfx1151, not merely whether they merge. (Note: plain `draft-mtp` on the live router
  was tested clear — 6/6 identical greedy runs — so the bug is specific op patterns, not all spec.)

The moment a gate clears, the model is fetched (if needed) and test-loaded on an **isolated port with a
separate engine build**. Vulkan correctness is checked the feasible way — **repeat one fixed-seed,
temp-0 raw completion N≥10× and diff** (a full CPU reference is impossible for 87–93 GB GGUFs against
~32 GB system RAM); any non-determinism is #27805. A test that needs the model resident **stops the
router first and restarts it after** — the pinned `b10431` engine and the `:8080` router are never left
disturbed. See `scripts/windows/stage-nextgen.ps1`.
