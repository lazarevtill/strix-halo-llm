# Adding machines over Ethernet — the design that actually helps

The Strix Halo box has 96 GB of unified memory and runs the big models well. If you own
smaller CUDA GPUs on other machines (this design was drawn for a **12 GB RTX 3060** and an
**8 GB RTX 4070**, joined by plain **Ethernet**), the question is how to make them help.

This page is a **design, not a measurement** — nothing here has been benchmarked on the
cluster yet, and it is written so the reasoning survives even if the numbers don't. Everything
in [RESULTS.md](RESULTS.md) / [BENCHMARKS.md](BENCHMARKS.md) is single-box measured; this is the
plan for going multi-box, clearly labelled as such.

## The one principle

> **Ethernet is perfect for *request* traffic and useless for *tensor* traffic.**

A streamed answer is bytes — a prompt in, tokens out. Even 1 GbE is thousands of times more
than a text stream needs, and the ~0.5 ms hop latency is nothing against generation time. But
a **KV cache** or a layer's **activations** are gigabytes that move *per token* or *per layer* —
Ethernet chokes on those.

So the whole design follows from one rule: **move requests across the wire, never model
internals.** That is also why the two "obvious" ideas are the wrong ones here:

| Tempting idea | Why it fails over Ethernet |
|---|---|
| **Cross-model KV transfer** (small model prefills, big model answers from a mapped cache — [arXiv:2608.03893](https://arxiv.org/abs/2608.03893)) | Moves GB-scale KV per request; needs a KV-ingest path llama.cpp doesn't have; and the small GPUs can't hold the 27B/35B to be the receiver anyway. Pays off only on a fast local bus (PCIe/NVLink), not Ethernet. |
| **llama.cpp RPC backend** (`ggml-rpc`, splits one model across machines) | Crosses the network **per layer, per token**. It only helps when you are *out of VRAM* (we are not — 96 GB) and have a *fast* interconnect (we do not). Over Ethernet it makes generation dramatically **slower**. |
| **Network speculative decoding** (draft model on a remote GPU) | Draft↔verify is a round-trip *per token*; network latency murders it. Keep speculation in-process (`draft-mtp`, already on). |

None of these can make a single 27B response faster over Ethernet — the 8/12 GB GPUs can't
even hold the big model to prefill it. So don't try to accelerate the big model across the
network. **Tier the workload instead.**

## Topology

```
   clients ─────►  LiteLLM proxy  :4000   (ONE OpenAI endpoint; routes by model name,
   (Open WebUI,     │   health checks, fallback, retries)
    astrolabe,      │
    your apps)      ├──Ethernet──►  Strix Halo :8080   llama.cpp Vulkan router
                    │                 • qwen38-uncensored (27B dense)
                    │                 • ornith (35B MoE)  • cyberstrike (35B MoE)
                    │                 • vision · big context · the HEAVY tier   [96 GB]
                    │
                    ├──Ethernet──►  3060 box :8080     llama.cpp CUDA
                    │                 • an 8B / 7B-coder @ Q5     → FAST tier
                    │                   (quick chat/code, sub-second first token)  [12 GB]
                    │
                    └──Ethernet──►  4070 box :8080     llama.cpp CUDA
                                      • a small 3–4B + embeddings + reranker
                                      • STT (whisper) / small VLM → UTILITY tier   [8 GB]
```

Every arrow carries JSON and an SSE token stream — nothing else. No KV, no activations, no
weights cross the wire at request time.

## Why this placement (VRAM-aware)

- **3060 (12 GB) = the fast tier.** An 8B at Q5 (~6 GB) leaves room for real context; the
  card's ~360 GB/s does roughly 40–60 t/s. Short, simple requests get answered here in a
  fraction of the time they'd spend queued behind a multi-thousand-token "thinking" generation
  on the big box. This is where most of the *felt* speedup comes from.
- **4070 (8 GB) = the utility tier.** Faster card, less VRAM — ideal for a small 3–4B plus the
  things you never want eating the Strix Halo: **embeddings, a reranker, STT, a small vision
  model.** Latency-sensitive, cheap, and better kept off the heavy box.
- **Strix Halo = the heavy tier, unchanged.** Freed from trivia and utilities, its 96 GB and the
  big models are available for what only it can do (big context, the 35B MoEs, vision).

## The router: LiteLLM

llama.cpp's own **router mode** only spawns *local* children — it cannot reach another machine.
So put a proxy in front. **LiteLLM proxy** is the clean fit: one OpenAI-compatible endpoint,
model-name → upstream-URL mapping, health checks, fallback and load-balancing. Point Open WebUI,
astrolabe and your apps at LiteLLM; it fans out to the three boxes. You also get astrolabe-style
primary/fallback *at the infra layer* for free (3060 down → transparently route to the Strix Halo).

A minimal config (secrets come from the environment — **never commit a real key**):

```yaml
# litellm.config.yaml  — one endpoint, three boxes. Names are what clients send as "model".
model_list:
  # heavy tier — the Strix Halo llama.cpp router (route by the model's own name).
  # <strix-host> / <gpu-a> / <gpu-b> are the LAN or overlay IPs of your three boxes.
  - model_name: qwen38-uncensored
    litellm_params: { model: openai/qwen38-uncensored, api_base: http://<strix-host>:8080/v1, api_key: os.environ/LLAMA_KEY }
  - model_name: ornith
    litellm_params: { model: openai/ornith,            api_base: http://<strix-host>:8080/v1, api_key: os.environ/LLAMA_KEY }
  - model_name: cyberstrike
    litellm_params: { model: openai/cyberstrike,       api_base: http://<strix-host>:8080/v1, api_key: os.environ/LLAMA_KEY }
  # fast tier — 3060
  - model_name: fast
    litellm_params: { model: openai/fast,  api_base: http://<gpu-a>:8080/v1, api_key: os.environ/LLAMA_KEY }
  # utility tier — 4070
  - model_name: embed
    litellm_params: { model: openai/embed, api_base: http://<gpu-b>:8080/v1, api_key: os.environ/LLAMA_KEY }

router_settings:
  # send "fast" to the Strix Halo big coder if the 3060 is down
  fallbacks: [{ "fast": ["qwen38-uncensored"] }]
```

Run it (if you operate an internal image mirror, pull through it rather than Docker Hub direct —
a partially-proxied build still rate-limits):

```bash
docker run -d -p 4000:4000 -v $PWD/litellm.config.yaml:/app/config.yaml \
  -e LLAMA_KEY \
  ghcr.io/berriai/litellm:main --config /app/config.yaml
```

## Serving the CUDA boxes

Keep them on **llama.cpp CUDA**, not vLLM, unless a box must serve many simultaneous users —
one mental model and the same flags/tooling as the Strix Halo stack. A CUDA llama.cpp build is
the same `llama-server`, just fetched for the CUDA release instead of Vulkan; the serving flags
carry over (`-fa on`, `-b 2048`, KV `q8_0`). **Re-sweep `-ub` on each card** — 256 is the
*measured* knee for gfx1151, not a portable constant (see the `-ub` note in BENCHMARKS.md); an
Ada/Ampere GPU will have a different optimum. Switch a box to **vLLM** only when you need its
continuous-batching concurrency.

## Routing policy — start explicit

1. **Phase 1 (do this first):** clients name the model; LiteLLM maps it to the box. Deterministic,
   debuggable, zero added latency.
2. **Phase 2 (optional):** a tiny classifier on the 4070 tags "simple vs hard" and auto-routes
   simple → 3060, hard → Strix Halo. Add only once Phase 1 is measured — it trades a little
   latency for hands-off convenience.

## What this does and does not speed up

- ✅ **System latency** — the many small requests are answered fast, never queued behind heavy
  generations.
- ✅ **Throughput** — three boxes in parallel; the heavy box is unblocked.
- ✅ **New capability** — embeddings / rerank / STT / vision without touching the Strix Halo.
- ❌ **A single 27B response is *not* faster.** That is still RAM XMP (the 7500 → 8533 BIOS fix,
  ~+14 % tg, the only lever that moves tg on this bandwidth-bound APU) plus speculative decoding
  (already on). No network topology changes it.

## Phased rollout

1. **3060 box:** llama.cpp CUDA + one fast 8B on `:8080`. Verify it serves a generation.
2. **LiteLLM** in front (Strix Halo + 3060 only at first). Point Open WebUI at LiteLLM. Measure —
   simple-query latency should drop sharply.
3. **4070 box:** add the utilities (embeddings / reranker first — highest value per GB).
4. **Then** consider the auto-classifier if you want hands-off routing.

## Guardrails

- **Never move tensors over Ethernet** — no RPC layer-split, no network KV, no network drafts.
  Requests and text only.
- **No keys in the repo.** LiteLLM keys come from the environment; the config here uses
  `os.environ/…` placeholders on purpose. If you run an internal image/package mirror, pull
  every image and model through it — a partially-proxied build still hits the public internet
  and rate-limits.
- **Re-measure `-ub` and quant choices per card** — the Strix Halo numbers are gfx1151-specific
  and do not port (the standing rule for every non-Windows tree in this repo).
