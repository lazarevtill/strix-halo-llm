<#
.SYNOPSIS
  Serve MULTIPLE models from ONE endpoint on :8080 using llama.cpp router mode (b10431+).

.DESCRIPTION
  Router mode: start llama-server with NO -m and it becomes a coordinator that spawns a child
  llama-server per model and routes each request by the OpenAI `model` field. Verified on b10431
  2026-08-18: both models stay co-resident (models-max 2), and per-model tuned flags survive into
  each child (checked via GET /models -> status.args).

  Why this over two hand-run servers: one port, one process tree, LRU eviction if you ever exceed
  models-max, and no manual juggling. Route coding -> "qwen38", big-text -> "ornith" (MoE, ~2.5x the
  dense 27B's generation speed).

  MEASURED GOTCHAS baked in here:
    * load-mode = none per model. The dual setup's real trap: default mmap pins a ~15 GB host
      file-cache mirror PER model, and this box has only ~32 GB system RAM -- two mirrors would
      exhaust it. `none` keeps weights in the VRAM carve-out, host copy paged out (the old -lm none).
    * Pre-load. Autoload does NOT fire on the first /v1/chat/completions call -- it 400s
      ("model is not loaded"). We POST /models/load for each model at startup so clients never see it.
    * Context is 131072 per model, NOT the 262144 a solo model gets: two resident models split the
      ~109 GB budget. 131072 x2 (q8_0 KV) fits with room to spare (~54 GB measured).

.EXAMPLE
  .\run-router.ps1                      # :8080, qwen38 + ornith, both pre-loaded
  .\run-router.ps1 -DryRun              # print the router cmdline and the generated preset, launch nothing
  .\run-router.ps1 -Preload qwen38      # bring the router up but only pre-load qwen38 (ornith loads on demand)
#>
[CmdletBinding()]
param(
    [int]      $Port      = 8080,
    [int]      $Ctx       = 131072,
    [int]      $ModelsMax = 2,
    [string[]] $Preload   = @('qwen38','ornith'),
    [switch]   $DryRun,
    [switch]   $Force        # stop other servers even if one has a request in flight
)
$ErrorActionPreference = 'Stop'
$repoRoot = $PSScriptRoot | Split-Path -Parent | Split-Path -Parent
$bin = "$repoRoot\bin\llama-server.exe"
if (-not (Test-Path $bin)) { Write-Error "llama-server.exe not found: $bin"; exit 1 }

$modelsDir = $env:MODELS_DIR
if (-not $modelsDir) { $modelsDir = "$repoRoot\models" }

# ---- per-model tuned presets (this box's serving models) ----------------------------------------
# file is resolved under $modelsDir; 'spec' is the per-model spec flag; 'mmproj' (optional) is a
# multimodal projector under $modelsDir that turns the model into a vision (image+text) model --
# MEASURED 2026-08-23: Qwen3.8-27B is a Qwen-VL, mmproj-F16.gguf loads and it reads images. Everything
# else is the shared tuned baseline below. Add a model by adding an entry here.
$models = [ordered]@{
    'qwen38' = @{ file = 'Qwen3.8-27B-UD-Q4_K_XL.gguf'; spec = @('spec-type = draft-mtp','spec-draft-n-max = 3'); mmproj = 'mmproj-F16.gguf' }  # coding+vision; KL-best quant (Round 5)
    'ornith' = @{ file = 'ornith-1.0-35b-Q5_K_M.gguf';   spec = @('spec-type = ngram-mod'); mmproj = 'mmproj-deepreinforce-ai_Ornith-1.0-35B-f16.gguf' }  # big-text+vision; MoE A3B, ~2.5x faster
}
# shared tuned flags -- the measured optima for gfx1151 (see docs/BENCHMARKS.md, docs/OPTIMIZATION.md)
$common = @(
    "ctx-size = $Ctx",
    'load-mode = none',            # VRAM residency; NOT mmap (two host mirrors would blow ~32 GB sys RAM)
    'flash-attn = on',
    'cache-type-k = q8_0','cache-type-v = q8_0',
    'batch-size = 2048','ubatch-size = 256',
    'temp = 0.6','top-p = 0.95','top-k = 20','min-p = 0'
)

# ---- build the preset INI -----------------------------------------------------------------------
$iniPath = "$repoRoot\scripts\windows\router-models.generated.ini"
$lines = New-Object System.Collections.Generic.List[string]
foreach ($name in $models.Keys) {
    $file = Join-Path $modelsDir $models[$name].file
    if (-not (Test-Path $file)) { Write-Warning "model file missing, skipping [$name]: $file"; continue }
    $lines.Add("[$name]")
    $lines.Add("model = $file")
    foreach ($c in $common) { $lines.Add($c) }
    foreach ($s in $models[$name].spec) { $lines.Add($s) }
    $mm = $models[$name].mmproj
    if ($mm) {
        $mmPath = Join-Path $modelsDir $mm
        if (Test-Path $mmPath) { $lines.Add("mmproj = $mmPath") }
        else { Write-Warning "mmproj missing for [$name], serving text-only: $mmPath" }
    }
    $lines.Add('')
}
Set-Content -Path $iniPath -Value $lines -Encoding ASCII

$routerArgs = @(
    '--models-preset', $iniPath,
    '--models-max', $ModelsMax,
    '--models-autoload',
    '-ngl', 999,
    '--jinja',
    '--host', '0.0.0.0',
    '--port', $Port
)

Write-Host ""
Write-Host "llama-server ROUTER -> http://0.0.0.0:$Port  (route by OpenAI `"model`" field)" -ForegroundColor Cyan
Write-Host ("  models   : {0}" -f ($models.Keys -join ', '))
Write-Host ("  each     : ctx=$Ctx  fa=on  kv=q8_0  batch=2048/256  load-mode=none  + per-model spec")
Write-Host ("  max resident: $ModelsMax   pre-load: {0}" -f ($Preload -join ', '))
Write-Host ("  preset   : $iniPath")
if ($DryRun) {
    Write-Host "`n[DryRun] would run:`n  $bin $($routerArgs -join ' ')" -ForegroundColor DarkGray
    Write-Host "`n--- generated preset ---" -ForegroundColor DarkGray
    Get-Content $iniPath | ForEach-Object { Write-Host "  $_" -ForegroundColor DarkGray }
    exit 0
}

# ---- stop existing llama-servers, drain the GPU -------------------------------------------------
$others = @(Get-Process llama-server -EA SilentlyContinue)
foreach ($o in $others) {
    if (-not $Force) {
        $busy = 0
        foreach ($prt in 8080..8099) {
            $owner = (Get-NetTCPConnection -LocalPort $prt -State Listen -EA SilentlyContinue).OwningProcess
            if ($owner -eq $o.Id) {
                try { $busy = @((Invoke-RestMethod "http://127.0.0.1:$prt/slots" -TimeoutSec 3) | Where-Object { $_.is_processing }).Count } catch {}
            }
        }
        if ($busy -gt 0) { Write-Error "llama-server PID $($o.Id) has $busy active request(s). Wait, or use -Force."; exit 1 }
    }
    Write-Host "  stopping llama-server PID $($o.Id)" -ForegroundColor Yellow
    try { Stop-Process -Id $o.Id -Force -EA Stop }
    catch { Write-Error "Cannot stop PID $($o.Id): $($_.Exception.Message). Probably elevated -- run as Administrator."; exit 1 }
}
Start-Sleep -Seconds 3

# ---- launch router ------------------------------------------------------------------------------
$env:GGML_VK_ENABLE_MEMORY_PRIORITY = '1'
Write-Host "  launching router..." -ForegroundColor DarkGray
$proc = Start-Process -FilePath $bin -ArgumentList $routerArgs -PassThru -WindowStyle Hidden
Write-Host "  router PID $($proc.Id)"

# wait for the router to answer
$up = $false
for ($i = 0; $i -lt 30; $i++) {
    try { Invoke-RestMethod "http://127.0.0.1:$Port/models" -TimeoutSec 3 | Out-Null; $up = $true; break } catch { Start-Sleep -Seconds 1 }
}
if (-not $up) { Write-Error "router did not come up on :$Port"; exit 1 }

# ---- pre-load requested models (avoids the first-request 400) -----------------------------------
foreach ($name in $Preload) {
    Write-Host "  pre-loading $name ..." -ForegroundColor DarkGray
    try {
        Invoke-RestMethod "http://127.0.0.1:$Port/models/load" -Method Post -Body (@{ model = $name } | ConvertTo-Json) -ContentType 'application/json' -TimeoutSec 300 | Out-Null
    } catch { Write-Warning "pre-load $name failed: $($_.Exception.Message)" }
}

# ---- report -------------------------------------------------------------------------------------
Start-Sleep -Seconds 2
Write-Host "`nrouter ready:" -ForegroundColor Green
try {
    (Invoke-RestMethod "http://127.0.0.1:$Port/models" -TimeoutSec 5).data |
        ForEach-Object { Write-Host ("  {0,-8} {1}" -f $_.id, $_.status.value) }
} catch {}
$c = ((Get-Counter '\GPU Process Memory(*)\Total Committed' -EA SilentlyContinue).CounterSamples | Measure-Object CookedValue -Sum).Sum / 1GB
Write-Host ("  GPU committed total: {0:N1} GB of ~109" -f $c)
Write-Host "`n  coding  -> curl :$Port/v1/chat/completions -d '{`"model`":`"qwen38`",...}'"
Write-Host "  bigtext -> curl :$Port/v1/chat/completions -d '{`"model`":`"ornith`",...}'"
