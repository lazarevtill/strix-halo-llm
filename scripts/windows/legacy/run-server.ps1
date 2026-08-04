<#
.SYNOPSIS
  Launch llama.cpp llama-server (Vulkan backend) on the Radeon 8060S with an
  OpenAI-compatible API + built-in web UI. Strix-Halo-tuned defaults.

.EXAMPLE
  .\run-server.ps1                                   # serves the default model on :8080
  .\run-server.ps1 -Model .\models\gpt-oss-20b-mxfp4.gguf -Ctx 32768 -Port 8080
  # then open http://127.0.0.1:8080  (web UI) or point Open WebUI / any OpenAI client at it.

.NOTES
  OpenAI endpoints: http://127.0.0.1:<port>/v1/chat/completions , /v1/models
  Vulkan uses the AMD proprietary Windows driver (confirmed: coopmat matrix cores).
  -b 2048 -ub 1024 is the MEASURED pp sweet spot on gfx1151 (2026-06-29); tg is bandwidth-bound (batch-agnostic).
#>
[CmdletBinding()]
param(
    [string] $Model = "$($PSScriptRoot | Split-Path -Parent | Split-Path -Parent | Split-Path -Parent)\models\gpt-oss-20b-mxfp4.gguf",
    [int]    $Ctx   = 131072,       # 128K — fits big files/repos; KV still fits 96GB VRAM
    [int]    $Port  = 8080,
    [int]    $Batch  = 2048,        # logical batch (MEASURED 2026-06-29: 2048 > 256 for pp; old 256 was over-cautious)
    [int]    $Ubatch = 1024,        # physical micro-batch — pp sweet spot on gfx1151 (pp8192: 921 t/s @1024 vs 817 @512, 744 @2048)
    [int]    $NGL   = 999,          # offload all layers to GPU
    [string] $Spec  = 'none',       # token-prediction: none | draft-mtp | ngram-mod | draft-eagle3
    [int]    $SpecNMax = 3,         # max draft tokens per step
    [string] $DraftModel = '',      # for draft-eagle3 / draft-simple: path to draft model
    [switch] $NoFlashAttn,
    [string] $Mmproj = '',          # vision projector GGUF (enables image input for VL models)
    [switch] $NoKvQuant,            # by default KV cache is q8_0 (half size, stays in VRAM); set to keep f16
    [switch] $Mmap,                 # opt-in mmap. DON'T: it pins a ~21GB file-cache mirror in physical RAM.
    # server-side sampling defaults (apply when a client doesn't send its own). Leave '' to use
    # llama.cpp defaults. For Qwen3.x set these via the model launchers; gpt-oss wants neutral sampling.
    [string] $Temp = '', [string] $TopK = '', [string] $TopP = '', [string] $MinP = '', [string] $PresencePenalty = ''
)
# NOTE: do NOT add --mlock on this Vulkan/UMA box. It pins weights in the ~32GB system-RAM
# partition and BLOCKS the Vulkan backend from uploading them to the 96GB VRAM carve-out
# (measured: -ngl 999 silently runs from host RAM, GPU dedicated ~0, RAM ~1GB free).
# Permanent VRAM residency is already provided by --no-mmap alone.
$bin = "$($PSScriptRoot | Split-Path -Parent | Split-Path -Parent | Split-Path -Parent)\bin\llama-server.exe"
if (-not (Test-Path $bin))   { Write-Error "llama-server.exe not found in bin\"; exit 1 }
if (-not (Test-Path $Model)) { Write-Error "Model not found: $Model"; exit 1 }

# --no-mmap vs mmap (MEASURED on this Strix Halo / Vulkan box, 2026-06-26 - physical RAM is what matters):
#   -ngl 999 uploads weights to VRAM EITHER way. The difference is the host-side copy:
#     --no-mmap (default) -> weights go to the GPU carve-out; the host copy is paged out, only
#                            ~1.4GB stays physically resident -> RAM ~23GB free. CORRECT for this box.
#     mmap                -> llama.cpp keeps a ~21GB file-cache MIRROR resident in physical RAM
#                            -> RAM free crashes to ~3.7GB (this is the "RAM 100%"). Do not use.
$fa = if ($NoFlashAttn) { 'off' } else { 'on' }
$args = @(
    '-m', $Model,
    '-ngl', $NGL,
    '--ctx-size', $Ctx,
    '--batch-size', $Batch,
    '--ubatch-size', $Ubatch,
    '-fa', $fa,
    '--host', '0.0.0.0',
    '--port', $Port,
    '--jinja',                     # use the model's chat template
    '--cache-reuse', '256'         # reuse unchanged KV prefix across turns (big win for agentic/multi-turn coding)
)
# q8_0 KV cache: ~half the KV memory at equal quality, so the whole context stays in the VRAM
# carve-out (no spill to the 32GB system-RAM partition). Needs flash-attn on (OPTIMIZATION.md #4).
if ((-not $NoFlashAttn) -and (-not $NoKvQuant)) {
    $args += @('--cache-type-k', 'q8_0', '--cache-type-v', 'q8_0')
}
# Qwen3.x quality sampling (NEVER greedy — causes endless repetition). Only added if explicitly set.
if ($Temp -ne '')            { $args += @('--temp', $Temp) }
if ($TopK -ne '')            { $args += @('--top-k', $TopK) }
if ($TopP -ne '')            { $args += @('--top-p', $TopP) }
if ($MinP -ne '')            { $args += @('--min-p', $MinP) }
if ($PresencePenalty -ne '') { $args += @('--presence-penalty', $PresencePenalty) }
if (-not $Mmap) {
    $args += '--no-mmap'           # default: weights in VRAM carve-out, host copy paged out (~1.4GB RAM)
} else {
    Write-Host "  mmap ON: warning - keeps a ~21GB file-cache mirror in physical RAM" -ForegroundColor Yellow
}
if ($Spec -ne 'none') {
    $args += @('--spec-type', $Spec, '--spec-draft-n-max', $SpecNMax)
    if ($DraftModel) { $args += @('--spec-draft-model', $DraftModel) }
    Write-Host "  token-prediction: $Spec (n-max=$SpecNMax)" -ForegroundColor Magenta
}
if ($Mmproj) {
    if (-not (Test-Path $Mmproj)) { Write-Error "mmproj not found: $Mmproj"; exit 1 }
    $args += @('--mmproj', $Mmproj)   # vision encoder; offloaded to GPU by default
    Write-Host "  vision: $Mmproj (image input enabled)" -ForegroundColor Magenta
}
Write-Host "Starting llama-server (Vulkan) on http://127.0.0.1:$Port" -ForegroundColor Green
Write-Host "  model = $Model" -ForegroundColor DarkGray
Write-Host "  ctx=$Ctx batch=$Batch ngl=$NGL fa=$fa" -ForegroundColor DarkGray
Write-Host "  OpenAI API: http://127.0.0.1:$Port/v1   |   Web UI: http://127.0.0.1:$Port" -ForegroundColor Cyan
& $bin @args
