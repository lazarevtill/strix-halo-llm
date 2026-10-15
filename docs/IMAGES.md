# Image generation — what this box serves since 2026-10-15

On 2026-10-15 the box switched from serving an LLM to serving **images**: text-to-image, editing,
inpainting and image-to-image across five switchable models, behind one router on the same `:8080`. Everything below was measured on this box
(Radeon 8060S / gfx1151, Windows 11, AMD driver 26.9.2) unless marked otherwise.

## What runs

```
:8080  images-router.py  (Python stdlib; supervised by run-images.ps1, started at logon)
         ├─ serves Image Studio at /  (scripts/windows/images-ui.html)
         ├─ /studio/models            model list + live state; load / unload
         └─ one sd-server backend per model, 127.0.0.1:18200+, several resident within a GPU budget
              (stable-diffusion.cpp master-967-e47426c, prebuilt Windows Vulkan, weights pinned to the GPU)
```

| model (registry id) | what it is | memory (measured) | speed at 1024² (measured) | licence |
|---|---|---|---|---|
| **Qwen-Image 2.1 Turbo** (`qwen-image-2.1-turbo`, default) | #1 open model for generation **and** editing (Artificial Analysis, Oct 2026); 8 fixed steps | 23.5 GB | ~1.5–1.8 min; edit ~2 min | Qwen Research — **non-commercial** |
| Qwen-Image 2.1 full (`qwen-image-2.1`) | the non-distilled base, 40 steps, real CFG | 23.5 GB | ~12 min (extrapolated) | non-commercial |
| **Z-Image Turbo** (`z-image-turbo`) | **the fast option**: Tongyi-MAI's 6B distilled model, 8 steps at CFG 1; strong photorealism and exact English text (a chalkboard sign came out letter-perfect) | 10.5 GB | **~53 s**; 512² in 12 s | **Apache-2.0** — the only commercially usable one |
| **Kroma** (`kroma`) | uncensored photoreal: Krea 2 fine-tune on the Chroma dataset by the Chroma author; 12.9B, turbo, 10 steps | 17.3 GB | ~2–2.5 min (12.6 s/step) | MIT + Krea 2 Community License (commercial cap; bans non-consensual intimate imagery) |
| **Anima Turbo** (`anima`) | uncensored anime / illustration; 2B; rating tags `safe / sensitive / nsfw / explicit` steer content | 3.5 GB | **44 s**; 512² in 9 s | CircleStone non-commercial + NVIDIA Open Model License |

Every weight sits **on the GPU, 0 MB in system RAM** (each backend runs `--backend vulkan0
--params-backend vulkan0 --eager-load`). The router reserves each loaded model's measured size plus 8 GB
of compute headroom against an 88 GB budget and evicts the least-recently-used *idle* model when a new
one needs room. Three resident at once (Turbo + Kroma + Anima) measured **44.4 GB committed** (69.5 GB
reserved). Adding a model = adding an entry to `scripts/windows/image-models.json` (data only) and its
files to `fetch-models.ps1`.

Why these: Qwen-Image-2.1 tops both open leaderboards and does editing in the same model. For uncensored
content (added at the owner's request), CivitAI's monthly downloads show photoreal NSFW has moved to
Krea 2 fine-tunes and anime to Anima; Kroma and Anima are the strongest of those that load in
stable-diffusion.cpp straight from Hugging Face without a login (the popular SDXL "Lustify" needs a
CivitAI API key, so it was skipped). Both were gated here on neutral prompts only: load, same-seed
byte-identical output, and renders that were looked at.

Why stable-diffusion.cpp and not ComfyUI: one binary with OpenAI `generations` + `edits` built in, the
Vulkan driver this repo already trusts, and weights loaded tensor-by-tensor **straight to the GPU**.
PyTorch runtimes (ComfyUI, Lemonade's TheNoise) are likely 2-3x faster on ROCm, but ComfyUI has no
OpenAI API and stages weights through system RAM — and only ~32 GB is visible to Windows here, often
<10 GB free. A ROCm runtime is the obvious next A/B, not a settled loss.

## Web UI — Image Studio (`http://<box>:8080/`)

`scripts/windows/images-ui.html`, served by the router (re-read per request). No external
dependencies; light/dark; usable at phone width. Everything below was exercised in a browser.

- **Model picker** in the header — switching loads the model on demand (status shown: loaded /
  loading… / failed), applies its defaults (steps, CFG, sampler), and gates the controls it does not
  support. Uncensored models carry an NSFW badge; the licence is shown under the header.
- **Four modes (real tabs):** **Generate**; **Edit** — instruction edits with up to 3 reference
  images (Qwen-Image family only; disabled with an explanation for the others); **Inpaint** — paint a
  mask over the image with a brush (paint / erase / invert / clear), describe what goes there;
  **Image→Image** — the image is the starting point, *strength* sets how far it moves.
- **Prompt and negative prompt.** The negative prompt only acts at **CFG > 1**, and the turbo models run
  at CFG 1 — the UI says so and warns when a negative prompt would be ignored. CFG 2–3 works on Turbo
  (measured: a "fog" negative cleared the fog) at roughly 2x the time.
- **Size** presets (1024², 1344×768, 768×1344, 1152×864, 864×1152, 512²), custom W×H, and "Match
  source" (source aspect and pixel count, clamped to 512²…1.25 MP). **Batch** 1–4, **seed** (random /
  fixed / keep between runs), **transparent background** (Qwen RGBA).
- **Sampling:** steps (shown as fixed where a model's schedule overrides them — Turbo ignores a steps
  override, measured), CFG, image CFG, sampler and scheduler (lists come from the live model), flow
  shift, eta. **LoRA** (appears when `models\loras` has any). **Hires fix** (upscaler, scale, steps,
  denoise — measured 512→768). **Speed cache** (easycache, dbcache, …: approximate, faster), **live
  preview** (fast blurry projection, full-quality VAE, or off), VAE tiling, output format / quality /
  embedded metadata.
- **Results:** live preview + step counter, cancel, batch strip, and one-click **Edit / Inpaint /
  Img→Img** on any result, **Variation**, **Reuse** (restores the prompt, model and settings),
  **Download**. History of the last 80 results in this browser's IndexedDB.
- **Zoom.** Click any result (or double-click a history thumbnail) for a full-screen viewer: wheel or
  pinch to zoom around the pointer, drag to pan, Fit / 1:1 (pixels go crisp from 200%), ← → through the
  history, Esc or a click on the backdrop closes. The **mask painter zooms too** (wheel / pinch / − + Fit),
  with Space-drag, middle-drag or a Hand tool to move around, a brush-size cursor (the brush is in screen
  pixels, so zooming in paints finer), **Undo** (Ctrl+Z), and `[` `]` for the brush size.
- **Inpaint modes — what the model is sent.** sd.cpp takes one starting image + one mask (white =
  repaint); the page builds both in the browser, and **Show what the model gets** displays them:
  - *Masked area starts as* — **Original** (what is there; for changing something while keeping its
    place and light, strength ~0.85), **Surroundings** (the hole is filled from the colours around it
    first; for removing, and the default at 0.9), **Noise**, **Blank** (grey). At strength 1.0 the
    starting content is ignored, so the choice only matters below 1.
  - *Inpaint area* — **Whole image**, or **Only masked**: the mask's bounding box plus padding is cut
    out, rendered at ~1 MP and pasted back, so a small area gets far more detail; the output keeps the
    source size.
  - **Mask blur** (default 8 px, one latent cell): the model repaints the mask grown by that much, and
    the result is faded back over that band. **Keep the rest pixel-exact** (default on) pastes the
    result over the untouched original.

Verified in the browser on the router: model switch, Edit disabled for Anima, generate → **Inpaint** →
paint → "a slice of strawberry cake on the plate" produced exactly that inside the mask (mean pixel
change 105.8 inside vs 2.5 outside, 11 s at 512² on Anima).

Inpaint modes, measured 2026-10-15 on Z-Image Turbo (512² source, a box mask over an apple, "a ripe
orange", seed 5): with the blend-back on, **0 of 202,274 pixels** outside the mask's blend band changed
(without it, the VAE round trip moves every pixel slightly — the 2.5 above). Quality by mode, same seed:
**Only masked + Original 0.85** was the most natural (a smaller orange with its own shadow, no seam);
**Whole image + Surroundings 0.9** was clean; **Noise 1.0** left a visible box-shaped seam in the wood
grain in both areas, because the whole masked rectangle is invented with no colour to anchor it. Hence
the default (Surroundings 0.9). Only-masked costs the time of a ~1 MP render (51–74 s on Z-Image vs
12–14 s for the whole 512² image).

## Adding models and LoRAs from Hugging Face and CivitAI

**＋ Add** in Image Studio's header (or the API below) takes a link from **huggingface.co**,
**civitai.com** or **civitai.red** — a model page, a pinned version, or a single file — and:

1. **Identifies it**: checkpoint or LoRA, and which stable-diffusion.cpp *family* it belongs to — from
   CivitAI's `baseModel`, the HF card's `base_model` / tags, and the **tensor names in the file's own
   header** (read with two HTTP Range requests, no download). Families: SD 1.5, **SDXL / Pony /
   Illustrious / NoobAI**, SD 3.5, FLUX.1 dev/Krea/schnell, FLUX.2 klein 4B/9B and dev, Chroma,
   Qwen-Image 1.x and 2.1, Z-Image Turbo/base, Krea 2, Anima — every open-weight image ecosystem on
   civitai.red/ecosystems that this build loads. HiDream I1, Pony V7 (AuraFlow), Kolors and the
   hosted-only ones (Nano Banana, Imagen, Seedream, GPT Image) are refused with the reason.
2. **Shows the plan**: licence / commercial-use terms, NSFW flag, trigger words, and every file it would
   fetch — the model plus the **companions** its family needs (text encoders, VAEs: e.g. the SDXL
   fp16-fix VAE, `clip_l` + `t5xxl` for FLUX.1, Qwen3-8B for klein 9B), with what is already on disk.
3. **Downloads** one job at a time: resumable `.part` files, **sha256-verified** (CivitAI's
   `hashes.SHA256`, HF's LFS oid), refused if it would leave under 50 GB free.
4. **Registers** a model in **`<models>\image-models.local.json`** — *not* the tracked
   `image-models.json`: this repo is public and the owner's additions are their business — or drops a
   LoRA into `models\loras`, which every backend rescans live. Defaults (steps, CFG, sampler, size) come
   from the family, with fast defaults for turbo / lightning / hyper / LCM / DMD variants and
   `--prediction v` for v-pred files. After its first load the router replaces the estimated memory with
   the **measured** `total params memory size` and saves it.

**Keys.** Many CivitAI files answer **401** without an API key (measured: a Z-Image LoRA did; the
WAI-illustrious checkpoint did not). Create one at civitai.com → Account settings → API keys and, **on the
box, in a terminal** (not in a chat), run `setx CIVITAI_TOKEN <key>`; gated HF repos take
`setx HF_TOKEN <token>`. The router reads `HKCU\Environment` on every request, so no restart is needed. A
token is sent only to civitai.* / huggingface.co — dropped on the redirect to the storage CDN — and never
appears in a URL, a response or a log. civitai.red is the same platform and API as civitai.com
(adult content moved there in April 2026); the lookup tries both.

**Measured 2026-10-15** (through the feature, on a side router): **WAI-illustrious-SDXL v17**
(CivitAI's top Illustrious checkpoint, from civitai.red, 7.27 GB incl. the fp16-fix VAE) downloaded at
~70 MB/s, sha256 OK, loaded in 4 s, **6.6 GB** measured, **57 s at 1024²** (28 steps, 1.73 s/step, CFG 6),
same seed → byte-identical, and a clean render — the first SDXL-family model on this box, and it runs
well. **Pixel Art XL** (an SDXL LoRA from HF) appeared in the running backend's LoRA list without a
restart and applied **2166 / 2166** tensors (the 0 / 2166 lines in the log are the text encoder and VAE
passes); same seed with vs without it: grid pixel art vs smooth illustration.

The LoRA panel lists LoRAs of the loaded model's family first, marks the others *will not work here*,
and shows trigger words as chips that add themselves to the prompt.

## API (router, `:8080`)

```
GET  /v1/models                     the registry's models (OpenAI list)
POST /v1/images/generations         {"model": "kroma", "prompt": "...", "size": "1024x1024"} -> data[].b64_json
POST /v1/images/edits               multipart: model, prompt, image[], optional mask, size
POST /sdcpp/v1/img_gen              native async job; {"model": ..., + any native field} -> {"id": ...}
GET  /sdcpp/v1/jobs/{id}            status, live preview, result     (POST .../cancel to cancel)
GET  /sdcpp/v1/capabilities?model=  samplers, schedulers, LoRAs, upscalers, limits for that model
GET  /studio/models                 every model's state; POST /studio/models/load | /unload {"model": id}
POST /studio/remote/inspect         {"url"} -> kind, family, files, licence, NSFW, download plan
POST /studio/remote/add             {"url", "file", "family", "label"} -> download job -> local registry
GET  /studio/remote/jobs            progress (POST .../cancel {"id"}); POST .../remove {"kind", "id", "delete_files"}
```

The `model` field picks the backend (default: the last one loaded). Apps can now choose a model per
request. **No authentication**; `:8080` is reachable from the LAN through the existing firewall rule.

> **Known sd-server crash, now blocked by the router:** an `<sd_cpp_extra_args>` block inside an
> `/v1/images/edits` prompt aborts sd-server master-967 (`0xc0000409`; generations and the native API
> are unaffected). The router answers such requests with **400** instead of forwarding them. Not yet
> reported upstream.

**Recovery (measured):** a dead backend is detected on the next request, restarted, and that request
retried (33 s including the restart); killing the router reaps every backend (Windows job object) and
the supervisor brings router + default model back in ~19 s.

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
| Kroma Q8_0, 10 steps, CFG 1 (first call) | 125.8 s (12.6 s/step) | 152 s; 1344×768 120 s; 512² ~27 s |
| Anima Turbo Q8_0, 10 steps, CFG 1 | — | **44 s**; 1344×768 37 s; 512² 9 s |
| Z-Image Turbo Q8_0, 8 steps, CFG 1 | 44.7 s (5.5 s/step) | **52–54 s**; 1344×768 53 s; 512² 12 s (1.15 s/step) |

Same seed → byte-identical PNG on all five models (512², two runs each). Feature checks on Turbo at
512² (native API): CFG 3 + negative prompt works (2x passes); batch of 2 returns 2 distinct images;
inpaint with a white-means-repaint mask replaces only the masked area; hires fix 1.5x returns 768²;
image→image runs but the Turbo model barely restyles at strength 0.6; `--sigmas` presets make the
steps field a no-op for Turbo (8 steps whatever is requested).

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
.\scripts\windows\run-images.ps1                        # what the Startup launcher runs: router on :8080
.\scripts\windows\run-images.ps1 -Preload kroma         # start with a different model loaded
.\scripts\windows\run-images.ps1 -DryRun                # print the router command line
.\scripts\windows\run-images.ps1 -Single -Model turbo-q8   # old mode: one sd-server, one model (rollback)
.\scripts\windows\fetch-models.ps1 -Only qwen-image-21-turbo-q8,qwen-image-21-te,z-image-turbo,z-image-te,flux-ae,kroma,kroma-te,wan21-vae,anima,anima-te
```

Logs: `logs\images-router-<ts>.out` (the router: loads, evictions, restarts) and
`logs\images-<model>-<ts>.err/.out` per backend. The supervisor restarts the router if it exits and,
after more than 5 exits in an hour, **backs off 15 minutes and tries again** rather than giving up —
a hard stop would leave `:8080` dead until the next logon with nothing watching. Edit
`image-models.json` and `POST /studio/reload-registry` to pick up registry changes without a restart.

- **Client timeouts must be 3+ minutes.** A 1024² generation takes 1.5–2.5 min depending on the model,
  and the OpenAI routes answer only when the image is done; many clients default to 60 s.
- **Concurrent requests to one model queue** (measured: two simultaneous 512² requests returned after
  14 s and 28 s). Requests to *different* resident models run at the same time and share the GPU.
- **Registry reloads keep live ports (fixed 2026-10-15).** Backend ports used to be numbered by list
  position, so a model inserted mid-list on `POST /studio/reload-registry` was handed the port of a
  *running* backend further down — its health check and requests would have reached the other model.
  A new entry now gets the lowest port no existing backend holds, and an entry removed from the file has
  its running backend stopped. (Takes effect at the next router start; until then append new models
  at the END of `image-models.json`.)
- **Freezes are not detected.** Exits are (backend: on the next request; router: by the supervisor);
  a backend that hangs with the GPU idle is not. Kill its `sd-server.exe` and the router restarts it.
- **System RAM:** the backends use none, but Windows only sees ~32 GB. On 2026-10-15 WSL / Docker
  Desktop (`vmmemWSL`) grew to 14 GB of it while a model loaded, and free RAM briefly hit ~0. Keep
  WSL's memory capped (`.wslconfig`) or stopped when the box is busy.

**Rollback to the LLM:** the Startup launcher keeps the three LLM lines (router, metrics exporter,
watchdog) commented out with a `rem ROLLBACK-LLM:` prefix. Uncomment them and comment out the
`run-images.ps1` line. Both cannot share `:8080`.

**Lost by the switch:** any app calling `/v1/chat/completions` on `:8080` now gets an error — there is
no text model on this box any more. The LLM's metrics exporter (`:9114`) and watchdog are off.
