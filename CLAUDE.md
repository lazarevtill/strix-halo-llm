# CLAUDE.md — llama.cpp Vulkan stack (Strix Halo)

Production local-inference stack for **AMD Ryzen AI MAX+ 395 "Strix Halo" / Radeon 8060S (gfx1151)**,
128 GB unified LPDDR5X, **96 GB carved out as VRAM**. This is the realized, day-to-day server —
the `..\Documents\ollama-strixhalo-bench\` folder is the research that led here.

## What this is
llama.cpp **Vulkan** backend (build **b10338** as of 2026-08-10, win-vulkan-x64) serving an OpenAI-compatible API +
web UI on `:8080`. Vulkan was chosen after measuring **1.79× faster token-gen than _Ollama's_ ROCm**
(gpt-oss-20b: 71.7 vs 40.2 t/s). **Nuance (2026 community data):** vs **llama.cpp's own ROCm** it's
only ~1.2× short-context, and **ROCm wins at long context (8K+) and prompt-processing** — re-test at
128K for the coder before assuming "Vulkan always." Windows≈Linux Vulkan parity is unverified.

## Layout
```
bin\                llama-server, llama-bench, llama-cli, ... (Vulkan binaries)
models\             standard community GGUFs (ggml-org / unsloth / bartowski)
                    incl. mmproj-F16.gguf (vision projector for Qwen3.6-35B-A3B)
run-server.ps1      start the OpenAI server + web UI (Strix-tuned defaults; -Spec, -Mmproj, -NoKvQuant)
run-qwen36.ps1      one-command launcher: MTP Qwen3.6 + vision + q8_0 KV, asserts VRAM residency
run-ornith.ps1      launcher: Ornith-1.0-35B coding model as a 2nd VRAM-resident server on :8081
keep-resident.ps1   daemon: watchdog (restart on death) + keep-warm (no VRAM trim), run until stop
bench.ps1           measure pp/tg t/s for a model
bench-spec.ps1      A/B a model baseline vs speculative (--spec-type)
download-model.ps1  fetch a GGUF from Hugging Face into models\
README.md           full reference (quick start, MTP, vision, bench table, troubleshooting)
docs/OPTIMIZATION.md     tuning playbook (RAM XMP, sleep, --fit, mmap/mlock, expert offload)
vbench_*.txt        raw llama-bench outputs per model (source of the README table)
*-proof.txt         MTP / speculative speedup evidence
```

## Run / bench
```powershell
cd D:\llamacpp-vulkan
.\run-server.ps1                                          # serve default model on :8080
.\run-server.ps1 -Model .\models\<file>.gguf             # serve a specific model
.\run-server.ps1 -Model .\models\<mtp>.gguf -Spec draft-mtp   # speculative (MTP head)
# MTP Qwen3.6-35B-A3B WITH vision (image input) — the production daily driver:
.\run-server.ps1 -Model .\models\MTP-Qwen3.6-35B-A3B-UD-Q4_K_M.gguf -Spec draft-mtp -Mmproj .\models\mmproj-F16.gguf
.\run-qwen36.ps1                                          # ^ same thing in one command, asserts VRAM residency
.\keep-resident.ps1                                       # keep it loaded+resident+alive forever (until stop)
.\bench.ps1 -Model .\models\<file>.gguf                  # tg/pp throughput
.\bench-spec.ps1 -Model .\models\<mtp>.gguf -Spec draft-mtp   # baseline vs spec speedup
```
API base URL for clients (Pi, Open WebUI, any OpenAI SDK): `http://127.0.0.1:8080/v1` (no key).
Reachable on LAN at `<lan-ip>:8080` and over NetBird at `<inference-host>:8080` (firewall
already allows the llama-server binary inbound on any port; covers the `<netbird-cidr>` overlay).
**Vision:** Qwen3.6-35B-A3B is a VL model — image input needs `-Mmproj .\models\mmproj-F16.gguf`,
else the API returns *"image input is not supported"*. (Its answers go to `content`; chain-of-thought
goes to `reasoning_content` — a small `max_tokens` can return empty `content` while it's still thinking.)

## Hard-won facts (don't re-derive)
- **Ollama's AMD-bundle blobs do NOT load in stock llama.cpp** — they declare custom arch names
  (`gptoss`, `gemma4`, `qwen3.6`). Always use standard community GGUFs (`download-model.ps1`).
- **The "32 GB Windows ROCm VRAM cap" does NOT apply to this UMA box** — empirically refuted.
  The real ceiling was **commit charge**, fixed by a **160 GB pagefile** (commit limit ~192 GB).
  Rule of thumb: ~1.1 GB commit per GB of VRAM weights.
- **⭐ The usable memory ceiling is ~109 GB, NOT the 96 GB carve-out (MEASURED 2026-07-30).**
  Vulkan sees `114507 MiB` = 96 GB dedicated + ~15.8 GB WDDM shared (half the 32 GB Windows
  partition). Spilling past 96 GB into shared **costs zero tg** — same physical LPDDR5X. Measured on
  235B Q2_K_XL: 99.3 GB→16.71 t/s, 105.6 GB→17.04, **109.0 GB→16.77**, 113 GB→OOM. So ~26 GB more
  headroom than the docs assumed — enough to run a **Q3-class 235B (~104 GB) instead of Q2_K_XL**.
  Past ~105 GB the binding constraint is **RAM free** (9.7 GB at the 109 GB point), not VRAM.
  Full table + caveats in docs/OPTIMIZATION.md.
- **`--fit on` / `llama-fit-params` are useless on this box.** `-ngl 999` aborts the fit
  (`n_gpu_layers already set by user to 999, abort`), and llama.cpp's reported free VRAM is a
  **constant** (`108782 MiB` whether 0 or 42 GB is in use), so the fit sizes against a fiction.
  Size manually from the measured ceiling table.
- **`ErrorOutOfDeviceMemory` usually means a stale process still holds VRAM**, not "too big" —
  3 configs "failed" then passed on a clean baseline. Check `\GPU Adapter Memory(...)\dedicated usage`
  is <2 GB first. **Elevated** llama-servers can't be killed from a non-elevated shell (Access denied).
- **Prefer MoE over dense.** Token-gen is memory-bandwidth-bound; dense ≥30B is slow (~7–9 t/s),
  MoE of similar size is 50–90 t/s because only a few experts are active.
- **Speculative decoding — model-dependent, not blanket "free" (MEASURED 2026-06-29):**
  - **Native MTP head (`--spec-type draft-mtp`) is a BIG win on the MoEs**: Qwen3.6-35B-A3B
    **67.9 vs 50.2 t/s = +35%** (production draft acceptance ~0.78). Keep it on (needs an MTP-head GGUF).
  - **Generic `ngram-mod` ≈ neutral on code** (Ornith 59.4 vs 57.6 = noise); community data shows
    generic draft/ngram **net-negative (−3 to −12%) on general MoE text**. Use only for code.
  - Dense coder still **2.22×** with draft-mtp (7.3 → 16.2) — different regime. Rule: draft-mtp = yes;
    separate draft model = no on these MoEs; ngram-mod = code-only.
- **Batch: `-b 2048 -ub 1024`** (MEASURED) — pp sweet spot (pp8192 921 t/s @ub1024 vs 817 @512, 744 @2048),
  ~+10-13% prompt-processing vs the old `-b 256`. **tg is bandwidth-bound — batch doesn't change it**
  (~68 t/s); the tg lever is RAM XMP (7500→8533). Now the run-server.ps1 default.
- **Sampling for quality (Qwen3.x): `--temp 0.6 --top-p 0.95 --top-k 20 --min-p 0`, NEVER greedy**
  (greedy → endless repetition). Set server-side in the launchers; gpt-oss needs neutral sampling instead.
- **Thinking mode = the fast↔quality lever.** These MoEs reason at length by default (~2500 reasoning
  tokens before the answer → answer in `reasoning_content`/`content` split). Best quality but needs
  `max_tokens ≥ ~2500`, else `content` comes back empty. `/no_think` gives fast direct answers on
  Qwen3.6 (8080) but is IGNORED by Ornith (8081) — Ornith needs the budget (or enable_thinking=false kwarg).
- **Flash attention (`-fa on`) + KV `q8_0`** are default-on wins (smaller KV, equal quality).
  run-server.ps1 now adds `--cache-type-k/v q8_0` by default (`-NoKvQuant` to disable).
- Memory was found running at **7500 MT/s vs rated 8533** — user-side BIOS/XMP fix pending (~+14%).
- **Sleep = the real cause of "model offloaded from VRAM after a while"** (2026-06-27). Windows
  modern-standby slept the box after **10 min idle (AC) / 4 min (DC)**, which suspends the GPU and
  **drops all VRAM**. Fixed at OS level: `powercfg /change standby-timeout-ac 0` (+`-dc 0`, hibernate 0).
  Idle alone (≤5 min) does NOT evict — verified. Keep sleep disabled.
- **NEVER use `--mlock` on this Vulkan/UMA box.** It pins weights in the ~32 GB system-RAM partition
  and BLOCKS the Vulkan upload to the 96 GB carve-out → `-ngl 999` silently runs from host RAM
  (GPU dedicated ~0.1 GB, RAM ~1 GB free, slow). Measured 2026-06-26.
- **Keep `--no-mmap` (the default); do NOT switch to mmap.** Measured: `--no-mmap` keeps only
  ~1.4 GB physically resident (weights in VRAM, host copy paged out) → RAM ~24 GB free; **mmap pins
  a ~21 GB file-cache mirror in physical RAM → RAM free crashes to ~3.7 GB ("RAM 100%")**. Watch
  *physical RAM / WorkingSet*, not committed bytes (committed is ~27 GB either way but mostly paged).
- **`draft-mtp` + vision (`--mmproj`) coexist fine**, and build b9771 supports the `qwen3_5_moe`
  vision encoder. Measured: MTP Qwen3.6-35B-A3B with q8_0 KV ran ~60–75 t/s and read images correctly.

## Measured throughput (Vulkan, fa=on) — keep README table as source of truth
gpt-oss-20b MoE **71.7** · Qwen3.6-35B-A3B MoE **56.4** · **Ornith-1.0-35B Q4_K_M MoE 67.4 (pp 964)** ·
gemma-4-26B-A4B MoE **49.2** · dense coder 27B **7.3→16.2 (MTP)** ·
**Qwen3-235B-A22B Q2_K_XL 17.3** (82.7 GB; re-measured 2026-07-30: **16.7–17.0 t/s flat at
32K–224K ctx**, up to 109 GB total — no offload, no shared-memory penalty).

## SOLO MODE is the current setup (2026-07-30) — `scripts/windows/run-solo.ps1`
User chose **one model at a time**. `scripts/windows/run-solo.ps1` serves a single model with the whole ~109 GB
budget: solo-occupancy enforcement, `--parallel 1`, max context, `GGML_VK_ENABLE_MEMORY_PRIORITY=1`.
**VERIFIED RUNNING:** Ornith-1.0-35B Q5_K_M at **262144 ctx** (8× the old 32768), 29.94 GB total
GPU, **63.3 t/s** (empty-cache solo verification, 2026-07-30; expect **~58 t/s** under eval load at
depth — see docs/BENCHMARKS.md), RAM free 22.3 GB. Two big models genuinely cannot co-reside (Ornith 24 GB + 235B
83 GB = ~107 GB of weights → the newcomer OOMs; WDDM does NOT trim the incumbent to make room).
⚠️ **"Next quality step = a bigger quant/model" was TESTED AND DISPROVED (2026-08-04).** Do not
re-suggest it:
- **bf16 is 5.6x SLOWER, not better** — measured 11.17 t/s vs Q5_K_M's ~58, and pp collapses too
  (241 vs 698). A bigger Ornith is a bigger *quant*, not a better model.
- **Laguna-S-2.1 and Qwen3.5-122B TIE Ornith Q5_K_M** on two private uncontaminated suites (tool
  calling 27-28/29 for all three, all CIs overlapping, McNemar p=1.0; agentic coding 70/70 for all
  three) — at 3.9x/3.4x the size and 4x/2x the wall-clock. Their published benchmark leads did not
  reproduce.
- Reach for a bigger model only for a **capability**: `draft-mtp` (Qwen) or >262K ctx (Laguna).

Read **docs/BENCHMARKS.md before quoting any eval number** — five harness bugs produced five believable
wrong figures on 2026-08-03/04, and `evals\code\smoke.py` now gates every run. The multi-model
section below is retained for reference only.

## ⚠️ The old bench stack on :8082–:8088 is RETIRED (2026-08-04)
An elevated PowerShell left running since 2026-07-31 was restoring those servers within ~2 minutes
of any being killed, stealing ~42 GiB, pushing the box past its ceiling (requests 500) and twice
killing a live model server mid-eval. It was killed; no respawn in the 7-minute watch after. If
foreign `llama-server` processes reappear, check for another such shell before anything else, and
note `evals\run-guarded.ps1` defends itself by **holding :8082/:8088** — llama-server binds its port
before loading weights, so a respawn dies in 0.6s having allocated nothing.

## Two-model serving (both fully in VRAM, both vision-enabled) — SUPERSEDED by solo mode
`:8080` MTP Qwen3.6-35B-A3B (vision) + `:8081` Ornith-1.0-35B (coding, vision) run **simultaneously** —
measured 25.0 GB + ~23 GB = ~48 GB of the 96 GB carve-out, RAM ~18 GB free. `keep-resident.ps1`
keeps BOTH warm/alive. **Ornith vision:** official GGUF body is text-only, so image input uses
bartowski's `mmproj-deepreinforce-ai_Ornith-1.0-35B-f16.gguf` — the mmproj pairs across quant repos
since it's the same base model (verified). **Gotcha:** loading/benching a 3rd big GPU process (or one
model loading) transiently trims an idle model to ~0.1 GB (WDDM pressure); it pages back on the next
request/keep-warm (~6 s ramp).

## Operational caution
Only restart `llama-server` when **Pi is idle (0 active slots)** — a mid-task restart kills its
in-flight request (`run-qwen36.ps1` enforces this; `-Force` overrides). Context is set to 128K/slot.
Don't let `pip`/installers overwrite a ROCm torch elsewhere on this machine with CPU torch
(separate gotcha, see user memory).

**Keeping them resident "forever":** `keep-resident.ps1` is a daemon that manages BOTH servers
(:8080 Qwen3.6 + :8081 Ornith) = watchdog (relaunch on death) + keep-warm (tiny inference every
45 s per idle server so WDDM never trims VRAM) + residency log (`keep-resident.log`, flags when a
model is trimmed). It does NOT survive a reboot yet — register it as a logon Scheduled Task for
that. Sleep is disabled (see hard-won facts) so the GPU isn't suspended. To stop: stop the daemon
process, then `Stop-Process` the :8080 / :8081 owners.
