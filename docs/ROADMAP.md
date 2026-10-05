# Next-gen models — staged, tracked, and the exact gate on each

This page is the "not yet fully cleared" list. The published, pinned-build numbers are in
[RESULTS.md](RESULTS.md); models cleared *after* that pin (Ornith-1.5, Qwen3-Coder-Next) carry their
own measurements in the "Cleared" section below, not in RESULTS. The repo's rule is to publish the
claim *and* the thing blocking it — so each model below records its exact gate, honestly.

**Status refreshed 2026-10-05.** Current state:

1. **`:8080` serves `ornith15` solo** — Ornith-1.5-35B-A3B Q6_K on **`bin-b11414`** (since 2026-10-05;
   b11330 before), 2 slots × 262144, `draft-dflash` (Q8_0 draft, n=3), `-ub 1024`, vision + tools +
   thinking, ~41 GB of ~109. b11414 was taken for correctness
   ([#29942](https://github.com/ggml-org/llama.cpp/pull/29942), tool-call parser use-after-free); speed
   is unchanged. Gates: determinism 12/12, 20/20 concurrent requests with 0 child restarts.
2. **Gated 2026-10-05 on b11414 — runnable, selectable, not served** (numbers in CLAUDE.md):
   - **Qwen3.8-Flash-Next** UD-IQ4_XS (`flashnext`): loads **only with `--lazy-mode on`** (the 28.8 GB
     per-layer embedding table otherwise exhausts the ~32 GB system RAM). Determinism 12/12;
     20.6 t/s plain, **26.9 t/s with the ggml-org MTP draft**; 380 t/s prefill @16K; one slot
     (#28280); text-only on Vulkan (#29093); lazy reads grow host RAM during long runs.
     [Strata](https://github.com/Niko1221/Strata), the dedicated engine for this model, was evaluated
     and is not usable here: CUDA/HIP/SYCL only (no Vulkan), gfx1151 only in unmerged PRs, and its
     core trick (expert caching across VRAM/RAM/SSD) does nothing on unified memory. Its other two
     levers — the Q2_0 type and the model's MTP head — are already in stock llama.cpp.
   - **Holo4-35B-A3B** Q6_K (`holo4`): same arch as ornith15; determinism 12/12, tool calls OK.
   - **Ling-3.0-flash-VL** Q4_K_M (`ling3-vl`, 124B / 5.5B active, MIT): download incomplete (stopped
     under memory pressure); not yet gated.
   - **GLM-5.3-Flash**: post-merge GGUFs exist but the smallest is 133.8 GB; the `glm53-flash`
     registry files declare `glm5next` (pre-merge name) and will not load.
3. **The previous engine was `bin-b11330`**, taken for correctness
   ([#28956](https://github.com/ggml-org/llama.cpp/pull/28956), wrong `mul_mat` results on sliced
   caches). `glm5-next` is now **present** in it ([#27773](https://github.com/ggml-org/llama.cpp/pull/27773)
   merged 2026-09-30); GLM is gated on its *file*, not the engine — see below.

*(history, 2026-09-16 revision: "Qwen3-Coder-Next cleared its gate and is now the model on `:8080`"
and "the staged engine moved `b10677` → `b11003`… `glm5-next` is still absent". Coder was replaced by
ornith15 on 2026-09-19; the engine went on to b11046 and then b11330.)*

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

The current engine for new arches is **`bin-b11414`** (the live `:8080` engine since 2026-10-05; b11330 from 2026-10-02;
carries everything b11003 had — `qwen4exp`, `qwen3next`, `nemotron_h_moe`, `deepseek4`, `hy_v4`,
`laguna`, `muse-glimmer`, `dflash`, the #27805 fix — plus `glm5-next` and `mimo2`).
*(history: this was `bin-b11003` as of 2026-09-16, then `bin-b11046`.)*
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

### Ornith-1.5-35B-A3B  (arch `qwen35moe`) — ✅ SERVING SOLO on `:8080` (2026-09-19)
- **Lineage correction, worth recording once:** an earlier note here guessed that `ornith-ai` was a
  different publisher reusing the "Ornith" name. **It is not.**
  `huggingface.co/api/models/deepreinforce-ai/Ornith-1.0-35B` returns **307 → `ornith-ai/…`** — the org
  was renamed, and Ornith-1.5 is the genuine successor to the `ornith-1.0-35b` already on this box.
- **What:** 36 B total / **~3 B active** MoE, `model_type qwen3_5_moe` → llama.cpp **`qwen35moe`**,
  which the pinned `bin\` *already* knows (same arch as Ornith-1.0). Standard attention — **not** an
  SSM/linear-attention hybrid, so **no #27805 risk class** and no determinism gate required.
  262144 native context (1 M only via YaRN 4.0, deliberately unused). **MIT.**
- **GGUF:** first-party [`ornith-ai/Ornith-1.5-35B-A3B-GGUF`](https://huggingface.co/ornith-ai/Ornith-1.5-35B-A3B-GGUF)
  — Q4_K_M 20.22 / Q5_K_M 23.61 / **Q6_K 27.20** / Q8_0 35.21 / BF16 66.19 GiB, plus
  `mmproj-Ornith-1.5-35B-BF16.gguf` (0.84 GiB). Q6_K chosen; the gemma A/B is the prior that Q8_0
  buys nothing but latency, and that remains **unmeasured on this model**.
- **Current serving config (2026-10-05, verified from `GET /models` `status.args`):** `bin-b11414` (b11330 2026-10-02 → 10-05),
  `--parallel 2 --ctx-size 524288` (2 slots × 262144), `-ub 1024`, `draft-dflash` with the first-party
  **Q8_0** DFlash draft at n=3, vision mmproj, tools, thinking — **~41 GB of ~109**. Launched at logon
  by the Startup-folder router (`run-router.ps1 -Models ornith15 -Bin .\bin-b11414 -Parallel 2
  -PerSlotCtx 262144`); see [MULTI-USER.md](MULTI-USER.md) §8/§10 for why 2 slots *with* speculation
  and the `-Parallel 4 -PerSlotCtx 262144 -NoSpec` alternative for concurrent load.
- **Verified working on b11046, re-checked after tuning:** text + thinking, **vision**, **tool
  calling** (`sql_query` emitted with valid JSON args), and needle retrieval at 9 k tokens
  (`finish_reason=stop`, exact key returned). *(history: ~36 GB committed of ~109 solo at `-ub 1024`,
  1 slot, `draft-mtp` — the 2026-09-19 config.)*
- **Both per-model settings are now MEASURED (2026-09-19, b11046, solo, 2 reps):**

  | `-ub` | pp4096 @ d0 | **pp4096 @ d32768** | tg128 | peak GPU |
  |---|---|---|---|---|
  | 256 | 674.05 ± 5.74 | 391.34 ± 10.36 | 58.45 | 30.61 GiB |
  | 512 | 854.77 ± 1.98 | 477.81 ± 6.98 | 58.83 | 30.86 |
  | **1024** | **984.89 ± 0.08** | **543.80 ± 2.53** | 58.85 | **31.40** |
  | 2048 | 942.86 ± 0.09 | 481.66 ± 0.54 | 58.74 | 32.84 |

  **`-ub 1024` wins: +39.0% at depth, +46.1% at depth 0, for +0.8 GiB — and 2048 regresses**, the same
  shape as the coder despite a completely different arch. See the ubatch note in
  [OPTIMIZATION.md](OPTIMIZATION.md) row 10.

  `draft-mtp` depth, seed 42, llama-cli default sampler (**NOT greedy** — label corrected 2026-10-02;
  `bench-spec.ps1` never passed `--temp`), n_predict 256: **baseline 58 t/s**; n=1 **64.2 (1.11×)**,
  n=2 62.2 (1.07×), n=3 **64.1 (1.11×)**, n=4 **54.3 (0.94×) — worse than no speculation at all.**
  n=1 and n=3 tie within noise (0.16% on single runs), so **n=3 is kept** as llama.cpp's default.
  **Do not raise it**; the n=4 regression confirms non-monotonic depth on a second model.
  Note the ceiling is only **1.11×** here, nowhere near qwen38's 1.79×.
  *(history: `draft-mtp` n=3 was served 2026-09-19 → 2026-10-02.)* **Superseded 2026-10-02 by
  `draft-dflash`:** single-stream A/B on b11046, seed 42, llama-cli default sampler — baseline 57.9 →
  `draft-mtp` n=3 64.1 (1.11×) → `draft-dflash` + BF16 draft 66.1 (1.15×) → **`draft-dflash` + Q8_0
  draft 70.8 (1.22×)**. DFlash depth peaks at n=3 too (n=4 1.01×, n=7 0.63×). 70.8 is a **single-slot
  bench** number; the shipped 2-slot server measures **51.0 t/s at 1 client** (MULTI-USER.md §10).

  End-to-end after tuning: a 9041-token prefill went **19.3 s → 12.0 s**.
- **Thinking-model caveat:** budget `max_tokens` ≥ 2048 or `content` returns EMPTY. A *counting* prompt
  ("how many times does X appear") spiralled past 4096 tokens of `reasoning_content` and returned
  `finish_reason=length` with empty `content` — the known thinking-model pathology (cf. eval Bug 13),
  **not** a config fault; retrieval over the same 9 k context answered correctly.
- **Vendor-reported and UNMEASURED here:** SWE-bench Verified 79%, SWE-bench Pro 59.6%,
  Terminal-Bench 2.1 68.5%, GPQA Diamond 89.2%. `docs/BENCHMARKS.md` records that decontaminated
  scores run ~4× below self-reported figures. **Do not rank it against `coder` on these.**

### Qwen3-Coder-Next  (arch `qwen3next`) — ✅ cleared; served until 2026-09-19, now on demand
Still fully working and still needs **`-ub 1024`** (its per-model override) and `-Bin .\bin-b11046`.
Bring it back with `run-router.ps1 -Models coder -Bin .\bin-b11046`, or alongside Ornith with
`-Models coder,ornith15` (measured co-resident at **86.3 GB of ~109**, both loaded, vision intact).
Its 512 experts are what make [#28501](https://github.com/ggml-org/llama.cpp/pull/28501) matter — see
the engine A/B below.

Coding MoE, **80 B total / 3 B active**, 262 K context, **text-only** (no vision tower), no MTP head.
`UD-Q4_K_XL` 49.6 GB. Determinism confirmed on b11003 at the serving ubatch — **12/12 byte-identical**
(2026-09-16). Its **`-ub 1024`** override is worth **+34.8%** prefill at depth on this arch; see
[OPTIMIZATION.md](OPTIMIZATION.md) row 10 and [BENCHMARKS.md](BENCHMARKS.md). It will **not** load on
the pinned `bin\` (b10431) at all.

## Arch-supported (b11003 and later, incl. live b11330), pending only a Vulkan confirmation

These arches are present in `bin-b11003` and every later build here, including `bin-b11330`. Because they are linear-attention / SSM hybrids — the exact class
#27805 used to corrupt — each still gets one **fixed-seed, temp-0, N≥10 raw-completion diff** on an
isolated port before being trusted (byte-identical = safe; any divergence = a *new* correctness
issue). Post-#27805 these are expected to pass; the check is confirmation, not a blocker. It needs
the router **stopped** for the big ones, so it's a human-approved, router-down operation. See
`scripts/windows/stage-nextgen.ps1`.

### NVIDIA Nemotron-3-Puzzle-75B-A9B  (`nemotron_h_moe`) — ❌ TESTED 2026-09-16, DOES NOT LOAD
- **What:** NAS-derived ("Puzzle") Nemotron-H variant, **75 B total / 9 B active**, 1 M context
  (256 K default), thinking model, **has an MTP head**, no vision. **License: OpenMDW v1.1** — not
  Apache/MIT like the rest of this list.
- **GGUF:** Q4_K_M 48.1 GB, Q5_K_M 54.7 GB, Q6_K 62.6 GB — all fit the ceiling with real headroom,
  which is exactly why it looked like the best new fit for this box.
- **Result: Q6_K was fetched (62.6 GB, byte-verified) and b11003 refuses it.**
  ```
  load_arch_tensors: layer 88 declares neither expert_feed_forward_length
  nor expert_used_count, cannot determine the expert FFN size
  ```
- **This is an upstream packaging problem, not a bad quant and not a config error.** Decoding the
  GGUF header here shows the file is internally *consistent*: Puzzle is genuinely heterogeneous, so
  `expert_feed_forward_length` / `expert_used_count` are **per-layer arrays of 90**, of which 49 are
  legitimately `0` (Mamba-2 / attention layers with no expert FFN). `block_count = 90` and
  `nextn_predict_layers = 2`, so layers 88–89 are the MTP block — and layer 88 holds `nextn.*` plus
  attention tensors and **no** `ffn_*_exps`, so its `0` is the correct description of that layer.
- **Root cause:** every published Puzzle GGUF was converted from the **#25444 review branch** and uses
  an MTP layout master does not read. [PR #28779](https://github.com/ggml-org/llama.cpp/pull/28779)
  (merged 2026-09-13, already in b11003) only turns the former SIGFPE into this clean error; its own
  description states the files *"need reconverting with the current converter."*
  **So a newer build will not fix this.** All four publishers predate the fix (checked 2026-09-16):
  RemySkye 07-14, YanissAmz 07-08, MRockatansky 08-03, Myric 09-09.
- **RETESTED 2026-09-19 on b11046 — fails identically**, byte-for-byte the same error. b11046 carries
  [#29018](https://github.com/ggml-org/llama.cpp/pull/29018) ("extend Nemotron MTP support"), which
  looked promising because it registers `FFN_LATENT_DOWN`/`FFN_LATENT_UP` — exactly the tensors this
  file has in `blk.87`/`blk.89`. But #29018 targets Nemotron **Super 3**, not **Puzzle**, and the
  #28779 verdict stands: the file needs *reconverting*, not a better loader. **Two builds, same
  error — stop retesting this file and watch the publishers instead.**
- **All publishers still stale** (re-checked **2026-10-02**, third check, unchanged): RemySkye 07-14,
  YanissAmz 07-08, MRockatansky 08-03, Myric 09-09. The only Puzzle work in the 284 commits from
  b11046→b11330 was CUDA-side ([#28717](https://github.com/ggml-org/llama.cpp/pull/28717), ssm_scan
  state size 96). **Stop checking this monthly** — it needs a publisher action, not an upstream one.
- **Gate:** a **re-upload converted after 2026-09-13**, or a local conversion from the BF16
  safetensors (~150 GB). Re-check publisher `lastModified` before spending the bandwidth again.
- **Lesson worth keeping:** the arch string resolving (`nemotron_h_moe`, confirmed by range-fetching
  the first 1 MiB of the file *before* downloading) is **necessary but not sufficient** — the engine
  can know an arch and still reject a specific file's tensor layout. The 1 MiB header preflight was
  still worth it; it just can't catch this class. Only a load attempt can.

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
  ([#28154](https://github.com/ggml-org/llama.cpp/pull/28154)), so a re-test on a b11003+ build (now
  `bin-b11330`, since the confirmation is per-binary) is worth more than the previous attempt. 13 B active → expect the slowest tg of anything here.

### Tencent Hy 4  (arch `hy_v4`) — new in b11003, unexplored
Preview arch support landed ([#28127](https://github.com/ggml-org/llama.cpp/pull/28127)); `hy_v4` is
present in b11003 and absent from b10677. No GGUF assessed yet.

## File-gated (arch now in b11330; the GGUF is the blocker)

*(history: this section was "Still engine-gated (arch NOT in any build here)" until #27773 merged
2026-09-30.)*

### GLM-5.3-Flash  (arch `glm5-next`) — ⛔ **TESTED 2026-10-02: the only fitting GGUF does not load**
The two *original* blockers did clear (arch merged, REAP makes 4-bit fit — detail below), so this was
reopened and the 82 GB IQ4_XS was fetched. **It is rejected by both b11330 and b11324:**

```
error loading model hyperparameters: key not found in model: glm5-next.attention.indexer.kpool
```

The file carries `indexer.head_count` / `key_length` / `top_k` but **not `kpool`**. The arch is
genuinely supported — this is a *file* problem, the same class that killed Nemotron-3-Puzzle.

> **The check that caught it, and the one that fooled me first.** The repo's `lastModified` reads
> **2026-10-01**, i.e. *after* the 09-30 merge, which is why it looked safe to download. That field
> is **misleading** — it reflects any file change, and on 10-01 only `README.md` was touched. Per-file
> `lastCommit.date` from the HF tree API shows the **`.gguf` files were uploaded 2026-08-30/31, a
> month before upstream support existed**, and the repo ships its own `glm5-next-llama.cpp.patch`
> + `.bundle`: they were converted with the author's private fork. **Always check per-file dates,
> never repo `lastModified`.**

Also tried: **b11324**, the last build before
[#29805](https://github.com/ggml-org/llama.cpp/pull/29805) ("clamp kpool re-pool bound", 2026-10-01
19:55), on the theory that `kpool` was a late addition. It fails identically — `kpool` was required
from the original merge, so **no post-merge build will load this file**.

**Gate:** a re-conversion with current upstream `convert_hf_to_gguf.py`. No other GLM-5.3 REAP GGUF
exists (checked 2026-10-02), and the unpruned 320B still only fits at 1-bit. Re-check **per-file**
dates before spending 82 GB again.

<details><summary>Why it was reopened (still true, and still the path once a good GGUF exists)</summary>
Ruled out twice (arch unsupported + only 1-bit fit). **Both of those facts have changed:**
- **Arch support MERGED** — [#27773](https://github.com/ggml-org/llama.cpp/pull/27773) merged
  2026-09-30, and `glm5-next` / `glm5_next` are **confirmed present in `bin-b11330`**.
- **REAP makes it fit at an honest quant.** Expert pruning (REAP = 50% of experts removed) takes the
  320 B-A18B model down to a size where 4-bit fits:
  [patrickbdevaney/GLM-5.3-Flash-REAP50-GGUF](https://huggingface.co/patrickbdevaney/GLM-5.3-Flash-REAP50-GGUF)
  — IQ3_M 67.2 / Q3_K_M 73.4 / **IQ4_XS 82.0** / Q4_K_S 87.1 / **Q4_K_M 92.5 GiB**, plus a 1.05 GiB
  mmproj. All fit the ~109 GB ceiling.
- **The genuinely interesting question this poses:** at ~92 GiB you can now have *either* **half the
  experts at honest 4-bit** (REAP50 Q4_K_M) *or* **all the experts at 1-bit** (full IQ1_S, 93.1 GiB).
  Same footprint, two completely different degradation modes, and **this repo cannot currently
  measure which is better** — quality scores are withdrawn. Treat any claim either way as unmeasured.
- **Temper it on speed:** A18B active is ~6× ornith15's ~3B, and tg is bandwidth-bound on *active*
  params, so expect roughly 10–15 t/s against ornith15's 70.8 t/s single-slot bench (the shipped
  2-slot server measures 51.0 t/s at 1 client). REAP does not reduce
  active params, only total. **This is a "bigger brain, much slower" trade, not a free upgrade.**

</details>

### (superseded) GLM-5.3-Flash — the original size verdict, kept for the contrast
- **What:** Z.ai multimodal GLM-5 — **320 B-A18B**, sparse+linear hybrid, 1 M context.
- **Size verdict (the real blocker):** at 320 B total, only **1-bit** quants fit the ~109 GB ceiling
  (`UD-IQ1_S` 93.1 GB; everything ≥ IQ3 is 120–200 GB, and `Q8_0` is ~360 GB across 8 shards —
  confirmed against the HF file tree 2026-09-16). A 1-bit cut of a 320 B MoE is quality-dubious and
  unmeasured, and it would leave ~15 GB for KV on a 1 M-context model.
- **Gate (as of 2026-09-16, superseded):** [#27773](https://github.com/ggml-org/llama.cpp/pull/27773)
  (`glm5-next`, supersedes [#27752](https://github.com/ggml-org/llama.cpp/pull/27752)) was **still
  open**, and `glm5-next` was **confirmed absent from b11003**. *Superseded 2026-10-02: merged
  2026-09-30, present in b11330 — see above.*
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
headline 3.43× is vLLM/SGLang + FA-3 on datacenter GPUs and doesn't transfer here.
*(history, 2026-09-16: "the current `:8080` model (`qwen3next`) has no MTP head and no draft, so this
only applies to the qwen38 line.")* **Superseded:** the current `:8080` model `ornith15` **does** serve
`draft-dflash` — with its own first-party DFlash draft (Q8_0), measured **1.22×** single-stream, not the
advertised ~1.8×. The DFlash2 qwen38 draft above remains un-A/B'd.

## REAP (expert pruning) — the technique that changes what "fits" means here

**REAP** publishes MoEs with a fraction of their experts removed (REAP50 = half). Total params drop,
**active params do not**, so the effect on this box is specific: it buys *fit*, costs *quality* (by an
unmeasured amount), and does **nothing** for tg. That makes it exactly the right tool for models that
were ruled out on size alone, and the wrong tool for anything limited by speed.

Candidates that now fit the ~109 GB ceiling (sizes verified against the HF API 2026-10-02):

| model | REAP size | notes |
|---|---|---|
| **GLM-5.3-Flash-REAP50** | IQ4_XS 82.0 / Q4_K_M 92.5 GiB | arch now supported; see above. A18B → slow tg |
| **MiMo-V2.6-Flash-REAP50** | Q2_K 61.6 / MXFP4_MOE 86.1 GiB | ships mmproj **and** an mtp draft; 1 M ctx, vision |
| Qwen3.6-35B-A3B-REAP-48 | 8.8 GiB | already small; REAP adds little here |

**MiMo-V2.6-Flash unpruned does NOT fit** — 310.8 B total, smallest GGUF is Q2_K at **117.6 GiB**,
over the ceiling. Its arch (`mimo_v2` → `mimo2`) *is* in b11330, and **`ggml-org` publishes the GGUF
themselves**, which is the strongest support signal available — so the REAP50 build is the only way
to run it here.

## Month sweep, 2026-08-19 → 2026-09-19 — what is actually runnable here

Method that works, and the one to repeat: query the HF API for trending `text-generation` models,
filter by `createdAt`, then read each candidate's `model_type` from `config.json` and check that arch
string **against the local build's DLLs** — not against release notes. Generic "best local LLM"
listicles were useless; everything they surfaced was already on disk.

**Runnable — arch present in `bin-b11046`:**
- **Edge0-35B-A3B-preview** (3.4 k likes) — `qwen3_5_moe` → `qwen35moe`, **has vision**. Same arch and
  shape as Ornith-1.5, so it is the obvious head-to-head rival. Not fetched.
- **Qwen3.8-35B-A3B-Distill** (empero-ai) — `qwen3_5_moe`, vision. A distill of the 27B already here.
- **Ternary-Bonsai-2-27B** (918 likes, 405 k downloads) — GGUF header says arch **`qwen35`**, and
  TQ1_0 Vulkan support landed in b11003. Genuinely novel, but a 1.58-bit 27 B optimises for a
  constraint this box does not have; same category error as picking a 9 B here.

**NOT runnable — arch absent from b11046 (checked, not assumed):** Xing4.0-29B-A4B (`xing4_0`),
K2-Horizon-MoVA-36B-A4B (`k2_horizon`), AliceAI-Foundation-80B-A3B (`alice_ai`). All need upstream
support first. **Still ruled out on size:** GLM-5.3 / 5.3-Flash (320 B). *(superseded 2026-10-02:
REAP50 builds fit at 4-bit and the arch is in b11330 — now file-gated, see above.)*

## Watching

- **[#27805](https://github.com/ggml-org/llama.cpp/issues/27805)** — Vulkan `ggml_vk_graph_optimize`
  correctness bug: **CLOSED**, fixed by [#27812](https://github.com/ggml-org/llama.cpp/pull/27812),
  shipped in **b10677**. This was the bellwether for hybrid/SSM arches on gfx1151.
- **[#27742](https://github.com/ggml-org/llama.cpp/pull/27742) `qwen4exp`** — MERGED; in b11003.
- **[#25444](https://github.com/ggml-org/llama.cpp/pull/25444) Nemotron-3-Puzzle** — MERGED; in b11003.
- **[#28127](https://github.com/ggml-org/llama.cpp/pull/28127) `hy_v4`** — MERGED; in b11003.
- **[#27773](https://github.com/ggml-org/llama.cpp/pull/27773) `glm5-next`** — MERGED 2026-09-30;
  present in b11330 *(was OPEN and absent from b11003 as of 2026-09-16)*. The published REAP50 GGUF
  still won't load — file-gated, see above.
- **Not upstream, don't export:** `GGML_VK_MMID_ROWLISTS` / `_SMALLN` / `_BM64` / `_WAVE32`,
  `GGML_VK_FA_WAVE32` and `--tensor-read-lazy` circulate in Strix-Halo tuning write-ups but exist
  only in a **fork**. Verified 2026-09-16 against `ggml-vulkan.cpp` on master and `--help` on b11003:
  they are **silent no-ops** on stock builds. Real upstream knobs not currently used here:
  `GGML_VK_MAX_NODES_PER_SUBMIT`, `GGML_VK_ALLOW_SYSMEM_FALLBACK`, `GGML_VK_PREFER_HOST_MEMORY`.

The moment a gate clears, the model is fetched (if needed) and test-loaded on an **isolated port with
`bin-b11414`** (b11330 2026-10-02 → 10-05; `bin-b11003` as of 2026-09-16); Vulkan correctness is confirmed with the fixed-seed/temp-0 N≥10 diff (a full CPU
reference is impossible for 50–93 GB GGUFs vs ~32 GB system RAM). A test that needs the model resident
**stops the router first and restarts it after**. See `scripts/windows/stage-nextgen.ps1`.
