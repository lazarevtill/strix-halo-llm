# Image generation — what this box serves since 2026-10-15

On 2026-10-15 the box switched from serving an LLM to serving **images**: text-to-image and image
editing, over an OpenAI-compatible API on the same `:8080`. Everything below was measured on this box
(Radeon 8060S / gfx1151, Windows 11, AMD driver 26.9.2) unless marked otherwise.

## What runs

| | |
|---|---|
| model | **Qwen-Image-2.1 Turbo**, Q8_0 GGUF (`unsloth/Qwen-Image-2.1-Turbo-GGUF`, 7.64 GB) — 8 steps, CFG 1 |
| text encoder | Qwen3-VL-8B-Instruct, F16 GGUF (16.4 GB) + its vision mmproj (1.16 GB, needed for edits) |
| VAE | `qwen_image_2.1_vae_bf16.safetensors` (0.68 GB) — not interchangeable with Qwen-Image / Wan VAEs |
| engine | [stable-diffusion.cpp](https://github.com/leejet/stable-diffusion.cpp) `master-967-e47426c`, prebuilt Windows **Vulkan** `sd-server.exe` |
| memory | 23.5 GB of weights, **all on the GPU, 0 MB in system RAM** |
| launcher | `scripts/windows/run-images.ps1 -Model turbo-q8` — supervised (restarts sd-server if it exits) |
| licence | **Qwen Research licence — non-commercial.** For commercial use, Z-Image Turbo (Apache-2.0) is the alternative |

Why this model: as of 2026-10-15 Qwen-Image-2.1 is **#1 among open-weight models on the
[Artificial Analysis](https://artificialanalysis.ai/image/leaderboard/text-to-image/open-weights)
boards for both text-to-image (ELO 1041) and editing (1074)** — one model does both. It is also small
(7.1B diffusion transformer + 8B encoder), so the freed memory buys precision, not size. FLUX.2 dev
(32B) fits too but ranks lower and is slower; HunyuanImage 3.0 has no stable-diffusion.cpp support.

Why stable-diffusion.cpp and not ComfyUI: one binary with OpenAI `generations` + `edits` built in, the
Vulkan driver this repo already trusts, and weights loaded tensor-by-tensor **straight to the GPU**.
PyTorch runtimes (ComfyUI, Lemonade's TheNoise) are likely 2-3x faster on ROCm, but ComfyUI has no
OpenAI API and stages weights through system RAM — and only ~32 GB is visible to Windows here, often
<10 GB free. A ROCm runtime is the obvious next A/B, not a settled loss.

## API

```
POST /v1/images/generations   {"prompt": "...", "n": 1, "size": "1024x1024", "output_format": "png"}
                              -> {"data": [{"b64_json": "..."}]}
POST /v1/images/edits         multipart: prompt, image[] (1+ reference images), optional mask, size
GET  /v1/models               one id, "sd-cpp-local" (the request's "model" field is ignored)
GET  /                        built-in web UI
```

Native controls ride inside the prompt:
`... <sd_cpp_extra_args>{"seed": 42, "sample_params": {"sample_steps": 8}}</sd_cpp_extra_args>`.

> **Known crash (measured): never put `<sd_cpp_extra_args>` in an EDIT request.** On master-967 it
> aborts the whole server (`0xc0000409`) — the same block is fine on `/generations`. Bisected
> 2026-10-15: plain edits, the legacy `image` field and `output_format` all work; only the extra-args
> block crashes it. The launcher's restart loop brings the server back in ~13 s. Not yet reported upstream.

No authentication. `:8080` is reachable from the LAN through the existing firewall rule.

## Measured speed

All Turbo runs are 8 steps, CFG 1, seed fixed. "Sampling" is the denoising loop; totals add text
encoding (~7-15 s on a new prompt, cached on repeats) and the VAE decode.

**Weight format matters more than anything else on this Vulkan driver** (512x512, LLM still resident):

| diffusion weights | sampling | note |
|---|---|---|
| bf16 safetensors | 46.0 s | flash attention auto-probed *off* |
| bf16, `--flash-attn on` | 55.7 s | slower — keep `auto` |
| bf16 converted at load (`--type f16`) | 40.5 s | |
| **Q8_0 GGUF** | **33.8 s** | ← served |

**At 1024x1024** (the size that matters):

| | sampling | total |
|---|---|---|
| Turbo bf16 | 175.6 s (22 s/step) | 215.7 s |
| **Turbo Q8_0** | **73.5 s (9.2 s/step)** | **109.0 s** |
| Turbo Q8_0, served, called over the LAN | — | **107.5 s** |
| edit, Turbo Q8_0, 1024² (server) | — | **123 s** |
| Base (non-Turbo) Q8_0, CFG 6 | 17.4 s/step | **~12 min** for its 40 steps (extrapolated from 4) |

Q8_0 and bf16 produce visually indistinguishable images at the same seed (compared side by side), so
the 2.4x speedup is free. The base model's 40 steps with real CFG (two passes per step) make it too
slow for an always-on API; it stays available as `-Model base-q8` / `-Model base`.

With the LLM stopped, a 512x512 Turbo-Q8 image took **32 s** end to end, vs 53.9 s for the same
weights while the LLM was resident. The cause is not isolated: the later run also had `--max-vram 90`
and a different prompt, so treat "the idle LLM cost ~40%" as a hypothesis, not a measurement.

**Correctness:** the same prompt and seed produce a byte-identical PNG (512x512, two runs). Caveat:
`--flash-attn auto` re-probes at every start and has flipped between on and off across restarts, so
the *same seed can give a different image after a restart*. Pin `--flash-attn` if reproducibility
across restarts matters.

**Why Vulkan is slow here:** at ~9 s/step for a 7B transformer at 1024² the sampler sustains a few
TFLOPS — in line with llama.cpp's own prefill on this box (~7 TFLOPS), and far below the ~2.4 s/step
a Linux ROCm/PyTorch run reported for the same model (INT8, not measured here). The Vulkan matmul path
on this driver, not the model, is the limit.

## Operating it

```powershell
.\scripts\windows\run-images.ps1 -Model turbo-q8        # what the Startup launcher runs (port 8080)
.\scripts\windows\run-images.ps1 -Model base-q8         # best quality, ~12 min per 1024^2 image
.\scripts\windows\run-images.ps1 -DryRun                # print the sd-server command line
.\scripts\windows\fetch-models.ps1 -Only qwen-image-21-turbo-q8,qwen-image-21-te,qwen-image-21
```

Logs: `logs\images-<timestamp>.err/.out` (newest 10 kept). The launcher restarts sd-server on exit
(~13 s back, measured by killing it). After more than 5 exits in an hour it **backs off 15 minutes and
tries again** rather than giving up: a client can crash the server on demand (the edits bug above), and
a hard stop would leave `:8080` dead until the next logon with nothing watching.

- **Client timeouts must be 3+ minutes.** A 1024² generation takes ~108 s and an edit ~123 s; many
  OpenAI clients default to 60 s and will report a failure for a request that is still running.
- **Concurrent requests queue** (measured: two simultaneous 512² requests returned after 14 s and 28 s,
  same server process). There is one sampler; throughput does not scale with clients.
- **Freezes are not detected.** The restart loop only catches the process *exiting*. The LLM side
  needed a watchdog for a deadlocked child; sd-server has none yet — if requests hang with the GPU
  idle, kill `sd-server.exe` and the loop will restart it.

**Rollback to the LLM:** the Startup launcher keeps the three LLM lines (router, metrics exporter,
watchdog) commented out with a `rem ROLLBACK-LLM:` prefix. Uncomment them and comment out the
`run-images.ps1` line. Both cannot share `:8080`.

**Lost by the switch:** any app calling `/v1/chat/completions` on `:8080` now gets an error — there is
no text model on this box any more. The LLM's metrics exporter (`:9114`) and watchdog are off.
