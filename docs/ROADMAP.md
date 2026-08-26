# Next-gen models — staged, pending engine support

Two 2026 frontier-preview models are **downloaded / tracked but not yet runnable** on this box:
their architectures are so new that no released `llama.cpp` can load them. This page records the
exact gate for each so the status is honest — the repo's rule is to publish the claim *and* the
thing blocking it, not a promise.

Everything runnable today is in [RESULTS.md](RESULTS.md); this is the "not yet" list.

## Why they can't run yet

The Strix Halo stack is **llama.cpp Vulkan** and needs **GGUF** with an architecture the engine
recognises. A brand-new model needs *two* upstream things to line up:

1. a **GGUF** build published (FP8 / safetensors do not load in llama.cpp), and
2. **architecture support** merged into llama.cpp and shipped in a release.

Until both land, a download is just staged bytes.

## Qwen3.8-Flash-Next  (arch `qwen4exp`)

- **What:** Qwen's "Qwen4 architecture preview" — 180 B, MoE + hybrid SSM/attention, natively
  multimodal, 1 M context. Base + FP8 are safetensors (won't load); community GGUFs exist.
- **GGUF:** [unsloth/Qwen3.8-Flash-Next-GGUF](https://huggingface.co/unsloth/Qwen3.8-Flash-Next-GGUF)
  — full quant ladder from `UD-IQ1_S` (67.6 GB) to `UD-Q4_K_XL` (103.7 GB). Fetchable via the
  `flashnext` / `flashnext-iq1` registry keys (see `fetch-models`).
  **Recommended fit for the ~109 GB ceiling: `UD-IQ4_XS` (87.2 GB)** — best quality that still
  leaves ~22 GB for KV/compute; `UD-Q4_K_XL` (103.7 GB) is weights-alone near the ceiling and
  likely too tight to serve with usable context.
- **Engine gate:** llama.cpp **[PR #27742](https://github.com/ggml-org/llama.cpp/pull/27742)**
  ("model: add Qwen3.8-Flash-Next (qwen4exp)") — *open, not merged* as of 2026-08-26. Neither
  `b10431` (this repo's pinned build) nor the latest release lists `qwen4exp` in its arch table.
- **Plan:** when #27742 merges → fetch the first release that includes it into a *separate*
  `bin-<build>\`, confirm the binary knows `qwen4exp`, and test-load the staged GGUF on an
  isolated port — the proven `b10431` engine and the live router stay untouched until measured.

## GLM-5.3-Flash  (arch `glm5_next`)

- **What:** Z.ai's first multimodal GLM-5 — **320 B-A18B**, MIT, sparse+linear hybrid attention,
  1 M context ([zai-org/GLM-5.3-Flash](https://huggingface.co/zai-org/GLM-5.3-Flash)). Weights are
  safetensors; an [FP8 build](https://huggingface.co/unsloth/GLM-5.3-Flash-FP8) exists — neither
  loads in llama.cpp.
- **GGUF:** **none yet.** The GGUF repos (`unsloth/GLM-5.3-Flash-GGUF`,
  `vcruz305/…`, `AtomicChat/…`, `aj9o9/…`) are README-only placeholders so far.
- **Engine gate:** llama.cpp **[PR #27752](https://github.com/ggml-org/llama.cpp/pull/27752)**
  ("model: add GLM-5.3-Flash (glm5next)") — *open, not merged*.
- **Plan:** **two** gaps must close — a real GGUF must appear **and** #27752 must merge + ship.
  When a GGUF lands, its quants/sizes get reported so a fit under the 109 GB ceiling can be
  chosen before downloading 300 B-class weights.

## Watching

The gate for each model is a public upstream signal you can check yourself: the two llama.cpp PRs
(#27742, #27752) for `merged`, and the HF GGUF trees for real `.gguf` files. The moment a gate
clears, the model is fetched (if needed) and test-loaded on an **isolated port with a separate
engine build** — the production `:8080` router and the pinned `b10431` engine are never disturbed
by the experiment until a result is measured.
