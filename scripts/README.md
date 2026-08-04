# scripts/

Platform-separated. Each directory is self-contained — pick the one for your OS.

```
scripts/
├── windows/     PowerShell 5.1  (supported today)
│   ├── run-solo.ps1        ⭐ serve ONE model with the whole ~109 GB budget
│   ├── fetch-models.ps1    resume-capable downloader, verifies byte counts
│   ├── download-model.ps1  fetch a single GGUF
│   ├── bench-big.ps1       depth-aware benchmark (llama-bench -d)
│   ├── bench-spec.ps1      A/B baseline vs speculative decoding
│   ├── build-poolside.ps1  build poolside's llama.cpp fork (DFlash drafting)
│   ├── reclaim-ollama.ps1  reclaim disk from Ollama blobs (dry-run by default)
│   └── legacy/             superseded multi-model launchers (:8082-:8088 stack)
│
└── linux/       Bash  (planned — see below)
```

## Windows

PowerShell **5.1**, not 7 — no `&&`, no ternary, no `??`. That constraint is deliberate: 5.1 is what
ships with Windows, so nothing here needs installing first. If you are editing these, the 5.1
gotchas that have actually cost time are listed at the top of
[docs/BENCHMARKS.md](../docs/BENCHMARKS.md) and in [evals/README.md](../evals/README.md) —
`ConvertTo-Json` re-wrapping arrays, `Add-Content -Encoding UTF8` emitting a BOM, and
`[math]::Min(1, 0.98)` binding the *integer* overload and silently rounding to 1.

Scripts resolve the repo root by climbing out of their own directory, so they work from any working
directory — but they must stay at their current depth. If you move one, fix its
`Split-Path $PSScriptRoot` chain (`windows/` climbs 2, `windows/legacy/` climbs 3).

## Linux — planned

Everything will be **bash**, kept fully separate rather than mixed in with the PowerShell. No
porting shims, no PowerShell-on-Linux dependency.

What should port cleanly, because it's about llama.cpp and the GPU rather than the OS:

- batch/ubatch sweet spot (`-b 2048 -ub 1024`)
- KV quantisation (`q8_0`) + flash attention
- MoE-over-dense preference, and the bf16 trap
- speculative decoding behaviour (`draft-mtp` wins, generic drafts don't)
- the model comparison and both eval suites

What must be **re-measured**, because it is genuinely Windows-specific:

- the ~109 GB ceiling — that number is 96 GB carve-out **+ WDDM shared heap**, and Linux manages
  GTT/VRAM split differently
- `Total Committed` vs `Dedicated Usage` accounting — a Windows perf-counter distinction
- modern standby dropping all VRAM, and the commit-charge limit / pagefile sizing
- `--mlock` being harmful here (it blocks the Vulkan upload on this WDDM path)

Also worth testing on Linux specifically: **ROCm may beat Vulkan** at long context and prompt
processing. The 1.79× Vulkan win recorded here is against *Ollama's* ROCm on Windows, which is not
the same comparison.

Already portable, no bash version needed: `evals/code/run-code-eval.py`, `evals/code/smoke.py` and
the Docker sandbox are plain Python.
