<#
.SYNOPSIS
  Serve Qwen-Image-2.1 (text-to-image + image editing) over an OpenAI-compatible HTTP API, using
  stable-diffusion.cpp's sd-server on Vulkan. Supervised: restarts the server if it exits.

.DESCRIPTION
  Since 2026-10-15 this box serves IMAGES instead of an LLM. The engine is stable-diffusion.cpp
  (leejet), not llama.cpp: a single sd-server.exe exposing
      POST /v1/images/generations     (JSON: prompt, n, size, output_format -> data[].b64_json)
      POST /v1/images/edits           (multipart: prompt, image[], optional mask)
      GET  /v1/models                 (one id, "sd-cpp-local" -- the request's model field is ignored)
      GET  /                          (built-in web UI)
  plus the A1111-style /sdapi/v1/* and the native async /sdcpp/v1/* APIs. Per-request sampler
  overrides go INSIDE the prompt:  ...<sd_cpp_extra_args>{"sample_params":{"sample_steps":20}}</sd_cpp_extra_args>

  Why these choices (all from the 2026-10-15 research + this box's constraints, see docs/IMAGES.md):
    * Qwen-Image-2.1 is #1 on the Artificial Analysis open-weights boards for both generation and
      editing. LICENCE: Qwen Research -- NON-COMMERCIAL.
    * Weights stay on the GPU: --backend vulkan0 --params-backend vulkan0. An explicit params backend
      also disables --auto-fit, which would otherwise quietly spill weights into the ~32 GB of
      Windows-visible system RAM (often <10 GB free here). Never --offload-to-cpu, never --mmap.
    * Text encoder is the F16 GGUF: this driver's largest single Vulkan allocation is 2 GiB, and
      sd.cpp #1718 (Windows, Strix Halo) died allocating a 2.49 GB F32 token table from an FP8 file.
    * --vae-tiling: a 1024^2 VAE decode otherwise wants one >2 GiB buffer (sd.cpp #1290).

  -Model turbo-q8 = Turbo, Q8_0 GGUF, 8 steps, CFG 1 -- THE DEFAULT and the served config:
                    ~108 s per 1024^2 image. Q8_0 measured 2.4x faster than bf16 on this driver.
  -Model base-q8  = base weights Q8_0, 40 steps, CFG 6 -- best quality, ~12 min per 1024^2 image
  -Model turbo / base = the bf16 safetensors -- same images as Q8_0 here, ~2.4x slower

  No authentication. Binding 0.0.0.0 exposes it to the LAN; firewall the port to the LAN only.

  KNOWN CRASH (sd.cpp master-967, 2026-10-15, measured): a <sd_cpp_extra_args> block inside the prompt of
  a POST /v1/images/edits request aborts the whole server (0xc0000409). The same block is fine on
  /v1/images/generations. Edits without it work. The restart loop below brings the server back (~15 s).

.EXAMPLE
  .\run-images.ps1                         # Turbo Q8_0 on :8080, supervised (the served config)
  .\run-images.ps1 -Model base-q8          # best quality, ~12 min per 1024^2 image
  .\run-images.ps1 -DryRun                 # print the sd-server command line only
  .\run-images.ps1 -Once                   # run without the restart loop (testing)
#>
[CmdletBinding()]
param(
    [ValidateSet('base', 'turbo', 'base-q8', 'turbo-q8')]
    [string] $Model     = 'turbo-q8',
    [int]    $Port      = 8080,   # replaces the LLM on the same port (LAN firewall rule already exists)
    [string] $Bind      = '0.0.0.0',
    [string] $Bin       = '.\bin-sd-master-967-e47426c',
    [int]    $MaxRestartsPerHour = 5,
    # GPU budget for sd.cpp. Without it sd.cpp trusts the driver's live free-VRAM figure, which is wrong on
    # this iGPU (stable-diffusion.cpp #2022). 90 assumes the box serves images ALONE (no LLM resident).
    [int]    $MaxVram = 90,
    [string[]] $Extra   = @(),          # passed through verbatim to sd-server
    [switch] $Once,
    [switch] $DryRun
)
$ErrorActionPreference = 'Stop'
$repoRoot = $PSScriptRoot | Split-Path -Parent | Split-Path -Parent
$binDir = if ([IO.Path]::IsPathRooted($Bin)) { $Bin } else { Join-Path $repoRoot $Bin }
$exe = Join-Path $binDir 'sd-server.exe'
$modelsDir = if ($env:MODELS_DIR) { $env:MODELS_DIR } else { Join-Path $repoRoot 'models' }
$logDir = Join-Path $repoRoot 'logs'
New-Item -ItemType Directory -Force -Path $logDir | Out-Null

$diffusion = @{
    'base'    = 'qwen_image_2.1_bf16.safetensors'
    'turbo'   = 'qwen_image_2.1_turbo_bf16.safetensors'
    'base-q8' = 'qwen_image_2.1-Q8_0.gguf'
    'turbo-q8' = 'qwen-image-2.1-turbo-Q8_0.gguf'
}[$Model]
$sampling = if ($Model -like 'turbo*') {
    @('--sigmas', 'qwen-image-2.1-turbo', '--steps', '8', '--cfg-scale', '1.0', '--sampling-method', 'euler')
} else {
    @('--steps', '40', '--cfg-scale', '6.0', '--sampling-method', 'euler')
}
$files = [ordered]@{
    diffusion = Join-Path $modelsDir $diffusion
    vae       = Join-Path $modelsDir 'qwen_image_2.1_vae_bf16.safetensors'
    llm       = Join-Path $modelsDir 'Qwen3VL-8B-Instruct-F16.gguf'
    vision    = Join-Path $modelsDir 'mmproj-Qwen3VL-8B-Instruct-F16.gguf'
}
$a = @(
    '--diffusion-model', $files.diffusion, '--vae', $files.vae, '--llm', $files.llm, '--llm_vision', $files.vision,
    '--backend', 'vulkan0', '--params-backend', 'vulkan0',
    '--flash-attn', 'auto', '--vae-tiling', '--max-vram', $MaxVram,
    '--listen-ip', $Bind, '--listen-port', $Port
) + $sampling + $Extra

Write-Host "sd-server  Qwen-Image-2.1 [$Model] -> http://${Bind}:$Port  (OpenAI /v1/images/generations + /edits, web UI at /)" -ForegroundColor Cyan
Write-Host "  engine : $exe"
foreach ($k in $files.Keys) { Write-Host ("  {0,-9}: {1}" -f $k, $files[$k]) }
Write-Host "  sampling: $($sampling -join ' ')"
if ($DryRun) { Write-Host "`n[DryRun] $exe $($a -join ' ')" -ForegroundColor DarkGray; exit 0 }

if (-not (Test-Path $exe)) { Write-Error "sd-server.exe not found: $exe (fetch the stable-diffusion.cpp Vulkan release into $binDir)"; exit 1 }
foreach ($k in $files.Keys) {
    if (-not (Test-Path $files[$k])) { Write-Error "missing $k weights: $($files[$k])  -> .\scripts\windows\fetch-models.ps1 -Only qwen-image-21,qwen-image-21-te"; exit 1 }
}
$busy = Get-NetTCPConnection -LocalPort $Port -State Listen -EA SilentlyContinue
if ($busy) { Write-Error "port $Port is already in use by PID $($busy[0].OwningProcess)"; exit 1 }

# ---- supervise: run, and restart on exit (sd-server never reloads itself) ------------------------
$restarts = New-Object System.Collections.ArrayList
while ($true) {
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $out = Join-Path $logDir "images-$stamp.out"; $err = Join-Path $logDir "images-$stamp.err"
    # keep the newest 10 launches
    Get-ChildItem $logDir -Filter 'images-*.err' | Sort-Object LastWriteTime -Descending | Select-Object -Skip 10 | ForEach-Object {
        Remove-Item $_.FullName -Force -EA SilentlyContinue; Remove-Item ([IO.Path]::ChangeExtension($_.FullName, '.out')) -Force -EA SilentlyContinue }
    $p = Start-Process -FilePath $exe -ArgumentList $a -PassThru -WindowStyle Hidden -RedirectStandardOutput $out -RedirectStandardError $err
    Write-Host ("{0:s}  sd-server PID {1} started (logs: {2})" -f (Get-Date), $p.Id, $err)
    if ($Once) { exit 0 }
    $p.WaitForExit()
    $code = $p.ExitCode
    Write-Warning ("{0:s}  sd-server exited (code {1})" -f (Get-Date), $code)
    $null = $restarts.Add((Get-Date))
    $recent = @($restarts | Where-Object { $_ -gt (Get-Date).AddHours(-1) }).Count
    if ($recent -gt $MaxRestartsPerHour) {
        # BACK OFF, never give up. A client can crash sd-server on demand (the edits + extra_args abort
        # above), so a hard exit here would let six bad requests take :8080 down until the next logon --
        # and with no exporter or watchdog running, nobody would see it. Wait, then try again.
        Write-Warning ("{0:s}  sd-server exited {1} times in the last hour -- backing off 15 min. See {2}" -f (Get-Date), $recent, $err)
        Start-Sleep -Seconds 900
        $restarts.Clear()
        continue
    }
    Start-Sleep -Seconds 10
}
