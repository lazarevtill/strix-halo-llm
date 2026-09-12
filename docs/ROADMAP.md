# Next-gen models — staged, tracked, and the exact gate on each

This page is the "not yet fully cleared" list. Everything runnable today is in
[RESULTS.md](RESULTS.md). The repo's rule is to publish the claim *and* the thing blocking it —
so each model below records its exact gate, honestly.

**Status refreshed 2026-09-12 — the big change since the last revision: the Vulkan correctness
gate CLEARED.** The `ggml_vk_graph_optimize` bug
([#27805](https://github.com/ggml-org/llama.cpp/issues/27805)) that silently corrupted
view-aliased-state (SSM/linear-attention) models at temp 0 on gfx1151 was **fixed by
[PR #27812](https://github.com/ggml-org/llama.cpp/pull/27812) and shipped in release b10677**
(commit `b387ddfd8`, staged here in `bin-b10677\`). That bug was the emergent blocker for *every*
hybrid arch below. With it fixed, the remaining step for the arch-supported models is a **one-time
Vulkan determinism *confirmation*** (N≥10 fixed-seed temp-0 diff), not an open blocker.

## What "runnable on this box" requires

llama.cpp **Vulkan** + a **GGUF** whose architecture the engine recognises. A brand-new model needs
three upstream things to line up:

1. a **GGUF** build published (FP8 / safetensors do not load in llama.cpp),
2. **architecture support** merged into llama.cpp and shipped in a release, **and**
3. that support **working on the Vulkan backend** — new arches land CUDA/Metal-first and Vulkan
   correctness has historically lagged (that was #27805, now fixed).

The current engine for new arches is **`bin-b10677`** (carries `qwen4exp`, `qwen3next`,
`nemotron_h_moe`, `deepseek4`, `laguna`, `muse-glimmer`, `dflash` **plus** the #27805 fix). The
pinned **`b10431`** stays the engine for every *published* number (a build change breaks
comparability) and for the live `:8080` router.

## Arch-supported on b10677, pending only a Vulkan confirmation

These load on `bin-b10677` today. Because they are linear-attention / SSM hybrids — the exact class
#27805 used to corrupt — each still gets one **fixed-seed, temp-0, N≥10 raw-completion diff** on an
isolated port before being trusted (byte-identical = safe; any divergence = a *new* correctness
issue). Post-#27805 these are expected to pass; the check is confirmation, not a blocker. It needs
the router **stopped** for the big ones, so it's a human-approved, router-down operation — the pinned
`b10431` engine and `:8080` router stay untouched until then. See `scripts/windows/stage-nextgen.ps1`.

### Qwen3.8-Flash-Next  (arch `qwen4exp`) — closest to runnable
- **What:** Qwen's "Qwen4 architecture preview" — 180 B, MoE + hybrid SSM/attention, natively
  multimodal, 1 M context. Base + FP8 are safetensors (won't load); community GGUFs exist.
- **GGUF:** [unsloth/Qwen3.8-Flash-Next-GGUF](https://huggingface.co/unsloth/Qwen3.8-Flash-Next-GGUF)
  — `UD-IQ4_XS` (87.2 GB) is downloaded and is the recommended fit under the ~109 GB ceiling
  (leaves ~22 GB for KV/compute). Registry keys `flashnext` / `flashnext-iq1`.
- **Gate:** arch **merged** ([PR #27742](https://github.com/ggml-org/llama.cpp/pull/27742)) and present
  in b10677; Vulkan fix **landed**. Only the confirmation diff remains (router-down).

### Qwen3-Coder-Next  (arch `qwen3next`) — downloaded 2026-09-12
- **What:** coding-agent MoE, **80 B total / 3 B active** (512 experts, 10/token), 262 K context, no
  vision, no MTP head. Same qwen3_next model family as Flash-Next but a *different* arch string
  (`qwen3next`, confirmed from the GGUF header — not `qwen4exp`).
- **GGUF:** `UD-Q4_K_XL` (49.6 GB, single file) downloaded; registry key `coder-next`. Fits solo with
  room; ~50 GB could co-reside.
- **Gate:** arch present in b10677. Linear-attention hybrid → same Vulkan confirmation diff as
  Flash-Next (they share the qwen3_next lineage — one clears the class). Spec via `ngram-mod` or a
  draft model (no native MTP).

### NVIDIA Nemotron-3.5-Lightning-30B-A3B  (arch `nemotron_h_moe`) — fetchable
- **What:** hybrid **Mamba-2 + MoE + attention** (only ~6 attention layers of 52 → tiny KV even at
  long context), **30 B / 3 B active**, 262 K context, **MTP draft head built in**
  (`--spec-type draft-mtp`).
- **GGUF:** [bartowski/NVIDIA-Nemotron-3.5-Lightning-30B-A3B-GGUF](https://huggingface.co/bartowski/NVIDIA-Nemotron-3.5-Lightning-30B-A3B-GGUF)
  — Q4_K_M ~25.5 GB (IQ4_XS 18.9). Not yet downloaded. Needs b10362+; b10677 qualifies and carries
  `nemotron_h_moe`.
- **Gate:** arch present in b10677. Mamba-2 state is view-aliased → run the Vulkan confirmation diff
  before trusting. Small enough (~25 GB) to **co-reside in the router** — the most interesting new
  fetch once verified.

## Still engine-gated (arch NOT in any build here)

### GLM-5.3-Flash  (arch `glm5-next`)
- **What:** Z.ai multimodal GLM-5 — **320 B-A18B**, MIT, sparse+linear hybrid, 1 M context. Weights
  are safetensors / FP8 — neither loads in llama.cpp.
- **GGUF:** [unsloth/GLM-5.3-Flash-GGUF](https://huggingface.co/unsloth/GLM-5.3-Flash-GGUF) exists,
  but at 320 B-A18B only **1-bit** quants fit the ~109 GB ceiling (`UD-IQ1_S` 93.1 GB; everything
  ≥ IQ3 is 120–200 GB). A harsh cut on a 320 B MoE — quality dubious and unmeasured. Registry key
  `glm53-flash`; **don't fetch 93 GB until it's runnable and 1-bit is judged worth it.**
- **Gate:** the canonical upstream PR is now **[#27773](https://github.com/ggml-org/llama.cpp/pull/27773)**
  (`glm5-next`) — upstream is converging on it, superseding the earlier
  [#27752](https://github.com/ggml-org/llama.cpp/pull/27752). **Still open, not merged; `glm5-next`
  absent from every build here.** Wait for merge + a shipped release, then weigh whether 1-bit GLM
  beats what already runs on this box.

## DFlash2 — a speed lever, not a model (Vulkan gate now cleared)
[`incoai/dflash-2`](https://huggingface.co/collections/incoai/dflash-2) ships 2–3 B block-diffusion
**draft** models for speculative decoding, incl. one for Qwen3.8-27B
([GGUF](https://huggingface.co/incoai/Qwen3.8-27B-DFlash2-GGUF), Q4_K_M 1.14 GB, registry
`dflash2-qwen38`). Support merged ([#27342](https://github.com/ggml-org/llama.cpp/pull/27342)) as
`--spec-type draft-dflash`. It **was** blocked on Vulkan by #27805 — **now fixed in b10677**, so it's
worth an A/B. Temper expectations: in llama.cpp its ~1.8× decode ≈ our existing `draft-mtp` (1.79×);
the headline 3.43× is vLLM/SGLang + FA-3 on datacenter GPUs and doesn't transfer here. Verify on
b10677, expect draft-mtp-level gains.

## Watching

- **[#27805](https://github.com/ggml-org/llama.cpp/issues/27805)** — Vulkan `ggml_vk_graph_optimize`
  correctness bug: **CLOSED**, fixed by [#27812](https://github.com/ggml-org/llama.cpp/pull/27812),
  shipped in **b10677**. This was the bellwether for hybrid/SSM arches on gfx1151.
- **[#27742](https://github.com/ggml-org/llama.cpp/pull/27742) `qwen4exp`** — MERGED; in b10677.
- **[#27773](https://github.com/ggml-org/llama.cpp/pull/27773) `glm5-next`** — OPEN, the PR upstream
  is converging on for GLM-5.3-Flash (supersedes #27752); absent from all builds.

The moment a gate clears, the model is fetched (if needed) and test-loaded on an **isolated port with
`bin-b10677`**; Vulkan correctness is confirmed with the fixed-seed/temp-0 N≥10 diff (a full CPU
reference is impossible for 50–93 GB GGUFs vs ~32 GB system RAM). A test that needs the model resident
**stops the router first and restarts it after** — the pinned `b10431` engine and the `:8080` router
are never left disturbed. See `scripts/windows/stage-nextgen.ps1`.
