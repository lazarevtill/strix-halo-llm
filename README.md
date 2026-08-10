<div align="center">

# strix-halo-llm

**Get the most out of an AMD Strix Halo box for local LLM inference — measured, not guessed.**

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/platform-Windows%2011-0078D6?logo=windows&logoColor=white)](#requirements)
[![Linux](https://img.shields.io/badge/Linux-drafts%20(unproven)-FCC624?logo=linux&logoColor=black)](#linux-drafts)
[![llama.cpp](https://img.shields.io/badge/llama.cpp-b10338%20Vulkan-blue)](https://github.com/ggml-org/llama.cpp)
[![GPU](https://img.shields.io/badge/GPU-Radeon%208060S%20gfx1151-ED1C24?logo=amd&logoColor=white)](#requirements)
[![PowerShell](https://img.shields.io/badge/PowerShell-5.1-5391FE?logo=powershell&logoColor=white)](#requirements)
[![Python](https://img.shields.io/badge/Python-3.12-3776AB?logo=python&logoColor=white)](#requirements)

[Quick start](#quick-start) · [Findings](#what-we-found) · [Benchmarking](docs/BENCHMARKS.md) · [Tuning playbook](docs/OPTIMIZATION.md) · [Linux drafts](#linux-drafts)

</div>

---

## What is this

You bought a **Ryzen AI MAX+ 395 "Strix Halo"** with 128 GB of unified memory to run big models
locally. Then you hit the questions nobody answers well: how much memory can you *actually* use, is
Vulkan or ROCm faster, does a 90 GB model beat a 23 GB one, and why is the thing slower than the
benchmarks promised?

This repo is the worked answer. Every number here was measured on the box — and where a published
claim didn't survive measurement, **both the claim and the refutation are kept**, because the
contrast is the useful part.

## Who this is for

- **New owners of a Strix Halo / gfx1151 box** who want a working, tuned setup without repeating a
  month of trial and error.
- **Anyone trying to speed up local inference** on unified-memory hardware — most of the memory,
  batching and speculative-decoding findings generalise beyond this exact chip.
- **Anyone benchmarking LLMs** who wants a harness that fails loudly instead of producing a
  plausible wrong number. That part is hardware-independent.

## What you get

| | |
|---|---|
| ⚡ **A tuned single-model launcher** | `run-solo.ps1` — one model, the whole memory budget, full context, measured-optimal flags |
| 📏 **A real memory ceiling** | ~109 GB usable, not the 96 GB the BIOS carve-out implies |
| 🧪 **Two private eval suites** | tool-calling + agentic coding, uncontaminated, with a self-test that gates every run |
| 📊 **A measured model comparison** | three frontier-class models, with confidence intervals and an honest "these are tied" |
| 🧯 **A list of ways benchmarks lie** | six harness bugs, each with the believable wrong number it produced |

---

## What we found

### The memory ceiling is ~109 GB, not 96 GB

96 GB dedicated carve-out **+ ~13.4 GB of WDDM shared heap**, and token generation is *flat* from
89 GB to 109 GB — spilling past the carve-out costs nothing on a UMA APU, because it's the same
physical LPDDR5X either way. That's ~13 GB of free headroom most setups leave on the table.

> **Measure with `Total Committed`, never `Dedicated Usage`.** Windows trims an idle model's
> *dedicated* bytes to ~0 while it still holds the reservation — that counter under-reported two
> resident servers by **42.5 GB**, which is how the box silently blew past its ceiling while the
> console showed plenty of room.

### Three models tie on quality — so pick the small one

Measured 2026-08-04, each the sole GPU occupant at `ctx=131072`, on two private uncontaminated suites:

| model | tool calling | 95% CI | agentic coding | truncations | tg | size |
|---|---|---|---|---|---|---|
| 🥇 **Ornith-1.0-35B Q5_K_M** | 28/29 = 96.6% | [82.8, 99.4] | **70/70** | 1 | **~58 t/s** | **23 GB** |
| Qwen3.5-122B-A10B Q4_K_XL | 28/29 = 96.6% | [82.8, 99.4] | **70/70** | 3 | ~34 t/s | 78 GB |
| Laguna-S-2.1 Q4_K_M | 27/29 = 93.1% | [78.0, 98.1] | **70/70** | 1 | ~14 t/s | 89 GB |

All three: 4/4 tasks, **zero regressions**, perfect first turn. Every confidence interval overlaps
and McNemar exact is **p = 1.0** — a three-way tie, not a ranking.

**So take the 23 GB model.** Same measured quality, a quarter of the footprint, 4× the throughput.
Laguna's published Terminal-Bench 2.1 lead (70.2 vs 64.4) produced no measurable advantage here.

> ⚠️ **Don't read an ordering into those numbers.** n=29 tool cases and an *effective* n=4 coding
> tasks can catch a bad model but cannot rank close ones — a single test flipped between two
> identical temperature-0 runs. Ranking frontier models would need ~100 paired cases and ~10 tasks.
> [How to read this properly →](docs/BENCHMARKS.md)

### bf16 is a trap

The obvious "upgrade" from Q5_K_M to full precision makes everything **worse**: 11.17 t/s versus
~58 (5.6× slower), and prompt processing collapses too (241 vs 698 t/s). A bigger Ornith is a bigger
*quant*, not a better model.

### Other things that cost us time

| finding | short version |
|---|---|
| Vulkan vs Ollama-ROCm | **1.79× faster** token generation — use the Vulkan build |
| `--mlock` | **Never** on this box. Pins weights in system RAM and blocks the GPU upload |
| `--fit on` | Useless here — reported free VRAM is a constant, so it sizes against a fiction |
| `--cache-reuse` | A no-op on these MoEs; prefix caching already works |
| Sleep | Modern standby drops all VRAM. `powercfg /change standby-timeout-ac 0` |
| Batch size | `-b 2048 -ub 1024` is the prompt-processing sweet spot on gfx1151 |

Full detail and the measurements behind each: **[docs/OPTIMIZATION.md](docs/OPTIMIZATION.md)**.

---

## Quick start

```powershell
git clone https://github.com/lazarevtill/strix-halo-llm.git
cd strix-halo-llm

# 1. Get a model (resume-capable, verifies byte counts against the HF API)
.\scripts\windows\fetch-models.ps1 -List
.\scripts\windows\fetch-models.ps1 -Only ornith-q5

# 2. Serve it: whole memory budget, full 262144 context
.\scripts\windows\run-solo.ps1
#    -> Web UI:     http://127.0.0.1:8080
#    -> OpenAI API: http://127.0.0.1:8080/v1/chat/completions
```

That's it — you now have an OpenAI-compatible endpoint. **Claude Code, Codex and any OpenAI SDK can
point straight at it**, no shim required (see [docs/OPTIMIZATION.md](docs/OPTIMIZATION.md)).

<details>
<summary><b>Going further</b> — bigger models, benchmarking, evaluation</summary>

```powershell
# A bigger model (one at a time -- run-solo stops any other server first)
.\scripts\windows\run-solo.ps1 -Model .\models\Qwen3.5-122B-A10B-UD-Q4_K_XL-00001-of-00003.gguf `
                       -Ctx 131072 -Spec draft-mtp

# Benchmark at real context depths, not the misleading depth 0
.\scripts\windows\bench-big.ps1

# A/B speculative decoding
.\scripts\windows\bench-spec.ps1 -Model .\models\<model>.gguf -Spec draft-mtp

# Score a model on the private eval suites (smoke-gated, refuses a dirty GPU)
docker build -f evals\code\Dockerfile.sandbox -t llm-eval-sandbox evals\code
.\evals\run-guarded.ps1 -Models ornith-q5
```

</details>

---

## Repository layout

```
strix-halo-llm/
├── docs/
│   ├── OPTIMIZATION.md     ⭐ the tuning playbook + full model comparison
│   ├── BENCHMARKS.md       ⭐ what to measure, how, and how not to fool yourself
│   ├── FLEET.md            multi-machine roles; retrieval / memory-layer findings
│   └── PUBLISHING.md       what is safe to publish, and what must never be
│
├── scripts/                platform-separated -- see scripts/README.md
│   ├── windows/            PowerShell 5.1 (supported today)
│   │   ├── run-solo.ps1        ⭐ serve ONE model with the whole ~109 GB budget
│   │   ├── fetch-models.ps1    resume-capable downloader, verifies byte counts
│   │   ├── bench-big.ps1       depth-aware benchmark
│   │   ├── bench-spec.ps1      A/B baseline vs speculative decoding
│   │   ├── build-poolside.ps1  build poolside's llama.cpp fork (DFlash drafting)
│   │   └── legacy/             superseded multi-model launchers
│   └── linux/              bash DRAFTS -- unproven, see its README
│       ├── run-solo.sh         serve one model (has --dry-run)
│       ├── fetch-models.sh     download + byte-verify
│       ├── bench-big.sh        depth-aware benchmark
│       └── bench-spec.sh       A/B speculative decoding
│
├── evals/                  ⭐ the evaluation harness
│   ├── run-guarded.ps1     run suites across models: smoke-gated, respawn-proof
│   ├── run-tools-eval.ps1  tool-calling eval (29 cases)
│   ├── tools/tools.json    the 10 tool schemas (public)
│   └── code/
│       ├── run-code-eval.py   agentic coding eval (portable)
│       ├── smoke.py           harness self-test — gates every run (portable)
│       └── Dockerfile.sandbox no network, 512 MB, 1 CPU, read-only
│
└── archive/coding-eval/    superseded first-gen eval, kept for history
```

Local-only, never committed: `models/` (~640 GB of GGUF), `bin*/` (llama.cpp binaries), logs,
benchmark output, eval results.

---

## The evaluation harness

Most published benchmark numbers are contaminated: on decontaminated **SWE-rebench**, A3B-class
models score roughly **4× below** their self-reported SWE-bench figures. So this repo carries its
own suites — and **the harness is public while the cases are not**, because a published benchmark
stops measuring anything the moment models train on it.

[docs/BENCHMARKS.md](docs/BENCHMARKS.md) documents exactly what the suites contain — per-category
case counts, what each isolates, each coding task's entry point and per-turn test counts — so the
results are interpretable without handing over the answers.
[docs/PUBLISHING.md](docs/PUBLISHING.md) shows the file shapes so you can author your own.

**The most reusable part may be the failure list.** Six harness bugs each produced a *believable*
wrong number during development — `17.2%`, `"34/34 = 100%"`, `92.2%`, `44.3%`, `"first-shot 64.3%"`
— and one task turned out to be **unsatisfiable**, quietly rewarding models that ignored the user.
Each is written up with the fake number it produced in [evals/README.md](evals/README.md).

That's why `smoke.py` gates every run: it proves the sandbox distinguishes good code from bad, that
prose isn't mistaken for code, and that **every task prompt is satisfiable by a reference solution**.

---

## Platform support

| | status | notes |
|---|---|---|
| **Windows 11** | ✅ supported | Everything here is measured on Windows 11 + PowerShell 5.1 |
| **Linux** | 📝 **unproven drafts** | Bash ports exist in [`scripts/linux/`](scripts/linux/) — syntax-checked, never run on Linux. **They will be updated and proven** once there's a box to run them on |

Today's scripts are PowerShell 5.1, and several findings are genuinely Windows-specific — the WDDM
shared-heap ceiling, `Total Committed` accounting, modern-standby dropping VRAM, and the commit-charge
limit. Those need re-measuring on Linux rather than assuming they carry over.

**Portable already:** [`evals/code/run-code-eval.py`](evals/code/run-code-eval.py),
[`evals/code/smoke.py`](evals/code/smoke.py) and the
[Docker sandbox](evals/code/Dockerfile.sandbox) are plain Python and run anywhere.

### Linux drafts

Bash ports live in their own tree at **[`scripts/linux/`](scripts/linux/)** — not `.sh` interleaved
with `.ps1`, and no PowerShell-on-Linux dependency.

| script | mirrors | what it does | state |
|---|---|---|---|
| [`run-solo.sh`](scripts/linux/run-solo.sh) | [`windows/run-solo.ps1`](scripts/windows/run-solo.ps1) | serve ONE model with the whole memory budget; has `--dry-run` | flags ported 1:1; **GPU accounting unverified** |
| [`fetch-models.sh`](scripts/linux/fetch-models.sh) | [`windows/fetch-models.ps1`](scripts/windows/fetch-models.ps1) | resume-capable download + byte verification | most portable; byte counts verified |
| [`bench-big.sh`](scripts/linux/bench-big.sh) | [`windows/bench-big.ps1`](scripts/windows/bench-big.ps1) | depth-aware benchmark sweep | **dirty-GPU guard only warns, doesn't block** |
| [`bench-spec.sh`](scripts/linux/bench-spec.sh) | [`windows/bench-spec.ps1`](scripts/windows/bench-spec.ps1) | A/B speculative decoding, classifies WIN/NEUTRAL/NEGATIVE | **output parsing is version-sensitive** |

> ### 📝 These drafts are unproven
>
> They are syntax-checked (`bash -n`) and their argument handling works, but **none has served a
> model or benchmarked anything on Linux.** **All of this will be updated and proven** once there is
> a box to run it on. Until then treat them as a starting point, not a reference — and don't trust a
> number they produce without checking it by hand.

```bash
chmod +x scripts/linux/*.sh          # exec bits are set in git, so usually not needed
scripts/linux/fetch-models.sh --list
scripts/linux/run-solo.sh --dry-run  # prints the exact llama-server invocation, launches nothing
```

**What transfers, and what must be re-measured** — the full table is in
[`scripts/linux/README.md`](scripts/linux/README.md). The short version:

| | |
|---|---|
| ✅ **likely transfers** | `-b 2048 -ub 1024` batch sweet spot · `q8_0` KV + flash attention · MoE-over-dense · the bf16 trap · `draft-mtp` wins where generic drafts don't |
| ❌ **must be re-measured** | the ~109 GB ceiling (that's 96 GB carve-out **+ WDDM shared heap**) · `Total Committed` vs `Dedicated Usage` (a Windows perf-counter distinction; Linux uses `amdgpu_top` / `rocm-smi` / sysfs) · whether `--mlock` is harmful (it is on WDDM — may be *correct* on Linux) · sleep dropping VRAM · pagefile commit limits |

**Port the method, not the numbers.** Anything measured on Linux belongs in its own column in
[`docs/OPTIMIZATION.md`](docs/OPTIMIZATION.md), not merged into the Windows figures.

Also worth testing there: **ROCm may beat Vulkan on Linux** at long context and prompt processing.
The 1.79× Vulkan win recorded here is against *Ollama's* ROCm on Windows — not the same comparison
as llama.cpp's own ROCm backend.

**Contributions from a Linux box are the single most useful thing anyone could send.**

## Requirements

- **AMD Strix Halo** (Ryzen AI MAX+ 395 / Radeon 8060S, gfx1151) — most of it applies to other
  unified-memory AMD parts, but the numbers are from this chip
- **Windows 11** + PowerShell 5.1 (scripts are 5.1-compatible throughout — no PS7 required)
- **llama.cpp Vulkan build** in `bin\` (currently b10338; b10182+ for `laguna`/`deepseek4`, and `muse-glimmer` needs a build newer than b10338)
- **Docker Desktop** — only for the coding-eval sandbox
- **Python 3.12** — only for the coding eval

## Contributing

Numbers are welcome, especially from **other Strix Halo boxes** or **Linux**. The one rule:
a benchmark result needs its **context depth, quant, backend and build** attached, or it can't be
compared to anything. If a run is worse than a previous one, that's still a result — say so.

## License

MIT — see [LICENSE](LICENSE).
