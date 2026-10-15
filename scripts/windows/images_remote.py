"""images_remote.py -- add image models and LoRAs from Hugging Face and CivitAI to images-router.

Loaded by images-router.py by file path (the router runs under `python -I`, which keeps this
directory off sys.path). Stdlib only.

  inspect(url)   a huggingface.co / civitai.com / civitai.red link -> what it is: model or LoRA, which
                 sd.cpp family (from CivitAI's baseModel, the HF card's base_model, or the tensor names
                 in the file's own header), the files, licence, NSFW flag, what else it needs
  Remote.add()   queue a download (the file + any missing companion encoders/VAEs), verify size and
                 sha256, then register it in the LOCAL registry (<models>/image-models.local.json --
                 never the tracked one: this repo is public)

Tokens come from the environment or HKCU\\Environment (so `setx CIVITAI_TOKEN ...` works without a
restart). They are sent ONLY to civitai.* / huggingface.co -- never on the cross-host redirect to the
storage CDN (a presigned S3 URL rejects a request that also carries Authorization) -- and never put in
a URL, a response or a log line.
"""
import hashlib
import http.client
import json
import os
import re
import shutil
import ssl
import struct
import threading
import time
import urllib.parse

CIVITAI_HOSTS = {"civitai.com", "civitai.red", "civitai.green", "www.civitai.com"}
HF_HOSTS = {"huggingface.co", "www.huggingface.co"}
MIN_FREE_BYTES = 50 * 1000 ** 3          # refuse a download that would leave less than this on the models disk
UA = "strix-image-studio/1.0"
MODEL_EXT = (".safetensors", ".gguf")


class RemoteError(Exception):
    """A user-facing failure (message is shown in the UI as is)."""


class NeedAuth(RemoteError):
    pass


# ---- tokens ----------------------------------------------------------------------------------------
def _token(names):
    for n in names:
        v = os.environ.get(n)
        if v:
            return v.strip()
    if os.name == "nt":                  # a `setx` after the router started lands here, not in os.environ
        try:
            import winreg
            with winreg.OpenKey(winreg.HKEY_CURRENT_USER, "Environment") as k:
                for n in names:
                    try:
                        v, _ = winreg.QueryValueEx(k, n)
                        if v:
                            return str(v).strip()
                    except OSError:
                        pass
        except OSError:
            pass
    return None


def civitai_token():
    return _token(("CIVITAI_TOKEN", "CIVITAI_API_TOKEN", "CIVITAI_API_KEY"))


def hf_token():
    return _token(("HF_TOKEN", "HUGGING_FACE_HUB_TOKEN"))


def token_status():
    return {"civitai": bool(civitai_token()), "hf": bool(hf_token())}


def _auth_for(host):
    host = (host or "").lower()
    if host in CIVITAI_HOSTS:
        return civitai_token()
    if host in HF_HOSTS:
        return hf_token()
    return None                           # CDN / S3 hosts: never


# ---- HTTP with hand-followed redirects ---------------------------------------------------------------
_CTX = ssl.create_default_context()


def open_url(url, headers=None, timeout=60, method="GET"):
    """Return (conn, response) for the final hop. Authorization goes only to civitai/HF hosts."""
    for _ in range(10):
        u = urllib.parse.urlsplit(url)
        if u.scheme != "https" or not u.hostname:
            raise RemoteError("only https links are supported")
        h = {"User-Agent": UA, "Accept-Encoding": "identity"}
        h.update(headers or {})
        tok = _auth_for(u.hostname)
        if tok:
            h["Authorization"] = "Bearer " + tok
        conn = http.client.HTTPSConnection(u.hostname, u.port or 443, timeout=timeout, context=_CTX)
        conn.request(method, (u.path or "/") + ("?" + u.query if u.query else ""), headers=h)
        r = conn.getresponse()
        if r.status in (301, 302, 303, 307, 308):
            loc = r.getheader("Location")
            r.read()
            conn.close()
            if not loc:
                raise RemoteError("redirect without a location from %s" % u.hostname)
            url = urllib.parse.urljoin(url, loc)
            continue
        if r.status in (401, 403):
            body = r.read(400).decode("utf-8", "replace")
            conn.close()
            raise NeedAuth(_auth_message(u.hostname, r.status, body))
        return conn, r
    raise RemoteError("too many redirects")


def _auth_message(host, status, body):
    host = (host or "").lower()
    if host in CIVITAI_HOSTS:
        if civitai_token():
            return ("CivitAI refused the download with your API key (HTTP %d) -- the model may be early-access, "
                    "or the key is invalid/expired." % status)
        return ("CivitAI needs an API key for this file (HTTP %d). Create one at civitai.com > Account settings > "
                "API keys, then on the box run  setx CIVITAI_TOKEN <key>  in a terminal (no restart needed)." % status)
    if host in HF_HOSTS:
        if hf_token():
            return "Hugging Face refused access (HTTP %d): accept the model's terms on its page with your account." % status
        return ("This Hugging Face repo is gated (HTTP %d): accept its terms on huggingface.co, then on the box run "
                " setx HF_TOKEN <read token>  in a terminal." % status)
    return "access denied by %s (HTTP %d)" % (host, status)


def get_json(url, timeout=30):
    conn, r = open_url(url, {"Accept": "application/json"}, timeout)
    try:
        data = r.read()
    finally:
        conn.close()
    if r.status == 404:
        raise RemoteError("not found: %s" % url)
    if r.status >= 400:
        raise RemoteError("HTTP %d from %s" % (r.status, urllib.parse.urlsplit(url).hostname))
    return json.loads(data)


def get_range(url, start, end, timeout=60):
    conn, r = open_url(url, {"Range": "bytes=%d-%d" % (start, end)}, timeout)
    try:
        if r.status == 206:
            return r.read()
        if r.status == 200:                  # no range support: take only what we asked for
            return r.read(end - start + 1) if start == 0 else None
        raise RemoteError("HTTP %d reading the file header" % r.status)
    finally:
        conn.close()


# ---- companions + families ---------------------------------------------------------------------------
# Companion files a family needs besides the main model (text encoders, VAEs). `file` = local name under
# MODELS_DIR; src = an ungated HF file with its exact byte count (checked 2026-10-15).
def _hf(repo, path, size):
    return {"repo": repo, "path": path, "bytes": size}


COMPANIONS = {
    "sdxl-vae":    dict(file="sdxl-vae-fp16-fix.safetensors", **_hf("madebyollin/sdxl-vae-fp16-fix", "sdxl.vae.safetensors", 334641162)),
    "clip-l":      dict(file="clip_l.safetensors", **_hf("comfyanonymous/flux_text_encoders", "clip_l.safetensors", 246144152)),
    "clip-g":      dict(file="clip_g.safetensors", **_hf("Comfy-Org/stable-diffusion-3.5-fp8", "text_encoders/clip_g.safetensors", 1389382176)),
    "t5xxl":       dict(file="t5xxl_fp16.safetensors", **_hf("comfyanonymous/flux_text_encoders", "t5xxl_fp16.safetensors", 9787841024)),
    "flux-ae":     dict(file="ae.safetensors", **_hf("Comfy-Org/z_image_turbo", "split_files/vae/ae.safetensors", 335304388)),
    "flux2-vae":   dict(file="flux2-vae.safetensors", **_hf("Comfy-Org/flux2-klein-4B", "split_files/vae/flux2-vae.safetensors", 336211292)),
    "qwen3-4b":    dict(file="Qwen3-4B-Q8_0.gguf", **_hf("Qwen/Qwen3-4B-GGUF", "Qwen3-4B-Q8_0.gguf", 4280404704)),
    "qwen3-8b":    dict(file="Qwen3-8B-Q8_0.gguf", **_hf("Qwen/Qwen3-8B-GGUF", "Qwen3-8B-Q8_0.gguf", 8709518112)),
    "mistral-24b": dict(file="Mistral-Small-3.2-24B-Instruct-2506-Q8_0.gguf",
                        **_hf("unsloth/Mistral-Small-3.2-24B-Instruct-2506-GGUF", "Mistral-Small-3.2-24B-Instruct-2506-Q8_0.gguf", 25054793248)),
    "qwen25vl-7b": dict(file="Qwen2.5-VL-7B-Instruct.Q8_0.gguf", **_hf("mradermacher/Qwen2.5-VL-7B-Instruct-GGUF", "Qwen2.5-VL-7B-Instruct.Q8_0.gguf", 8098524160)),
    "qwen-image-vae": dict(file="qwen_image_vae.safetensors", **_hf("Comfy-Org/Qwen-Image_ComfyUI", "split_files/vae/qwen_image_vae.safetensors", 253806246)),
    "qwen3vl-8b":  dict(file="Qwen3VL-8B-Instruct-F16.gguf", **_hf("Qwen/Qwen3-VL-8B-Instruct-GGUF", "Qwen3VL-8B-Instruct-F16.gguf", 16388044896)),
    "qwen3vl-8b-mmproj": dict(file="mmproj-Qwen3VL-8B-Instruct-F16.gguf", **_hf("Qwen/Qwen3-VL-8B-Instruct-GGUF", "mmproj-Qwen3VL-8B-Instruct-F16.gguf", 1159029824)),
    "qwen-image-21-vae": dict(file="qwen_image_2.1_vae_bf16.safetensors", **_hf("Comfy-Org/Qwen-Image-2.1", "vae/qwen_image_2.1_vae_bf16.safetensors", 675509688)),
    "qwen3vl-4b":  dict(file="Qwen3VL-4B-Instruct-Q8_0.gguf", **_hf("Qwen/Qwen3-VL-4B-Instruct-GGUF", "Qwen3VL-4B-Instruct-Q8_0.gguf", 4280406144)),
    "wan21-vae":   dict(file="wan_2.1_vae.safetensors", **_hf("Comfy-Org/Wan_2.1_ComfyUI_repackaged", "split_files/vae/wan_2.1_vae.safetensors", 253815318)),
    "qwen3-06b":   dict(file="qwen_3_06b_base.safetensors", **_hf("circlestone-labs/Anima", "split_files/text_encoders/qwen_3_06b_base.safetensors", 1192135096)),
}


# sha256 of each companion (HF LFS oid, fetched 2026-10-16): a fresh download is verified against it
COMPANION_SHA256 = {
    "sdxl-vae": "235745af8d86bf4a4c1b5b4f529868b37019a10f7c0b2e79ad0abca3a22bc6e1",
    "clip-l": "660c6f5b1abae9dc498ac2d21e1347d2abdb0cf6c0c0c8576cd796491d9a6cdd",
    "clip-g": "ec310df2af79c318e24d20511b601a591ca8cd4f1fce1d8dff822a356bcdb1f4",
    "t5xxl": "6e480b09fae049a72d2a8c5fbccb8d3e92febeb233bbe9dfe7256958a9167635",
    "flux-ae": "afc8e28272cd15db3919bacdb6918ce9c1ed22e96cb12c4d5ed0fba823529e38",
    "flux2-vae": "868fe7b343cc8f3a19dbcfcafbc3d5f888802be3f89bd81b65b3621a066ce8f3",
    "qwen3-4b": "8c2f07f26af9747e41988551106f149b03eb9b5cb6df636027b6bf6278473300",
    "qwen3-8b": "408b955510e196121c1c375201744783b5c9a43c7956d73fc78df54c66e883d6",
    "mistral-24b": "b2a40e5ef4eab8837d0462c303e8147ec754e2963e41916b551107d2b0ca6527",
    "qwen25vl-7b": "577bfb3e41f93f00414e594c56a38bbe91207b3b636ab7faf343e34a20aa73ca",
    "qwen-image-vae": "a70580f0213e67967ee9c95f05bb400e8fb08307e017a924bf3441223e023d1f",
    "qwen3vl-8b": "2715c1a097f1943fb88ad59c7c0e9288a7a50c84d60cf18c6227bd9a40520972",
    "qwen3vl-8b-mmproj": "ca524100ebf825c9a870db1c580d03879e0da0ab2541697e2458e64891cf9d38",
    "qwen-image-21-vae": "bb21f7473051e1ac368515dd3f2e15cd44d7a11748ee8823e1ddca3e4876b7c9",
    "qwen3vl-4b": "054721f478bc5fa6beffb7f38eae575d45298f88cbb8d2f83ef675a727863eb1",
    "wan21-vae": "2fc39d31359a4b0a64f55876d8ff7fa8d780956ae2cb13463b0223e15148976b",
    "qwen3-06b": "cd2a512003e2f9f3cd3c32a9c3573f820bb28c940f73c57b1ddaa983d9223eba",
}


def _ui(steps, cfg, sampler="euler", w=1024, h=1024, **extra):
    d = {"edit": False, "alpha": False, "steps": steps, "cfg": cfg, "sampler": sampler, "width": w, "height": h}
    d.update(extra)
    return d


# Each family: how stable-diffusion.cpp master-967 loads it. `main` = the flag the downloaded file is
# passed with; `comps` = flag -> companion. `fast` = defaults for distilled / turbo / lightning variants.
# `group` = LoRA compatibility. Recipes follow upstream docs/*.md for this build.
FAMILIES = {
    "sd15": dict(label="Stable Diffusion 1.5", group="sd15", main="model", comps={},
                 ui=_ui(25, 7, "euler_a", 512, 512), fast=_ui(6, 1.5, "euler_a", 512, 512),
                 note="SD 1.5 renders natively at 512-768 px."),
    "sdxl": dict(label="SDXL / Pony / Illustrious / NoobAI", group="sdxl", main="model", comps={"vae": "sdxl-vae"},
                 ui=_ui(28, 6, "euler_a"), fast=_ui(8, 1.5, "euler_a"),
                 note="Illustrious / NoobAI: booru tags, e.g. 'masterpiece, best quality, 1girl, ...'. Pony: start with "
                      "'score_9, score_8_up, score_7_up'. The fp16-fix VAE replaces the baked-in one (fp16 NaNs)."),
    "sd2": dict(label="Stable Diffusion 2.x", group="sd2", main="model", comps={},
                ui=_ui(25, 7, "euler_a", 768, 768), fast=_ui(8, 1.5, "euler_a", 768, 768),
                note="SD 2.x 768 models are v-prediction (set automatically when the file or CivitAI says so)."),
    "sd35": dict(label="Stable Diffusion 3.5", group="sd35", main="model", comps={"clip_l": "clip-l", "clip_g": "clip-g", "t5xxl": "t5xxl"},
                 ui=_ui(28, 4.5), fast=_ui(8, 1.5)),
    "flux1": dict(label="FLUX.1 (dev / Krea)", group="flux1", main="diffusion-model", comps={"clip_l": "clip-l", "t5xxl": "t5xxl", "vae": "flux-ae"},
                  ui=_ui(20, 1), fast=_ui(8, 1), note="Guidance is distilled: keep CFG 1."),
    "flux1-schnell": dict(label="FLUX.1 schnell", group="flux1", main="diffusion-model",
                          comps={"clip_l": "clip-l", "t5xxl": "t5xxl", "vae": "flux-ae"}, ui=_ui(4, 1), fast=_ui(4, 1)),
    "flux2-klein4": dict(label="FLUX.2 klein 4B", group="flux2-klein4", main="diffusion-model", comps={"llm": "qwen3-4b", "vae": "flux2-vae"},
                         ui=_ui(4, 1), fast=_ui(4, 1), base_ui=_ui(20, 4)),
    "flux2-klein9": dict(label="FLUX.2 klein 9B", group="flux2-klein9", main="diffusion-model", comps={"llm": "qwen3-8b", "vae": "flux2-vae"},
                         ui=_ui(4, 1), fast=_ui(4, 1), base_ui=_ui(20, 4)),
    "flux3-klein": dict(label="FLUX.3 Image Klein", group="flux3-klein", main="diffusion-model",
                        comps={"llm": "qwen3vl-4b", "vae": "flux2-vae"}, engine="bin-sd-master-968-8cd731e/sd-server.exe",
                        ui=_ui(16, 1, edit=True, img_cfg=1), fast=_ui(16, 1, edit=True, img_cfg=1), base_ui=_ui(20, 3.5, edit=True, img_cfg=3.5),
                        note="FLUX Kommunity License: free commercial use under $5M revenue. Needs sd.cpp master-968+."),
    "flux2-dev": dict(label="FLUX.2 dev (heavy: 24B text encoder)", group="flux2-dev", main="diffusion-model",
                      comps={"llm": "mistral-24b", "vae": "flux2-vae"}, ui=_ui(28, 1), fast=_ui(8, 1)),
    "chroma": dict(label="Chroma", group="chroma", main="diffusion-model", comps={"t5xxl": "t5xxl", "vae": "flux-ae"},
                   args=["--model-args", "chroma_use_dit_mask=false"], ui=_ui(26, 4), fast=_ui(8, 1)),
    "qwen-image": dict(label="Qwen-Image (1.x)", group="qwen-image", main="diffusion-model", comps={"llm": "qwen25vl-7b", "vae": "qwen-image-vae"},
                       ui=_ui(30, 4), fast=_ui(8, 1)),
    "qwen-image-2.1": dict(label="Qwen-Image 2.1", group="qwen-image-2.1", main="diffusion-model",
                           comps={"llm": "qwen3vl-8b", "llm_vision": "qwen3vl-8b-mmproj", "vae": "qwen-image-21-vae"},
                           ui=_ui(40, 6, edit=True, alpha=True, img_cfg=6), fast=_ui(8, 1, edit=True, alpha=True, img_cfg=1)),
    "zimage-turbo": dict(label="Z-Image Turbo", group="zimage", main="diffusion-model", comps={"llm": "qwen3-4b", "vae": "flux-ae"},
                         ui=_ui(8, 1), fast=_ui(8, 1)),
    "zimage-base": dict(label="Z-Image (base)", group="zimage", main="diffusion-model", comps={"llm": "qwen3-4b", "vae": "flux-ae"},
                        ui=_ui(30, 4), fast=_ui(8, 1)),
    "krea2": dict(label="Krea 2", group="krea2", main="diffusion-model", comps={"llm": "qwen3vl-4b", "vae": "wan21-vae"},
                  ui=_ui(28, 4), fast=_ui(10, 1)),
    "anima": dict(label="Anima", group="anima", main="diffusion-model", comps={"llm": "qwen3-06b", "vae": "qwen-image-vae"},
                  ui=_ui(30, 4), fast=_ui(10, 1), note="Rating tags steer content: safe, sensitive, nsfw, explicit."),
}

UNSUPPORTED = {   # CivitAI ecosystems that are open-weight but not loadable by this sd.cpp build (or hosted-only)
    "HiDream": "HiDream I1 is not supported by stable-diffusion.cpp (only HiDream-O1 is)",
    "Pony V7": "Pony V7 is AuraFlow-based, which stable-diffusion.cpp does not load",
    "AuraFlow": "AuraFlow is not supported by stable-diffusion.cpp",
    "Kolors": "Kolors is not supported by stable-diffusion.cpp",
    "Hunyuan 1": "Hunyuan-DiT is not supported by stable-diffusion.cpp",
    "Stable Cascade": "Stable Cascade is not supported by stable-diffusion.cpp",
    "Flux.1 Kontext": "Kontext is an editing model; add it from Hugging Face as FLUX.1 if you want to try it",
}

CIVITAI_BASE = {
    "SD 1.4": "sd15", "SD 1.5": "sd15", "SD 1.5 LCM": "sd15", "SD 1.5 Hyper": "sd15",
    "SD 2.0": "sd2", "SD 2.0 768": "sd2", "SD 2.1": "sd2", "SD 2.1 768": "sd2",
    "SDXL 0.9": "sdxl", "SDXL 1.0": "sdxl", "SDXL 1.0 LCM": "sdxl", "SDXL Lightning": "sdxl", "SDXL Hyper": "sdxl",
    "SDXL Turbo": "sdxl", "SDXL Distilled": "sdxl", "Pony": "sdxl", "Illustrious": "sdxl", "NoobAI": "sdxl",
    "SD 3": "sd35", "SD 3.5": "sd35", "SD 3.5 Large": "sd35", "SD 3.5 Large Turbo": "sd35", "SD 3.5 Medium": "sd35",
    "Flux.1 D": "flux1", "Flux.1 Krea": "flux1", "Flux.1 S": "flux1-schnell",
    "Flux.2 Klein 4B": "flux2-klein4", "Flux.2 Klein 4B-base": "flux2-klein4",
    "Flux.2 Klein 9B": "flux2-klein9", "Flux.2 Klein 9B-base": "flux2-klein9", "Flux.2 D": "flux2-dev",
    "Flux.3 Klein": "flux3-klein", "Flux.3 Klein-base": "flux3-klein",
    "Chroma": "chroma", "Qwen": "qwen-image", "Qwen 2.1": "qwen-image-2.1",
    "ZImageTurbo": "zimage-turbo", "ZImageBase": "zimage-base",
    "Krea 2": "krea2", "Krea 2 Turbo": "krea2", "Anima": "anima",
}

FAST_RE = re.compile(r"\b(turbo|lightning|hyper(-?sd)?|lcm|dmd2?|distill(ed)?|schnell|fast)\b|\b\d{1,2}[ _-]?steps?\b", re.I)


def family_list():
    return [{"id": k, "label": v["label"], "group": v["group"],
             "companions": [dict(COMPANIONS[c], key=c, flag=f) for f, c in v["comps"].items()]}
            for k, v in FAMILIES.items()]


# ---- family detection from a file's own tensor names -------------------------------------------------
LORA_MARKS = ("lora_a", "lora_b", "lora_down", "lora_up", "hada_w1", "lokr_w1", "lora_te", "lora_unet", "dora_scale")


def classify_keys(keys):
    """(kind, family, allinone) from tensor names; kind in {'lora','model',None}."""
    norm = [k.lower().replace(".", "_") for k in keys]
    blob = "\n".join(norm[:5000])
    kind = "lora" if any(m in blob for m in LORA_MARKS) else "model"
    has = blob.__contains__
    fam = None
    if has("cap_embedder") or has("context_refiner") or has("noise_refiner") or \
            (has("layers_0_attention") and (has("feed_forward") or has("adaln_modulation"))):
        fam = "zimage-turbo"
    elif has("txtfusion") or has("txtmlp"):
        fam = "krea2"
    elif has("llm_adapter") or has("adaln_modulation_cross_attn"):
        fam = "anima"
    elif (has("double_blocks") and has("single_blocks")) or has("single_transformer_blocks"):
        fam = "chroma" if has("distilled_guidance_layer") else ("flux1" if has("guidance_in") or kind == "lora" else "flux1-schnell")
    elif has("double_stream_modulation") or has("single_stream_modulation"):
        fam = "flux2-klein4"
    elif has("transformer_blocks") and (has("img_mod") or has("img_mlp") or (has("img_in") and has("txt_in"))):
        fam = "qwen-image-2.1" if re.search(r"(^|_)modulation_1_", blob) and not has("img_mod") else "qwen-image"
    elif has("joint_blocks") or has("context_block"):
        fam = "sd35"
    elif has("conditioner_embedders_1") or has("lora_te2") or has("label_emb") or has("add_embedding") or \
            re.search(r"(input|middle|output|down|mid|up)_blocks?_\d+_(\d+_|attentions_\d+_)transformer_blocks_[1-9]", blob):
        # SDXL's attention blocks hold 2-10 transformer blocks; SD 1.5's hold exactly one (index 0)
        fam = "sdxl"
    elif has("cond_stage_model_model_transformer"):            # OpenCLIP text encoder = SD 2.x
        fam = "sd2"
    elif has("cond_stage_model_transformer") or has("input_blocks") or has("down_blocks") or has("lora_te_"):
        fam = "sd15"
    allinone = kind == "model" and (has("text_encoders_") or has("cond_stage_model") or has("conditioner_embedders")) \
        and fam not in ("sd15", "sd2", "sdxl", "sd35")
    return kind, fam, allinone


def unet_only(keys, family):
    """A UNet-only SD/SDXL file has no text encoder to load with -m (and this tool has no CLIP companions for it)."""
    if family not in ("sd15", "sd2", "sdxl"):
        return False
    blob = "\n".join(k.lower() for k in keys[:20000])
    return not any(m in blob for m in ("conditioner.", "cond_stage_model.", "text_encoders.", "te_"))


def is_vpred(keys, meta):
    meta = meta or {}
    pt = str(meta.get("modelspec.prediction_type") or meta.get("prediction_type") or "").lower()
    return pt in ("v", "v_prediction", "v-prediction") or any(k in ("v_pred", "ztsnr") for k in keys)


def _gguf_names(buf):
    """Tensor names from a GGUF header held in `buf` (raises IndexError/struct.error if buf is too short)."""
    o = 4 + 4
    nt, nkv = struct.unpack_from("<QQ", buf, o)
    o += 16
    sz = {0: 1, 1: 1, 2: 2, 3: 2, 4: 4, 5: 4, 6: 4, 7: 1, 10: 8, 11: 8, 12: 8}

    def rstr(o):
        n, = struct.unpack_from("<Q", buf, o)
        if o + 8 + n > len(buf):
            raise IndexError
        return buf[o + 8:o + 8 + n].decode("utf-8", "replace"), o + 8 + n
    for _ in range(nkv):
        _, o = rstr(o)
        t, = struct.unpack_from("<I", buf, o)
        o += 4
        if t == 8:
            _, o = rstr(o)
        elif t == 9:
            et, n = struct.unpack_from("<IQ", buf, o)
            o += 12
            if et == 8:
                for _ in range(n):
                    _, o = rstr(o)
            else:
                o += sz[et] * n
        else:
            o += sz[t]
    names = []
    for _ in range(nt):
        nm, o = rstr(o)
        nd, = struct.unpack_from("<I", buf, o)
        o += 4 + 8 * nd + 4 + 8
        names.append(nm)
    return names


def sniff(url):
    """(tensor names, safetensors __metadata__) of a remote .safetensors / .gguf via Range requests (a few MB)."""
    head = get_range(url, 0, 7)
    if not head or len(head) < 8:
        return None
    if head[:4] == b"GGUF":
        for size in (2 << 20, 16 << 20, 64 << 20):
            buf = get_range(url, 0, size - 1)
            try:
                return _gguf_names(buf), {}
            except (IndexError, struct.error):
                if not buf or len(buf) < size:
                    return None
        return None
    n, = struct.unpack("<Q", head)
    if n > 100 << 20:
        return None
    hdr = json.loads(get_range(url, 8, 8 + n - 1))
    meta = hdr.pop("__metadata__", None) or {}
    return list(hdr), meta


# ---- inspect ---------------------------------------------------------------------------------------------
def _slug(s, n=40):
    s = re.sub(r"[^a-z0-9]+", "-", (s or "").lower()).strip("-")
    return s[:n].strip("-") or "model"


def safe_filename(name):
    base = os.path.basename((name or "").replace("\\", "/"))
    base = re.sub(r"[^A-Za-z0-9._()+ -]+", "_", base).strip(" .")
    if not base.lower().endswith(MODEL_EXT):
        raise RemoteError("only .safetensors and .gguf files can be added (got %r)" % name)
    return base


def _fast(*texts):
    return bool(FAST_RE.search(" ".join(t or "" for t in texts)))


def _commercial(v):
    if isinstance(v, list):
        v = ",".join(v)
    v = v or ""
    if not v or v == "None":
        return "no commercial use"
    parts = []
    if "Image" in v:
        parts.append("images may be sold")
    if "Rent" in v:
        parts.append("may be run on paid services")
    if "Sell" in v:
        parts.append("the model may be sold")
    return ", ".join(parts) or v


def parse_url(url):
    url = (url or "").strip()
    if url.startswith("civitai:") or url.isdigit():
        return {"site": "civitai", "host": "civitai.com", "model": url.split(":")[-1], "version": None}
    u = urllib.parse.urlsplit(url)
    host = (u.hostname or "").lower()
    if host in CIVITAI_HOSTS:
        q = urllib.parse.parse_qs(u.query)
        m = re.match(r"^/models/(\d+)", u.path)
        d = re.match(r"^/api/download/models/(\d+)", u.path)
        v = re.match(r"^/model-versions/(\d+)", u.path)
        return {"site": "civitai", "host": "civitai.green" == host and "civitai.com" or host.replace("www.", ""),
                "model": m.group(1) if m else None,
                "version": (q.get("modelVersionId") or [None])[0] or (d.group(1) if d else None) or (v.group(1) if v else None)}
    if host in HF_HOSTS:
        parts = [urllib.parse.unquote(p) for p in u.path.strip("/").split("/")]
        if len(parts) < 2:
            raise RemoteError("that Hugging Face link has no repo in it")
        repo, rev, path = "/".join(parts[:2]), "main", None
        if len(parts) >= 4 and parts[2] in ("blob", "resolve", "tree"):
            rev = parts[3]
            rest = "/".join(parts[4:])
            path = rest if parts[2] != "tree" and rest else None
        return {"site": "hf", "repo": repo, "rev": rev, "path": path}
    raise RemoteError("paste a link from huggingface.co, civitai.com or civitai.red")


_CACHE, _CACHE_LOCK = {}, threading.Lock()


def inspect(url, file_key=None):
    """Cached for 5 minutes per (url, file): changing the family in the dialog must not re-query the site."""
    key = (url, file_key)
    with _CACHE_LOCK:
        hit = _CACHE.get(key)
        if hit and time.time() - hit[0] < 300:
            return json.loads(hit[1])
    p = parse_url(url)
    info = _inspect_civitai(p, file_key) if p["site"] == "civitai" else _inspect_hf(p, file_key)
    with _CACHE_LOCK:
        if len(_CACHE) > 64:
            _CACHE.clear()
        _CACHE[key] = (time.time(), json.dumps(info))
    return info


DIT_FAMILIES = ("flux1", "flux1-schnell", "chroma", "sd35", "qwen-image", "qwen-image-2.1", "krea2", "zimage-turbo",
                "zimage-base", "flux2-klein4", "flux2-klein9", "flux2-dev", "anima")


def _flags(info, keys, meta, sel):
    """Shared post-sniff checks for both sites."""
    fam = info.get("family")
    info["vpred"] = bool(keys) and is_vpred(keys, meta) or bool(re.search(r"v-?pred", sel["name"], re.I)) or \
        info.get("base") in ("SD 2.0 768", "SD 2.1 768")
    info["unet_only"] = bool(keys) and info.get("kind") == "model" and unet_only(keys, fam)
    if info["unet_only"]:
        info["unsupported"] = ("this is a UNet-only %s file without its text encoders -- pick the full checkpoint "
                               "(usually the bigger file)" % (FAMILIES[fam]["label"] if fam in FAMILIES else "SD"))
    fp8 = re.search(r"fp8|e4m3|e5m2", sel["name"] + " " + sel.get("detail", ""), re.I)
    info["warn_fp8"] = bool(fp8) and fam in DIT_FAMILIES
    # FLUX.2 klein 4B and 9B share tensor names; the file cannot tell them apart, so don't claim it does
    if fam and info.get("sniffed") and fam.startswith("flux2-klein") and info["sniffed"].startswith("flux2-klein"):
        info["sniffed"] = fam
    return info


def _civitai_api(p, path):
    hosts = [p["host"]] + [h for h in ("civitai.red", "civitai.com") if h != p["host"]]
    last = None
    for h in hosts:                      # SFW-only .com may hide what .red shows
        try:
            return get_json("https://%s/api/v1/%s" % (h, path)), h
        except RemoteError as e:
            last = e
            if isinstance(e, NeedAuth):
                raise
    raise last


def _inspect_civitai(p, file_key):
    if p["model"]:
        m, host = _civitai_api(p, "models/%s" % p["model"])
        versions = m.get("modelVersions") or []
        v = next((x for x in versions if str(x.get("id")) == str(p["version"])), None) if p["version"] else None
        v = v or next((x for x in versions if x.get("status", "Published") == "Published"), versions[0] if versions else None)
        if not v:
            raise RemoteError("that CivitAI model has no downloadable version")
    else:
        v, host = _civitai_api(p, "model-versions/%s" % p["version"])
        m, host = _civitai_api(dict(p, host=host), "models/%s" % v.get("modelId"))
        versions = m.get("modelVersions") or [v]
    mtype = m.get("type") or ""
    kind = "lora" if mtype in ("LORA", "LoCon", "DoRA") else "model" if mtype in ("Checkpoint", "UNet") else None
    base = v.get("baseModel") or ""
    files = []
    for f in v.get("files") or []:
        name = f.get("name") or ""
        if not name.lower().endswith(MODEL_EXT):
            continue
        dl = f.get("downloadUrl") or ""
        dl = re.sub(r"^https://civitai\.(com|red|green)/", "https://%s/" % host, dl)
        md = f.get("metadata") or {}
        files.append({"key": str(f.get("id")), "name": name, "bytes": int(float(f.get("sizeKB") or 0) * 1024),
                      "sha256": ((f.get("hashes") or {}).get("SHA256") or "").lower() or None,
                      "format": md.get("format") or ("GGUF" if name.lower().endswith(".gguf") else "SafeTensor"),
                      "detail": " ".join(str(x) for x in (md.get("fp"), md.get("size")) if x),
                      "primary": bool(f.get("primary")), "url": dl,
                      "scan": f.get("pickleScanResult") == "Success" and f.get("virusScanResult") == "Success"})
    if not files:
        raise RemoteError("this version has no .safetensors or .gguf file")
    sel = next((f for f in files if f["key"] == str(file_key)), None) or next((f for f in files if f["primary"]), files[0])
    family = CIVITAI_BASE.get(base)
    why = "CivitAI base model '%s'" % base if family else None
    unsupported = None if family else UNSUPPORTED.get(base) or ("'%s' is not a family this sd.cpp build can load" % base if base else None)
    allinone = False
    access, sniffed, keys, meta = None, None, None, {}
    try:
        got = sniff(sel["url"])
        if got:
            keys, meta = got
            k2, f2, allinone = classify_keys(keys)
            sniffed = f2
            if kind is None:
                kind = k2
            if not family and f2:
                family, why, unsupported = f2, "tensor names in the file", None
        access = "ok"
    except NeedAuth as e:
        access = str(e)
    except (RemoteError, OSError, ValueError) as e:
        access = "could not read the file header: %s" % e
    nsfw = bool(m.get("nsfw")) or bool((m.get("nsfwLevel") or 0) & 24)   # bitmask: 1 PG, 2 PG-13, 4 R, 8 X, 16 XXX
    return _flags({
        "site": "civitai", "host": host, "page": "https://%s/models/%s?modelVersionId=%s" % (host, m.get("id"), v.get("id")),
        "name": m.get("name"), "version": {"id": v.get("id"), "name": v.get("name")},
        "versions": [{"id": x.get("id"), "name": x.get("name"), "base": x.get("baseModel")} for x in versions[:30]],
        "kind": kind, "type": mtype, "base": base, "family": family, "family_why": why, "sniffed": sniffed,
        "unsupported": unsupported, "allinone": allinone, "fast": _fast(base, v.get("name"), sel["name"], m.get("name")),
        "nsfw": nsfw, "licence": "CivitAI: %s%s" % (_commercial(m.get("allowCommercialUse")),
                                                    "" if m.get("allowDerivatives", True) else "; no derivatives"),
        "trained_words": v.get("trainedWords") or [], "files": files, "file": sel["key"], "access": access,
        "suggested_id": _slug(m.get("name")), "suggested_label": "%s%s" % (m.get("name"), " (%s)" % v.get("name") if len(versions) > 1 else ""),
    }, keys, meta, sel)


HF_BASE = [  # regex over the card's base_model / tags / repo name -> family
    (r"z-image-turbo|z_image_turbo", "zimage-turbo"), (r"z-image|z_image", "zimage-base"),
    (r"flux[.-]?3.*klein", "flux3-klein"),
    (r"flux\.?2.*klein.*9b", "flux2-klein9"), (r"flux\.?2.*klein", "flux2-klein4"), (r"flux\.?2", "flux2-dev"),
    (r"flux\.?1.*schnell", "flux1-schnell"), (r"flux\.?1|flux-dev|flux1", "flux1"),
    (r"\bchroma", "chroma"), (r"\bkrea-?2|\bkrea2", "krea2"), (r"\banima\b", "anima"),
    (r"qwen-image-2\.1|qwen_image_2\.1", "qwen-image-2.1"), (r"qwen-image|qwen_image", "qwen-image"),
    (r"stable-diffusion-3|sd3", "sd35"),
    (r"stable-diffusion-xl|sdxl|pony|illustrious|noob", "sdxl"),
    (r"stable-diffusion-2|sd-?2\.[01]\b", "sd2"),
    (r"stable-diffusion-v1|stable-diffusion-v-1|sd-?1\.5|sd15", "sd15"),
]


def _inspect_hf(p, file_key):
    repo, rev = p["repo"], p["rev"]
    info = get_json("https://huggingface.co/api/models/%s?blobs=false" % repo)
    tree = get_json("https://huggingface.co/api/models/%s/tree/%s?recursive=true" % (repo, urllib.parse.quote(rev)))
    files = []
    for f in tree:
        path = f.get("path") or ""
        if f.get("type") != "file" or not path.lower().endswith(MODEL_EXT):
            continue
        if re.search(r"-\d{5}-of-\d{5}\.", path):      # diffusers shards are not single loadable files
            continue
        lfs = f.get("lfs") or {}
        files.append({"key": path, "name": os.path.basename(path), "path": path, "bytes": int(f.get("size") or lfs.get("size") or 0),
                      "sha256": lfs.get("oid"), "format": "GGUF" if path.lower().endswith(".gguf") else "SafeTensor",
                      "detail": os.path.dirname(path), "primary": False,
                      "url": "https://huggingface.co/%s/resolve/%s/%s" % (repo, urllib.parse.quote(rev), urllib.parse.quote(path))})
    if not files:
        raise RemoteError("no .safetensors or .gguf files in %s (diffusers-format repos with only sharded weights can't be loaded)" % repo)

    def rank(f):   # Q8_0 GGUF first (2.4x faster than bf16 on this driver), then root-level safetensors, bigger first
        n = f["name"].lower()
        return (0 if "q8_0" in n else 1 if n.endswith(".safetensors") and "/" not in f["path"] else 2, -f["bytes"])
    files.sort(key=rank)
    files[0]["primary"] = True
    want = file_key or p.get("path")
    sel = next((f for f in files if f["key"] == want), None) or files[0]
    card = info.get("cardData") or {}
    bm = card.get("base_model")
    bm = " ".join(bm) if isinstance(bm, list) else (bm or "")
    tags = info.get("tags") or []
    text = " ".join([bm, " ".join(tags), repo]).lower()
    family = next((fam for rx, fam in HF_BASE if re.search(rx, text)), None)
    why = "the model card (base_model / tags)" if family else None
    kind = "lora" if ("lora" in tags or "lora" in sel["name"].lower()) else None
    allinone, access, sniffed, keys, meta = False, None, None, None, {}
    try:
        got = sniff(sel["url"])
        if got:
            keys, meta = got
            k2, f2, allinone = classify_keys(keys)
            sniffed = f2
            kind = k2
            if f2 and (not family or (f2 != family and FAMILIES[f2]["group"] != FAMILIES[family]["group"])):
                family, why = f2, "tensor names in the file"
        access = "ok"
    except NeedAuth as e:
        access = str(e)
    except (RemoteError, OSError, ValueError) as e:
        access = "could not read the file header: %s" % e
    gated = info.get("gated")
    return _flags({
        "site": "hf", "host": "huggingface.co", "page": "https://huggingface.co/%s" % repo,
        "name": repo.split("/")[-1], "version": {"id": rev, "name": rev}, "versions": [],
        "kind": kind or "model", "type": "HF", "base": bm, "family": family, "family_why": why, "sniffed": sniffed,
        "unsupported": None, "allinone": allinone, "fast": _fast(repo, sel["name"], bm),
        "nsfw": "not-for-all-audiences" in tags, "licence": "HF: %s%s" % (card.get("license") or "see the model card",
                                                                         " (gated)" if gated else ""),
        "trained_words": card.get("instance_prompt") and [card["instance_prompt"]] or [], "files": files, "file": sel["key"],
        "access": access, "suggested_id": _slug(repo.split("/")[-1]), "suggested_label": repo.split("/")[-1],
    }, keys, meta, sel)


# ---- downloads ---------------------------------------------------------------------------------------------
class Job:
    def __init__(self, jid, label, items, on_done):
        self.id, self.label, self.items, self.on_done = jid, label, items, on_done
        self.state, self.error, self.result = "queued", "", None
        self.done_bytes, self.current, self.started, self.finished = 0, "", 0.0, 0.0
        self.speed, self.cancel = 0.0, False
        self.total = sum(i["bytes"] for i in items if not i.get("present"))

    def view(self):
        return {"id": self.id, "label": self.label, "state": self.state, "error": self.error, "result": self.result,
                "total": self.total, "done": self.done_bytes, "current": self.current, "speed": round(self.speed),
                "files": [{"name": i["name"], "bytes": i["bytes"], "present": bool(i.get("present"))} for i in self.items]}


class Remote:
    def __init__(self, models_dir, lora_dir, local_registry, log, on_change, ids=lambda: set()):
        self.models_dir, self.lora_dir, self.path, self.log, self.on_change = models_dir, lora_dir, local_registry, log, on_change
        self.ids = ids                         # every model id the router knows (tracked + local)
        self.lock = threading.RLock()
        self.jobs, self.queue = [], []
        self.cv = threading.Condition(self.lock)
        threading.Thread(target=self._worker, daemon=True).start()

    # local registry (atomic write; read on every change)
    def read(self):
        try:
            with open(self.path, encoding="utf-8") as f:
                d = json.load(f)
        except (OSError, ValueError):
            d = {}
        d.setdefault("models", [])
        d.setdefault("loras", [])
        return d

    def write(self, d):
        tmp = self.path + ".tmp"
        with open(tmp, "w", encoding="utf-8", newline="\n") as f:
            json.dump(d, f, indent=2, ensure_ascii=False)
            f.write("\n")
        os.replace(tmp, self.path)

    def update_model(self, mid, **fields):
        with self.lock:
            d = self.read()
            for m in d["models"]:
                if m.get("id") == mid:
                    m.update(fields)
            self.write(d)

    def companion_items(self, family):
        out = []
        for flag, c in FAMILIES[family]["comps"].items():
            cp = COMPANIONS[c]
            dest = os.path.join(self.models_dir, cp["file"])
            out.append({"name": cp["file"], "dest": dest, "bytes": cp["bytes"], "sha256": COMPANION_SHA256.get(c), "flag": flag,
                        "url": "https://huggingface.co/%s/resolve/main/%s" % (cp["repo"], urllib.parse.quote(cp["path"])),
                        "present": os.path.exists(dest) and os.path.getsize(dest) == cp["bytes"]})
        return out

    def plan(self, info, family):
        """What adding this would download (for the UI's confirm step)."""
        if family and family not in FAMILIES:
            raise RemoteError("unknown family %r" % family)
        sel = next(f for f in info["files"] if f["key"] == info["file"])
        lora = info["kind"] == "lora"
        dest = os.path.join(self.lora_dir if lora else self.models_dir, safe_filename(sel["name"]))
        items = [{"name": os.path.basename(dest), "dest": dest, "bytes": sel["bytes"], "sha256": sel["sha256"], "url": sel["url"],
                  "present": os.path.exists(dest) and os.path.getsize(dest) == sel["bytes"], "main": True}]
        if not lora and family and not info.get("allinone"):
            items += self.companion_items(family)
        need = sum(i["bytes"] for i in items if not i["present"])
        free = shutil.disk_usage(self.models_dir).free
        queued = self.queued_bytes()            # what jobs already in the queue will still write
        return {"items": [{k: i[k] for k in ("name", "bytes", "present")} for i in items], "download_bytes": need,
                "free_bytes": free, "queued_bytes": queued, "ok_space": free - queued - need >= MIN_FREE_BYTES}, items

    def queued_bytes(self):
        with self.lock:
            return sum(max(0, j.total - j.done_bytes) for j in self.jobs if j.state in ("queued", "downloading"))

    def add(self, url, file_key, family, mid, label, existing_ids):
        info = inspect(url, file_key)
        lora = info["kind"] == "lora"
        if not lora and not family:
            raise RemoteError("pick the model family first")
        if info.get("unsupported") and not family:
            raise RemoteError(info["unsupported"])
        plan, items = self.plan(info, family)
        if not plan["ok_space"]:
            raise RemoteError("not enough disk space: %.1f GB to download, %.1f GB free (keeping %d GB spare)" %
                              (plan["download_bytes"] / 1e9, plan["free_bytes"] / 1e9, MIN_FREE_BYTES // 1000 ** 3))
        if info["access"] and info["access"] != "ok" and "could not read" not in info["access"]:
            raise RemoteError(info["access"])
        mid = _slug(mid or info["suggested_id"])
        base_id, n = mid, 2
        while mid in existing_ids:
            mid = "%s-%d" % (base_id, n)
            n += 1
        sel = next(f for f in info["files"] if f["key"] == info["file"])
        with self.lock:
            jid = "dl%d" % (int(time.time() * 1000) % 10 ** 9)
            job = Job(jid, label or info["suggested_label"], items,
                      lambda j: self._register(j, info, sel, family, mid, label or info["suggested_label"], items))
            self.jobs.insert(0, job)
            live = [j for j in self.jobs if j.state in ("queued", "downloading", "verifying")]
            done = [j for j in self.jobs if j not in live]
            self.jobs = [j for j in self.jobs if j in live or j in done[:20]]   # never drop a job that is still running
            self.queue.append(job)
            self.cv.notify()
        self.log("download %s queued: %s (%s, %.2f GB to fetch)" % (jid, job.label, family or "lora", plan["download_bytes"] / 1e9))
        return job.view()

    def cancel(self, jid):
        with self.lock:
            for j in self.jobs:
                if j.id == jid and j.state in ("queued", "downloading", "verifying"):
                    j.cancel = True
                    if j in self.queue:
                        self.queue.remove(j)
                        j.state = "cancelled"
                    return True
        return False

    def views(self):
        with self.lock:
            return [j.view() for j in self.jobs]

    def _worker(self):
        while True:
            with self.lock:
                while not self.queue:
                    self.cv.wait()
                job = self.queue.pop(0)
            job.state, job.started = "downloading", time.time()
            try:
                for it in job.items:
                    if it.get("present"):
                        continue
                    job.current = it["name"]
                    self._fetch(job, it)
                job.state = "verifying"
                job.result = job.on_done(job)
                job.state = "done"
                self.log("download %s done: %s" % (job.id, job.result))
            except Exception as e:  # noqa: BLE001 -- shown to the user
                job.state = "cancelled" if job.cancel else "failed"
                job.error = "" if job.cancel else str(e)
                self.log("download %s %s: %s" % (job.id, job.state, e))
            job.finished, job.current = time.time(), ""

    def _fetch(self, job, it):
        dest, part = it["dest"], it["dest"] + ".part"
        os.makedirs(os.path.dirname(dest), exist_ok=True)
        h = hashlib.sha256() if it.get("sha256") else None
        have = os.path.getsize(part) if os.path.exists(part) else 0
        if have > it["bytes"]:
            os.remove(part)
            have = 0
        if have and h:
            with open(part, "rb") as f:
                for blk in iter(lambda: f.read(1 << 22), b""):
                    h.update(blk)
        conn, r = open_url(it["url"], {"Range": "bytes=%d-" % have} if have else None, timeout=120)
        try:
            if r.status == 200 and have:          # server ignored the range: start over
                have = 0
                h = hashlib.sha256() if it.get("sha256") else None
            elif r.status not in (200, 206):
                raise RemoteError("HTTP %d downloading %s" % (r.status, it["name"]))
            base_done = job.done_bytes
            got, t0, t_last, b_last = have, time.time(), time.time(), have
            with open(part, "ab" if have else "wb") as f:
                while True:
                    if job.cancel:
                        raise RemoteError("cancelled")
                    blk = r.read(1 << 20)
                    if not blk:
                        break
                    f.write(blk)
                    if h:
                        h.update(blk)
                    got += len(blk)
                    job.done_bytes = base_done + got
                    now = time.time()
                    if now - t_last >= 1:
                        job.speed = (got - b_last) / (now - t_last)
                        t_last, b_last = now, got
        finally:
            conn.close()
        if job.cancel:
            raise RemoteError("cancelled")
        if got != it["bytes"] and it["bytes"]:
            raise RemoteError("%s: got %d bytes, expected %d -- try again (it resumes)" % (it["name"], got, it["bytes"]))
        if h and h.hexdigest().lower() != it["sha256"].lower():
            os.remove(part)
            raise RemoteError("%s: sha256 mismatch -- the download was corrupted and has been deleted" % it["name"])
        os.replace(part, dest)
        it["present"] = True

    def _register(self, job, info, sel, family, mid, label, items):
        src = {"site": info["site"], "page": info["page"], "file": sel["name"], "sha256": sel.get("sha256"),
               "version": info["version"], "base": info["base"]}
        with self.lock:
            d = self.read()
            if info["kind"] == "lora":
                fname = os.path.basename(items[0]["dest"])
                d["loras"] = [x for x in d["loras"] if x.get("file") != fname]
                d["loras"].append({"file": fname, "name": label, "group": FAMILIES[family]["group"] if family else None,
                                   "family": family, "trained_words": info.get("trained_words") or [], "nsfw": info["nsfw"],
                                   "licence": info["licence"], "source": src, "added": time.strftime("%Y-%m-%d")})
                self.write(d)
                result = "LoRA %s" % fname
            else:
                taken = set(self.ids()) | {x.get("id") for x in d["models"]}
                base_id, n = mid, 2
                while mid in taken:                    # another add may have taken the id while this one downloaded
                    mid = "%s-%d" % (base_id, n)
                    n += 1
                d["models"].append(build_entry(info, family, mid, label, items, src))
                self.write(d)
                result = "model %s" % mid
        self.on_change()
        return result

    def remove(self, kind, ident, delete_files, protected=frozenset()):
        """protected: file names any OTHER model (tracked or local) still uses -- never deleted."""
        with self.lock:
            d = self.read()
            if kind == "lora":
                hit = [x for x in d["loras"] if x.get("file") == ident]
                d["loras"] = [x for x in d["loras"] if x.get("file") != ident]
                paths = [os.path.join(self.lora_dir, ident)]
            else:
                hit = [x for x in d["models"] if x.get("id") == ident]
                d["models"] = [x for x in d["models"] if x.get("id") != ident]
                main = hit[0].get("main_file") if hit else None
                # only the model's own file -- companions are shared with other models
                still = {f for x in d["models"] for f in (x.get("files") or {}).values()} | set(protected)
                paths = [os.path.join(self.models_dir, main)] if main and main not in still else []
            if not hit:
                raise RemoteError("%s %r was not added from a remote (only those can be removed here)" % (kind, ident))
            self.write(d)
        deleted = []
        if delete_files:
            for pth in paths:
                if os.path.isfile(pth):
                    os.remove(pth)
                    deleted.append(os.path.basename(pth))
        self.on_change()
        return {"removed": ident, "deleted": deleted}


def build_entry(info, family, mid, label, items, src):
    fam = FAMILIES[family]
    fast = info.get("fast")
    ui = dict(fam["fast"] if fast else fam["ui"])
    main = next(i for i in items if i.get("main"))
    if (family.startswith("flux2-klein") or family == "flux3-klein") and re.search(r"base", (info.get("base") or "") + main["name"], re.I):
        ui = dict(fam["base_ui"])
    files = {("model" if info.get("allinone") else fam["main"]): main["name"]}
    for i in items:
        if i.get("flag"):
            files[i["flag"]] = i["name"]
    args = list(fam.get("args", []))
    if info.get("vpred"):
        args += ["--prediction", "v"]
    if family == "sdxl" and re.search(r"pony|illustrious|noob", " ".join(str(x) for x in (info.get("base"), info.get("name"))), re.I):
        ui["clip_skip"] = 2                                # what these anime SDXL lines are trained and prompted with
    if family == "qwen-image-2.1" and fast:                # same preset the tracked Turbo entry uses
        args += ["--sigmas", "qwen-image-2.1-turbo"]
        ui["fixed_steps"] = 8
    args += ["--steps", str(ui["steps"]), "--cfg-scale", str(float(ui["cfg"])), "--sampling-method", ui["sampler"]]
    total = sum(i["bytes"] for i in items)
    if fam.get("note"):
        ui["note"] = fam["note"]
    return {
        "id": mid, "label": label, "user": True, "family": family, "main_file": main["name"],
        "description": "%s %s from %s%s." % (fam["label"], "checkpoint" if info["kind"] == "model" else info["kind"],
                                             "CivitAI" if info["site"] == "civitai" else "Hugging Face",
                                             " (fast/distilled defaults)" if fast else ""),
        "licence": info["licence"], "nsfw": bool(info["nsfw"]),
        "vram_gb": round(total / 1e9 * 1.05 + 0.5, 1),       # replaced by the measured figure after the first load
        "vram_measured": False, "files": files, "args": args, "ui": ui, "source": src, "added": time.strftime("%Y-%m-%d"),
        **({"engine": fam["engine"]} if fam.get("engine") else {}),
    }
