# llama.cpp Vulkan stack for Strix Halo (Radeon 8060S / gfx1151)

A standalone, faster-and-more-stable alternative to Ollama's ROCm path — the **Vulkan backend**
that the research recommends. OpenAI-compatible API + web UI, **~109 GB usable** (not 96 — see
OPTIMIZATION.md), MoE-friendly.

llama.cpp build: **b10182 win-vulkan-x64** (upstream ggml-org; b9771 preserved in `bin-b9771\` for
rollback). Vulkan device confirmed: AMD Radeon 8060S, driver 26.6.2, `KHR_coopmat` matrix cores,
`uma:1 fp16:1 bf16:1`.

## ⭐ Start here: what to run

**`.\run-solo.ps1`** — serves **Ornith-1.0-35B Q5_K_M** at its full 262144 context, one model with
the whole memory budget. That default is the outcome of a measured three-way comparison
(2026-08-04), not a guess:

| | tool calling | 95% CI | agentic coding | tg | size |
|---|---|---|---|---|---|
| **Ornith-1.0-35B Q5_K_M** | 28/29 = 96.6% | [82.8, 99.4] | **70/70** | **~58 t/s** | **23 GB** |
| Qwen3.5-122B-A10B Q4_K_XL | 28/29 = 96.6% | [82.8, 99.4] | **70/70** | ~34 t/s | 78 GB |
| Laguna-S-2.1 Q4_K_M | 27/29 = 93.1% | [78.0, 98.1] | **70/70** | ~14 t/s | 89 GB |

All three tie on quality — every CI overlaps, McNemar p = 1.0 — so **choose on cost**. Ornith gives
the same measured quality at a quarter of the size and 4x the speed. Reach for Qwen3.5-122B only if
you need `draft-mtp`, and Laguna only if you need >262K context.

**Do not read an ordering into those scores.** With n=29 tool cases and an effective n=4 coding
tasks, this design can catch a bad model but cannot rank models this close; a single test flipped
between two identical temperature-0 runs. Full detail and the statistics are in `evals\README.md`.

## ⚠️ Key finding — why we use standard GGUFs here, not Ollama's models
Ollama's AMD-bundle stores models as blobs in `D:\llama\blobs` that declare **Ollama-specific
architecture names** (`gptoss`, `gemma4`, `qwen3.6`) and tensor layouts. **Upstream llama.cpp
cannot load them** (`unknown model architecture` / `wrong number of tensors`). Ollama runs a
forked engine. So to use llama.cpp/Vulkan you must download **standard community GGUFs**
(ggml-org, unsloth, bartowski) — which `download-model.ps1` does.

## Folder layout
```
D:\llamacpp-vulkan\
  bin\          llama.cpp b10182 Vulkan binaries (llama-server, llama-bench, llama-cli, ...)
  bin-b9771\    previous build, kept for rollback
  models\       standard GGUF model files (+ mmproj-F16.gguf = Qwen3.6 vision projector)

  run-solo.ps1       ⭐ START HERE. One model, whole 109 GB budget, full context
  fetch-models.ps1   resume-capable downloader with byte-count verification
  bench-big.ps1      depth-aware benchmark (llama-bench -d), budget-aware guard
  bench-spec.ps1     A/B a model: baseline vs speculative (--spec-type)
  download-model.ps1 fetch a single GGUF from Hugging Face into models\
  build-poolside.ps1 build poolside's llama.cpp fork (DFlash) into bin-poolside\

  evals\             ⭐ private uncontaminated eval suites -- see evals\README.md
    run-guarded.ps1    run the suites across models, smoke-gated, respawn-proof
    run-model-suite.ps1  serve ONE model solo + run both suites
    run-tools-eval.ps1   native tool-calling eval (29 cases)
    code\run-code-eval.py  agentic coding eval (4 tasks x 3 turns, hidden pytest, Docker sandbox)
    code\smoke.py        harness self-test -- gates every run

  OPTIMIZATION.md    ⭐ tuning playbook + the measured model comparison
  BENCHMARKS.md      ⭐ what/how to benchmark, how to read it, and how not to fool yourself
  CLAUDE.md          working notes for agents on this box
  FLEET.md           roles for the other machines on the LAN
  README.md
```

Superseded launchers (`run-server.ps1`, `run-qwen36.ps1`, `run-ornith.ps1`, `keep-resident.ps1`,
`bench.ps1`) were written for the old multi-model stack on :8082-:8088. **Use `run-solo.ps1`** —
two big models cannot co-reside here, and WDDM does not trim a resident model to make room.

### Tracked vs local-only

The repo is **~0.3 MB / 51 files** — scripts, docs and harness only. Everything heavy or private is
local-only and reproducible. See **PUBLISHING.md** before pushing.

| local-only (gitignored) | why |
|---|---|
| `models/` | ~640 GB of GGUF weights — `fetch-models.ps1` re-downloads them |
| `bin*/` | vendored llama.cpp binaries |
| `evals/tools/cases.jsonl`, `evals/code/{tasks.json,tests/,reference/}` | **the private eval answers.** Publishing them destroys the suites' value — see below |
| `.remember/`, logs, `vbench_*.txt`, eval results/transcripts | working state, regenerate freely |
| `ornith-router/` | its own git repo with an internal remote |

> ⚠️ **The eval suites are deliberately unpublished.** Their whole value is that no model has
> trained on them — on decontaminated SWE-rebench, A3B-class models score ~4x below their
> self-reported SWE-bench numbers, and that gap is benchmark leakage. The **harness** here is
> public and reusable; the **cases, tasks, hidden tests and reference solutions are not**.
> `PUBLISHING.md` explains how to author your own.

## Quick start
```powershell
cd D:\llamacpp-vulkan

# 1. Serve the recommended model: whole memory budget, full 262144 context
.\run-solo.ps1
#  -> Web UI:     http://127.0.0.1:8080
#  -> OpenAI API: http://127.0.0.1:8080/v1/chat/completions   (model name = the gguf)

# A bigger model instead (one at a time -- run-solo stops any other server first)
.\run-solo.ps1 -Model .\models\Qwen3.5-122B-A10B-UD-Q4_K_XL-00001-of-00003.gguf -Ctx 131072 -Spec draft-mtp

# 2. Fetch models (resume-capable, verifies byte counts against the HF API)
.\fetch-models.ps1 -List
.\fetch-models.ps1 -Only qwen122b

# 3. Benchmark at real context depths, not just depth 0
.\bench-big.ps1

# 4. Score a model on the private eval suites (smoke-gated)
.\evals\run-guarded.ps1 -Models ornith-q5
```

**Claude Code can point straight at this server** — no shim needed. See OPTIMIZATION.md.

## Token prediction / speculative decoding (MTP) — 1.3–2.4× faster, no quality loss
Your llama.cpp b9771 supports `--spec-type`: **draft-mtp** (Multi-Token Prediction),
**draft-eagle3**, **ngram-mod** (no extra model), draft-simple.
**MEASURED on this box:** Qwopus3.6-27B-Coder-MTP went **7.3 → 16.2 t/s = 2.22×** with `draft-mtp`,
no quality loss (matches the community Strix Halo figure of ~2.44×).

```powershell
# MTP (needs an MTP-variant GGUF, e.g. Qwopus3.6-27B-Coder-MTP-Q8_0.gguf):
.\run-server.ps1 -Model .\models\Qwopus3.6-27B-Coder-MTP-Q8_0.gguf -Spec draft-mtp

# n-gram self-speculation (works on ANY model, best on code/repetitive output):
.\run-server.ps1 -Model .\models\gpt-oss-20b-mxfp4.gguf -Spec ngram-mod

# Measure the speedup (baseline vs spec):
.\bench-spec.ps1 -Model .\models\Qwopus3.6-27B-Coder-MTP-Q8_0.gguf -Spec draft-mtp
.\bench-spec.ps1 -Model .\models\gpt-oss-20b-mxfp4.gguf -Spec ngram-mod
```
- **MTP** = prediction heads baked into the model draft several tokens per forward pass; the
  main model verifies them. No separate draft model, minimal VRAM overhead. Biggest win on the
  slow **dense coder** (~9 t/s → potentially ~18–22 t/s).
- **ngram-mod** = drafts from repeated n-grams in the context. Free, great for editing code.

## Vision / image input (Qwen3.6-35B-A3B is a VL model)
Qwen3.6-35B-A3B accepts images, but llama-server needs the **vision projector (mmproj)** loaded or
it returns `image input is not supported - hint: you may need to provide the mmproj`.

```powershell
# one-time: get the projector (858 MB) from the same repo as the model
.\download-model.ps1 -Repo unsloth/Qwen3.6-35B-A3B-MTP-GGUF -File mmproj-F16.gguf

# serve MTP + vision (image input enabled), permanently resident in VRAM:
.\run-server.ps1 -Model .\models\MTP-Qwen3.6-35B-A3B-UD-Q4_K_M.gguf -Spec draft-mtp -Mmproj .\models\mmproj-F16.gguf
.\run-qwen36.ps1     # ^ same, one command, with a VRAM-residency self-check
```
- mmproj variants: `mmproj-BF16/F16/F32.gguf` — **F16** is the right default (the projector is tiny).
- Verified: build **b9771 supports the `qwen3_5_moe` vision encoder**, and **vision coexists with
  `--spec-type draft-mtp`** (MTP). The model's answer is in `content`; its chain-of-thought is in
  `reasoning_content` — a small `max_tokens` can return empty `content` while it's still thinking, so
  give it room (e.g. `max_tokens >= 256`) or disable thinking client-side.

## Keep the model permanently resident in VRAM (no offload)
The model lives in the 96 GB VRAM carve-out (`-ngl 999` + `--no-mmap`) and **stays there until the
server stops** — *as long as the machine doesn't sleep*.

- **Disable sleep (the #1 cause of "offloaded after a while").** Windows modern-standby sleeps the
  box after 10 min idle (AC) / 4 min (DC); **sleep suspends the GPU and drops all VRAM**. Fix once:
  ```powershell
  powercfg /change standby-timeout-ac 0 ; powercfg /change standby-timeout-dc 0
  powercfg /change hibernate-timeout-ac 0 ; powercfg /change hibernate-timeout-dc 0
  ```
- **`keep-resident.ps1`** — a daemon that manages **both** servers (:8080 Qwen3.6 + :8081 Ornith):
  (1) **relaunches** a server if it dies, (2) sends a tiny **keep-warm** inference every 45 s per
  idle server so WDDM never trims a model out of VRAM, and (3) logs per-port `GPU_dedicated` /
  `RAM_free` to `keep-resident.log` (warns when a model is trimmed). Run it and leave it running:
  ```powershell
  .\keep-resident.ps1                              # foreground (Ctrl+C to stop)
  Start-Process powershell -ArgumentList '-File','D:\llamacpp-vulkan\keep-resident.ps1'   # background
  ```
  Not auto-started at boot yet — register it as a **logon Scheduled Task** to survive reboots.
- **Never `--mlock`** (forces weights into the 32 GB system RAM, blocks VRAM) and **never switch to
  mmap** (pins a ~21 GB file-cache mirror in physical RAM = "RAM 100%"). See OPTIMIZATION.md.

## Use it from Open WebUI / any OpenAI client
Point the client's base URL at `http://127.0.0.1:8080/v1` (no API key needed). Works as a
drop-in OpenAI backend. For multiple models / hot-swap, run one server per model on different
ports, or use `llama-swap` as a router.

## Strix Halo tuning baked into run-server.ps1 (MEASURED 2026-06-29)
- `-ngl 999` — all layers on the GPU (you have 96 GB; use it).
- `-fa on` — flash attention (faster + smaller KV; a real win on gfx1151/WMMA).
- `--batch-size 2048 --ubatch-size 1024` — pp sweet spot (pp8192 **921 t/s** @ub1024 vs 817 @512,
  744 @2048; the old `-b 256` cost ~10–13% prompt-processing). **tg is bandwidth-bound — batch
  doesn't change it** (~68 t/s); the tg lever is RAM XMP (7500→8533 MT/s, BIOS).
- `--cache-type-k/v q8_0` — half-size KV (memory, not speed); keeps 128K context + two models in VRAM.
- Sampling (quality): `--temp 0.6 --top-p 0.95 --top-k 20 --min-p 0` for Qwen3.x — **never greedy**.
- `--jinja` — uses each model's real chat template.

### Speculative decoding: use the native MTP head, skip generic drafts (MEASURED)
- **Qwen3.6 + `--spec-type draft-mtp`: +35%** (67.9 vs 50.2 t/s) — the trained MTP head drafts well. KEEP.
- **Ornith + `ngram-mod`: ≈ neutral on code** (59.4 vs 57.6); generic draft/ngram is net-negative on
  general MoE text. So: draft-mtp when the GGUF has the head, ngram-mod for code only, no separate draft model.

### Thinking mode = the fast↔quality dial
These MoEs reason at length by default (~2500 tokens before the answer). Quality is excellent, but a
client using a small `max_tokens` gets **empty `content`** (it's all in `reasoning_content`). For full
answers use `max_tokens ≥ ~2500`; for fast direct answers send `/no_think` (works on Qwen3.6; Ornith
ignores it — give Ornith the budget instead).

## Benchmarked on THIS box — Vulkan tg (token-gen), fa=on
| Model | Arch | tg t/s | pp512 t/s | notes |
|---|---|---|---|---|
| gpt-oss-20b MXFP4 | MoE | **71.7** | 1629 | vs Ollama ROCm 40.2 → **1.79×** |
| Qwen3.6-35B-A3B Q4 | MoE | **56.4** | 1064 | vs Ollama ROCm ~50 |
| **Ornith-1.0-35B Q4_K_M** | MoE | **67.4** | 964 | DeepReinforce coding model (`qwen35moe`); 2nd server on :8081, MEASURED 2026-06-29 |
| gemma-4-26B-A4B Q4 | MoE | **49.2** | 1259 | your gemma4, fast |
| Qwopus3.6-27B-Coder-MTP Q8 | dense | **7.3 → 16.2 (MTP)** | 217 | coding; **MTP 2.22× MEASURED** |
| Qwen3.6-35B-A3B-Uncensored Q6 | MoE | **55.3** | 888 | uncensored, fast |
| gemma-4-26B-A4B-uncensored Q6 | MoE | **48.9** | 989 | uncensored gemma4 |
| Qwen3-235B-A22B UD-Q2_K_XL | MoE 22B-act | **17.3** | 136 | frontier reasoning; 82.7GB fits 96GB, no offload |

(Reminder: Ollama's own AMD-bundle blobs for qwen3.6/gemma4/gpt-oss DON'T load in stock llama.cpp —
custom arch names. These are standard community GGUFs, which load fine and run ~1.8× faster than ROCm.)

## Recommended models — MEASURED, not predicted (2026-08-04)

Fetch with `.\fetch-models.ps1 -Only <key>`. 2026-era models only; gpt-oss and the other 2025
entries were deliberately dropped from the registry.

| key | Model | size | Why |
|---|---|---|---|
| ⭐ `ornith-q5` | **Ornith-1.0-35B Q5_K_M** | **23 GB** | **The default.** Ties the two big models on both eval suites at ~58 t/s. 262K ctx, MIT |
| `qwen122b` | Qwen3.5-122B-A10B UD-Q4_K_XL | 78 GB | Ties on quality, ~34 t/s. Honest 4-bit, MTP head → `--spec-type draft-mtp` |
| `laguna` | Laguna-S-2.1 Q4_K_M | 89 GB | Ties on quality, ~14 t/s. Only reason to pick it is >262K context |
| `deepseek-v4-flash` | DeepSeek-V4-Flash UD-IQ2_M | 85 GB | ~2-bit of a 284B, A13B active. **Never benched** — the one untested model here |

**bf16 is a trap on this box.** Ornith bf16 (64.61 GB) measures **11.17 t/s — 5.6x slower than
Q5_K_M**, and prompt processing collapses too (241 vs 698). Bigger Ornith means a bigger *quant*,
not a better model; Q5_K_M is the sweet spot.

### Ornith-1.0-35B — DeepReinforce agentic coding model (the default in `run-solo.ps1`)
Open-source coding MoE by DeepReinforce AI (Jun 2026): 35B total / ~3B active, self-scaffolding RL,
**262K context**, MIT. Same `qwen3_5_moe` arch as Qwen3.6-35B-A3B, so it runs identically here.

> ⚠️ **CORRECTED 2026-07-30 — the benchmark claims previously in this section were wrong.**
> - **"Beats Qwen3.5-397B on Terminal-Bench 2.1 (64.4 vs 53.5)" is NOT what the model card says.**
>   The card claims Ornith *matches* Qwen3.5-397B on **SWE-bench Multilingual** (69.3) — a different
>   benchmark, and "matches", not "beats". No Ornith-vs-397B TB2.1 comparison is published anywhere.
> - **TB2.1 is 64.2** (Terminus-2 harness) or **62.8** (Claude Code harness), not 64.4.
> - **Every Ornith number is SELF-REPORTED.** Ornith-1.0-35B is absent from tbench.ai, SWE-rebench,
>   and Artificial Analysis entirely. There is no third-party replication.
>
> ✅ **RESOLVED 2026-08-04 by measurement.** Rather than trust any of the published numbers, Ornith
> was scored against Laguna-S-2.1 and Qwen3.5-122B-A10B on two private uncontaminated suites here:
> **it ties both** (tool calling 28/29, agentic coding 70/70) while being 3-4x smaller and 2-4x
> faster. The published deltas in either direction did not show up. See BENCHMARKS.md.
> - **Calibration that matters more than any of the above:** on **SWE-rebench** (decontaminated, fresh
>   tasks) **Qwen3.5-35B-A3B scores 17.1%** against the **70% SWE-bench Verified its family claims** —
>   a ~4x collapse. Fresh uncontaminated tasks gut A3B-class self-reported scores. Ornith's claimed
>   75.6% SWE-bench Verified should be read in that light.
>
> Ornith remains a good practical choice here — it is fast (measured 63 t/s), MIT, 262K ctx, and
> scored 97.1% on our own router benchmark. That measured local evidence is worth more than its
> published numbers. Just don't treat "Ornith-tier" as a verified quality bar. Runs as a **second VRAM-resident server on :8081** next to the
Qwen3.6 driver on :8080 (both fit in the 96 GB carve-out).
```powershell
.\download-model.ps1 -Repo deepreinforce-ai/Ornith-1.0-35B-GGUF -File ornith-1.0-35b-Q4_K_M.gguf
# vision projector (image input) — the official body is text-only, so use bartowski's matching mmproj:
.\download-model.ps1 -Repo bartowski/deepreinforce-ai_Ornith-1.0-35B-GGUF -File mmproj-deepreinforce-ai_Ornith-1.0-35B-f16.gguf
.\run-ornith.ps1                         # serve on :8081, ngram-mod + VISION, fully in VRAM
.\bench.ps1 -Model .\models\ornith-1.0-35b-Q4_K_M.gguf
```
- **Image input is enabled by default**: `run-ornith.ps1` pairs the official Q4_K_M body with
  bartowski's `mmproj-deepreinforce-ai_Ornith-1.0-35B-f16.gguf` (the mmproj is the vision tower of
  the same base model, so it works across quant repos — verified). Pass `-Mmproj ''` to disable.
- Speculative decoding: `ngram-mod` (free, great on code) is the default; MTP-head GGUF variants
  exist (e.g. `dan9070/..._APEX-MTP-GGUF`) if you want `draft-mtp`.

## Vulkan vs Ollama-ROCm (MEASURED on this box, 2026-06-23) 🚀
Same model **gpt-oss-20b (MXFP4)**, same hardware, flash-attention on both:

| Engine | token-gen (tg) | prompt-proc (pp512) |
|---|---|---|
| **llama.cpp Vulkan (b9771)** | **71.7 t/s** | 1629 t/s |
| Ollama ROCm (0.30.10) | 40.2 t/s | — |
| **Vulkan advantage** | **+79% (1.79×)** | — |

→ Vulkan is **~1.8× faster than _Ollama's_ ROCm** on the same weights. **Nuance (community primary
data, 2026):** against **llama.cpp's own ROCm**, Vulkan leads only **~1.2× at short context**, and
**ROCm *wins* token-gen at long context (8K+) and prompt-processing**. So the headline win is mostly
*Ollama-ROCm being slow*, not Vulkan beating ROCm everywhere. Vulkan/RADV stays the best short-context
tg default here; **Windows-vs-Linux Vulkan parity is unverified** (community leans Linux).
> ⚠️ **TODO (production):** re-test `llama.cpp`-ROCm vs Vulkan at **128K context** on the coder — the
> Pi workload is long-context, exactly the regime where ROCm may overtake Vulkan. Don't treat
> "Vulkan = always" as settled until measured at 128K.

## Troubleshooting (measured on this box)
| Symptom | Cause | Fix |
|---|---|---|
| **Model offloaded from VRAM "after a while"** | Windows **slept** (10 min idle AC / 4 min DC) → GPU suspended → VRAM dropped | `powercfg /change standby-timeout-ac 0` (+`-dc 0`, hibernate 0). Run `keep-resident.ps1`. |
| **RAM at ~100%** | Running with **mmap** (pins ~21 GB file-cache mirror in physical RAM) | Use **`--no-mmap`** (the default). Don't pass `-Mmap`. |
| **Model in system RAM, GPU ~0, slow** | **`--mlock`** pinned weights in the 32 GB RAM partition, blocking VRAM upload | **Never use `--mlock`** here. |
| **`image input is not supported`** | VL model loaded without its vision projector | Add `-Mmproj .\models\mmproj-F16.gguf`. |
| **Empty `content` in chat reply** | Qwen3.6 thinking mode used the whole token budget | Raise `max_tokens` (≥256) or read `reasoning_content`; disable thinking client-side. |
| **Server won't restart** | A request is in flight (Pi-idle rule) | Wait for idle, or `run-qwen36.ps1 -Force`. |
| Check residency anytime | — | `Get-Counter '\GPU Process Memory(*)\Dedicated Usage'` (~25 GB = resident) or tail `keep-resident.log`. |

## Other stacks considered
- **vLLM / SGLang**: ROCm-only, Linux-only, shaky gfx1151 support — not viable on Windows.
- **WSL2**: weak GPU passthrough (D3D12→Vulkan translation, immature ROCm) — slower than native
  Windows Vulkan; skip. For vLLM, dual-boot native Linux instead.
- **LM Studio / koboldcpp**: same llama.cpp engine with a GUI — equivalent speed to this.
