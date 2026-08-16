# scripts/macos/ — Apple silicon (Metal)

> ### 📝 These are drafts
>
> Written on a Windows box and **never run on macOS.** The argument handling and the llama.cpp
> flags are ported deliberately, but no number in this repo was measured on Apple silicon. Use
> `--dry-run` first — it prints the exact `llama-server` invocation and launches nothing.

```bash
chmod +x scripts/macos/*.sh
./scripts/macos/fetch-llamacpp.sh            # Homebrew; Metal is on by default
./scripts/linux/fetch-models.sh --only qwen38
./scripts/macos/run-solo.sh --dry-run
./scripts/macos/run-solo.sh                  # no -m => lists models/ and asks which to serve
```

Model downloading has nothing platform-specific about it, so macOS reuses
[`scripts/linux/fetch-models.sh`](../linux/fetch-models.sh).

## Why a Mac directory exists in a Strix Halo repo

An M-series Mac is the other mainstream **unified-memory** machine: the GPU and the CPU share one
pool of LPDDR instead of copying across a PCIe bus. That makes the questions this repo exists to
answer the same questions, with different numbers — how much of the pool can the GPU actually have,
does a bigger model beat a faster one, where does prefill time actually go.

## The one setting to know

macOS caps GPU-*wired* memory well below installed RAM. This is the Apple equivalent of the BIOS
carve-out that this repo spends so much time on, and it is the first thing to check when a model
that arithmetic says fits refuses to load:

```bash
sysctl iogpu.wired_limit_mb           # 0 means system default, roughly 65-75% of RAM
sudo sysctl iogpu.wired_limit_mb=<MB> # raise it; resets on reboot
```

Leave several GB for the OS. Setting it to your full RAM will hang the machine rather than speed
anything up.

## What to expect from the ported flags

| flag | expectation on Metal |
|---|---|
| `-ngl 999` | correct — offload everything |
| `-fa on` + `-ctk/-ctv q8_0` | should carry over; halves the KV cache for no measurable quality cost |
| `--spec-type draft-mtp` | should carry over where the model ships an MTP head — it's a model property |
| `-ub 256` | **do not copy this.** It is the biggest Windows win here (+29% prefill) and the most architecture-specific flag in the repo: 256 wins because the tile fits gfx1151's 32 KB of shared memory. The default here is 512; sweep it |
| `--mlock` | left off deliberately. The weights are already in the pool the GPU reads |

## If you measure something

Numbers from a Mac are genuinely useful — and they belong in **their own column**, never merged
into the Windows figures. A result needs its **context depth, quant, backend and build** attached
or it cannot be compared to anything. A run that came out *worse* is still a result; say so.

See [../../docs/BENCHMARKS.md](../../docs/BENCHMARKS.md) for how to measure without fooling
yourself, and [../../docs/INSTALL.md](../../docs/INSTALL.md) for the full first-run walkthrough.
