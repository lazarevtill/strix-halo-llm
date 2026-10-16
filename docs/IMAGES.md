# Images and video — measured numbers (since 2026-10-15)

Since 2026-10-15 the box's `:8080` serves image generation (and since 2026-10-16 video) instead of an LLM.
**The serving code and how it works are private.** This page publishes only **measurements** and the
**configs** they came from: the model registry [`scripts/windows/image-models.json`](../scripts/windows/image-models.json)
(files, engine flags and defaults per model) and the download labels in
[`scripts/windows/fetch-models.ps1`](../scripts/windows/fetch-models.ps1).

Every number was measured on this box — Radeon 8060S (gfx1151), Windows 11, AMD driver 26.9.2 — with
**stable-diffusion.cpp master-967-e47426c** (prebuilt Windows Vulkan release; FLUX.3 needs
**master-968-8cd731e**), weights pinned to the GPU (`--backend vulkan0 --params-backend vulkan0`,
`--eager-load`, 0 MB in system RAM), `--flash-attn auto` (video models pinned `on`), `--vae-tiling`.

## Image models

| model (registry id) | memory (measured) | speed at 1024² (measured) | licence |
|---|---|---|---|
| Qwen-Image 2.1 Turbo Q8_0 (`qwen-image-2.1-turbo`), 8 steps, CFG 1 | 23.5 GB | ~1.5–1.8 min; edit ~2 min | Qwen Research — **non-commercial** |
| Qwen-Image 2.1 full Q8_0 (`qwen-image-2.1`), 40 steps, CFG 6 | 23.5 GB | ~12 min (extrapolated from 4 steps) | non-commercial |
| FLUX.3 Image Klein Q8_0 (`flux3-klein`), 16 steps, CFG 1 | 10.0 GB | **76 s**; edit with one reference 175 s | FLUX Kommunity License — free commercial use under $5M revenue |
| Z-Image Turbo Q8_0 (`z-image-turbo`), 8 steps, CFG 1 | 10.5 GB | **~53 s**; 512² in 12 s | Apache-2.0 |
| Kroma Q8_0 (`kroma`, Krea 2 family), 10 steps, CFG 1 | 17.3 GB | ~2–2.5 min (12.6 s/step) | MIT + Krea 2 Community License |
| Anima Turbo Q8_0 (`anima`), 10 steps, CFG 1 | 3.5 GB | **44 s**; 512² in 9 s | CircleStone non-commercial + NVIDIA Open Model License |
| WAI-illustrious-SDXL v17 (SDXL), 28 steps, CFG 6 | 6.6 GB | **57 s** | CivitAI model licence |

## Video models

| model (registry id) | memory | measured | licence |
|---|---|---|---|
| Wan 2.2 TI2V-5B Turbo Q8_0 (`wan22-ti2v-turbo`), 4 steps | 11–12 GB | 1280×704 × 49 frames: **92 s**; 896×512 × 25 frames (image→video): **20 s** | Apache-2.0 |
| Wan 2.2 I2V-A14B, lightx2v 4-step (`wan22-i2v-a14b`) | 35.4 GB | 832×480 × 49 frames: **565 s** (190 s per expert + 126 s decode) | Apache-2.0 |
| LTX-2.3 distilled 1.1 Q8_0 + Gemma 3 12B Q8_0 (`ltx23`), 8 steps, CFG 1 | 38.4 GB | 768×512 × 49 frames **with sound: 191 s** (99 s sampling, 75 s video decode, 3 s audio); image→video 768×448 × 25 frames: **86 s** | LTX-2 Community License (free under $10M revenue) + Gemma terms |

## Weight format matters most on this Vulkan driver

512×512, Qwen-Image 2.1 Turbo, LLM still resident:

| diffusion weights | sampling | note |
|---|---|---|
| bf16 safetensors | 46.0 s | flash attention auto-probed *off* |
| bf16, `--flash-attn on` | 55.7 s | slower — keep `auto` |
| bf16 converted at load (`--type f16`) | 40.5 s | |
| **Q8_0 GGUF** | **33.8 s** | ← served |

At 1024×1024:

| | sampling | total |
|---|---|---|
| Turbo bf16 | 175.6 s (22 s/step) | 215.7 s |
| **Turbo Q8_0** | **73.5 s (9.2 s/step)** | **109.0 s** |
| Turbo Q8_0, called over the LAN | — | **107.5 s** |
| edit, Turbo Q8_0 | — | **123 s** |
| Base (non-Turbo) Q8_0, CFG 6 | 17.4 s/step | **~12 min** for 40 steps (extrapolated from 4) |
| FLUX.3 Image Klein Q8_0, 16 steps (master-968) | 66.6 s (4.2 s/step) | **74–78 s**; edit 175 s; 736² 35 s |
| Kroma Q8_0, 10 steps (first call) | 125.8 s (12.6 s/step) | 152 s; 1344×768 120 s; 512² ~27 s |
| WAI-illustrious-SDXL v17, 28 steps, CFG 6 | 48.5 s (1.73 s/step) | **57 s** |
| Anima Turbo Q8_0, 10 steps | — | **44 s**; 1344×768 37 s; 512² 9 s |
| Z-Image Turbo Q8_0, 8 steps | 44.7 s (5.5 s/step) | **52–54 s**; 1344×768 53 s; 512² 12 s (1.15 s/step) |

Q8_0 and bf16 gave visually indistinguishable images at the same seed, so the 2.4× is free. With the LLM
stopped, a 512² Turbo-Q8 image took **32 s** end to end vs 53.9 s while it was resident (cause not
isolated — a hypothesis, not a finding).

## Video: the decoder is the bottleneck

Wan 2.2 TI2V-5B Turbo, 1280×704, 49 frames, 4 steps (sampling **68 s**, 17 s/step):

| decoder | decode | total | note |
|---|---|---|---|
| full Wan 2.2 VAE, untiled | 897 s | 972 s | one buffer exceeded the driver's per-allocation limit and fell back to a slow path |
| full Wan 2.2 VAE, tiled + temporal tiling | ~630 s | 705 s | |
| **TAEHV `taew2_2` (tiny decoder)** | ~20 s | **92 s** | ← served; slightly softer at a 100% crop |

At 640×352 × 25 frames: full VAE untiled 35 s, tiled 65–73 s. The A14B's Wan 2.1 VAE: 126 s tiled for
832×480 × 49 frames.

## Other measurements

- **Residency:** three image models loaded at once (Qwen Turbo + Kroma + Anima) = **44.4 GB committed**.
- **4× ESRGAN upscale:** 832×1216 → 3328×4864 in **40 s** (RealESRGAN x4plus anime 6B).
- **Face repaint (YOLOv8 face detector + inpaint):** **76 s** on the SDXL model, including loading a second copy.
- **Determinism:** same seed → byte-identical PNG on every image model (two runs each). Caveat: `--flash-attn
  auto` re-probes at every start and has flipped between on and off across restarts, so the same seed *can*
  differ after a restart; the video models pin `on`.
- **SDXL IP-Adapter:** the *Plus* ViT-H adapter washed colours to near-greyscale (strengths 0.35–0.7, CFG 6);
  the plain `ip-adapter_sdxl_vit-h` kept full colour. +0.7 GB with the CLIP-Vision encoder resident.
- **Why Vulkan is slow here:** ~9 s/step for a 7B transformer at 1024² is a few TFLOPS — in line with
  llama.cpp's own prefill on this box (~7 TFLOPS) and far below the ~2.4 s/step a Linux ROCm/PyTorch run
  reported for the same model (INT8, not measured here). A ROCm A/B is the open question.
- **System RAM:** the backends use none, but Windows sees only ~32 GB; WSL / Docker Desktop (`vmmemWSL`)
  grew to 14 GB of it during one model load and free RAM briefly hit ~0.

## Fetching the weights

```powershell
.\scripts\windows\fetch-models.ps1 -Only qwen-image-21-turbo-q8,qwen-image-21-te,z-image-turbo,z-image-te,flux-ae,kroma,kroma-te,wan21-vae,anima,anima-te
.\scripts\windows\fetch-models.ps1 -Only flux3-klein,flux2-vae,wan22-ti2v-turbo,wan-umt5,wan22-i2v-a14b-4step
.\scripts\windows\fetch-models.ps1 -Only ltx23,ltx23-te,upscalers,upscaler-anime,upscaler-ultrasharp,adetailer,ipadapter-sdxl,clip-vision-h
# + the TAEHV decoders models\taew2_2.safetensors / taew2_1.safetensors (github.com/madebyollin/taehv)
# + bin-sd-master-968-8cd731e\ (the stable-diffusion.cpp release zip) for FLUX.3
```

**The LLM is dormant, not gone:** the Startup launcher keeps its three LLM lines (router, metrics exporter,
watchdog) commented out with a `rem ROLLBACK-LLM:` prefix; swapping them back restores `:8080` as an
OpenAI chat endpoint. Both cannot share the port.
