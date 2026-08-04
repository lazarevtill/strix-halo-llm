# scripts/linux/ — DRAFTS

> ## ⚠️ Status: unproven drafts
>
> These were ported from the PowerShell versions and **have never been run on Linux**.
> They are syntax-checked (`bash -n`) and their argument handling works, but **no script here
> has served a model, benchmarked anything, or been validated against real GPU behaviour.**
>
> **All of this will be updated and proven** once there is a Linux box to run it on. Until then:
> read them as a starting point, expect to fix things, and *do not* trust any number they produce
> without cross-checking it by hand.

| script | mirrors | draft state |
|---|---|---|
| `run-solo.sh` | `../windows/run-solo.ps1` | flags ported 1:1; **GPU accounting and occupancy logic unverified** |
| `fetch-models.sh` | `../windows/fetch-models.ps1` | most portable of the set — curl + arithmetic, no OS-specific behaviour; byte counts verified |
| `bench-big.sh` | `../windows/bench-big.ps1` | depth sweep ported; **the dirty-GPU guard only warns, it does not block** |
| `bench-spec.sh` | `../windows/bench-spec.ps1` | A/B harness ported; **output parsing is llama.cpp-version-sensitive** |

## What was verified, and what wasn't

**Verified from here:** `bash -n` on all four, `--help` output, argument parsing, error paths
(missing model, missing binary, missing required flag). `fetch-models.sh --list` was run against
the real model directory and correctly byte-verified three existing shards.

**Not verified:** anything that requires Linux. In particular every GPU-memory code path, because
Windows perf counters have no direct amdgpu equivalent.

One bug was already caught this way: the first draft of the model registry had `ornith-q5`'s
expected size **off by ~9 MB** from a guessed value. A size that looks plausible but is wrong
produces a GGUF that fails at load with a confusing error rather than an obvious one. All four
entries are now read from real files, not guessed.

## Before you trust these — the porting rules

**The llama.cpp flags transfer. The memory model does not.**

| finding | transfers? | why |
|---|---|---|
| `-b 2048 -ub 1024` batch sweet spot | ✅ likely | property of gfx1151, not the OS |
| `q8_0` KV + flash attention | ✅ likely | llama.cpp behaviour |
| MoE-over-dense, the bf16 trap | ✅ likely | bandwidth-bound arithmetic |
| `draft-mtp` wins, generic drafts don't | ✅ likely | model property — but re-measure per model anyway |
| **~109 GB usable ceiling** | ❌ **no** | that is 96 GB BIOS carve-out **+ WDDM shared heap**; Linux splits VRAM/GTT differently |
| **`Total Committed` vs `Dedicated Usage`** | ❌ **no** | a Windows perf-counter distinction. Linux: `amdgpu_top`, `rocm-smi`, or `/sys/class/drm/card*/device/mem_info_*` — semantics differ |
| **`--mlock` is harmful** | ❌ **no** | it blocks the Vulkan upload on the WDDM path. On Linux it may be correct — measure |
| Sleep dropping all VRAM; pagefile commit limits | ❌ **no** | Windows problems |

**Port the method, not the numbers.** Anything you measure on Linux belongs in its own column in
`docs/OPTIMIZATION.md`, not merged into the Windows figures.

## Also worth testing on Linux

**ROCm may beat Vulkan** at long context and prompt processing. The 1.79× Vulkan advantage recorded
in this repo is measured against *Ollama's* ROCm on **Windows** — llama.cpp's own ROCm backend on
Linux is a different comparison entirely, and community data suggests it wins at 8K+ context.

## Already portable — no bash version needed

`../../evals/code/run-code-eval.py`, `../../evals/code/smoke.py` and the Docker sandbox are plain
Python and run anywhere. The eval *runners* (`evals/*.ps1`) are still PowerShell; bash equivalents
are a later job, and the Python underneath them does the real work.

## Usage

```bash
chmod +x scripts/linux/*.sh

scripts/linux/fetch-models.sh --list
scripts/linux/fetch-models.sh --only ornith-q5
scripts/linux/run-solo.sh --dry-run          # print the command line, launch nothing
scripts/linux/run-solo.sh
```

`--dry-run` on `run-solo.sh` is the safest first thing to run: it prints the exact `llama-server`
invocation without starting anything, so you can compare it against what you would have typed.
