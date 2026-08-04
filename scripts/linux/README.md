# scripts/linux/ — planned

Bash equivalents of the PowerShell scripts in `../windows/`. Nothing here yet.

Kept as a separate tree on purpose: bash scripts, not a PowerShell-on-Linux dependency and not
`.sh` files interleaved with `.ps1` in one directory.

## Intended contents

| planned | mirrors | notes |
|---|---|---|
| `run-solo.sh` | `windows/run-solo.ps1` | serve one model with the whole memory budget |
| `fetch-models.sh` | `windows/fetch-models.ps1` | resume-capable download + byte-count verification |
| `bench-big.sh` | `windows/bench-big.ps1` | depth-aware `llama-bench -d` sweep |
| `bench-spec.sh` | `windows/bench-spec.ps1` | A/B speculative decoding |

## Before porting, read this

The **flags** transfer; the **memory model does not**. Specifically:

- The `~109 GB` ceiling is a Windows number: 96 GB BIOS carve-out **plus WDDM shared heap**. Linux
  handles the GTT/VRAM split differently — re-measure before assuming any headroom figure.
- Solo-occupancy enforcement and the contamination guards read Windows **perf counters**
  (`\GPU Process Memory(*)\Total Committed`). The Linux equivalent is
  `amdgpu_top` / `radeontop` / sysfs (`/sys/class/drm/card*/device/mem_info_*`), and the semantics
  are not identical — check what "committed but trimmed" even means there before porting the guard.
- `--mlock` is harmful on the Windows/WDDM path. On Linux it may well be *correct*. Measure.
- Sleep/standby VRAM loss and pagefile commit-charge limits are Windows problems.

**Do not port the numbers, port the method.** Anything measured belongs in a Linux column of its own
in the docs — `docs/OPTIMIZATION.md` labels findings by platform rather than assuming they carry.

Also test **ROCm vs Vulkan** on Linux. The 1.79× Vulkan advantage recorded in this repo is measured
against *Ollama's* ROCm on Windows; llama.cpp's own ROCm backend on Linux is a different comparison
and may win at long context and prompt processing.
