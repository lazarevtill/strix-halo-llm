# Images and video — what this box serves since 2026-10-15

On 2026-10-15 the box switched from serving an LLM to serving **images**; on 2026-10-16 it added **video**.
One router on `:8080` serves text-to-image, editing, inpainting, image-to-image, text-to-video and
image-to-video across switchable models, plus a web UI (**Image Studio**) and a server-side gallery.
Everything below was measured on this box (Radeon 8060S / gfx1151, Windows 11, AMD driver 26.9.2)
unless marked otherwise.

## What runs

```
:8080  images-router.py  (Python stdlib; supervised by run-images.ps1, started at logon)
         ├─ Image Studio at /            scripts/windows/ui/ (index.html + studio.css + studio.js, strict CSP)
         ├─ /studio/*                    models (load/unload/stop/pin), gallery, remote adds (HF / CivitAI)
         ├─ <repo>/outputs/<day>/        every finished image/video + a .json of its request (the gallery)
         └─ one sd-server backend per model, 127.0.0.1:18200+, several resident within an 88 GB budget
              stable-diffusion.cpp master-967-e47426c (prebuilt Windows Vulkan, weights pinned to the GPU);
              a model may name its own engine -- FLUX.3 runs on master-968-8cd731e
```

### Image models (tracked registry `scripts/windows/image-models.json`)

| model (id) | what it is | memory (measured) | speed at 1024² (measured) | licence |
|---|---|---|---|---|
| **Qwen-Image 2.1 Turbo** (`qwen-image-2.1-turbo`, default) | #1 open model for generation **and** editing (Artificial Analysis, Oct 2026); 8 fixed steps | 23.5 GB | ~1.5–1.8 min; edit ~2 min | Qwen Research — **non-commercial** |
| Qwen-Image 2.1 full (`qwen-image-2.1`) | the non-distilled base, 40 steps, real CFG | 23.5 GB | ~12 min (extrapolated) | non-commercial |
| **FLUX.3 Image Klein** (`flux3-klein`) | Black Forest Labs' newest open model (released 2026-10-15): 5.6B, 16 steps at CFG 1, generation **and editing with up to 10 references**; exact text | 10.0 GB | **76 s**; edit 175 s | FLUX Kommunity License — free commercial use under $5M revenue |
| **Z-Image Turbo** (`z-image-turbo`) | **the fast option**: Tongyi-MAI's 6B distilled model, 8 steps at CFG 1; exact English text | 10.5 GB | **~53 s**; 512² in 12 s | **Apache-2.0** |
| **Kroma** (`kroma`) | uncensored photoreal: Krea 2 fine-tune on the Chroma dataset; 12.9B, turbo, 10 steps | 17.3 GB | ~2–2.5 min (12.6 s/step) | MIT + Krea 2 Community License (commercial cap; bans non-consensual intimate imagery) |
| **Anima Turbo** (`anima`) | uncensored anime / illustration; 2B; rating tags `safe / sensitive / nsfw / explicit` | 3.5 GB | **44 s**; 512² in 9 s | CircleStone non-commercial + NVIDIA Open Model License |

### Video models

| model (id) | what it is | memory | measured | licence |
|---|---|---|---|---|
| **Wan 2.2 TI2V-5B Turbo** (`wan22-ti2v-turbo`) | text→video **and** image→video in one 5B model; 4 steps, 24 fps, 1280×704 native | 11–12 GB | **1280×704 × 49 frames (2 s): 92 s**; 896×512 × 25 frames (i2v): **20 s** | Apache-2.0 |
| **Wan 2.2 I2V-A14B, lightx2v 4-step** (`wan22-i2v-a14b`) | image→video with the 27B two-expert Wan 2.2: the best motion here; optional last frame | 35.4 GB | 832×480 × 49 frames (3 s at 16 fps): **565 s** (190 s per expert + 126 s decode) | Apache-2.0 |

Plus whatever the owner adds through **＋ Add model** (below) into the local registry — e.g. WAI-illustrious-SDXL.

Every weight sits **on the GPU, 0 MB in system RAM** (`--backend vulkan0 --params-backend vulkan0
--eager-load`). The router reserves each loaded model's measured size plus compute headroom (8 GB; 16 GB
for video models) against an 88 GB budget and evicts the least-recently-used *idle, unpinned* model when a
new one needs room. Three image models resident (Turbo + Kroma + Anima) measured **44.4 GB committed**
(69.5 GB reserved).

Why these: Qwen-Image-2.1 tops both open leaderboards and edits in the same model. FLUX.3 Klein (added the
day after its release) is the strongest small model, also edits, and is the commercially usable editor.
For uncensored content (added at the owner's request) CivitAI's monthly downloads show photoreal NSFW has
moved to Krea 2 fine-tunes and anime to Anima; both were gated on neutral prompts only. Video: Wan 2.2 is
the open-weights reference and sd-server master-967 serves it on `/sdcpp/v1/vid_gen`.

Why stable-diffusion.cpp and not ComfyUI: one binary with OpenAI `generations` + `edits` and an async
native API (images **and** video) built in, the Vulkan driver this repo already trusts, and weights loaded
tensor-by-tensor **straight to the GPU**. PyTorch runtimes are likely 2-3x faster on ROCm, but ComfyUI has
no OpenAI API and stages weights through system RAM — only ~32 GB is visible to Windows here, often
<10 GB free. A ROCm runtime is the obvious next A/B, not a settled loss.

## Image Studio (`http://<box>:8080/`)

Rebuilt 2026-10-16 after a review of the first version. Files: `scripts/windows/ui/` (no inline script or
style anywhere — the page runs under a strict Content-Security-Policy; no external dependencies).
Dark-first with a light theme; at phone width the canvas comes first. Everything listed was exercised in a
browser against the router, with **zero page errors and zero CSP violations**.

- **Model picker** — a card list (search; filters All / Images / Video / Loaded): family, memory, state
  (loaded / loading / failed), edit / video / NSFW badges, licence, and a **pin** toggle (pinned models are
  never evicted and load at router start). Clicking a card loads it; browsing does not.
- **Modes follow the model:** image models get **Generate / Edit / Inpaint / Image→Image** (Edit only where
  the model does instruction edits — Qwen-Image 2.1 and FLUX.3); video models get **Text → Video /
  Image → Video** (+ an optional *last frame* on the A14B).
- **Prompt first**, negative prompt (with a warning when CFG 1 makes it inert), **shape** as aspect-ratio
  buttons (1:1 … 21:9, or the source's own shape) × a resolution tier (small / the model's size / large;
  video: native / half), or exact W×H. **Steps and CFG** are sliders that mark when they differ from the
  model's default, with a reset. Seed (random / fixed / keep), images 1–8, transparent background
  (Qwen), a pixel-budget warning for requests likely to run out of memory.
- **Video:** length as frames *and* seconds (4n+1 frames), fps, format (WebM / animated WebP / AVI).
- **Advanced:** sampler, scheduler, image CFG, flow shift, **CLIP skip** (2 for Pony / Illustrious),
  eta, speed cache, live preview (fast projection / tiny decoder / full VAE / off), VAE tiling, output
  format / quality / embedded metadata. **LoRA** (this model's family first, trigger words as chips) and
  **hires fix**.
- **Queue:** Generate while something runs adds to a queue (per model, server-side); each job shows its
  preview and progress with an **ETA** from the measured step time. **Cancel** for queued jobs; for a
  running one the model can't interrupt (`cancel_generating: false` on this build), **Stop** restarts the
  model after a confirmation. Jobs **survive a page reload** (re-attached from the browser's storage).
- **Results:** a large stage with zoom / download overlay and **Edit · Inpaint · Img→Img · Animate**
  (hands the image to a video model as the first frame) · **Variation · Reuse** (restores model, prompt
  and every setting) · **Compare** (before/after slider against the source) · Download · Delete.
- **Gallery** (right rail / below on narrower screens): every finished result **from any client**, saved on
  the box in `outputs\<day>\` with its settings — so it is the same on every device and survives a browser
  cache clear. Filters (All / Images / Videos / This model), hover-to-play videos, load more. A browser that
  still holds the old local history is offered a one-click move into the gallery.
- **Drop a PNG** anywhere: its embedded parameters (A1111 format, which sd.cpp writes, plus sd.cpp's own
  JSON) fill the prompt, seed, size, steps, CFG, sampler and CLIP skip, and switch to the model that made it.
- **Viewer:** wheel / pinch zoom around the pointer, drag to pan, Fit / 1:1 (pixel-crisp from 200%),
  ← → through the gallery, `C` compare, Esc. **Mask painter:** zoom / pan (wheel, pinch, Space-drag,
  middle-drag, Hand), brush cursor, Undo, `[` `]` brush size.
- **Inpaint modes — what the model is sent** (built in the browser, shown by *Show what the model gets*):
  masked area starts as **Original / Surroundings / Noise / Blank**; **Whole image** or **Only masked**
  (crop + ~1 MP render + paste back); mask blur; keep-the-rest-pixel-exact.
- **Keyboard:** Ctrl+Enter generate, `M` models, `?` shortcuts, Esc; dialogs trap focus, status is
  announced (`aria-live`), controls have real labels, reduced-motion is respected.

Inpaint modes, measured 2026-10-15 on Z-Image Turbo (512² source, a box mask over an apple, "a ripe
orange", seed 5): with the blend-back on, **0 of 202,274 pixels** outside the mask's blend band changed
(without it, the VAE round trip moves every pixel slightly). Quality by mode, same seed: **Only masked +
Original 0.85** was the most natural (no seam); **Whole image + Surroundings 0.9** was clean; **Noise 1.0**
left a visible box-shaped seam in both areas. Hence the default (Surroundings 0.9). Only-masked costs the
time of a ~1 MP render (51–74 s on Z-Image vs 12–14 s for the whole 512² image).

## Video

sd-server master-967 already serves video over HTTP (PR #1437, April 2026): `POST /sdcpp/v1/vid_gen`
with `video_frames`, `fps`, `init_image`, `end_image`, `output_format` (webm / webp / avi) **at the top
level** (nested inside `sample_params` they are silently ignored and you get one frame), then the same
`/sdcpp/v1/jobs/{id}` polling; the result is one `b64_json` video. The OpenAI image routes cannot carry
video. Wan rounds frames to 4n+1.

**The decoder is the bottleneck, and the tiny one wins.** Wan 2.2 TI2V-5B Turbo, 1280×704, 49 frames, 4
steps (sampling **68 s** — 17 s/step):

| decoder | decode | total | note |
|---|---|---|---|
| full Wan 2.2 VAE, untiled | 897 s | 972 s | one buffer exceeded this driver's per-allocation limit ("Failed to allocate pinned memory") and fell back to a slow path |
| full Wan 2.2 VAE, tiled + temporal tiling | ~630 s | 705 s | |
| **TAEHV `taew2_2` (tiny decoder)** | ~20 s | **92 s** | ← served; at 100% crop slightly softer fur, otherwise the same frame |

At 640×352 × 25 frames: full VAE untiled 35 s, tiled 65–73 s — tiling costs ~2x at small sizes, but large
sizes can't go untiled. The A14B uses the Wan 2.1 VAE (8× lighter per pixel): 126 s tiled for 832×480 × 49.
Image→video through the UI (Animate on a 736² still → 896×512 × 25 frames on the 5B): **20 s**, the first
frame matches the source and the motion follows the prompt. The A14B (fox still → "lifts its head and trots
forward"): coherent, natural motion over 3 s.

## FLUX.3 Image Klein and the per-model engine

FLUX.3 support landed in sd.cpp **one commit after** the build this box runs (`8cd731e`, #2143,
2026-10-15 18:42; master-967 is `e47426c`, 15:08). Rather than move every model to an engine that has
not been gated, the registry gained `"engine": "bin-sd-master-968-8cd731e/sd-server.exe"` — only FLUX.3
runs on master-968. Weights: an ungated sd.cpp GGUF conversion (`flux3_image_klein_sd-Q8_0.gguf`,
5.99 GB) + the FLUX.2 VAE + the Qwen3-VL-4B encoder already on disk for Kroma. Measured: loads in 8 s,
**9.95 GB**, 1024² **76 s** (16 steps, 4.2 s/step), same seed → byte-identical; an edit ("make the bicycle
green and change the sign to CLOSED") changed exactly those two things, 175 s. The official repo is gated
by the FLUX Kommunity License (free commercial use under $5M annual revenue; bans NCII / CSAM).

## Adding models and LoRAs from Hugging Face and CivitAI

**＋ Add model** (or the API below) takes a link from **huggingface.co**, **civitai.com** or **civitai.red**
— a model page, a pinned version, or a single file — and:

1. **Identifies it**: checkpoint or LoRA, and which stable-diffusion.cpp *family* — from CivitAI's
   `baseModel`, the HF card's `base_model` / tags, and the **tensor names (and safetensors metadata) in the
   file's own header** (two HTTP Range requests, no download). Families: SD 1.5, SD 2.x, **SDXL / Pony /
   Illustrious / NoobAI**, SD 3.5, FLUX.1 dev/Krea/schnell, FLUX.2 klein 4B/9B and dev, **FLUX.3 Klein**,
   Chroma, Qwen-Image 1.x and 2.1, Z-Image Turbo/base, Krea 2, Anima — every open-weight image ecosystem
   on civitai.red/ecosystems this engine loads. HiDream I1, Pony V7 (AuraFlow), Kolors and the hosted-only
   ones are refused with the reason; a UNet-only SD/SDXL file (no text encoder) is refused; an fp8 file of
   a DiT family gets a warning (this driver has crashed on fp8 encoders before).
2. **Shows the plan**: licence / commercial terms, NSFW flag, trigger words, v-prediction (from
   `modelspec.prediction_type` or a `v_pred` key — not the filename), whether it is **already on the box**,
   and every file it would fetch — the model plus the family's **companions** (text encoders, VAEs) — with
   what is already on disk and what queued downloads will still take.
3. **Downloads** one job at a time: resumable `.part`, **sha256-verified** (CivitAI's hashes, HF's LFS
   oid; the 17 companions' hashes are pinned in `images_remote.py`), refused below 50 GB free *after*
   queued jobs.
4. **Registers** a model in **`<models>\image-models.local.json`** — *never* the tracked registry: this repo
   is public — or drops a LoRA into `models\loras`, which every backend rescans live. Defaults come from the
   family (fast defaults for turbo / lightning / hyper / LCM / DMD, matched as whole words: "HyperReal" is
   not Hyper-SD), `--prediction v` for v-pred, CLIP skip 2 for Pony / Illustrious / NoobAI, the FLUX.3
   engine for FLUX.3. After its first load the router replaces the estimated memory with the **measured**
   one. *Remove* deletes a file only if no other model uses it.

**Keys.** Many CivitAI files answer **401** without an API key. Create one at civitai.com → Account
settings → API keys and, **on the box, in a terminal** (not in a chat), run `setx CIVITAI_TOKEN <key>`;
gated HF repos take `setx HF_TOKEN <token>`. The router reads `HKCU\Environment` on every request, so no
restart is needed. A token is sent only to civitai.* / huggingface.co — dropped on the redirect to the
storage CDN — and never appears in a URL, a response or a log. civitai.red is the same platform and API
as civitai.com (adult content moved there in April 2026); the lookup tries both.

**Measured 2026-10-15** (through the feature): **WAI-illustrious-SDXL v17** (CivitAI's top Illustrious
checkpoint, from civitai.red, 7.27 GB incl. the fp16-fix VAE) ~70 MB/s, sha256 OK, loaded in 4 s, **6.6 GB**,
**57 s at 1024²** (28 steps, 1.73 s/step), same seed → byte-identical, clean render. **Pixel Art XL** (an
SDXL LoRA from HF) appeared in the running backend without a restart and applied **2166 / 2166** tensors.

## API (router, `:8080`)

```
GET  /v1/models                     the registry's models (OpenAI list; "kind": image | video)
POST /v1/images/generations         {"model": "kroma", "prompt": "...", "size": "1024x1024"} -> data[].b64_json
POST /v1/images/edits               multipart: model, prompt, image[], optional mask, size
POST /sdcpp/v1/img_gen              native async image job; {"model": ..., + any native field} -> {"id": "<model>~<job>"}
POST /sdcpp/v1/vid_gen              native async video job (video_frames, fps, init_image, end_image at top level)
GET  /sdcpp/v1/jobs/{id}            status, live preview, result     (POST .../cancel cancels a QUEUED job)
GET  /sdcpp/v1/capabilities?model=  samplers, schedulers, LoRAs, upscalers, features -- 409 if not loaded (GETs never load)
GET  /studio/models                 every model's state; POST /studio/models/{load,unload,stop,pin} {"model": id}
GET  /studio/gallery                saved outputs (?offset=&limit=&model=&kind=); GET /outputs/<day>/<file>
POST /studio/gallery/delete         {"file": "<day>/<file>"};   POST /studio/gallery/import {"image": data URL, "meta"}
POST /studio/remote/inspect         {"url"} -> kind, family, files, licence, NSFW, already, download plan
POST /studio/remote/add             {"url", "file", "family", "label"} -> download job -> local registry
GET  /studio/remote/jobs            progress (POST .../cancel {"id"}); POST .../remove {"kind", "id", "delete_files"}
```

Job ids are **namespaced** (`<model>~<backend id>`): sd-server numbers jobs `job_<unix seconds>_<counter>`
per process, so two backends could hand out the same id in the same second and a poll would reach the
wrong model. Results of every finished job — native or OpenAI, from any client — are saved to
`outputs\<day>\` with a `.json` of the request, even if nobody polls to the end (a monitor thread reaps
abandoned jobs and saves their output).

> **Known sd-server crash, blocked by the router:** an `<sd_cpp_extra_args>` block inside an
> `/v1/images/edits` prompt aborts sd-server master-967 (`0xc0000409`). The router answers such requests
> with **400**.

### Security (no authentication; LAN only)

Hardened 2026-10-16 after a review found any web page the owner visited could drive the box:
- **No CORS grant**: other sites cannot read responses; a cross-origin **POST** (it carries an `Origin`)
  is refused (**403**) — no CSRF from a page you happen to visit.
- **DNS-rebinding guard**: the `Host` header must be an IP, `localhost`, the machine's name, a single-label
  LAN name or `*.local / .lan / .home / .internal`; anything else gets **403** with how to allow it
  (`--allow-host <name>` or `IMAGES_ALLOW_HOSTS=a,b`).
- Bodies capped at 192 MB; LoRA paths reduced to a file name inside the LoRA dir; static UI files and
  outputs served only from their own folders by strict name patterns; the UI runs under a strict CSP.
- Remote adds only from huggingface.co / civitai.com / civitai.red (no SSRF to other hosts), tokens only to
  those hosts.

### Robustness

- **Freezes are now detected:** a monitor checks every ready backend every 20 s (`/capabilities` answers
  in ~2 ms even mid-generation — measured during a video decode); 3 misses → the backend is killed and
  restarts on the next request.
- **No eviction mid-request:** a request claims its backend atomically with the readiness check, so an
  eviction can't kill it between `ensure` and the POST; abandoned jobs no longer pin a model for an hour.
- **Retries only when safe:** a backend that was already dead before the request reached it is restarted
  and the request retried once; one that crashes *while* handling it is not (the same input may crash it
  again) — the client gets a 502 naming the log.
- Registry reloads keep live ports and stop backends whose model left the file; a port taken by
  something else is skipped; log files are closed in the router (pruning works again).

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
| FLUX.3 Image Klein Q8_0, 16 steps, CFG 1 (master-968) | 66.6 s (4.2 s/step) | **74–78 s**; edit with one reference 175 s; 736² 35 s |
| Kroma Q8_0, 10 steps, CFG 1 (first call) | 125.8 s (12.6 s/step) | 152 s; 1344×768 120 s; 512² ~27 s |
| WAI-illustrious-SDXL v17 (SDXL, 28 steps, CFG 6) | 48.5 s (1.73 s/step) | **57 s** |
| Anima Turbo Q8_0, 10 steps, CFG 1 | — | **44 s**; 1344×768 37 s; 512² 9 s |
| Z-Image Turbo Q8_0, 8 steps, CFG 1 | 44.7 s (5.5 s/step) | **52–54 s**; 1344×768 53 s; 512² 12 s (1.15 s/step) |

Same seed → byte-identical PNG on every image model tested (two runs each). Feature checks on Turbo at
512² (native API): CFG 3 + negative prompt works (2x passes); batch of 2 returns 2 distinct images;
inpaint with a white-means-repaint mask replaces only the masked area; hires fix 1.5x returns 768²;
image→image runs but the Turbo model barely restyles at strength 0.6; `--sigmas` presets make the
steps field a no-op for Turbo (8 steps whatever is requested).

Q8_0 and bf16 produce visually indistinguishable images at the same seed (compared side by side), so
the 2.4x speedup is free. With the LLM stopped, a 512x512 Turbo-Q8 image took **32 s** end to end, vs
53.9 s while the LLM was resident (cause not isolated — treat "the idle LLM cost ~40%" as a hypothesis).

**Correctness caveat:** `--flash-attn auto` re-probes at every start and has flipped between on and off
across restarts, so the *same seed can give a different image after a restart*. Video models pass
`--flash-attn on` after the router's `auto` (later flags win): their logs carry no auto-probe line, which every
`auto` model prints -- the evidence the pin took effect.

**Why Vulkan is slow here:** at ~9 s/step for a 7B transformer at 1024² the sampler sustains a few
TFLOPS — in line with llama.cpp's own prefill on this box (~7 TFLOPS), and far below the ~2.4 s/step a
Linux ROCm/PyTorch run reported for the same model (INT8, not measured here). The Vulkan matmul path on
this driver, not the model, is the limit.

## Operating it

```powershell
.\scripts\windows\run-images.ps1                        # what the Startup launcher runs: router on :8080
.\scripts\windows\run-images.ps1 -Preload kroma         # start with a different model loaded (comma list ok; pinned ones always load)
.\scripts\windows\run-images.ps1 -DryRun                # print the router command line
.\scripts\windows\run-images.ps1 -Single -Model turbo-q8   # old mode: one sd-server, one model, its own console (rollback)
.\scripts\windows\fetch-models.ps1 -Only qwen-image-21-turbo-q8,qwen-image-21-te,z-image-turbo,z-image-te,flux-ae,kroma,kroma-te,wan21-vae,anima,anima-te
.\scripts\windows\fetch-models.ps1 -Only flux3-klein,flux2-vae,wan22-ti2v-turbo,wan-umt5,wan22-i2v-a14b-4step
# + the TAEHV decoders models\taew2_2.safetensors / taew2_1.safetensors (github.com/madebyollin/taehv)
# + bin-sd-master-968-8cd731e\ (the sd.cpp release zip) for FLUX.3
```

Logs: `logs\images-router-<ts>.out` (loads, evictions, freezes, restarts, downloads) and
`logs\images-<model>-<ts>.err/.out` per backend. The supervisor restarts the router if it exits and,
after more than 5 exits in an hour, **backs off 15 minutes and tries again** rather than giving up.
Edit `image-models.json` and `POST /studio/reload-registry` to pick up registry changes without a restart.
Results accumulate in `outputs\` (gitignored) — prune it by hand; nothing deletes old results automatically.

- **Client timeouts must be 3+ minutes** for images (the OpenAI routes answer only when the image is done)
  and use the async API for video.
- **Concurrent requests to one model queue**; requests to *different* resident models run at the same time
  and share the GPU.
- **System RAM:** the backends use none, but Windows only sees ~32 GB. On 2026-10-15 WSL / Docker Desktop
  (`vmmemWSL`) grew to 14 GB of it while a model loaded, and free RAM briefly hit ~0. Keep WSL's memory
  capped (`.wslconfig`) or stopped when the box is busy.

**Rollback to the LLM:** the Startup launcher keeps the three LLM lines (router, metrics exporter,
watchdog) commented out with a `rem ROLLBACK-LLM:` prefix. Uncomment them and comment out the
`run-images.ps1` line. Both cannot share `:8080`.

**Lost by the switch:** any app calling `/v1/chat/completions` on `:8080` now gets an error — there is
no text model on this box any more. The LLM's metrics exporter (`:9114`) and watchdog are off.
