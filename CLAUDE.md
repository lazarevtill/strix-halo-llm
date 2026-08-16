# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

Tuning + benchmarking stack for local LLM inference on **AMD Ryzen AI MAX+ 395 "Strix Halo" /
Radeon 8060S (gfx1151)**, 128 GB unified LPDDR5X with **96 GB carved out as VRAM**. llama.cpp
**Vulkan** backend (build **b10431** — every published number is from it), serving an
OpenAI-compatible API on `:8080`. **This is a public repo** (MIT, GitHub Pages at
strix.lazarev.cloud); read `docs/PUBLISHING.md` before adding files or relaxing `.gitignore`.

## Two things to know before touching anything

**1. This checkout is not where the code runs.** The scripts are PowerShell/bash for the Windows
Strix Halo box; `bin/`, `models/`, `evals/results/`, and eval cases are all gitignored, so a Linux
checkout has *none* of them. You can edit and read here, but you cannot run a benchmark or an eval
here — a change is unverified until it runs on the box. Say so rather than claiming it works.

**2. The private eval content must never be committed.** `evals/tools/cases.jsonl`,
`evals/code/tasks.json`, `evals/code/tests/`, `evals/code/reference/` are gitignored on purpose:
the suites are trustworthy *because* they are unpublished (decontaminated SWE-rebench scores
A3B-class models ~4× below their self-reported SWE-bench figures — that gap is leakage). The
harness is public; the answers are not. Publishing them is irreversible and retroactively
invalidates every number in the repo.

## Layout

```
scripts/windows/    PowerShell 5.1 — supported; every number came from here
  run-solo.ps1        ⭐ serve ONE model with the whole ~109 GB budget (-DryRun prints the cmdline)
  fetch-llamacpp.ps1  step zero: prebuilt Vulkan release -> bin\
  fetch-models.ps1    resume-capable GGUF downloader, byte-verifies against the HF API
  bench-big.ps1       depth-aware llama-bench sweep (never trust depth 0)
  bench-spec.ps1      A/B baseline vs --spec-type
  bench-qwen38*.ps1   the sweeps behind docs/RESULTS.md (opt / ubatch / kquant / followup)
  legacy/             the superseded multi-model stack (run-server, run-qwen36, keep-resident)
scripts/linux|macos/  bash DRAFTS — syntax-checked, never run on their own platform
evals/              ⭐ the harness (see "Evals" below) — where most active work happens
docs/               INSTALL · EXPLAIN · RESULTS · GOING-FASTER · OPTIMIZATION · BENCHMARKS ·
                    FLEET · MULTI-USER · PUBLISHING · index.html (the Pages report)
archive/coding-eval/  superseded first-gen eval, kept for history
```

Path conventions differ by tree and this bites: `scripts/windows/*` resolve the repo root by
climbing out of `$PSScriptRoot` (windows/ climbs 2, windows/legacy/ climbs 3 — fix the chain if you
move a file), but **`evals/*.ps1` hardcode `D:\llamacpp-vulkan\...` and `C:\llm-router\models\...`**.
Don't assume either style; check the file.

## Serve

```powershell
.\scripts\windows\fetch-llamacpp.ps1 -Build b10431     # engine into bin\, nothing to compile
.\scripts\windows\fetch-models.ps1 -Only qwen38        # -List to see the registry
.\scripts\windows\run-solo.ps1                         # -> :8080, /v1 OpenAI API + web UI
.\scripts\windows\run-solo.ps1 -Model .\models\X.gguf -Ctx 131072 -Spec draft-mtp
.\scripts\windows\run-solo.ps1 -DryRun                 # print the llama-server invocation only
```

**No launcher has a default model.** With no `-Model` / `-m` they list the GGUFs they can see and
ask (taking the only one if there is just one). They look in `<repo>/models` unless `MODELS_DIR`
says otherwise — **this box needs it set**, since its weights are on `C:\llm-router\models` and
`D:\llamacpp-vulkan\models`, not in the checkout. The previous hardcoded defaults pointed at those
same paths, which is why every other clone died on startup.

`run-solo.ps1` enforces **solo occupancy** (stops any other llama-server, waits for the GPU to
drain), `--parallel 1`, max context, `-lm none`, `GGML_VK_ENABLE_MEMORY_PRIORITY=1`. Two big models
genuinely cannot co-reside — WDDM does not trim the incumbent, the newcomer just OOMs.

## Evals

Two private suites: **tool-calling** (29 cases, `run-tools-eval.ps1`) and **agentic coding**
(easy tier 4 tasks/70 tests, hard tier 3 tasks/89 tests, every turn scored, `code/run-code-eval.py`).

```powershell
docker build -f evals\code\Dockerfile.sandbox -t llm-eval-sandbox evals\code
python evals\code\smoke.py                  # ⭐ harness self-test, ~30s, no GPU — run this first
python evals\test-rescore.py                # unit test for the turn-selection rule, no GPU
.\evals\run-guarded.ps1 -Models ornith-q5   # smoke-gated; holds :8082/:8088; one model at a time
.\evals\run-guarded.ps1 -Models qwen122b -Tasks hard_semver -SkipTools   # a single task
.\evals\run-full-bench.ps1 -Phase hard -Only qwen38   # the 18-24h stack: speed -> hard -> easy
python evals\summarize-bench.py             # a completed run -> the published table
python evals\rescore.py --tier hard         # re-derive scores from stored runs; no GPU, no Docker
```

`run-guarded.ps1` refuses to start if `smoke.py` fails, and `run-model-suite.ps1` refuses to start
if anything else holds GPU memory. Both guards exist because every harness bug so far produced a
*believable wrong number*, never a crash.

**Read `docs/BENCHMARKS.md` and `evals/README.md` before quoting any eval number.** Thirteen harness
bugs are written up there with the fake number each produced (`17.2%`, `34/34 = 100%`, `92.2%`,
`70/70` for four models at once). Current rules that came out of them:

- **Quality scores are withdrawn and being re-measured.** The four-way tie came from temperature 0
  sending thinking models into repetition loops plus a truncation rule that rescued the empty turns.
  Do not quote the tie — and do not conclude the opposite either; relative quality is *unmeasured*.
  Speed and size numbers never depended on the sampler and still stand.
- **Never quote one score alone.** Every task reports `strict` / `rescued` / `best`; the gap between
  them is the finding. Effective n is the **task** count, not the test count.
- Tiers are reported separately — a combined percentage is dominated by the tier that separates
  nothing.
- Sampling is `temp 0.3`, seed recorded per row. Bug 13 is open: temp 0.3 still loops on some
  turn 1s, and a turn-1 loop zeroes the whole multi-turn task.

## Hard-won facts (don't re-derive)

- **The usable ceiling is ~109 GB, not the 96 GB carve-out** — 96 GB dedicated + ~13.4 GB WDDM
  shared heap. tg is *flat* from 89 GB to 109 GB; spilling past the carve-out costs nothing on a UMA
  APU. 113 GB OOMs, and past ~105 GB the binding constraint is free system RAM, not VRAM.
- **Measure with `\GPU Process Memory(*)\Total Committed`, never `Dedicated Usage`.** WDDM trims an
  idle model's dedicated bytes to ~0 while it still holds the reservation — that counter
  under-reported two resident servers by 42.5 GB, which is how the box blew past its ceiling with
  the console showing plenty of room.
- **`-b 2048 -ub 256`**, not 1024. `-ub` is the most architecture-specific flag here: 256 is +29%
  prefill over 1024 on gfx1151 because a 256-row tile fits its 32 KB of shared memory. 128 measured
  0.9% higher on one run — the curve is flat below 256, so 256 is the knee. **Sweep it on other
  hardware, don't copy it.** Every serving and eval path now defaults to 256; the one deliberate
  holdout is `evals/rerun-sampler.ps1`, which pins 1024 to match the run it is a control for
  (changing prefill timing in the same run that changes the sampler would make both meaningless).
  Anything measured before 2026-08-16 paid the 29% — its `medMs` is not comparable with a 256 run.
- **Speculative decoding is model-dependent, and depth is not monotonic.** `draft-mtp` at
  `--spec-draft-n-max 3` is the peak (Qwen3.8-27B: 11.33 → 20.27 t/s, 1.79×); n=5 collapses to
  **0.68× — worse than no speculation at all**. Generic `ngram-mod` is neutral-to-negative; a
  separate draft model loses on these MoEs.
- **`--mlock`: never on this box.** It pins weights in the ~32 GB system-RAM partition and blocks
  the Vulkan upload, so `-ngl 999` silently runs from host RAM. Related: b10182 deprecated
  `--no-mmap`/`--mlock` in favour of `--load-mode`, **which defaults to mmap** — use `-lm none`.
  mmap pins a ~21 GB host file-cache mirror in physical RAM ("RAM 100%"); watch WorkingSet, not
  committed bytes.
- **Bigger is not better.** bf16 is **5.6× slower** than Q5_K_M (11.17 vs ~58 t/s) and pp collapses
  too (241 vs 698). A bigger Ornith is a bigger *quant*, not a better model. Prefer MoE over dense:
  tg is bandwidth-bound on *active* params, so A3B@35B beats A13B@120B here.
- **`--fit on` / `llama-fit-params` are useless here** — `-ngl 999` aborts the fit, and llama.cpp's
  reported free VRAM is a constant regardless of actual use, so it sizes against a fiction.
  **`--cache-reuse` is a silent no-op** on these MoEs (needs KV shifting); plain prefix caching
  already avoids re-prefill on append-only conversations.
- **`ErrorOutOfDeviceMemory` usually means a stale process still holds VRAM**, not "too big". Check
  dedicated usage is <2 GB first. **Elevated llama-servers cannot be killed from a non-elevated
  shell.** llama-server binds its port *before* loading weights, which is why the eval scripts
  defend themselves by holding :8082/:8088 — a respawn dies in 0.6 s having allocated nothing.
- **Sleep drops all VRAM.** Windows modern standby suspends the GPU (10 min AC / 4 min DC). Fixed at
  OS level with `powercfg /change standby-timeout-ac 0`; keep it disabled. Idle alone does not evict.
- **Sampling: `--temp 0.6 --top-p 0.95 --top-k 20 --min-p 0` for Qwen3.x, never greedy** (greedy →
  endless repetition; Qwen ships the warning on its own model cards). gpt-oss wants neutral sampling.
- `-fa on` + KV `q8_0` are default-on wins (half the KV, equal quality). `draft-mtp` and `--mmproj`
  vision coexist fine. Ollama's AMD-bundle blobs do **not** load in stock llama.cpp (custom arch
  names) — always use standard community GGUFs.
- Memory runs at **7500 MT/s vs rated 8533**; a BIOS/XMP fix is pending (~+14% on tg, which is the
  only lever that moves tg — batch size does not).

## Conventions

- **PowerShell 5.1 only** — no `&&`, no ternary, no `??`. Deliberate: 5.1 ships with Windows.
  Gotchas that have cost real time: `ConvertTo-Json` re-wrapping a collection as
  `{"value":[...],"Count":n}`, `Add-Content -Encoding UTF8` emitting a BOM, PowerShell 5.1
  `Tee-Object` writing UTF-16LE (decode by BOM, not by assumption), `[math]::Min(1, 0.98)` binding
  the integer overload and rounding to 1, splatting an **array** binding positionally, and
  `powershell.exe -File` handing `-Models a,b` over as one string.
- **Every measurement needs context depth, quant, backend and build attached**, or it can't be
  compared. A worse result is still a result — record it.
- Where a claim didn't survive measurement, the repo keeps **both the claim and the refutation** —
  the contrast is the useful part. Don't silently delete a superseded number; mark it withdrawn.
- Linux/macOS ports live in their own trees, no PowerShell-on-Linux dependency, and are marked
  unproven. **Port the method, not the numbers** — anything measured elsewhere goes in its own
  column in `docs/OPTIMIZATION.md`, never merged into the Windows figures. The `~109 GB` ceiling,
  `Total Committed` accounting, `--mlock` being harmful, sleep dropping VRAM and commit-charge
  limits are all Windows/WDDM-specific and must be re-measured.
