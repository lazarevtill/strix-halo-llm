# strix-halo-llm

llama.cpp **Vulkan** tuning and a private evaluation harness for **AMD Ryzen AI MAX+ 395
"Strix Halo"** (Radeon 8060S / gfx1151) with 128 GB unified LPDDR5X.

Everything here is measured on the box, not predicted from model cards. Where a published claim did
not survive measurement, both the claim and the refutation are kept — that contrast is the useful
part.

llama.cpp build **b10182** win-vulkan-x64. Vulkan device: AMD Radeon 8060S, driver 26.6.2,
`KHR_coopmat`, `uma:1 fp16:1 bf16:1`.

---

## Headline findings

**The usable memory ceiling is ~109 GB, not the 96 GB BIOS carve-out.** 96 GB dedicated + ~13.4 GB
of WDDM shared heap, and token generation is *flat* from 89 GB to 109 GB — spilling past the
carve-out costs nothing on a UMA APU. Measure with `Total Committed`, never `Dedicated Usage`.

**Three models tie on quality; pick on cost.** Measured 2026-08-04, each the sole GPU occupant at
`ctx=131072`, on two private uncontaminated suites:

| model | tool calling | 95% CI | agentic coding | turn 1 | truncations | tg | size |
|---|---|---|---|---|---|---|---|
| **Ornith-1.0-35B Q5_K_M** | 28/29 = 96.6% | [82.8, 99.4] | **70/70** | 45/45 | 1 | **~58 t/s** | **23 GB** |
| Qwen3.5-122B-A10B Q4_K_XL | 28/29 = 96.6% | [82.8, 99.4] | **70/70** | 45/45 | 3 | ~34 t/s | 78 GB |
| Laguna-S-2.1 Q4_K_M | 27/29 = 93.1% | [78.0, 98.1] | **70/70** | 45/45 | 1 | ~14 t/s | 89 GB |

All three: 4/4 tasks, **zero regressions**, perfect turn 1. Every CI overlaps and McNemar exact is
**p = 1.0** — so this is a three-way tie, not a ranking. **Ornith-1.0-35B Q5_K_M is the default**:
same measured quality at a quarter of the size and 4x the throughput. Laguna's published
Terminal-Bench 2.1 lead (70.2 vs 64.4) produced no measurable advantage here.

> ⚠️ **Do not read an ordering into those scores.** n=29 tool cases and an *effective* n=4 coding
> tasks (tests cluster inside tasks) can catch a bad model but cannot rank close ones — a single
> test flipped between two identical temperature-0 runs. Ranking frontier-tier models would need
> ~100 paired cases and ~10 tasks. See [docs/BENCHMARKS.md](docs/BENCHMARKS.md).

**bf16 is a trap on this box:** 11.17 t/s, **5.6x slower** than Q5_K_M, and prompt processing
collapses too (241 vs 698). A bigger Ornith is a bigger *quant*, not a better model.

---

## Quick start

```powershell
# Serve the recommended model: whole memory budget, full 262144 context
.\scripts\run-solo.ps1
#  -> Web UI:     http://127.0.0.1:8080
#  -> OpenAI API: http://127.0.0.1:8080/v1/chat/completions

# A bigger model instead (one at a time -- run-solo stops any other server first)
.\scripts\run-solo.ps1 -Model .\models\Qwen3.5-122B-A10B-UD-Q4_K_XL-00001-of-00003.gguf -Ctx 131072 -Spec draft-mtp

# Fetch models (resume-capable, verifies byte counts against the HF API)
.\scripts\fetch-models.ps1 -List
.\scripts\fetch-models.ps1 -Only qwen122b

# Benchmark at real context depths, not just depth 0
.\scripts\bench-big.ps1

# Score a model on the private eval suites (smoke-gated)
.\evals\run-guarded.ps1 -Models ornith-q5
```

Claude Code and Codex can point **straight at this server** — no shim. See
[docs/OPTIMIZATION.md](docs/OPTIMIZATION.md).

---

## Layout

```
strix-halo-llm/
├── README.md               you are here
├── LICENSE                 MIT
├── CLAUDE.md               working notes for coding agents on this box
│
├── docs/
│   ├── OPTIMIZATION.md     ⭐ the tuning playbook + full model comparison
│   ├── BENCHMARKS.md       ⭐ what/how to benchmark, how to read it, how not to fool yourself
│   ├── FLEET.md            multi-machine roles, retrieval / memory-layer findings
│   └── PUBLISHING.md       what is safe to publish, and what must never be
│
├── scripts/
│   ├── run-solo.ps1        ⭐ serve ONE model with the whole ~109 GB budget
│   ├── fetch-models.ps1    resume-capable downloader, verifies byte counts
│   ├── download-model.ps1  fetch a single GGUF
│   ├── bench-big.ps1       depth-aware benchmark (llama-bench -d)
│   ├── bench-spec.ps1      A/B baseline vs speculative decoding
│   ├── build-poolside.ps1  build poolside's llama.cpp fork (DFlash)
│   ├── reclaim-ollama.ps1  reclaim disk from Ollama blobs (dry-run by default)
│   └── legacy/             superseded multi-model launchers (:8082-:8088 stack)
│
├── evals/                  ⭐ the private eval harness -- see evals/README.md
│   ├── run-guarded.ps1     run suites across models: smoke-gated, respawn-proof
│   ├── run-model-suite.ps1 serve ONE model solo + run both suites
│   ├── run-tools-eval.ps1  native tool-calling eval (29 cases)
│   ├── tools/tools.json    the 10 tool schemas (public)
│   └── code/
│       ├── run-code-eval.py   agentic coding eval (4 tasks x 3 turns, hidden pytest)
│       ├── smoke.py           harness self-test -- gates every run
│       └── Dockerfile.sandbox no network, 512 MB, 1 CPU, read-only
│
└── archive/coding-eval/    superseded first-gen eval (LRU-cache task; kept for history)
```

Local-only, never committed: `models/` (~640 GB of GGUF), `bin*/` (llama.cpp binaries), logs,
benchmark dumps, eval results.

---

## The eval suites, and why the cases are not here

**The harness is public. The answers are not.** These suites are trustworthy precisely because no
model has trained on them — on decontaminated SWE-rebench, A3B-class models score **~4x below**
their self-reported SWE-bench numbers, and that gap is benchmark leakage. Publishing the cases would
put them in the next crawl and retroactively devalue every number here, irreversibly.

So `evals/tools/cases.jsonl`, `evals/code/tasks.json`, `evals/code/tests/` and
`evals/code/reference/` are gitignored. [docs/BENCHMARKS.md](docs/BENCHMARKS.md) documents exactly
what they contain — category counts, what each isolates, what each coding task is — and
[docs/PUBLISHING.md](docs/PUBLISHING.md) shows the file shapes so you can author your own.

**Run the self-test before trusting any number:**

```powershell
docker build -f evals\code\Dockerfile.sandbox -t llm-eval-sandbox evals\code
python evals\code\smoke.py
```

It asserts the sandbox distinguishes good code from bad, that prose is not mistaken for code, and
that **every task prompt is satisfiable by a reference solution**. That last check matters: a turn-3
prompt here once asked for a spend to succeed while its own hidden test asserted it fails — it
silently rewarded *ignoring the user*, and any model that engaged with the contradiction scored 0.

Six harness bugs produced six believable-but-wrong figures during development (`17.2%`,
`"34/34 = 100%"`, `92.2%`, `44.3%`, `"first-shot 64.3%"`). Each is documented with the fake number
it produced in [evals/README.md](evals/README.md) — that list is arguably more reusable than the
harness itself.

---

## Requirements

- Windows 11, PowerShell 5.1 (scripts use 5.1-compatible syntax throughout)
- llama.cpp Vulkan build in `bin\`
- Docker Desktop (coding eval sandbox only)
- Python 3.12 (coding eval only)

## License

MIT — see [LICENSE](LICENSE).
