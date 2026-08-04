<#
.SYNOPSIS
  Launcher for Ornith-1.0-35B (DeepReinforce agentic-coding MoE, arch qwen3_5_moe) as a SECOND
  server on :8081, alongside the Qwen3.6 daily driver on :8080. Fully resident in the VRAM
  carve-out (-ngl 999 + --no-mmap, q8_0 KV), never offloaded to system RAM.

  Ornith = 35B total / ~3B active MoE, 262K context, MIT, coding-focused. Same arch family as
  Qwen3.6-35B-A3B so it loads on llama.cpp b9771 identically.

.EXAMPLE
  .\run-ornith.ps1                 # serve Ornith Q4_K_M on :8081, ngram-mod speculation, in VRAM
  .\run-ornith.ps1 -Spec none      # no speculative decoding
  .\run-ornith.ps1 -Force          # restart even if a request is in flight
#>
[CmdletBinding()]
param(
    [int]    $Port = 8081,
    [int]    $Ctx  = 131072,
    [string] $Spec = 'ngram-mod',   # coding model: ngram-mod is a free win; 'none' or 'draft-mtp' (needs MTP head)
    [string] $Mmproj = "$($PSScriptRoot | Split-Path -Parent | Split-Path -Parent | Split-Path -Parent)\models\mmproj-deepreinforce-ai_Ornith-1.0-35B-f16.gguf",  # vision; '' to disable
    [switch] $Force
)
$ErrorActionPreference = 'Stop'
$root   = $($PSScriptRoot | Split-Path -Parent | Split-Path -Parent | Split-Path -Parent)
$model  = Join-Path $root 'models\ornith-1.0-35b-Q4_K_M.gguf'
$runner = Join-Path $root 'run-server.ps1'
foreach ($f in @($model, $runner)) { if (-not (Test-Path $f)) { Write-Error "missing: $f"; exit 1 } }

$existing = (Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue).OwningProcess
if ($existing) {
    $busy = 0
    try { $busy = (Invoke-RestMethod "http://127.0.0.1:$Port/slots" -TimeoutSec 5 |
                   Where-Object { $_.is_processing } | Measure-Object).Count } catch {}
    if ($busy -gt 0 -and -not $Force) { Write-Error "Server on :$Port has $busy active request(s). Use -Force."; exit 1 }
    Write-Host "Stopping existing server on :$Port (PID $existing)..." -ForegroundColor Yellow
    Stop-Process -Id $existing -Force; Start-Sleep -Seconds 3
}

$specArgs = if ($Spec -ne 'none') { @('-Spec', $Spec) } else { @() }
$visArgs  = if ($Mmproj -and (Test-Path $Mmproj)) { @('-Mmproj', $Mmproj) } else { @() }
if ($Mmproj -and -not (Test-Path $Mmproj)) {
    Write-Warning "mmproj not found ($Mmproj) - starting text-only. Get it with:"
    Write-Warning "  .\download-model.ps1 -Repo bartowski/deepreinforce-ai_Ornith-1.0-35B-GGUF -File mmproj-deepreinforce-ai_Ornith-1.0-35B-f16.gguf"
}
$scriptArgs = @('-ExecutionPolicy','Bypass','-NoExit','-File', $runner,
    '-Model', $model, '-Ctx', $Ctx, '-Port', $Port,
    '-Temp','0.6','-TopP','0.95','-TopK','20','-MinP','0') + $specArgs + $visArgs   # Qwen3 thinking quality defaults
Write-Host ("Launching Ornith-1.0-35B (spec=$Spec, vision={0}) on :$Port ..." -f [bool]$visArgs.Count) -ForegroundColor Green
Start-Process powershell -ArgumentList $scriptArgs | Out-Null

Write-Host "Waiting for the model to load into VRAM..." -ForegroundColor DarkGray
$up = $false
for ($i = 0; $i -lt 60; $i++) {
    try { if ((Invoke-RestMethod "http://127.0.0.1:$Port/health" -TimeoutSec 3).status -eq 'ok') { $up = $true; break } } catch {}
    Start-Sleep -Seconds 3
}
if (-not $up) { Write-Error "Server did not become healthy on :$Port within ~3 min."; exit 1 }

$srvPid = (Get-NetTCPConnection -LocalPort $Port -State Listen).OwningProcess
$vram = 0.0
try { $vram = (((Get-Counter '\GPU Process Memory(*)\Dedicated Usage').CounterSamples |
        Where-Object { $_.InstanceName -like "*$srvPid*" } | Measure-Object CookedValue -Sum).Sum) / 1GB } catch {}
$os = Get-CimInstance Win32_OperatingSystem
$ramFree = $os.FreePhysicalMemory / 1MB
Write-Host ""
Write-Host ("VRAM resident (GPU dedicated) : {0:N1} GB" -f $vram) -ForegroundColor Cyan
Write-Host ("System RAM free              : {0:N1} GB" -f $ramFree) -ForegroundColor Cyan
if ($vram -lt 12 -or $ramFree -lt 4) {
    Write-Host "WARNING: model may have spilled to system RAM (NOT fully in VRAM)." -ForegroundColor Red
} else {
    Write-Host "PASS: Ornith pinned in VRAM on :$Port (until you stop the server)." -ForegroundColor Green
}
Write-Host ""
Write-Host "  Local    : http://127.0.0.1:$Port    (OpenAI API /v1)" -ForegroundColor Cyan
# NetBird overlay address. NetBird assigns from the 100.64.0.0/10 CGNAT range, so match the
# second octet properly rather than '100.*' (which would also catch 100.0-63.x public space).
$nb = (Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
       Where-Object { $_.IPAddress -match '^100\.(6[4-9]|[7-9]\d|1[01]\d|12[0-7])\.' } |
       Select-Object -First 1).IPAddress
if ($nb) { Write-Host ("  NetBird: http://{0}:{1}" -f $nb, $Port) -ForegroundColor Cyan }
Write-Host ("  Stop     : close the window, or  Stop-Process -Id {0}" -f $srvPid) -ForegroundColor DarkGray
