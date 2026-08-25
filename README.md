<div align="center">

# strix-halo-llm

**Get the most out of an AMD Strix Halo box for local LLM inference — measured, not guessed.**

[![verify](https://github.com/lazarevtill/strix-halo-llm/actions/workflows/verify.yml/badge.svg)](https://github.com/lazarevtill/strix-halo-llm/actions/workflows/verify.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/Windows%2011-measured-0078D6?logo=windows&logoColor=white)](#requirements)
[![Linux](https://img.shields.io/badge/Linux-drafts%20(unproven)-FCC624?logo=linux&logoColor=black)](#other-platforms)
[![macOS](https://img.shields.io/badge/macOS-drafts%20(unproven)-000000?logo=apple&logoColor=white)](#other-platforms)
[![llama.cpp](https://img.shields.io/badge/llama.cpp-b10431%20Vulkan-blue)](https://github.com/ggml-org/llama.cpp)
[![GPU](https://img.shields.io/badge/GPU-Radeon%208060S%20gfx1151-ED1C24?logo=amd&logoColor=white)](#requirements)
[![PowerShell](https://img.shields.io/badge/PowerShell-5.1-5391FE?logo=powershell&logoColor=white)](#requirements)
[![Python](https://img.shields.io/badge/Python-3.12-3776AB?logo=python&logoColor=white)](#requirements)
[![Report](https://img.shields.io/badge/report-strix.lazarev.cloud-16A34A)](https://strix.lazarev.cloud/)

### 📊 [**strix.lazarev.cloud**](https://strix.lazarev.cloud/) — the charts, without the reading

[**Install & first run →**](docs/INSTALL.md) · [What the terms mean](docs/EXPLAIN.md) · [Results](docs/RESULTS.md) · [Go faster](docs/GOING-FASTER.md) · [Benchmarking](docs/BENCHMARKS.md)

**Windows · Linux · macOS** — [installation for all three](docs/INSTALL.md)

</div>

```powershell
git clone https://github.com/lazarevtill/strix-halo-llm.git && cd strix-halo-llm
.\scripts\windows\fetch-llamacpp.ps1 -Build b10431   # the engine, into bin\. Nothing to compile.
.\scripts\windows\fetch-models.ps1 -Only qwen38      # ~17 GB. -List shows the registry.
.\scripts\windows\run-solo.ps1                       # -> OpenAI API on http://127.0.0.1:8080/v1
```

Linux and macOS are the same three steps in `scripts/linux/` and `scripts/macos/` — **ported but
unproven**, so run them with `--dry-run` first. [Full walkthrough for all three →](docs/INSTALL.md)

**Don't have this hardware?** Two parts of this repo are about measurement rather than about one
GPU, and they transfer: **[the fourteen harness bugs](evals/README.md)** — each with the believable
wrong number it produced, including the pair that faked a four-way tie between models spanning
16.7 GB to 89 GB — and **[how to benchmark without fooling yourself](docs/BENCHMARKS.md)**. The eval
harness runs anywhere Python and Docker do; `python evals/code/smoke.py` scores it against itself in
about thirty seconds.

---

## In one screen

Never tuned a local model before? **[docs/INSTALL.md](docs/INSTALL.md)** takes you from nothing to a
working endpoint on Windows, Linux or macOS, and **[docs/EXPLAIN.md](docs/EXPLAIN.md)** explains
every term below in plain English, with diagrams. No GPU or ML background needed.

**The settings that matter**, all measured on this box (llama.cpp b10431, Vulkan):

```
--model Qwen3.8-27B-UD-Q4_K_XL.gguf -ngl 99 -fa on
--spec-type draft-mtp --spec-draft-n-max 3     # +79%
-b 2048 -ub 256                                # +29% prefill vs the usual 1024
-ctk q8_0 -ctv q8_0                            # free, halves the KV cache
-c 262144                                      # full context costs only 3%
```

| | measured |
|---|---|
| generation | **20.3 t/s** (~38 t/s on code) |
| prefill | **167 t/s** — a 44k prompt is ~4.5 min before the first word |
| model size | **16.7 GB** — the smallest of the four models benchmarked here |
| quality | 🔄 **being re-measured** — see below |

> **The quality numbers are currently withdrawn, on purpose.** Both eval suites were run under
> greedy decoding (temperature 0), which sends thinking models into repetition loops that emit no
> answer — and the harness was quietly discarding exactly those turns. That is *why* four models
> spanning 16.7 GB to 89 GB all appeared to tie at 100%. The sampler and the scoring are fixed, a
> harder tier was added, and every model is being re-run. **[Full explanation →](docs/RESULTS.md#3-quality)**

**Five "obvious" optimisations that measurement killed** — full detail in
[GOING-FASTER.md](docs/GOING-FASTER.md):

| idea | why it sounded right | reality |
|---|---|---|
| rewrite the slow GPU kernel | the code really is serial | **1.1%** of prefill |
| use a smaller quant | fewer bytes to read | **slower** |
| bigger batches | fewer, larger operations | **29% slower** |
| deeper speculation | more tokens per pass | **worse than off** |
| lower "reasoning effort" | less thinking = faster | **74% slower** |

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
| ⚡ **A tuned single-model launcher** | `run-solo.ps1` — one model (prompts you to pick it), the whole memory budget, full context, measured-optimal flags |
| 🔀 **A two-model launcher** | `run-router.ps1` — serve two models at once from `:8080` via llama.cpp router mode (route by the `model` field); a fast MoE for big text alongside the dense coder, both VRAM-resident |
| 📏 **A real memory ceiling** | ~109 GB usable, not the 96 GB the BIOS carve-out implies |
| 🧪 **Two private eval suites** | tool-calling + agentic coding, uncontaminated, with a self-test that gates every run |
| 🪜 **A hard tier that actually bites** | 3 multi-turn tasks, 89 hidden tests. The first model through it scored **55%** — after scoring 100% on the easy tier |
| 🧯 **A list of ways benchmarks lie** | **fourteen** harness bugs, each with the believable wrong number it produced — including the pair that faked a four-way tie |

---

## What we found

### The memory ceiling is ~109 GB, not 96 GB

96 GB dedicated carve-out **+ a ~15.8 GB WDDM shared heap, of which ~13.4 GB is reachable** before
the ceiling (the rest goes to the desktop and compositor), and token generation is *flat* from
89 GB to 109 GB — spilling past the carve-out costs nothing on a UMA APU, because it's the same
physical LPDDR5X either way. That's ~13 GB of free headroom most setups leave on the table.

> **Measure with `Total Committed`, never `Dedicated Usage`.** Windows trims an idle model's
> *dedicated* bytes to ~0 while it still holds the reservation — that counter under-reported two
> resident servers by **42.5 GB**, which is how the box silently blew past its ceiling while the
> console showed plenty of room.

### A benchmark everyone passes is measuring the tasks, not the models

Four models spanning **16.7 GB to 89 GB** all scored **70/70** on the coding suite and 27–29/29 on
tool calling. That is not four tied models. That is a saturated benchmark, and chasing why it
saturated turned up something worse.

Both suites ran at **temperature 0** — chosen for reproducibility, and measurably the wrong choice
for thinking models. An audit of the retained transcripts found that **every truncated turn was a
repetition loop that emitted no answer at all — 9 of 9, across all four models**, one line repeated
up to 439 times until the token budget ran out. Qwen ships the warning on its own model cards:
*"We do NOT recommend using greedy decoding, as it can lead to performance degradation and endless
repetitions."*

It stayed hidden because the scorer **excluded truncated turns**. That rule was treating the
symptom in the wrong layer: it silently rescued turns where the model produced nothing, which is
precisely why very different models appeared to tie.

**What changed:**

| | |
|---|---|
| sampler | temperature 0.3, seed recorded in every result row |
| scoring | every task reports its score **twice** — rescued, and strict with no rescue at all |
| tiers | hard and easy scored separately; a saturated tier can no longer flatter a model |
| **a hard tier** | 3 multi-turn tasks, 89 hidden tests: a token-bucket rate limiter, semver ranges, and a SQL `WHERE` evaluator with full three-valued logic |

The hard tier discriminates. The first model through it — Ornith-1.0-35B, which scores 70/70 on the
easy tier — reached **49/89 (55%)**, passing *every* first-turn test and then **losing its work at
the handoff**: asked to extend its own code, it replies with just the new function, and the harness
scores that file alone.

```
                 turn 1      corrected     as first reported
hard_ratelimit   10/10       16/25         16/25
hard_semver      11/11       11/27          0/27   <- bug 12
hard_where       14/14       22/37          0/37   <- bug 12
```

That first `16/89 (18%)` was **mostly a harness artifact** — fragment detection used a substring
test, so a partial reply that merely *called* the entry symbol was graded as a complete solution
worth 0. It is written up as bug 12, and `evals/rescore.py` re-derives corrected scores from stored
runs without re-spending GPU time. The suite caught it the way it caught the others: a number that
was too clean to believe.

Writing the code was never the hard part. Revising it is.

> 🔄 **The full re-run across every model is in progress.** Until it lands, pick on **speed and
> size** — those numbers never depended on the sampler and still stand.
> [Method and current results →](docs/RESULTS.md#3-quality)

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
| Batch size | `-b 2048 -ub 256` on gfx1151. `-ub` is the most-often-wrong flag here — the common 1024 costs **29%** |

Full detail and the measurements behind each: **[docs/OPTIMIZATION.md](docs/OPTIMIZATION.md)**.

---

## Quick start

Three steps: get the engine, get a model, serve it. Full walkthrough with troubleshooting for all
three platforms in **[docs/INSTALL.md](docs/INSTALL.md)**.

**Windows** — measured, supported:

```powershell
git clone https://github.com/lazarevtill/strix-halo-llm.git
cd strix-halo-llm

# 1. Get the engine (llama.cpp Vulkan release -> bin\). Nothing to compile.
.\scripts\windows\fetch-llamacpp.ps1 -Build b10431

# 2. Get a model (resume-capable, verifies byte counts against the HF API)
.\scripts\windows\fetch-models.ps1 -List
.\scripts\windows\fetch-models.ps1 -Only qwen38

# 3. Serve it: whole memory budget, full context (prompts you to pick a model)
.\scripts\windows\run-solo.ps1
#    -> Web UI:     http://127.0.0.1:8080
#    -> OpenAI API: http://127.0.0.1:8080/v1/chat/completions
```

**Linux** and **macOS** — ported, unproven; `--dry-run` prints the command without launching:

```bash
git clone https://github.com/lazarevtill/strix-halo-llm.git && cd strix-halo-llm

# Linux (Vulkan)                         # macOS (Apple silicon / Metal)
chmod +x scripts/linux/*.sh              chmod +x scripts/macos/*.sh
./scripts/linux/fetch-llamacpp.sh        ./scripts/macos/fetch-llamacpp.sh
./scripts/linux/fetch-models.sh --only qwen38     # both platforms use this one
./scripts/linux/run-solo.sh --dry-run    ./scripts/macos/run-solo.sh --dry-run
```

Then check it:

```bash
curl http://127.0.0.1:8080/health                     # {"status":"ok"}
```

That's it — you now have an OpenAI-compatible endpoint. **Claude Code, Codex and any OpenAI SDK can
point straight at it**, no shim required: set the base URL to `http://127.0.0.1:8080/v1` and use any
string as the API key (see [docs/OPTIMIZATION.md](docs/OPTIMIZATION.md)).

<details>
<summary><b>Going further</b> — bigger models, benchmarking, evaluation</summary>

```powershell
# A bigger model (one at a time -- run-solo stops any other server first)
.\scripts\windows\run-solo.ps1 -Model .\models\Qwen3.5-122B-A10B-UD-Q4_K_XL-00001-of-00003.gguf `
                       -Ctx 131072 -Spec draft-mtp

# TWO models at once from :8080 (router mode) -- route by the OpenAI `model` field.
# Coding on the dense model, big-text on a faster MoE, both kept warm in VRAM.
.\scripts\windows\run-router.ps1                      # -> :8080; curl -d '{"model":"qwen38",...}' or "ornith"

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
│   ├── INSTALL.md          ⭐ START HERE -- first run on Windows / Linux / macOS
│   ├── EXPLAIN.md          ⭐ every term in plain English, with diagrams
│   ├── RESULTS.md          what was measured, and what it means
│   ├── GOING-FASTER.md     the settings worth copying, and five that measurement killed
│   ├── OPTIMIZATION.md     the full tuning playbook (long -- a reference)
│   ├── BENCHMARKS.md       ⭐ what to measure, how, and how not to fool yourself
│   ├── MULTI-USER.md       serving real people: saved chats, capacity, restart cost
│   ├── PUBLISHING.md       what is safe to publish, and what must never be
│   └── index.html          the GitHub Pages report -> strix.lazarev.cloud
│
├── scripts/                platform-separated -- see scripts/README.md
│   ├── windows/            PowerShell 5.1 -- supported, and where every number came from
│   │   ├── fetch-llamacpp.ps1  ⭐ step zero: the engine, into bin\
│   │   ├── run-solo.ps1        ⭐ serve ONE model with the whole ~109 GB budget (prompts for model)
│   │   ├── run-router.ps1      serve TWO models at once on :8080 (router mode; route by model name)
│   │   ├── fetch-models.ps1    resume-capable downloader, verifies byte counts
│   │   ├── bench-big.ps1       depth-aware benchmark
│   │   ├── bench-spec.ps1      A/B baseline vs speculative decoding
│   │   ├── build-poolside.ps1  build poolside's llama.cpp fork (DFlash drafting)
│   │   └── legacy/             superseded multi-model launchers
│   ├── linux/              bash DRAFTS -- unproven, see its README
│   │   ├── fetch-llamacpp.sh   download a prebuilt Vulkan release
│   │   ├── run-solo.sh         serve one model (prompts for model; has --dry-run)
│   │   ├── run-router.sh       serve TWO models at once (router mode; asks on start; --dry-run)
│   │   ├── fetch-models.sh     download + byte-verify (macOS uses this too)
│   │   ├── bench-big.sh        depth-aware benchmark
│   │   └── bench-spec.sh       A/B speculative decoding
│   └── macos/              bash DRAFTS -- Apple silicon / Metal, unproven
│       ├── fetch-llamacpp.sh   Homebrew, or the prebuilt macos-arm64 release
│       └── run-solo.sh         serve one model on Metal (prompts for model; has --dry-run)
│
└── evals/                  ⭐ the evaluation harness
    ├── run-full-bench.ps1  the whole stack: speed, then hard tier, then easy + tools
    ├── run-model-suite.ps1 one model, both suites, sole GPU occupant
    ├── summarize-bench.py  turn a run into the published table
    ├── rescore.py          re-derive scores from stored runs -- no GPU, no Docker
    ├── run-tools-eval.ps1  tool-calling eval (29 cases)
    ├── tools/tools.json    the 10 tool schemas (public)
    └── code/
        ├── run-code-eval.py   agentic coding eval, easy + hard tiers (portable)
        ├── smoke.py           harness self-test -- gates every run (portable)
        ├── Dockerfile.sandbox no network, 512 MB, 1 CPU, read-only
        └── examples/          ⭐ public example suite -- what makes smoke.py runnable
                               on a fresh clone, since the real cases are withheld
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

**The most reusable part may be the failure list.** **Thirteen** harness bugs each produced a
*believable* wrong number during development — `17.2%`, `"34/34 = 100%"`, `92.2%`, `44.3%`,
`"first-shot 64.3%"`, and finally `70/70` for four models at once — and one task turned out to be
**unsatisfiable**, quietly rewarding models that ignored the user. Each is written up with the fake
number it produced in [evals/README.md](evals/README.md).

That's why `smoke.py` gates every run: it proves the sandbox distinguishes good code from bad, that
prose isn't mistaken for code, and that **every task prompt is satisfiable by a reference solution**.

---

## Platform support

| | status | notes |
|---|---|---|
| **Windows 11** | ✅ supported | Everything here is measured on Windows 11 + PowerShell 5.1 |
| **Linux** | 📝 **unproven drafts** | Bash ports in [`scripts/linux/`](scripts/linux/) — syntax-checked, never run on Linux. **They will be updated and proven** once there's a box to run them on |
| **macOS** (Apple silicon) | 📝 **unproven drafts** | Bash ports in [`scripts/macos/`](scripts/macos/) — Metal instead of Vulkan. An M-series Mac is the other mainstream unified-memory machine, so the *method* transfers; no number here was measured on it |

Today's scripts are PowerShell 5.1, and several findings are genuinely Windows-specific — the WDDM
shared-heap ceiling, `Total Committed` accounting, modern-standby dropping VRAM, and the commit-charge
limit. Those need re-measuring on Linux rather than assuming they carry over.

**Portable already:** [`evals/code/run-code-eval.py`](evals/code/run-code-eval.py),
[`evals/code/smoke.py`](evals/code/smoke.py) and the
[Docker sandbox](evals/code/Dockerfile.sandbox) are plain Python and run anywhere.

That claim used to be false in the way that matters. The measured cases are gitignored, so on a
fresh clone `run-code-eval.py` raised `FileNotFoundError` at import and `smoke.py` — the script
offered here as the reason to trust any number in this repo — died with a traceback for everyone who
was not its author. There is now a committed
**[public example suite](evals/code/examples/)**: one deliberately textbook task, in the same
three-turn shape, that the harness falls back to and announces loudly. It ranks nothing and every
model passes it; it exists so that the self-test is something you can run rather than something you
are asked to believe.

### Other platforms

Bash ports live in their own trees at **[`scripts/linux/`](scripts/linux/)** and
**[`scripts/macos/`](scripts/macos/)** — not `.sh` interleaved with `.ps1`, and no
PowerShell-on-Linux dependency. Setup for all three platforms is in
**[docs/INSTALL.md](docs/INSTALL.md)**.

| script | mirrors | what it does | state |
|---|---|---|---|
| [`linux/fetch-llamacpp.sh`](scripts/linux/fetch-llamacpp.sh) | [`windows/fetch-llamacpp.ps1`](scripts/windows/fetch-llamacpp.ps1) | download a prebuilt Vulkan release into `bin/` | curl + unzip; **untested against a real driver stack** |
| [`macos/fetch-llamacpp.sh`](scripts/macos/fetch-llamacpp.sh) | — | Homebrew, or the prebuilt `macos-arm64` release | **never run on macOS** |
| [`macos/run-solo.sh`](scripts/macos/run-solo.sh) | [`windows/run-solo.ps1`](scripts/windows/run-solo.ps1) | serve one model on Metal; prompts for model; has `--dry-run` | **never run on macOS**; `-ub` deliberately left at 512, not the Windows 256 |
| [`run-solo.sh`](scripts/linux/run-solo.sh) | [`windows/run-solo.ps1`](scripts/windows/run-solo.ps1) | serve ONE model with the whole memory budget; prompts for model; has `--dry-run` | flags ported 1:1; **GPU accounting unverified** |
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
| ✅ **likely transfers** | `q8_0` KV + flash attention · MoE-over-dense · the bf16 trap · `draft-mtp` wins where generic drafts don't · quant size vs speed running backwards |
| ⚠️ **sweep, don't copy** | **`-ub 256`** — the biggest win here (+29% prefill) *and* the most architecture-specific flag in the repo: it works because a 256-row tile fits gfx1151's 32 KB of shared memory |
| ❌ **must be re-measured** | the ~109 GB ceiling (that's 96 GB carve-out **+ WDDM shared heap**) · `Total Committed` vs `Dedicated Usage` (a Windows perf-counter distinction; Linux uses `amdgpu_top` / `rocm-smi` / sysfs) · whether `--mlock` is harmful (it is on WDDM — may be *correct* on Linux) · sleep dropping VRAM · pagefile commit limits |

**Port the method, not the numbers.** Anything measured on Linux belongs in its own column in
[`docs/OPTIMIZATION.md`](docs/OPTIMIZATION.md), not merged into the Windows figures.

Also worth testing there: **ROCm may beat Vulkan on Linux** at long context and prompt processing.
The 1.79× Vulkan win recorded here is against *Ollama's* ROCm on Windows — not the same comparison
as llama.cpp's own ROCm backend.

**Contributions from a Linux box are the single most useful thing anyone could send.**

## Requirements

- **AMD Strix Halo** (Ryzen AI MAX+ 395 / Radeon 8060S, gfx1151) — most of it applies to other
  unified-memory parts, but the numbers are from this chip. Any Vulkan GPU will *run* this; only
  the tuning is chip-specific
- **Windows 11** + PowerShell 5.1 (scripts are 5.1-compatible throughout — no PS7 required), or
  bash on Linux / macOS — see [docs/INSTALL.md](docs/INSTALL.md)
- **llama.cpp Vulkan build** in `bin\` — `.\scripts\windows\fetch-llamacpp.ps1` puts it there,
  nothing to compile. Every number in this repo is from **b10431**; pin it with `-Build b10431`
  when reproducing one
- **A current GPU driver.** If the startup banner lists no Vulkan device, that is the problem —
  nothing else here works until it does
- **Docker Desktop** — only for the coding-eval sandbox
- **Python 3.12** — only for the coding eval

Memory is the real constraint: a model needs roughly its file size, plus the KV cache. The 27B
default here wants ~20 GB at a modest context.

## Contributing

Numbers are welcome, especially from **other Strix Halo boxes** or **Linux**. The one rule:
a benchmark result needs its **context depth, quant, backend and build** attached, or it can't be
compared to anything. If a run is worse than a previous one, that's still a result — say so.

## License

MIT — see [LICENSE](LICENSE).
