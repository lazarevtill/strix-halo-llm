# Optimization cheatsheet — Strix Halo / Vulkan / Windows / 96GB

Curated from carteakey.dev "Local LLM Inference Optimization" (Jun 2026), filtered for THIS box.
Many tips there are CUDA/Linux-specific; below is only what applies to AMD 8060S + Vulkan + Windows.
✅ = already doing it · ⬜ = available win · ⚠️ = needs you / caveat.

## Priority order (by impact, for our setup)

| # | Lever | Status | Note |
|---|-------|--------|------|
| 1 | **RAM at rated speed (XMP/EXPO)** | ⚠️ YOU | Measured 7500 vs rated 8533 MT/s → article says this is the #1 lever (up to 2-3× on MoE TG). BIOS. ~+14% for us. |
| 2 | **Speculative decoding — nuanced** | ✅ MEASURED 2026-06-29 | **Native MTP head (`--spec-type draft-mtp`) is a BIG win: Qwen3.6-35B-A3B 67.9 vs 50.2 t/s = +35%.** Generic drafts are NOT: `ngram-mod` ≈ neutral on code (Ornith 59.4 vs 57.6, noise), and community data shows generic draft/ngram **net-negative on general MoE text** (−3 to −12%). Rule: use draft-mtp when the GGUF has the MTP head; ngram-mod only for code; never a separate draft model on these MoEs. (Dense coder still 2.2× — different regime.) |
| 3 | **`--fit on`** for big models | ❌ **USELESS HERE (MEASURED 2026-07-30)** | Two independent reasons it can't work on this box. (a) `-ngl 999` **aborts the fit outright**: `common_fit_params: failed to fit params to free device memory: n_gpu_layers already set by user to 999, abort`. (b) Even without `-ngl`, it sizes against a **fiction** — llama.cpp reports a *constant* `108782 MiB free` whether 0 GB or 42 GB is actually allocated (verified both ways). `llama-fit-params` therefore recommended `-c 125696 -ngl -1` for the 235B regardless of load. **Size manually from the measured ceiling table below.** |
| 4 | **q8_0 KV cache** (`-ctk q8_0 -ctv q8_0`) | ✅ | frees VRAM for more GPU layers. (Article marks [CUDA] but works on our Vulkan.) |
| 5 | **`--parallel 1`** for single big model | ⬜ | Each slot = own KV. For the tight-fit 235B, drop 4→1 to reclaim VRAM for weights. |
| 6 | **flash-attn on** | ✅ | required for big context; works on 8060S (coopmat). |
| 7 | **`-lm none`** (was `--no-mmap`) | ✅ KEEP, NEW SPELLING | The behaviour is right — weights in the VRAM carve-out, host copy paged out (~1.4GB physically resident → RAM ~24GB free). **Do NOT switch to mmap** — measured 2026-06-26: mmap pins a ~21GB file-cache mirror in *physical* RAM → RAM free crashes to ~3.7GB ("RAM 100%"). Watch WorkingSet, not committed bytes. ⚠️ **`--no-mmap` was DEPRECATED in b10182 in favour of `--load-mode`, WHICH DEFAULTS TO MMAP.** Passing the old flag is a trap: it still parses today, so nothing appears to change until it stops being honoured. The launchers pass `-lm none`. |
| 8 | **`--mlock`** | ❌ HARMFUL | **Do NOT use on this Vulkan/UMA box.** Measured 2026-06-26: it pins weights in the ~32GB system-RAM partition and blocks the Vulkan upload to the 96GB VRAM carve-out → `-ngl 999` silently runs from host RAM (GPU dedicated ~0.1GB, RAM ~1GB free, slower). `-lm none` alone already gives permanent VRAM residency (no page-out/refetch until stop). |
| 9 | **Sampling defaults (quality)** | ✅ set 2026-06-29 | **Qwen3.x thinking: `--temp 0.6 --top-p 0.95 --top-k 20 --min-p 0`. NEVER greedy** (endless repetition). Baked into run-qwen36/run-ornith/keep-resident. gpt-oss is different (neutral: temp 1.0/top-p 1.0/top-k 0). Clients may override. |
| 10 | **batch/ubatch tuning** | ✅ RE-MEASURED 2026-08-14 | **`-b 2048 -ub 256`** is the pp sweet spot on gfx1151, and it is the launchers' default. **The `-ub 1024` this table used to recommend costs 29%** (167 vs 129 t/s prefill on Qwen3.8-27B, b10431): a 256-row tile fits gfx1151's 32 KB of shared memory and a 1024-row one does not. `-ub 128` measured 0.9% higher still on one run, so 256 is the knee, not the maximum. The superseded 2026-06-29 MoE figures were pp8192 921 @ub1024 vs 817 @512, 744 @2048 — measured on a different model class, which is why they pointed the wrong way. **tg is unaffected by batch** (~68 t/s either way — tg is bandwidth-bound; the tg lever is RAM XMP). **`-ub` is the most architecture-specific flag in this repo — sweep it, do not copy it.** |
| 11 | **`--prio` / `--no-warmup`** | ⬜ | minor; faster startup, less scheduler jitter. |
| 12 | **Build from source (LTO/native)** | ⬜ later | we use prebuilt b9771; a `-DGGML_VULKAN=ON -DGGML_NATIVE=ON -DGGML_LTO=ON` build squeezes a few %. |

## ⭐ The real memory ceiling is ~109 GB, NOT 96 GB (MEASURED 2026-07-30)

The 96 GB BIOS carve-out is **not** the limit. Because the 8060S is UMA (`uma: 1`), Vulkan exposes
**96 GB dedicated + ~15.8 GB WDDM "shared"** (shared = half the 32 GB Windows partition) =
`114507 MiB` total, which is exactly what llama.cpp prints. Allocating past 96 GB spills into the
shared heap **and costs nothing**, because on an APU that heap is the *same physical LPDDR5X*.

Measured with Qwen3-235B-A22B UD-Q2_K_XL (82.7 GB weights), `-ngl 999 -fa on --parallel 1`, q8_0 KV:

| `--ctx-size` | GPU dedicated | GPU shared | **total** | tg t/s | RAM free |
|---|---|---|---|---|---|
| 32768 | 88.9 GB | 0.6 GB | 89.5 GB | *(cold run)* | 12.6 GB |
| 131072 | 94.9 GB | 4.4 GB | 99.3 GB | **16.71** | 16.2 GB |
| 163840 | 94.9 GB | 7.5 GB | 102.3 GB | **16.67** | 13.5 GB |
| 196608 | 95.2 GB | 10.4 GB | 105.6 GB | **17.04** | 13.5 GB |
| **229376** | 95.6 GB | **13.4 GB** | **109.0 GB** | **16.77** | 9.7 GB |
| 262144 | — | — | ~113 GB needed | **OOM** | — |

**Token-gen is FLAT (16.7–17.0 t/s) from 89 GB all the way to 109 GB.** There is no shared-memory
penalty to avoid. The wall is ~109–110 GB: dedicated saturates at ~95.6 GB and the shared heap runs
out around 13.4 GB (the rest of its 15.8 GB goes to desktop/compositor).

### What this changes
- **Stop treating 96 GB as the budget — you have ~109 GB.** That is ~26 GB of headroom the docs
  previously wrote off, and it is enough to move the 235B from **Q2_K_XL up to a Q3-class quant**
  (~104 GB), which is a far bigger quality win than any flag in this file.
- Watch **RAM free**, not VRAM, as the real constraint past ~105 GB: at 109 GB the Windows partition
  is down to 9.7 GB. Keep `-lm none` (it keeps only ~1.4 GB host-resident) and don't run other
  memory-hungry apps in that regime.
- 262144 ctx does NOT fit for the 235B at Q2_K_XL. 229376 does.

### ⚠️⚠️ Measure `Total Committed`, NOT `Dedicated Usage` (MEASURED 2026-08-03)
**This invalidated several earlier "the GPU is free" conclusions.** A model that WDDM has trimmed
reads **~0 GiB dedicated while still committing tens of GiB.** Measured on two idle llama-servers:

| counter | reading |
|---|---|
| `\GPU Adapter Memory(...)\dedicated usage` | **1.66 GiB** |
| `\GPU Adapter Memory(...)\total committed` | **44.47 GiB** |
| `\GPU Process Memory(pid_7436)\Total Committed` | 24.56 GiB |
| `\GPU Process Memory(pid_27200)\Total Committed` | 17.93 GiB |

With "109 GiB free" on screen, Laguna (needs ~95 GiB) OOM'd on a 1.5 GiB buffer — because 42.5 GiB
was committed by two *idle, trimmed* servers. **Committed is what the allocator must respect.**
```powershell
# the number that actually matters:
(Get-Counter '\GPU Adapter Memory(luid_0x00000000_0x01c3ed4a_phys_0)\total committed').CounterSamples[0].CookedValue/1GB
# per process:
(Get-Counter '\GPU Process Memory(*)\Total Committed').CounterSamples | Where-Object { $_.CookedValue -gt 500MB }
```
`scripts\windows\run-solo.ps1` and `bench-big.ps1` now both key on Total Committed.

### ⚠️ The dirty-baseline OOM trap (cost me 3 false negatives)
`ErrorOutOfDeviceMemory` **usually means something else is still holding VRAM**, not that the config
is too big. All three of `f16 KV @131072`, `q8_0 @196608`, and `q8_0 @262144` first "failed" — then
passed on a clean baseline. Stale/trimmed `llama-server` processes had 14–42 GB still allocated.
**Always confirm the GPU is drained before concluding a model doesn't fit:**
```powershell
(Get-Counter '\GPU Adapter Memory(luid_0x00000000_0x01c3ed4a_phys_0)\dedicated usage').CounterSamples[0].CookedValue/1GB
# want < ~2 GB. If not, find the holder:
(Get-Counter '\GPU Process Memory(*)\Dedicated Usage').CounterSamples | Where-Object { $_.CookedValue -gt 500MB }
```
`ceiling-test.ps1` now hard-aborts rather than measuring on a dirty baseline. Note that servers
started **elevated** (e.g. by `remote-host-setup.ps1`) cannot be killed from a non-elevated shell —
`Stop-Process` returns *Access is denied* and the VRAM never frees.

## Layer placement for MoE that doesn't fully fit (the 235B case)
If weights+KV exceed 96GB, offload *expert* tensors to CPU/RAM (keep attention on GPU):
```
--n-cpu-moe N                       # coarse: first N layers' experts on CPU
--override-tensor ".ffn_(up|down|gate)_(ch|)exps=CPU"   # fine: all experts → CPU/RAM
```
⚠️ **Shared-expert gotcha:** match BOTH routed `_exps` and shared `_shexp` — the `(ch|)` in the
regex captures both. Missing `_shexp` silently eats VRAM → OOM.
Use `llama-fit-params -m model.gguf -fitt 1024 -fitc 32768` to get safe `-ngl`/`-ot` values first.

## Keep the model resident in VRAM forever (no offload)
**The #1 cause of "model offloaded from VRAM after a while" is the machine SLEEPING** (measured
2026-06-27). Windows modern-standby slept the box after **10 min idle (AC) / 4 min (DC)**; sleep
suspends the GPU and **drops all VRAM**, killing/suspending llama-server. Idle alone (≤5 min) does
NOT evict — verified. Fix once (OS level):
```
powercfg /change standby-timeout-ac 0   ;  powercfg /change standby-timeout-dc 0
powercfg /change hibernate-timeout-ac 0 ;  powercfg /change hibernate-timeout-dc 0
```
Then run **`scripts\windows\legacy\keep-resident.ps1`** = watchdog (relaunch on death) + keep-warm (tiny inference every
45s when idle so WDDM never trims VRAM) + residency log. There is no clean software "pin VRAM" API
for an iGPU on Windows, so disable-sleep + keep-warm is the working approach. (To survive reboots,
register keep-resident as a logon Scheduled Task — not done yet.)

## ⭐ RESOLVED: the ROCm-vs-Vulkan-at-128K TODO — **stay on Vulkan** (researched 2026-07-30)

The README's open question ("re-test llama.cpp-ROCm vs Vulkan at 128K before assuming Vulkan always")
is now answered, and the answer is **don't bother switching**. Two independent research passes agreed:

- **ROCm/HIP does NOT beat Vulkan at long context on gfx1151.** Best case, a *patched* ROCm wins
  prefill by ~+10% at 8K and ~0% at 32K, while **losing token-generation by 37–40% at every depth**.
  tg is what you care about.
- **The patch behind ROCm's headline gfx1151 prefill gains (PR #21344, +33–73% pp) was CLOSED
  WITHOUT MERGING.** No prebuilt Windows ROCm binary contains it. The only merged gfx1151 MMQ tuning
  (2026-07-29) is worth 0.98×–1.12×.
- **rocWMMA flash attention — the mechanism that used to make ROCm win long context — was REMOVED
  from llama.cpp upstream on 2026-07-24.**
- **hipBLASLt would matter (~7× on a rocBLAS microbenchmark) but its gfx1151 tuned kernels don't
  exist** (`TensileLibrary_lazy_gfx1151.dat` not found); the rocBLAS regression is still
  "Under Investigation", no PR, no assignee. On Windows AMD documents hipBLASLt for gfx1101 only.
- ROCm on Windows *is* officially supported for gfx1151 (HIP SDK 7.1.1 lists it) and prebuilt
  binaries exist (`lemonade-sdk/llamacpp-rocm` b1302, `llama-b1302-windows-rocm-gfx1151-x64.zip`).
  So it's *available* — just not better. ⚠️ The official `llama-*-bin-win-hip-radeon-x64.zip` is a
  backend-DLL overlay with **no llama-server.exe** — don't waste time on it.
- ⚠️ **HIP is also likely capped at the 96 GB carve-out**, where Vulkan reaches ~109 GB (measured
  above). That alone disqualifies ROCm for big-model work here.

**Verdict: mark the TODO closed. Vulkan + Adrenalin is correct on Windows.** There is also no Vulkan
driver choice to make: AMDVLK was discontinued 2025-09-15, RADV is Mesa/Linux-only, and Windows
exposes exactly one ICD (`amdvlk64.dll` inside your Adrenalin 32.0.31035.1003).

## ✅ DONE 2026-08-10: upgraded to b10338 (`bin\`), b10182 preserved (`bin-b10182\`)

156 builds in one step. `bin\` was byte-identical to `bin-b10182\` beforehand (SHA256 verified), so
the rollback was already staged before anything was touched. Downtime **26 s** (13:52:50 stop →
13:53:16 healthy), taken in a window where no slot was generating and the largest cached context was
3,557 tokens — a restart when a user is holding 60K costs them ~90 s of re-prefill, so wait for a
quiet window rather than taking one.

**Restart via `schtasks /run /tn llama-ornith-daily`, NOT by launching the server yourself** — the
daily server must stay SYSTEM-owned or it dies with your session.

Measured after: Ornith Q5_K_M, 3 slots x 131072, 28.58 GiB, **60.2 t/s** (vs ~63 on b10182, with a
17 MB/s download running concurrently — no regression). New in the `--spec-type` enum: `draft-dspark`
alongside `draft-dflash`, i.e. Meta's drafters are being wired in.

### ⚠️ Muse Glimmer 30B: downloaded, CANNOT LOAD YET (checked 2026-08-10)

Meta Superintelligence Labs, Apache-2.0, and it does **not** run on any tagged release:

```
llama_model_load: error loading model: unknown model architecture: 'muse-glimmer'
```

Note the arch string is **`muse-glimmer` with a HYPHEN**. Absent from b10182 AND b10338. Support
merged in PR #26841 at **2026-08-10 11:07Z**, which is **4.5 h after b10338 was tagged** (tip commit
06:32Z) — so it needs the next release or a master build. PR #26842 (drafter optimisation) is still
open/draft, so dFlash perf for it is not final.

**It is DENSE, and that is the whole story on this box.** ~29.6B params (incl. 1.8B vision encoder),
52 layers, hidden 6656 — every token reads *all* weights, so tg is set by the quant size, not by an
active-param count:

| model | bytes read per token | tg |
|---|---|---|
| Ornith-1.0-35B **A3B MoE** Q5 | ~2 GB | **63 t/s** |
| Qwen3.5-122B **A10B MoE** Q4 | ~5.6 GB | 34 t/s |
| **Muse Glimmer 30B dense** Q4 | **~15 GB** | ~8 t/s bare, **24 t/s with dFlash** |

**AMD measured 24 t/s on a Ryzen AI Max+ 395** — this exact chip, Windows, llama.cpp, Vulkan, dFlash
enabled ([blog](https://www.amd.com/en/blogs/2026/run-meta-muse-glimmer-30b-on-amd-ryzen-ai-max-and-radeon-gpus.html)),
flagged "preliminary". AMD notes the draft-token count needs tuning to get it.

⚠️ **Do NOT use the 5090's 3.1x to back out the baseline.** Meta's own GGUF card gives **3.1x on an
RTX 5090 but only 1.5–1.8x on Apple silicon** — and Apple silicon is bandwidth-bound like this box,
which is exactly the regime where a drafter helps *least* (you still re-read all 15 GB to verify a
batch of draft tokens). Taking 1.5–1.8x, AMD's 24 t/s implies a **~14 t/s baseline**, not the ~8 t/s
that dividing by 3.1 suggests. So the honest range unaccelerated is **8–15 t/s**, most likely nearer
14 — which is Laguna territory, i.e. usable. Measure it here; do not import either number.

Official guidance from the GGUF card, worth having ready:

| | |
|---|---|
| sampling | **`--temp 1.0 --top-p 0.95 --top-k 64`** — note this is NOT our Qwen/Ornith default (0.6/0.95/20) |
| file choice | `kquant-17gb` (15.61 GB) for **24 GB** VRAM; `kquant-dynamic` (18.30 GB) for 32 GB |
| llama.cpp flags for the drafter / mmproj | **not documented** — Meta says to consult llama.cpp itself |
| dFlash speedup | 3.1x RTX 5090 · 1.5–1.8x Apple silicon |

The spec-decoding head also ships standalone as
[`Muse-Glimmer-30B-assistant`](https://huggingface.co/meta-models/Muse-Glimmer-30B-assistant) —
that is the safetensors form (4.76 GB) of the same thing as `dflash-kquant.gguf` (1.52 GB), so for
llama.cpp the GGUF is all you need. An ExecuTorch PTE build exists too; not our path.

Downloaded and byte-verified (`fetch-models.ps1 -Only glimmer`, 17.61 GiB):
`Muse-Glimmer-30B-UD-Q4_K_XL.gguf` (14.79 GB) + `dflash-kquant.gguf` (1.52 GB) +
`mmproj-kquant.gguf` (1.30 GB, vision). **Q4 chosen over Q5 on purpose** — the opposite of the Ornith
call — because memory is not the constraint here (109 GiB) but bandwidth is, and on a dense model the
quant size *is* the per-token cost.

Why it is still worth testing at 24 t/s (2.6x slower than Ornith, but ~1.7x *faster* than Laguna,
which was usable): **MCP Atlas 75.5 vs Qwen3.6's 62.5.** Its other claims are far weaker —
SWE-Bench Pro 51.2 vs 50.2 is noise, and it *loses* SWE-Bench Verified 76.0 vs 77.2. Also note the
published comparison is against Qwen3.6-35B and Gemma4-31B, **not** against anything we actually run.
Given Laguna's published +5.8 TB2.1 lead produced zero measurable advantage here, run it through
`evals\` before believing the +13.

## ✅ DONE 2026-07-30: upgraded to b10182 (`bin\`), b9771 preserved (`bin-b9771\`)

`bin\` is now **b10182 (afeebe103, 2026-07-29)**. The old build is intact at **`bin-b9771\`** —
rollback is `Remove-Item bin -Recurse; Rename-Item bin-b9771 bin`. A pristine copy of the new build
also sits in `bin-b10182\`. All scripts reference `$PSScriptRoot\bin\`, so they picked it up with no
edits (verified: nothing references the one renamed binary, `rpc-server.exe` → `ggml-rpc-server.exe`).

**A/B on Ornith-1.0-35B Q5_K_M (`llama-bench`, -ngl 999 -fa 1 -ctk/-ctv q8_0, r=2) — dead even:**

| test | b9771 | b10182 |
|---|---|---|
| pp512 | 1051.78 ± 14.73 | 1053.81 ± 21.25 |
| pp4096 | 845.23 ± 0.23 | 843.71 ± 0.61 |
| tg128 | 62.74 ± 0.43 | 63.22 ± 0.39 |

Confirms the research: **zero gfx1151 Vulkan gains since b9771.** The upgrade bought
**architectures, not speed** — `laguna`, `deepseek4`, `minimax-m3` are now all PRESENT.
Production re-verified on b10182: Ornith Q5_K_M @ 262144 ctx, 27.67 GB dedicated, **62.9–63.6 t/s**
steady state. (A single *cold* first request reads ~51 t/s — don't mistake that for a regression.)
Also unchanged in b10182: the `108782 MiB free` constant and `shared memory: 32768`.

## Upgrading llama.cpp: no speed reason, only new architectures (researched 2026-07-30)
Latest release is **b10182** (2026-07-29) vs your **b9771**. **Zero gfx1151/RDNA3.5-specific Vulkan
optimizations merged in that window** — the big Strix Halo Vulkan wins (Wave32 FA #19625, graphics
queue #20551) *predate* b9771 and are already in your build. Recent RDNA3.5 work is all HIP-side.
So upgrade **only** to gain model architectures, notably **DeepSeek-V4 (needs ≥ b10034)**.
Note llama.cpp arch strings are `deepseek4`, `qwen35moe`, `minimax-m3`, `cohere2moe`, `glm-dsa` —
they do NOT match the HF `model_type` tags, so don't grep for those.

## Two structural Vulkan-on-Windows limits (explains your pp numbers)
- **Your Vulkan runs with 32 KB workgroup shared memory, not 64 KB** — confirmed in your own
  `llama-bench --list-devices` output (`shared memory: 32768`). This reportedly costs **~25–28%
  prompt-processing** versus published Linux/RADV numbers, and is **not fixable on Windows**.
- **`MUL_MAT_ID` (routed-expert matmul) burns 42–66% of Vulkan prefill time on gfx1151**, and its
  cost is constant with context length. No fix merged. This is why MoE pp is mediocre here.

Together these are the real reason a Linux move would gain ~15–25% — not a flag you're missing.

## GGML_VK_* environment variables (verified present in YOUR b9771 binary)
Extracted directly from `bin\ggml-vulkan.dll`, so this list is exact for your build — 30 vars exist.
The ones that matter on gfx1151:

| var | verdict |
|---|---|
| `GGML_VK_ENABLE_MEMORY_PRIORITY=1` | ⭐ **Present in your build.** Requests max memory priority via `VK_EXT_memory_priority` / `VK_EXT_pageable_device_local_memory` — the real WDDM trim-avoidance knob, which `keep-warm` exists to work around. See measured result below. |
| `GGML_VK_ALLOW_SYSMEM_FALLBACK` | **NO-OP on gfx1151** — setting it changes nothing. Don't bother. |
| `GGML_VK_PREFER_HOST_MEMORY` | Do NOT set — would push weights out of the carve-out. |
| `GGML_VK_DISABLE_COOPMAT` / `_F16` / `_BFLOAT16` | Diagnostic only; disabling any of these is slower here (you have `KHR_coopmat`, `fp16:1`, `bf16:1`). |
| `GGML_VK_ALLOW_GRAPHICS_QUEUE` | Already the default win on Strix Halo (merged pre-b9771). |
| `GGML_VK_FORCE_MAX_ALLOCATION_SIZE` | Only if you hit a single-buffer allocation limit; not needed at these sizes. |
| `GGML_VK_MEMORY_LOGGER=1` | Useful for debugging the dedicated-vs-shared split. |

**There is NO registry key, driver setting, or env var that raises your usable GPU pool on Windows** —
you are already at the platform max on both halves of the split. (Linux gets ~105–110 GiB via
`amdttm` GTT tunables; Windows has no analogue, but note we measured ~109 GB on Windows anyway.)
**HAGS** is at driver default (`HwSchMode` absent from the registry) and there is no published
gfx1151 Vulkan-compute measurement either way — **A/B it, don't assume**. **MPO is irrelevant.**

## ⭐ Claude Code (and Codex) can point STRAIGHT at llama-server — no shim (VERIFIED 2026-07-30)

**b10182 serves the Anthropic Messages API natively.** Verified two ways: byte-scanned
`bin\llama-server-impl.dll` (found `/v1/messages`, `/v1/messages/count_tokens`, the Anthropic SSE
event names, `x-anthropic-billing-header`) and confirmed live — `POST /v1/messages` returned a
correctly shaped `{"type":"message","content":[...],"stop_reason":"end_turn","usage":{...}}` and
`/v1/messages/count_tokens` returned `{"input_tokens":25}`. Upstream this is PR #17570, merged
2025-11-28. b10182 also serves `/v1/responses` (OpenAI Responses) and `/v1/chat/completions/control`.

**The entire claude-code-router / y-router / claude-bridge / LiteLLM-translation category is obsolete
on this box.** Just set:
```powershell
$env:ANTHROPIC_BASE_URL='http://127.0.0.1:8080'   # no trailing /v1
$env:ANTHROPIC_AUTH_TOKEN='dummy'
$env:ANTHROPIC_MODEL='<alias>'; $env:ANTHROPIC_SMALL_FAST_MODEL='<alias>'
```
Keep `--jinja` (required for tool use on `/v1/messages`).

⚠️ **ONE Claude Code tool breaks the grammar compiler.** With all 56 tools every request 400s with
`Failed to initialize samplers: failed to parse grammar`. Bisected tool-by-tool: **exactly one of 56
fails — the `Workflow` tool**, because its schema carries `{"type":"string","maxLength":524288}`.
Minimal repro: that schema at `maxLength 524288` → 400; at `1024` → 200; absent → 200. llama.cpp's
JSON-Schema→GBNF converter blows up on very large `maxLength` bounds.
**Workaround: `claude --disallowedTools Workflow`.** Worth filing upstream — it's a one-line clamp.

**Codex CLI** needs `wire_api="responses"` (it hard-removed chat/completions in Feb 2026), so every
pre-mid-2026 "Codex needs a shim" guide is obsolete for llama.cpp:
```toml
# %USERPROFILE%\.codex\config.toml
[model_providers.llama_cpp]
name = "llama.cpp"
base_url = "http://127.0.0.1:8080/v1"
wire_api = "responses"
```

## ⚠️ `--cache-reuse` is a NO-OP on these MoEs — removed (VERIFIED 2026-07-30)
The production 35B logs, at every startup:
```
srv load_model: cache_reuse is not supported by this context, it will be disabled
```
It requires KV shifting (`llama_memory_can_shift`), false for this MoE context. **Not** caused by
q8_0 KV or `kv_unified` — both were tested and fail the same way. Removed from `scripts\windows\run-solo.ps1`;
`scripts\windows\legacy\run-server.ps1` and `ornith-router\serve-model.ps1` still pass it and should
be cleaned up too.

**You don't need it.** Plain **prefix caching** already prevents re-prefill on append-only
conversations — MEASURED over a 4-step agentic loop (1327-token system prompt + tool defs):

| step | `prompt_n` (prefilled) | `cache_n` (reused) |
|---|---|---|
| 1 | 2185 | 0 |
| 2 | **344** | 2181 |
| 3 | **344** | 2521 |
| 4 | **344** | 2861 |

Only genuinely new tokens get prefilled (`cache_prompt` is on by default). `--cache-reuse` addresses a
*different* case: a prefix that diverges in the **middle**, where the surviving suffix is KV-shifted.
**The real lever is your harness:** log `timings.prompt_n` and `timings.cache_n` per agent step. If
`prompt_n` ever spikes to the full conversation length, the harness is rewriting history (compaction,
re-ordered tool results, a timestamp in the system prompt) — fix that, not the flag.

## Diagnostic-first rule
Before tuning flags, the article's #1 lesson: **check RAM speed** (our 7500<8533), **power plan**
(High Performance ✅) **AND sleep timeout = Never** (sleep drops VRAM — see above), and **thermals
under sustained load**. Don't optimize the wrong layer. When chasing memory issues, measure
*physical RAM / WorkingSet* and *GPU dedicated usage*, not committed bytes.

## ⭐ Model shortlist for 109 GB, July 2026 (researched 2026-07-30)

The 55–115 GB band is **only four models**. Everything else is either superseded or too big.

| model | quant | size | active | ctx | license | notes |
|---|---|---|---|---|---|---|
| model | quant | size | active | ctx | license | note |
|---|---|---|---|---|---|---|
| **Ornith-1.0-35B** | **bf16** | 64.61 GB | A3B | 262K | MIT | **fastest by far (~63 t/s), full precision.** Same model you already trust |
| ⭐ **Qwen3.5-122B-A10B** | UD-Q4_K_XL | **78.65 GB** | A10B | 262K | Apache-2.0 | best all-round: honest **4-bit**, `qwen35moe`, MTP head → `draft-mtp` (+35%) |
| **Laguna-S-2.1** | Q4_K_M | 89.4 GB | **A8B** | **1M** | OpenMDW-1.1 | best *published* agentic scores (TB2.1 70.2%). Our 2026-08-04 "measured tied" claim is **WITHDRAWN** — see the banner below. Still 4x the cost and the slowest of the three |
| DeepSeek-V4-Flash | UD-IQ2_M | 85.00 GB | A13B | 1M | MIT | 284B but only **~2-bit**; slowest of the set |
| DeepSeek-V4-Flash | UD-Q2_K_XL | 90.2 GB | A13B | 1M | MIT | as above, tighter fit (~19 GB for KV) |
| Nemotron-3-Super-120B-A12B | — | ~80 GB | A12B | — | NVIDIA | Mamba2 hybrid |
| gpt-oss-120b | mxfp4 | 60.88 GB | — | — | Apache-2.0 | fast, but the oldest here |

**All of the above now load** — `laguna` and `deepseek4` arrived with the b10182 upgrade.

### DeepSeek-V4-Flash: fits, but it's the weakest value here
`unsloth/DeepSeek-V4-Flash-GGUF` ships 13 rungs; UD-IQ2_M (85.00 GB) and UD-Q2_K_XL (90.2 GB) fit
the 109 GB ceiling. But note what you're buying: **a ~2-bit quant of a 284B model**, with **A13B
active** — the highest active-param count of the set, so the **slowest tg** (tg is bandwidth-bound on
active params: A3B→~63 t/s, A8B→~25-30, A10B→~20-25, A13B→~15-20, all estimates except A3B).
As a rule, **an honest 4-bit of a smaller model beats a 2-bit of a bigger one at equal bytes.**
So Qwen3.5-122B-A10B at Q4_K_XL (78.65 GB) is the better pick unless you specifically want
DeepSeek-V4's capabilities and accept both the quantization damage and the speed.

### Ranking for this box — SUPERSEDED BY MEASUREMENT (2026-08-04)

This ordering was predicted from published benchmarks. The **speed** half was tested and did not
survive. The **quality** half was tested, appeared settled, and has since been withdrawn — the run
that settled it was contaminated (see the banner below):

1. ~~**Speed + trusted quality:** Ornith-1.0-35B **bf16** (64.61 GB, ~63 t/s) — biggest easy win.~~
   **bf16 is a trap on this box: measured 11.17 t/s, 5.6x SLOWER than Q5_K_M** (pp collapses too,
   241 vs 698). Use **Q5_K_M (23 GB, ~58 t/s)**. *(Speed — stands.)*
2. **Best all-round:** Qwen3.5-122B-A10B — 3.4x the size, ~2x the wall-clock. *(Quality vs Ornith:
   unresolved. The "ties" claim is withdrawn.)*
3. **Best agentic coder:** Laguna-S-2.1 — 3.9x the size, 4x slower. *(Quality vs Ornith:
   unresolved. The "ties" claim is withdrawn.)*
4. **Max raw capability, accepting 2-bit and slow:** DeepSeek-V4-Flash UD-IQ2_M — speed measured
   2026-08-15 (85.9 pp / 12.5 tg); quality pending.

**Current recommendation is unchanged: `scripts\windows\run-solo.ps1` with its default,
Ornith-1.0-35B Q5_K_M** — but on **cost**, not on measured quality parity. It is a quarter the size
and several times faster, and those numbers are solid. Whether the big models buy real quality is
**an open question** the hard tier was built to answer; until it reports, treat "they buy nothing"
as unproven rather than established. Reach for Qwen3.5-122B when you need its 262K context or
`draft-mtp`, and Laguna when you need >262K context.

`.\scripts\windows\download-model.ps1 -Repo unsloth/Qwen3.5-122B-A10B-MTP-GGUF -File Qwen3.5-122B-A10B-UD-Q4_K_XL-00001-of-00003.gguf`
**Download to C: (1234 GB free), not D: (123 GB free).** Stop at Q4_K_XL — UD-Q5_K_XL (93.85 GB)
leaves no room for real context, UD-Q6_K (104.12 GB) doesn't fit at all.

### Qwen3.5-122B-A10B replaces the 235B outright
It is **better quality AND ~2× faster** (A10B vs A22B active — tg is bandwidth-bound on active
params). This also settles the "Q2_K_XL vs Q3_K_XL for the 235B" question: **neither**.

### Ruled out — do not download (byte-summed, not guessed)
- **GLM-5.2 (753B) UD-IQ1_S = 229.7 GB** — 2.1× the ceiling. 1-bit is not enough. GLM has gone
  barbell: GLM-4.7-Flash (31B) or GLM-5.2 (753B), nothing in between.
- **Ornith-1.0-397B UD-IQ1_S = 112.69 GB** — *looks* like it fits, but that's **weights alone**,
  leaving nothing for KV or compute buffers. Trap.
- MiniMax-M3 427B · Kimi-K2.7-Code / K3 (~1T) · DeepSeek-V4-Pro 1.6T · Qwen3.5-397B-A17B ·
  thinkingmachines/Inkling 952B — all far too big at any quant.
- Superseded: Qwen3-235B-A22B, GLM-4.5-Air, MiniMax-M2, Llama-4-Scout (17.2 t/s), Hunyuan-A13B,
  Step-3. ERNIE-4.5-300B-**A47B** is hopeless at ~256 GB/s regardless of size.
- **Honest ceiling: 128 GB of unified memory in July 2026 buys the 120–284B class, not frontier.**

### 30–60 GB band: nothing beats what you already run
No verified quality/benchmark delta over Ornith-1.0-35B / Qwen3.6-35B-A3B. The one genuine gap worth
trying: **GLM-4.7-Flash UD-Q8_K_XL (35.62 GB)** — 31B/~A3.5B, 202K ctx, MIT, and at 31B you can
afford a **near-lossless Q8** here, which is unusual. Your Qwen3-Coder-30B (Dec 2025) is the most
dated item in the lineup.

## ⭐ ONE MODEL AT A TIME → use `scripts\windows\run-solo.ps1` (measured 2026-07-30)

Chosen mode as of 2026-07-30: **single model, whole 109 GB budget**. `scripts\windows\run-solo.ps1` implements it —
solo occupancy enforcement, `--parallel 1`, max context, `GGML_VK_ENABLE_MEMORY_PRIORITY=1`.

**Two models cannot co-reside at the top of the range.** Measured: Ornith Q5_K_M (24.19 GB resident)
+ 235B Q2_K_XL (~83 GB weights) = ~107 GB of weights alone → the **235B OOMs**, even at ctx 4096.
And **WDDM did NOT trim the resident model to make room** — the newcomer simply failed while the
victim held all 24.19 GB and still answered at 69.9 t/s. This *contradicts* the older CLAUDE.md note
that "loading a 3rd big GPU process transiently trims an idle model to ~0.1 GB".

⚠️ **`GGML_VK_ENABLE_MEMORY_PRIORITY` trim-protection is UNVERIFIED.** The A/B was invalidated (two
concurrent test runs killed each other's processes). The var *is* present in b9771 and is harmless;
a single-sample tg reading was 62.5 vs 57.8 t/s but that is **not** a reliable result. Treat as
"enabled, benefit unproven" — re-test properly if you care.

### Bigger Ornith = a bigger QUANT, not a bigger model (verified byte counts)
`deepreinforce-ai/Ornith-1.0-35B-GGUF` ships five rungs. You were running the 2nd smallest:

| quant | size | fits with big ctx? |
|---|---|---|
| Q4_K_M | 19.72 GB | yes (what's in `D:\llamacpp-vulkan\models`) |
| Q5_K_M | 23.04 GB | yes — **current default**, 262144 ctx @ 29.93 GB total, **63.3 t/s** empty-cache / **~58 t/s** under eval load |
| Q6_K | 26.56 GB | yes |
| Q8_0 | **34.38 GB** | yes — effectively lossless, ~75 GB spare |
| **bf16** | **64.61 GB** | **yes — FULL PRECISION**, ~44 GB spare for KV |

With one model at a time there is no reason to run Q4/Q5 of your favourite coding model. **Go Q8_0
or bf16.** This is the highest quality-per-effort move available and needs no new architecture.
⚠️ Ornith-1.0-**397B** UD-IQ1_S (112.69 GB) is a trap — weights alone exceed the 109 GB ceiling.

### Laguna-S-2.1 (poolside) — loads since b10182; slowest of the three, quality unresolved
118B total / **A8B active** / **1,048,576 ctx** / OpenMDW-1.1. 48 layers, global:sliding-window
attention 1:3 (512-token window → cheap long context), 256 routed + 1 shared expert.
Published: **Terminal-Bench 2.1 70.2%** vs Ornith-1.0-35B's 64.4% · SWE-bench Multilingual 78.5% ·
SWE-Bench Pro 59.4%. ⚠️ **Neither the speed nor the quality prediction held.** "A8B active" implied
it would be fast here; it is the *slowest* of the three at ~14 t/s, because it routes **10 of 256**
experts and 256-way routing hits the gfx1151 `MUL_MAT_ID` weakness. ~~And on two private
uncontaminated suites it scored *level with* Ornith-1.0-35B, a model a quarter its size.~~ **That
quality comparison is withdrawn** — the run was contaminated (see the banner below), and Laguna's
transcript for one task contained no code at all. The **speed** finding stands: it is the slowest
of the three, and "A8B active" did not make it fast here.

`poolside/Laguna-S-2.1-GGUF` **Q4_K_M = 96,031,829,760 B = 89.4 GB → FITS** (~19 GB left for KV, and
sliding-window keeps KV small). Q8_0 (128.75 GB) and F16 (235.2 GB) do not fit.

🚧 **Blocker: arch `laguna` is ABSENT from your b9771** (verified against `bin\llama.dll`). It is
present in upstream `master` (`{ LLM_ARCH_LAGUNA, "laguna" }`), so **upgrade to b10182 and it works
with the stock Vulkan build — no Poolside fork needed.** (Done — see the b10182 section above.)

#### ⭐ Laguna measured on this box (2026-08-03)

Read straight from the GGUF metadata, because the research summary was wrong about this:
`expert_count 256`, **`expert_used_count 10`** (not "4 of 64"), `block_count 48`,
`sliding_window 512`, `context_length 1048576`, `rope.scaling.type yarn` factor 128 over an original
8192. Routing 10 of 256 experts is why it lands at **~14.1 t/s** — slower than Qwen3.5-122B-A10B
despite the "A8B" label, since 256-way routing hits the known gfx1151 `MUL_MAT_ID` weakness.

## ~~⭐⭐ Three-way comparison, measured 2026-08-04 — THEY ARE TIED~~ — WITHDRAWN 2026-08-15

> ### 🚩 The tie below was manufactured by the harness. Do not quote this table.
>
> The suites ran at **temperature 0**, which drove models into repetition loops that emitted no
> answer at all — 9 of 9 truncated turns were loops. The truncation rule then scored each turn on
> the last *complete* answer, so a turn that produced nothing inherited the previous turn's score.
> The two bugs cancelled into a clean-looking 70/70 for everything.
>
> Re-scoring the same transcripts without the rescue: Qwen3.5-122B's 70/70 contains a raw **0/20**
> and **0/18**; Laguna emitted **no code at all** on one task. Those are not tied models.
>
> Written up as bugs **10** and **11** in [`../evals/README.md`](../evals/README.md); current
> status in [`RESULTS.md`](RESULTS.md). The **speed** figures in the table are unaffected — they
> come from `llama-bench` and never touched the eval harness.

Ornith-1.0-35B Q5_K_M vs Laguna-S-2.1 Q4_K_M vs Qwen3.5-122B-A10B Q4_K_XL, each the sole occupant
of the box at `ctx=131072`, on two private uncontaminated suites (`evals\`).

| | tool calling | 95% CI | agentic coding | turn 1 | truncations | tg |
|---|---|---|---|---|---|---|
| **Ornith-1.0-35B Q5_K_M** | 28/29 = 96.6% | [82.8, 99.4] | **70/70** | 45/45 | 1 | **~58 t/s** |
| **Qwen3.5-122B-A10B Q4_K_XL** | 28/29 = 96.6% | [82.8, 99.4] | **70/70** | 45/45 | **3** | ~34 t/s |
| **Laguna-S-2.1 Q4_K_M** | 27/29 = 93.1% | [78.0, 98.1] | **70/70** | 45/45 | 1 | ~14 t/s |

~~Every model: 4/4 tasks, **zero regressions**, perfect turn 1. All three reach 70/70 — a clean
three-way tie.~~ **All three reaching 70/70 was the symptom, not the finding.** Each row is one
complete run recorded in `evals\code\results-code.jsonl` and `evals\results-tools.jsonl` with full
provenance (timestamp, script mtime, model, server args) — the provenance is intact, the *scoring*
was wrong.

**The one durable difference is verbosity.** Qwen truncated 3 turns at 16384 tokens (twice emitting
a `FRAGMENT` — code cut off mid-file, missing its entry symbol) against 1 each for Ornith and
Laguna. It still reached 70/70 because a truncated turn is scored on the last complete answer, but
in an agent loop with a token budget that is a real operational cost, not a scoring artifact.

**Zero regressions for all three.** The one apparent exception did not survive a second run: Qwen's
`shard_planner` went 14/14 → 13/14 on turn 3 in one sweep and 13/14 → **14/14** in the next, at
temperature 0 with a fixed seed. A single test flipping between identical runs is the noise floor of
this suite — which is the clearest possible demonstration that a 1-test difference means nothing
here.

**Do not read an ordering into this.** Every interval overlaps; McNemar exact on the paired cases
is p = 1.0. With n=29 tool cases and n=4 coding tasks (the effective sample is 4, not 70 — tests
cluster inside tasks) this design cannot separate them. Separating a true 95%-vs-85% pair at 80%
power needs ~100+ paired cases.

**The recommendation survives; its justification does not.** Ornith is still the default, but no
longer because "quality is tied" — that comparison is withdrawn. It stands on the half of the data
that was never in doubt: **23 GB instead of 89 GB, and 4x the tokens/sec**, both from `llama-bench`,
both re-confirmed in the 2026-08-15 sweep. What can no longer be said is that the big models buy
*nothing* in quality. That question is open, and the hard tier exists to answer it.

Every model truncated exactly once at 16384 tokens/turn, and **still truncated after a retry at
32768**. At the time this was read as verbosity. It was mostly **repetition looping at temperature
0** — see bug 10. Truncation is still worth tracking as its own column, but it was a symptom of the
sampler here, not a stable property of the models.

### What the earlier numbers in this file were, and why they were wrong

Every figure below was published, then found to be a harness artifact — each one flattering or
distorting a model. Kept here rather than deleted, because the failure modes recur and the wrong
number is the useful part:

| reported | actual | cause |
|---|---|---|
| **"70/70 for every model"** (2026-08-04, the tie above) | qwen122b raw **0/20** and **0/18**; laguna emitted **no code** on one task | temperature 0 looped models into empty answers, and the truncation rule scored each turn on the last *complete* answer — so an empty turn silently inherited the previous turn's pass count. Two bugs cancelling into a believable result |
| laguna tools 17.2% | run was 100% broken | PS re-wrapped the tools array; 500s scored as abstain PASSes |
| laguna coding "34/34 = 100%" | 2 of 4 tasks never ran | failed task contributed 0/0 and left the denominator |
| ornith coding 92.2% | 67.1% | a turn whose code fails to import reports `0/1`, not `0/20` |
| ornith 67.1% / qwen 44.3% | both ~100% | truncated turns and prose-in-`solution.py` scored as coding failures |
| "first-shot 64.3%" for all three | **100% (45/45)** | turn 1 was graded against turn-2/3 tests — it measured the test file's composition, which is why all three models returned byte-identical first-turn scores |

`token_budget` turn 3 was also **unsatisfiable**: it asked for `spend('a',80)` to succeed while the
hidden test asserts it returns False, and its stated arithmetic (`reserve_remaining()==5`) is
impossible. It rewarded ignoring the user. Fixed and verified satisfiable.

See `evals\README.md` for the full bug list and `evals\code\smoke.py`, which now gates every run and
would have caught most of these before a model was ever loaded.

#### Laguna-specific notes

**Parallel batching** (a property, not a score): Laguna 2/5, Qwen 3/5, Ornith 4/5 multi+chain cases
emit ≥2 tool calls in one response; the rest are sequenced over turns (median 2 turns). Harnesses
that assume batching will see more round-trips from Laguna.

tg climbs sharply on later turns (13.5 → 43–52 t/s) because the prompt prefix is already cached.

**Settings that are actually applied** (`scripts\windows\run-solo.ps1`):

| applied | why |
|---|---|
| `-lm none` | `--no-mmap` is DEPRECATED; `--load-mode` defaults to mmap, so the old flag silently did nothing |
| `-fa on` + `--cache-type-k/v q8_0` | halves KV; flash-attn is a prerequisite |
| `-b 2048 -ub 256` | measured pp sweet spot on gfx1151 (+29% prefill vs the 1024 this used to say) |
| `--parallel 1` | whole context to one agent; `-c` is SPLIT across slots |
| `--reasoning on` + `--reasoning-preserve` | poolside explicitly recommend thinking enabled AND reasoning preserved in history for agentic coding |
| SWA compact cache (`--swa-full` off) | `sliding_window 512` on 36 of 48 layers keeps KV cheap |
| YaRN left alone | the GGUF already carries the correct factor; overriding only hurts |
| `GGML_VK_ENABLE_MEMORY_PRIORITY=1` | WDDM trim resistance |

**`--reasoning-preserve` does nothing unless the CLIENT echoes `reasoning_content` back.** Both evals
had to be fixed to do that; setting the flag alone had been exercising nothing.

**⛔ Speculative decoding cannot be offloaded to another machine.** Worth stating because it is the
first thing people propose when they have a second box idle: llama.cpp loads the draft model
**in-process** (`--spec-type` / `--spec-draft-model`), and there is no remote-draft mode to
configure. The latency budget forbids it regardless — at 63 t/s the target verifies a token every
**15.9 ms**, and a LAN round trip plus drafting 3 tokens remotely costs more than that. Draft
locally or not at all.

**Speculative decoding: no working path for Laguna today.**
- `draft-dflash` — upstream b10182 lists it in `--spec-type` but the enum does not match poolside's
  tensor layout: `wrong number of tensors; expected 76, got 69`.
- poolside's own fork builds fine (`build-poolside.ps1`, ~2.3 min) and serves Ornith Q5 at
  60.35 t/s, but **OOMs loading Laguna at 1.5 GiB with the GPU verified free** — its older ggml
  cannot reach the 109 GiB ceiling. Fork also predates `--load-mode`, so it needs `--no-mmap`.
- `ngram-mod` measured **14.34 / 14.07 t/s vs 14.17 baseline — noise.** Left on (lossless, harmless).

Untried and the only remaining lead: `poolside/Laguna-XS-2.1-DFlash`, small enough for the fork, or
rebasing the DFlash implementation onto b10182.

### Architecture support in YOUR b9771 (verified against bin\llama.dll)
| arch | b9771 | note |
|---|---|---|
| `qwen35moe` | ✅ PRESENT | → **Qwen3.5-122B-A10B loads today** |
| `gemma4`, `minimax`, `cohere2moe`, `glm-dsa` | ✅ PRESENT | |
| `laguna` | ❌ absent | Laguna-S-2.1 — needs ≥ b10182 |
| `deepseek4` | ❌ absent | DeepSeek-V4 — needs ≥ b10034 |

**Revised upgrade verdict:** no *speed* reason (zero gfx1151 Vulkan gains since b9771), but **two
capability reasons — `laguna` and `deepseek4`.** Upgrade into a *sibling* directory and A/B; don't
overwrite `bin\`.

## ⚠️ Can you offload KV cache to another machine? No.
KV is not separable from its layer — llama.cpp's RPC backend (`bin\rpc-server.exe`, `--rpc host:port`)
splits by **layer**, carrying each layer's weights *and* KV together. And the bandwidth math forbids
it: tg reads the whole KV **every token** (13.4 GB at 224K ctx). Local LPDDR5X does ~256 GB/s;
10 GbE does ~1.25 GB/s → ~10 s/token. Moot anyway — at a 109 GB ceiling nothing in the viable model
range needs a second box.

## Deferred: BIOS items (need you at the BIOS screen; software-only was chosen 2026-07-30)

| # | item | expected gain | notes |
|---|------|---------------|-------|
| 1 | **Memory 7500 → 8532 MT/s** | **~+14% tg** (the single biggest tg lever) | ⚠️ This is **soldered LPDDR5X — there is no XMP/EXPO profile to toggle**; earlier notes calling it "RAM XMP" were misleading. The realistic path is a **BIOS update** (yours is `EVO-X2 1.05`, 2025-07-16, ~1 yr stale). Verify a newer GMKtec BIOS actually claims improved memory training before expecting the number. |
| 2 | **Raise the UMA carve-out above 96 GB** | more headroom above the measured 109 GB | Interacts with the ceiling: total = carve-out + (half of remaining Windows RAM). Going to 112/16 would give ~120 GB *if* the BIOS offers it, but leaves Windows only 16 GB — risky. `-lm none` keeps only ~1.4 GB host-resident, so it's *plausible*. Untested. |
| 3 | **iGPU TDP / power limit** | pp lever | EVO-X2 exposes a TDP setting; check thermals under sustained load. |

## What does NOT apply to us (CUDA/Linux-only)
- `GGML_CUDA_*` env vars, cuBLAS, CUDA graphs — N/A (we're Vulkan).
- `taskset` P-core pinning, `tuned-ppd`, huge pages, governor — Linux-only. (Windows equiv: High
  Performance power plan ✅, and a possible future Linux move for the ~15-20% OS-level TPS gain.)
- QAT models — would help, but none exist for our coder yet.

## Planned 235B launch (applies #3,#4,#5,#6,#7 — NOT #8: --mlock is harmful here)
```
llama-server -m Qwen3-235B-...UD-Q2_K_XL-00001-of-00002.gguf \
  -lm none -fa on \
  --fit on --fit-ctx 32768 --fit-target 1024 \
  --ctx-size 32768 --parallel 1 \
  --cache-type-k q8_0 --cache-type-v q8_0 \
  --host 0.0.0.0 --port 8081 --jinja --alias qwen235
```
(Separate port 8081 so it doesn't disturb the Pi coder on 8080.)
⚠️ No `--mlock` (it blocks VRAM upload — see #8). Use `-lm none`, not the deprecated `--no-mmap`
(`--load-mode` defaults to mmap); disable sleep first (see above).
