# Fleet, retrieval and memory — decisions and findings (2026-07-30)

Companion to `OPTIMIZATION.md` (which covers llama.cpp/Vulkan tuning on the main box).
This file covers the **multi-machine fleet**, and **retrieval / knowledge-base / memory layers**.

Sources: a 20-agent research sweep with an adversarial verify stage. Where the verifier overturned
the researcher, the **verifier's correction is what's recorded here** — several headline findings did
not survive checking, and that is the most useful part of the output.

---

## The fleet

| host | CPU | GPU | role |
|---|---|---|---|
| **MAIN** | Ryzen AI MAX+ 395 (Strix Halo) | Radeon 8060S gfx1151 | **THE endpoint.** One 2026 agentic coder at a time, ~109 GiB budget, Windows 11 |
| box-1 | i9 11th gen (**AVX-512**) | **RTX 3060 12GB** (Ampere sm_86) | embeddings + reranker (CUDA/FA2); the only viable fine-tuning card |
| box-2 | i9 11th gen (**AVX-512**) | — | gateway/router + monitoring; best CPU-inference candidate |
| box-3 | i9 13th gen (AVX2, DDR5) | — | **data layer**: Qdrant (+ graph if ever justified) |
| box-4 | i9 13th gen (AVX2, DDR5) | — | batch: eval/bench runners, dataset generation, indexing |
| laptop | Ultra 9 185H (AVX2, NPU) | RTX 4070 Laptop 8GB (Ada sm_89) | small fast 2026 model; opportunistic, not load-bearing |

All hosts ≥64 GB RAM + NVMe. LAN + NetBird.
**Hardware gotcha:** the *11th-gen* boxes are the AVX-512 ones (Rocket Lake was the last consumer
Intel with it; 13th gen and Meteor Lake have it fused off). But CPU token-gen is usually
**bandwidth**-bound, so the DDR5 13th-gen boxes may still out-generate the DDR4 11th-gen ones. Open
empirical question — measure before assuming.

## ⛔ Speculative decoding CANNOT be offloaded to another host
llama.cpp loads the draft model **in-process** (`--spec-type` / `--spec-draft-model`); there is no
remote-draft mode to configure. The latency budget forbids it anyway: at 63 t/s the target verifies a
token every **15.9 ms**, and a LAN round trip plus remote drafting of 3 tokens costs more than that.
**Do spec decoding locally on the main box** — but only one of the two assets actually works:
- ✅ Qwen3.5-122B's **MTP head** → `--spec-type draft-mtp` (measured +35% on the same family).
- ❌ `laguna-s-2.1-DFlash-BF16.gguf` (2.23 GB) — **no working path as of 2026-08-04.** Upstream
  b10182 lists `draft-dflash` but its tensor layout does not match poolside's
  (`expected 76 tensors, got 69`), and poolside's own fork — which builds fine and serves Ornith at
  60 t/s — OOMs loading the 89 GiB Laguna because its older ggml cannot reach the 109 GiB ceiling.
  `ngram-mod` on Laguna measured **neutral** (14.34/14.07 vs 14.17 baseline). See OPTIMIZATION.md.

---

## Retrieval: what to run

### Vector DB: Qdrant — but the reason matters less than you'd think
Run **Qdrant v1.18.3** in Docker on a **Linux CPU host** (box-3), reached over NetBird:
```bash
docker run -p 6333:6333 -p 6334:6334 -v /srv/qdrant:/qdrant/storage qdrant/qdrant:v1.18.3
```
- **Not on the main box.** Qdrant has no native Windows binary; Docker+WSL2 is the only Windows path
  and WSL2 bind-mounts have known data-loss modes. Keeping it off host A also means the vector store
  survives you freely killing llama.cpp servers — which is the normal workflow here.
- ⚠️ **The DB choice is close to a wash.** The verifier dismantled the comparison matrix that
  justified this pick (a load-bearing throughput number was attributed to a vendor blog that does not
  contain it; Chroma was excluded on a factually wrong basis). The *action* survives, the *reasoning*
  did not. Pick Qdrant for operational simplicity, then **spend your remaining effort on chunking and
  reranking, not on DB selection.**
- **Skip capacity planning entirely.** An agentic-coding corpus over real repos is ~10⁵–10⁶ chunks ≈
  **1 GB** with overhead on a 64 GB host. Run **full precision, keep full recall.** TurboQuant (the
  headline 1.18 feature) optimizes RAM on a machine that has plenty, and costs 1–2 pp recall you
  would actually feel in code retrieval. Revisit only if the corpus grows an order of magnitude.
- If you ever do quantize: TQ4 is below scalar-int8 recall on 7 of 10 of Qdrant's *own* datasets, and
  all recall figures are vendor self-reported with no third-party reproduction. Validate against fp32
  on your own repo corpus with a golden set first.

### Graph DB: only if something specific justifies it
- ⛔ **KuzuDB is DEAD.** Repo archived (`archived: true`, last push 2025-10-10); team reportedly
  acquired by Apple. Downstream confirmation: Graphiti marks its Kuzu backend DEPRECATED as
  "upstream project unmaintained". **Do not start anything on Kuzu.** The live community fork is
  **LadybugDB** (MIT, 1.5k stars, pushed 2026-07-29, embedded, runs natively on Windows) — young, so
  accept the bus-factor risk.
- **Licensing:** Memgraph and ArangoDB are BSL 1.1; FalkorDB is SSPL v1. None is OSI-approved.
  OSI-clean options: **Apache AGE** (Apache-2.0 — a Postgres extension, so *one* host gives you
  graph **and** vectors in one process), Neo4j Community (GPL-3.0), Oxigraph, NetworkX, LadybugDB.
  Practical note: SSPL/BSL only bite if you offer the software as a service to third parties — for
  solo LAN self-hosting they are operationally unencumbered. It's a future-proofing question.

### ⛔ GraphRAG is not worth it for agentic coding on this hardware
The verifier made this verdict **stronger**, not weaker. Two independent disqualifiers:
1. **Per-query cost, forever.** Global search fans out **one LLM call per 12k-token context chunk on
   every query**, then a reduce — confirmed in `global_search/search.py` (`asyncio.gather` over
   `context_chunks`). Its own concurrency (`Semaphore(32)`, `concurrent_requests=25`) buys nothing on
   a box serving one model on one GPU: it's the same total prefill queued against the same device.
   No partial results during the map phase. The official mitigation (dynamic community selection)
   *rates communities with the LLM first* — it adds calls to remove calls.
2. **The index is not one-time on a repo that changes.** Entity extraction runs per 1200-token unit
   (up to 2 passes), plus per-entity description summarization, plus per-community reports across the
   hierarchy. Estimated **~12.6M prefill + ~2.5M generated tokens per 1M source tokens (~4 MB)** =
   **~4 h batched / ~14 h single-stream** on this box, and it recurs on every commit. Cross-check:
   Microsoft's own 1M-token dataset took 4.7 h on GPT-4-turbo at concurrency 25 — same ballpark.
   The binding constraint is **generation (63 t/s)**, not prefill.

**Verdict:** never in an interactive/agentic loop. If evaluated at all: frozen corpus (docs, specs)
only, **local search only**, index as an overnight batch job. Before committing to anything of this
shape, measure your own `--parallel 8` aggregate generation throughput — it is the one number that
decides feasibility and takes ten minutes to get.

---

## Memory layers

- ⛔ **Letta (ex-MemGPT) OSS server is DEPRECATED.** README states the legacy server "is no longer
  actively developed"; 4 commits since 2026-05-01, last PyPI release 0.16.8 on 2026-05-14. Work moved
  to `letta-ai/letta-code` (Apache-2.0, pushed daily). **Every 2026 "Mem0 vs Zep vs Letta" comparison
  article missed this** — the widely-quoted "~83% LoCoMo" figure refers to a codebase now in
  maintenance. Do not adopt it as a memory backend.
- ✅ **Mem0 runs fully offline against llama.cpp :8080** — verified in source, both LLM and embedder
  (`mem0/llms/openai.py` and `mem0/embeddings/openai.py` both honour `openai_base_url` /
  `OPENAI_BASE_URL`; the factory also registers explicit local providers). Back it with the Qdrant
  above.
  ⚠️ **It ships telemetry** (`notices.py`, `mem0.notice_displayed` with A/B variants). **Disable it**
  before anything touches EHR-adjacent data.

---

---

## ⚠️ Benchmark epistemics — read before trusting any model ranking

**The single most important finding of the whole sweep.** On **SWE-rebench** (decontaminated, fresh
tasks, window 15/05–01/07/2026 — the only *live* agentic board):

| model | SWE-rebench Resolved | that family's self-reported SWE-bench Verified |
|---|---|---|
| Qwen3.5-35B-A3B | **17.1%** | **70%** |
| Qwen3.6-35B-A3B | 24.7% | — |
| Qwen3.6-27B (dense) | **31.2%** | — |
| GLM-5.2 (753B) | **62.9%** (top open-weights, Pass@5 81.1% — highest on the board) | — |

**Fresh uncontaminated tasks collapse A3B-class scores by ~4x.** Treat every self-reported
SWE-bench number for a small MoE as heavily contamination-inflated.

**Ornith-1.0-35B is absent from tbench.ai, SWE-rebench and Artificial Analysis entirely** — every
number for it is self-reported, and two of the figures previously in our own `README.md` were wrong
(see the correction there). So **"Ornith-tier or better" is not a usable selection bar.** Re-anchor to
SWE-rebench, or better, to **our own measured suites** — local measurement beats published claims.

✅ **Settled by measurement 2026-08-04 (see `BENCHMARKS.md`).** Ornith-1.0-35B Q5_K_M, Laguna-S-2.1
Q4_K_M and Qwen3.5-122B-A10B Q4_K_XL were scored head-to-head on two private uncontaminated suites:
**all three tie** — tool calling 28/28/27 of 29 (every CI overlapping, McNemar p = 1.0), agentic
coding 70/70 each. Laguna's published +5.8-point Terminal-Bench lead over Ornith produced **no
measurable advantage**, at 3.9x the size and 4x the wall-clock.

Two lessons for picking models for the rest of the fleet:
1. **Published deltas of this magnitude do not survive contact with a private suite.** Select on
   size and speed, and verify quality locally before believing a leaderboard gap.
2. **Small suites cannot rank close models.** n=29 cases and an effective n=4 coding tasks can only
   catch a *bad* model; a single test flipped between identical temperature-0 runs. Do not quote an
   ordering off these numbers — `BENCHMARKS.md` explains what it would take to earn one.

⚠️ **Methodology warning worth internalizing:** a text-summarizing page fetch *invented* an
"Open-weights/Proprietary" column on SWE-rebench that does not exist, which made open-weights look
capped at 31.2% instead of 62.9% — a **31.7-point inversion** that would have driven the wrong
decision. Re-render leaderboards in a real browser before acting on them.

## Fleet verdicts

### CPU hosts: batch only, never interactive
**MEASURED** (Mellum2-12B-A2.5B Q4_K_M, CPU, 16 threads): pp512 483.6, pp4096 411.9,
**pp16384 325.1 t/s**. At 325 t/s a 16k context costs **~50 s time-to-first-token**, and 30k costs
~100 s — *before the first token*. Agentic coding is the worst case because every tool result
reinjects the conversation, so you pay that TTFT **every turn**. And that's the *fastest* CPU tier
running a *small* A2.5B model.
→ Tier-D hosts get **batch roles only**: overnight embedding/summarization backfills, eval harness
runs, dataset generation. Never behind an interactive coding agent.
⚠️ Also learned: **`-ngl 0` does NOT force CPU-only** — op-offload is on by default (`-nopo` defaults
to 0) and the results table still prints `backend Vulkan`. Use **`--device none`** for a true CPU
measurement.

### Gateway: llama-swap with `peers` — no LiteLLM needed
llama-swap gained a **`peers`** block that federates to remote hosts, giving **one
OpenAI-compatible URL** that routes by model name across the fleet, with per-host on-demand load and
idle unload. This supersedes older community guidance (discussion #326) that said remote proxying
wasn't supported. `winget install llama-swap` on Windows; Docker images (cuda/cpu/vulkan) for Linux.

```yaml
healthCheckTimeout: 900        # NOT the default 120 -- 60-90 s model loads will abort
startPort: 10001
peers:
  gpu3060:
    proxy: http://<host-a>:8080
    models: ["embed-host", "rerank-host"]
    timeouts:
      connect: 30
      keepalive: 300
      responseHeader: 900     # CRITICAL -- default 60 aborts cold loads
      idleConn: 300
  gpu4070:
    proxy: http://<host-b>:8080
    models: ["small-fast"]
    timeouts: { connect: 30, keepalive: 300, responseHeader: 900, idleConn: 300 }
```
⚠️ Peer models appear in `/v1/models` as `peer-id/model-id`; **some coding clients choke on slashes**
— declare local `aliases` for the names you actually type if so.

### RPC: capable, but that isn't the same as advisable
Heterogeneous **AMD-Vulkan + NVIDIA-CUDA over llama.cpp RPC is genuinely supported** —
`rpc-server.cpp get_devices()` is backend-agnostic (accepts any non-CPU device), `--rpc` registers
remotes as ordinary ggml devices, and release CI sets `GGML_RPC=ON` for **all** artifacts including
`win-vulkan-x64`. So **`rpc-server.exe` already ships in your b10182** — no rebuild to experiment.
Caveats: all nodes must run the same commit (protocol `RPC server v3.0.0`), and the low-latency RDMA
transport is Linux + RoCEv2-NIC only, so unavailable to the Windows main box.

### 12 GB card: run a BIG MoE with expert offload, not a small model
**GLM-4.7-Flash 31B-A3B** (zai-org, Jan 2026, MIT, `glm4_moe_lite`) at **UD-Q4_K_XL (16.32 GiB)** with
llama.cpp CUDA `--n-cpu-moe`. Only 4 of 64 routed experts are active per token, so routed experts live
in system RAM while attention + shared expert + MLA KV stay on GPU (~3–4 GiB). This beats picking a
smaller model that fits, and avoids quality-destroying IQ2/IQ3.
⚠️ Needs llama.cpp **newer than the 2026-01-21 `scoring_func` softmax→sigmoid fix** — re-download the
GGUF if you pulled it before that date, or outputs are degraded.

### Fine-tuning ceilings (Unsloth's own table — SELF-REPORTED)
QLoRA 4-bit / LoRA bf16: 3B 3.5/8 · 7B 5/19 · 8B 6/22 · 9B 6.5/24 · 11B 7.5/29 · **14B 8.5/33** ·
27B 22/64 · 32B 26/76 GB.
→ **12 GB: QLoRA up to ~14B; bf16 LoRA capped at ~3B. 8 GB: QLoRA ~9–11B.**
⚠️ The table encodes **no sequence length**, so it cannot answer 2k/8k/32k. And **derate ~1.5 GB for
WDDM + display** on Windows (12 GB → ~10.5 usable, 8 GB → ~6.5).

---

## ⭐ Fine-tuning on the 8060S: it ALREADY WORKS on native Windows (VERIFIED 2026-07-30)

The `ornith-router\finetune\README.md` table calls the AMD-iGPU path *"experimental: torch-directml
or ROCm-on-WSL"*. **That is stale — this box already has working native-Windows ROCm PyTorch on
gfx1151.** Independently confirmed on the machine:
```
torch 2.9.1+rocmsdk20260116 | hip 7.2.26024-f6f897bd3d | arch gfx1151
total_memory 110456 MB | bf16_supported True | multi_processor_count 20
```
No DirectML, no WSL, no dual-boot. It's a TheRock (`rocm-sdk 7.2.0.dev0`) build.
Note **110456 MB = 107.9 GiB** — an independent corroboration of the ~109 GiB ceiling measured via
Vulkan, from a completely different code path.
⚠️ Nuance: *official* AMD Windows ROCm covers only gfx1200/1201 (RDNA4); this working gfx1151 stack is
via community/nightly TheRock wheels. It works, it's just not on AMD's support matrix.
⚠️ **Do NOT `pip upgrade` this torch in place.** It's a Jan 2026 nightly (~6 months stale) but it
demonstrably works and already has AOTriton. Build a separate venv to try anything newer.

### ⭐ The single highest-value one-liner found in the entire sweep
```
TORCH_ROCM_AOTRITON_ENABLE_EXPERIMENTAL=1
```
**SET PERMANENTLY as a User env var on 2026-07-30.** Faster attention, measured twice:

| measurement | AOTriton on | off | speedup |
|---|---|---|---|
| research agent (quiet box) | 1.90 ms/call | 22.19 ms | **11.7x** |
| **my own re-measurement (box under load)** | **4.27 ms/call** | **25.19 ms** | **5.9x** |

Same SDPA shape (4,16,1024,64) bf16, 50 iterations after warmup. **Trust the 5.9x** — it's the
conservative figure and was taken under realistic load; either way the effect is large and free.
It unlocks the real backends (FLASH_ATTENTION ~1.95 ms, EFFICIENT_ATTENTION ~1.99 ms) instead of the
MATH fallback. Without it PyTorch *silently* falls back to math while printing a warning to stderr.
Directionally corroborates the ~19x reported in ROCm issue #6034 for gfx1151.
- **AOTriton ≠ standalone Triton.** AOTriton (kernels precompiled into the torch wheel) works here;
  standalone Triton does not. Don't conflate them.
- Leave **`PYTORCH_HIP_ALLOC_CONF` unset** — ROCm #6034 reports `backend:malloc` crashing PyTorch.
- **`HSA_OVERRIDE_GFX_VERSION` is NOT needed** anymore; ignore older guides that set it.

If you want a *fresh* stack instead, AMD's official stable wheels for gfx1151 on Windows are
ROCm 7.2.1 / torch 2.9.1, **Python 3.12 only** (you have 3.12), installed from explicit
`repo.radeon.com/rocm/windows/rocm-rel-7.2.1/...whl` URLs — not an index URL. Newer channels:
`--index-url https://repo.amd.com/rocm/whl/gfx1151/` (ROCm 7.9 preview) and
`https://rocm.nightlies.amd.com/v2/gfx1151/`. Use `--no-cache-dir`; on Windows pip will otherwise
happily replace ROCm wheels with CPU-only ones from PyPI. Docs live under **`installryz`** (Ryzen APU)
— the `installrad` pages are gfx1201-only and will mislead you.

### torch-directml is dead — and it's a dependency-level dead end
Microsoft's repo header says verbatim *"⚠️DirectML is in maintenance mode ⚠️"*, no new features, and
the latest PyPI release is `0.2.5.dev240914` (2024-09-15, ~22 months stale). The killer for the
fine-tune pipeline is not performance: it **hard-pins `torch==2.4.1`** (MS Learn says it supports up to
2.3.1, and scopes it to *inferencing*). A 2026 TRL/transformers stack cannot coexist with that pin.

## Open / not yet answered
Four other research streams are still running: fine-tuning on gfx1151, best local coding-agent
harness, the 2026 leaderboard sweep, and fleet/CPU-inference + embeddings model picks. Those will
determine the embeddings/reranker model choices and the CPU-host inference verdict.
