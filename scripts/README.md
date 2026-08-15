# scripts/

Platform-separated. Each directory is self-contained — pick the one for your OS.

**First time here?** → **[docs/INSTALL.md](../docs/INSTALL.md)** walks all three platforms from
nothing to a working endpoint.

```
scripts/
├── windows/     PowerShell 5.1  — supported, and where every number came from
│   ├── fetch-llamacpp.ps1  ⭐ step zero: download the llama.cpp Vulkan release into bin\
│   ├── run-solo.ps1        ⭐ serve ONE model with the whole ~109 GB budget
│   ├── fetch-models.ps1    resume-capable downloader, verifies byte counts
│   ├── download-model.ps1  fetch a single GGUF
│   ├── bench-big.ps1       depth-aware benchmark (llama-bench -d)
│   ├── bench-spec.ps1      A/B baseline vs speculative decoding
│   ├── bench-qwen38*.ps1   the sweeps behind docs/RESULTS.md
│   ├── build-poolside.ps1  build poolside's llama.cpp fork (DFlash drafting)
│   ├── reclaim-ollama.ps1  reclaim disk from Ollama blobs (dry-run by default)
│   └── legacy/             superseded multi-model launchers (:8082-:8088 stack)
│
├── linux/       Bash  — DRAFTS, never run on Linux
│   ├── fetch-llamacpp.sh   download a prebuilt Vulkan release into bin/
│   ├── fetch-models.sh     download + byte-verify (also used on macOS)
│   ├── run-solo.sh         serve one model; has --dry-run
│   ├── bench-big.sh        depth-aware benchmark
│   └── bench-spec.sh       A/B speculative decoding
│
└── macos/       Bash  — DRAFTS, never run on macOS (Apple silicon / Metal)
    ├── fetch-llamacpp.sh   Homebrew, or the prebuilt macos-arm64 release
    └── run-solo.sh         serve one model on Metal; has --dry-run
```

## Windows

PowerShell **5.1**, not 7 — no `&&`, no ternary, no `??`. That constraint is deliberate: 5.1 is what
ships with Windows, so nothing here needs installing first. If you are editing these, the 5.1
gotchas that have actually cost time are listed at the top of
[docs/BENCHMARKS.md](../docs/BENCHMARKS.md) and in [evals/README.md](../evals/README.md) —
`ConvertTo-Json` re-wrapping arrays, `Add-Content -Encoding UTF8` emitting a BOM,
`[math]::Min(1, 0.98)` binding the *integer* overload and silently rounding to 1, and splatting an
**array** binding positionally (which once made three models die with a type-conversion error
before a single token was generated).

Scripts resolve the repo root by climbing out of their own directory, so they work from any working
directory — but they must stay at their current depth. If you move one, fix its
`Split-Path $PSScriptRoot` chain (`windows/` climbs 2, `windows/legacy/` climbs 3).

## Linux and macOS — drafts

Both trees are **bash**, kept fully separate rather than mixed in with the PowerShell. No porting
shims, no PowerShell-on-Linux dependency.

They are syntax-checked and their argument handling works, but **neither has served a model on its
own platform.** Use `--dry-run` first: it prints the exact `llama-server` invocation and launches
nothing, which is the cheapest way to see whether a port did something silly.

macOS reuses `scripts/linux/fetch-models.sh` — downloading a GGUF is the one step with nothing
platform-specific about it.

### What should port cleanly

These are properties of llama.cpp, the model, and the GPU architecture rather than the OS:

- KV quantisation (`q8_0`) together with flash attention
- MoE-over-dense preference, and the bf16 trap — a bigger file is a bigger *quant*, not a better model
- speculative decoding behaviour: `draft-mtp` wins where the model ships an MTP head, generic drafts don't
- quant size and speed running *backwards* — unpacking a more compressed format costs more arithmetic than the bandwidth it saves
- both eval suites, which are plain Python and already portable

### What must be re-measured

`-b 2048 -ub 256` is the measured Windows/gfx1151 optimum, and **`-ub` is the most
architecture-specific flag in this repo.** 256 wins here because a 256-row tile fits gfx1151's
32 KB of shared memory — a different GPU has a different threadgroup budget and therefore a
different answer. Sweep it rather than copying the number. (This repo used `-ub 1024` until
2026-08-14, when measurement showed 256 was **29% faster**; if you find an older reference to 1024
anywhere, it is stale.)

Genuinely OS-specific, and not to be assumed:

- the ~109 GB ceiling — that number is 96 GB carve-out **+ WDDM shared heap**, and Linux manages
  the GTT/VRAM split differently
- `Total Committed` vs `Dedicated Usage` accounting — a Windows perf-counter distinction. On Linux
  use `amdgpu_top` / `rocm-smi` / sysfs; on macOS the analogous cap is `iogpu.wired_limit_mb`
- modern standby dropping all VRAM, and the commit-charge limit / pagefile sizing
- `--mlock` being harmful here (it blocks the Vulkan upload on this WDDM path — it may be
  *correct* on Linux)

Also worth testing on Linux specifically: **ROCm may beat Vulkan** at long context and prompt
processing. The 1.79× Vulkan win recorded here is against *Ollama's* ROCm on Windows, which is not
the same comparison as llama.cpp's own ROCm backend.

**Port the method, not the numbers.** Anything measured elsewhere belongs in its own column in
[docs/OPTIMIZATION.md](../docs/OPTIMIZATION.md), never merged into the Windows figures.
