<div align="center">

# strix-halo-llm

**Get the most out of an AMD Strix Halo box for local LLM inference — measured, not guessed.**

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/platform-Windows%2011-0078D6?logo=windows&logoColor=white)](#requirements)
[![Linux](https://img.shields.io/badge/Linux-planned-FCC624?logo=linux&logoColor=black)](#platform-support)
[![llama.cpp](https://img.shields.io/badge/llama.cpp-b10182%20Vulkan-blue)](https://github.com/ggml-org/llama.cpp)
[![GPU](https://img.shields.io/badge/GPU-Radeon%208060S%20gfx1151-ED1C24?logo=amd&logoColor=white)](#the-hardware)
[![PowerShell](https://img.shields.io/badge/PowerShell-5.1-5391FE?logo=powershell&logoColor=white)](#requirements)
[![Python](https://img.shields.io/badge/Python-3.12-3776AB?logo=python&logoColor=white)](#requirements)

[Quick start](#quick-start) · [Findings](#what-we-found) · [Benchmarking](docs/BENCHMARKS.md) · [Tuning playbook](docs/OPTIMIZATION.md)

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
│   └── linux/              bash (planned) -- porting notes in its README
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
| **Linux** | 🚧 planned | See below |

Today's scripts are PowerShell 5.1, and several findings are genuinely Windows-specific — the WDDM
shared-heap ceiling, `Total Committed` accounting, modern-standby dropping VRAM, and the commit-charge
limit. Those need re-measuring on Linux rather than assuming they carry over.

**Portable already:** `evals/code/run-code-eval.py`, `evals/code/smoke.py` and the Docker sandbox are
plain Python and run anywhere. The tuning findings that are about *llama.cpp and the GPU* rather
than about Windows — batch sizes, KV quantisation, MoE-over-dense, speculative decoding, the
bf16 trap — should transfer directly.

**Linux will be bash, in its own tree** at [`scripts/linux/`](scripts/linux/) — not `.sh` interleaved
with `.ps1`, and no PowerShell-on-Linux dependency. The directory already carries porting notes:
which findings transfer, which must be re-measured, and the Linux equivalents of the Windows
perf-counter guards. Nothing that works today will move when it lands.

One thing worth re-testing there: **ROCm may beat Vulkan on Linux** at long context and prompt
processing. The 1.79× Vulkan win recorded here is against *Ollama's* ROCm on Windows — not the same
comparison as llama.cpp's own ROCm backend.

## Requirements

- **AMD Strix Halo** (Ryzen AI MAX+ 395 / Radeon 8060S, gfx1151) — most of it applies to other
  unified-memory AMD parts, but the numbers are from this chip
- **Windows 11** + PowerShell 5.1 (scripts are 5.1-compatible throughout — no PS7 required)
- **llama.cpp Vulkan build** in `bin\` (b10182 or newer for the `laguna` / `deepseek4` architectures)
- **Docker Desktop** — only for the coding-eval sandbox
- **Python 3.12** — only for the coding eval

## Contributing

Numbers are welcome, especially from **other Strix Halo boxes** or **Linux**. The one rule:
a benchmark result needs its **context depth, quant, backend and build** attached, or it can't be
compared to anything. If a run is worse than a previous one, that's still a result — say so.

## License

MIT — see [LICENSE](LICENSE).
