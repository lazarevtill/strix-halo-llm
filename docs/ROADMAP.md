# Next-gen models — staged, tracked, and the exact gate on each

This page is the "not yet fully cleared" list. Everything runnable today is in
[RESULTS.md](RESULTS.md). The repo's rule is to publish the claim *and* the thing blocking it —
so each model below records its exact gate, honestly.

**Status refreshed 2026-09-16.** Two changes since the last revision:

1. **Qwen3-Coder-Next cleared its gate and is now the model on `:8080`.** It is no longer on this
   page as a candidate — see [RESULTS.md](RESULTS.md) and the note below.
2. **The staged engine moved `b10677` → `b11003`**, which is measurably faster on MoE prefill
   (numbers below) and adds `hy_v4`. `glm5-next` is still absent.

The earlier milestone still holds: the `ggml_vk_graph_optimize` bug
([#27805](https://github.com/ggml-org/llama.cpp/issues/27805)) that silently corrupted
view-aliased-state (SSM/linear-attention) models at temp 0 on gfx1151 was **fixed by
[PR #27812](https://github.com/ggml-org/llama.cpp/pull/27812), shipped in b10677** (commit
`b387ddfd8`). It was the emergent blocker for *every* hybrid arch below. The remaining step for
arch-supported models is a **Vulkan determinism confirmation**, not an open blocker.

> **The confirmation is per-BINARY and per-CONFIG, not per-arch.** Learned 2026-09-16: `qwen3next`
> passing on b10677 does **not** carry to b11003, and a changed `-ub` changes the compute path. Re-run
> the diff on the exact engine *and* flags you intend to serve. `stage-nextgen.ps1 -UBatch` exists for
> this.

## What "runnable on this box" requires

llama.cpp **Vulkan** + a **GGUF** whose architecture the engine recognises. A brand-new model needs
three upstream things to line up:

1. a **GGUF** build published (FP8 / safetensors do not load in llama.cpp),
2. **architecture support** merged into llama.cpp and shipped in a release, **and**
3. that support **working on the Vulkan backend** — new arches land CUDA/Metal-first and Vulkan
   correctness has historically lagged (that was #27805, now fixed).

The current engine for new arches is **`bin-b11003`** (carries `qwen4exp`, `qwen3next`,
`nemotron_h_moe`, `deepseek4`, `hy_v4`, `laguna`, `muse-glimmer`, `dflash` **plus** the #27805 fix).
The pinned **`b10431`** stays the engine for every *published* number — a build change breaks
comparability. `bin-b10677` is retained only as the A/B baseline for the b11003 measurement.

### Engine A/B — b10677 → b11003 (MEASURED 2026-09-16)

Qwen3-Coder-Next UD-Q4_K_XL, solo, `-b 2048 -ub 256 -fa on`, KV q8_0, `-lm none`, 2 reps:

| test | b10677 | b11003 | Δ |
|---|---|---|---|
| pp4096 | 444.65 ± 1.90 | 455.53 ± 1.81 | **+2.4%** |
| pp4096 @ d32768 | 275.01 ± 1.13 | 298.10 ± 5.40 | **+8.4%** |
| tg128 | 44.33 ± 0.57 | 44.86 ± 0.58 | +1.2% (noise) |
| tg128 @ d32768 | 38.59 ± 0.21 | 38.96 ± 0.13 | +1.0% (noise) |

326 commits bought **prefill only**, and the gain grows with depth — consistent with what landed
(topk_moe prefill fusion [#28422], MUL_MAT_ID BN/2 tail [#28923], rms_norm and UNARY×MUL fusion,
sparse FA [#28105]). Nothing in that range touches the memory bandwidth that caps tg, and tg did not
move. The `pp512` rows from the same run carry ±11% spread and are **not** quoted — they separate
nothing.

## Cleared since the last revision

### Qwen3-Coder-Next  (arch `qwen3next`) — ✅ SERVING on `:8080`
Coding MoE, **80 B total / 3 B active**, 262 K context, **text-only** (no vision tower), no MTP head.
`UD-Q4_K_XL` 49.6 GB. Determinism confirmed on b11003 at the serving ubatch — **12/12 byte-identical**
(2026-09-16). Served at **`-ub 1024`**, a per-model override of the global 256 that is worth **+34.8%**
prefill at depth on this arch; see [OPTIMIZATION.md](OPTIMIZATION.md) row 10 and
[BENCHMARKS.md](BENCHMARKS.md). Requires `-Bin .\bin-b11003` — it will **not** load on the pinned
`bin\` (b10431).

## Arch-supported on b11003, pending only a Vulkan confirmation

These load on `bin-b11003` today. Because they are linear-attention / SSM hybrids — the exact class
#27805 used to corrupt — each still gets one **fixed-seed, temp-0, N≥10 raw-completion diff** on an
isolated port before being trusted (byte-identical = safe; any divergence = a *new* correctness
issue). Post-#27805 these are expected to pass; the check is confirmation, not a blocker. It needs
the router **stopped** for the big ones, so it's a human-approved, router-down operation. See
`scripts/windows/stage-nextgen.ps1`.

### NVIDIA Nemotron-3-Puzzle-75B-A9B  (`NemotronHPuzzle`) — best new fit, not yet fetched
- **What:** NAS-derived ("Puzzle") Nemotron-H variant, **75 B total / 9 B active**. Arch support
  merged [#25444](https://github.com/ggml-org/llama.cpp/pull/25444), in the b10677→b11003 range.
- **GGUF:** [RemySkye/…-GGUF](https://huggingface.co/RemySkye/NVIDIA-Nemotron-Labs-3-Puzzle-75B-A9B-GGUF)
  — **Q4_K_M 48.1 GB, Q5_K_M 54.7 GB, Q6_K 62.6 GB**. All three fit the ~109 GB ceiling with real
  headroom, which makes **Q6_K affordable here** in a way it is not on a 24–48 GB card.
- **Why it's interesting:** it is the one genuinely new model that *fits the box's shape* — big total,
  low-ish active, and room to spend on quant rather than on context.
- **Gate:** confirm the arch string resolves (it appears to map onto `nemotron_h_moe` rather than
  carrying a distinct id — **verify by loading**, don't assume), then the determinism diff.
  ⚠️ 9 B active is 3× the coder's; expect materially lower tg. Measure before adopting.

### Qwen3.8-Flash-Next  (arch `qwen4exp`) — downloaded, unverified
- **What:** Qwen's "Qwen4 architecture preview" — MoE + hybrid SSM/attention, natively multimodal,
  1 M context. **There is no Qwen3.9 or Qwen4 release**; this preview is the current frontier of that
  line and it is already on disk.
- **GGUF:** `UD-IQ4_XS` (87.2 GB) downloaded — the recommended fit under the ceiling (~22 GB left for
  KV/compute). Registry keys `flashnext` / `flashnext-iq1`.
- **Gate:** arch merged ([#27742](https://github.com/ggml-org/llama.cpp/pull/27742)), present in
  b11003. Only the confirmation diff remains (router-down; 87 GB cannot co-reside).

### NVIDIA Nemotron-3.5-Lightning-30B-A3B  (arch `nemotron_h_moe`) — fetchable
- **What:** hybrid **Mamba-2 + MoE + attention** (only ~6 attention layers of 52 → tiny KV even at
  long context), **30 B / 3 B active**, 262 K context, **MTP draft head built in**
  (`--spec-type draft-mtp`).
- **GGUF:** [bartowski/…-GGUF](https://huggingface.co/bartowski/NVIDIA-Nemotron-3.5-Lightning-30B-A3B-GGUF)
  — Q4_K_M ~25.5 GB (IQ4_XS 18.9). Not yet downloaded.
- **Gate:** arch present in b11003. Mamba-2 state is view-aliased → run the confirmation diff. Small
  enough (~25 GB) to **co-reside in the router**.

### DeepSeek-V4-Flash  (arch `deepseek4`) — downloaded, and b11003 added fused ops for it
- **GGUF:** `UD-IQ2_M` (~91 GB) already on disk. b11003 adds DeepSeek-V4 hyper-connection fused ops
  ([#26578](https://github.com/ggml-org/llama.cpp/pull/26578)) and vision input
  ([#28154](https://github.com/ggml-org/llama.cpp/pull/28154)), so a re-test on b11003 is worth more
  than the previous attempt. 13 B active → expect the slowest tg of anything here.

### Tencent Hy 4  (arch `hy_v4`) — new in b11003, unexplored
Preview arch support landed ([#28127](https://github.com/ggml-org/llama.cpp/pull/28127)); `hy_v4` is
present in b11003 and absent from b10677. No GGUF assessed yet.

## Still engine-gated (arch NOT in any build here)

### GLM-5.3-Flash  (arch `glm5-next`) — deprioritised, not just blocked
- **What:** Z.ai multimodal GLM-5 — **320 B-A18B**, sparse+linear hybrid, 1 M context.
- **Size verdict (the real blocker):** at 320 B total, only **1-bit** quants fit the ~109 GB ceiling
  (`UD-IQ1_S` 93.1 GB; everything ≥ IQ3 is 120–200 GB, and `Q8_0` is ~360 GB across 8 shards —
  confirmed against the HF file tree 2026-09-16). A 1-bit cut of a 320 B MoE is quality-dubious and
  unmeasured, and it would leave ~15 GB for KV on a 1 M-context model.
- **Gate:** [#27773](https://github.com/ggml-org/llama.cpp/pull/27773) (`glm5-next`, supersedes
  [#27752](https://github.com/ggml-org/llama.cpp/pull/27752)) is **still open**, and `glm5-next` is
  **confirmed absent from b11003**.
- **Recommendation:** treat this as *deprioritised rather than pending*. Even if the PR merges
  tomorrow, the size verdict is independent of it and does not improve. **Don't fetch 93 GB** to find
  out. Nemotron-3-Puzzle-75B-A9B at Q6_K is the better use of the same disk and the same window.

## DFlash2 — a speed lever, not a model (Vulkan gate cleared)
[`incoai/dflash-2`](https://huggingface.co/collections/incoai/dflash-2) ships 2–3 B block-diffusion
**draft** models for speculative decoding, incl. one for Qwen3.8-27B
([GGUF](https://huggingface.co/incoai/Qwen3.8-27B-DFlash2-GGUF), Q4_K_M 1.14 GB, registry
`dflash2-qwen38`). Support merged ([#27342](https://github.com/ggml-org/llama.cpp/pull/27342)) as
`--spec-type draft-dflash`. It **was** blocked on Vulkan by #27805 — **now fixed**, so it's worth an
A/B. Temper expectations: in llama.cpp its ~1.8× decode ≈ our existing `draft-mtp` (1.79×); the
headline 3.43× is vLLM/SGLang + FA-3 on datacenter GPUs and doesn't transfer here. Note the current
`:8080` model (`qwen3next`) has **no MTP head and no draft**, so this only applies to the qwen38 line.

## Watching

- **[#27805](https://github.com/ggml-org/llama.cpp/issues/27805)** — Vulkan `ggml_vk_graph_optimize`
  correctness bug: **CLOSED**, fixed by [#27812](https://github.com/ggml-org/llama.cpp/pull/27812),
  shipped in **b10677**. This was the bellwether for hybrid/SSM arches on gfx1151.
- **[#27742](https://github.com/ggml-org/llama.cpp/pull/27742) `qwen4exp`** — MERGED; in b11003.
- **[#25444](https://github.com/ggml-org/llama.cpp/pull/25444) Nemotron-3-Puzzle** — MERGED; in b11003.
- **[#28127](https://github.com/ggml-org/llama.cpp/pull/28127) `hy_v4`** — MERGED; in b11003.
- **[#27773](https://github.com/ggml-org/llama.cpp/pull/27773) `glm5-next`** — OPEN; absent from all
  builds here, including b11003.
- **Not upstream, don't export:** `GGML_VK_MMID_ROWLISTS` / `_SMALLN` / `_BM64` / `_WAVE32`,
  `GGML_VK_FA_WAVE32` and `--tensor-read-lazy` circulate in Strix-Halo tuning write-ups but exist
  only in a **fork**. Verified 2026-09-16 against `ggml-vulkan.cpp` on master and `--help` on b11003:
  they are **silent no-ops** on stock builds. Real upstream knobs not currently used here:
  `GGML_VK_MAX_NODES_PER_SUBMIT`, `GGML_VK_ALLOW_SYSMEM_FALLBACK`, `GGML_VK_PREFER_HOST_MEMORY`.

The moment a gate clears, the model is fetched (if needed) and test-loaded on an **isolated port with
`bin-b11003`**; Vulkan correctness is confirmed with the fixed-seed/temp-0 N≥10 diff (a full CPU
reference is impossible for 50–93 GB GGUFs vs ~32 GB system RAM). A test that needs the model resident
**stops the router first and restarts it after**. See `scripts/windows/stage-nextgen.ps1`.
