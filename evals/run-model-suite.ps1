<#
.SYNOPSIS
  Serve ONE model solo, run BOTH private eval suites against it, then stop it.

.DESCRIPTION
  The comparison is only meaningful if each model is the sole occupant of the GPU while it is
  scored. This box has repeatedly had a foreign bench stack reappear on :8082/:8088 and steal
  ~42 GiB (see memory: bench-stack-respawner), which on 2026-08-03 produced a fake 17.2% and a fake
  0/29 before the guards existed. So this script REFUSES TO START if anything else holds GPU memory,
  rather than producing a number that looks real.

.EXAMPLE
  .\run-model-suite.ps1 -Label ornith-q5 -Model C:\llm-router\models\ornith-1.0-35b-Q5_K_M.gguf
  .\run-model-suite.ps1 -Label qwen122b -Model D:\...-00001-of-00003.gguf -Spec draft-mtp
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $Label,
    [Parameter(Mandatory)] [string] $Model,
    [int]    $Ctx  = 131072,
    [int]    $Port = 8080,
    [string] $Reasoning = 'auto',
    [string] $Spec = '',
    [int]    $SpecNMax = 5,
    [switch] $SkipTools,
    [switch] $SkipCode,
    # Comma-separated coding task ids, for finishing a run that was interrupted part-way.
    [string] $Tasks = ''
)
$ErrorActionPreference = 'Continue'
$root = $PSScriptRoot
$bin  = 'D:\llamacpp-vulkan\bin\llama-server.exe'

function Get-CommittedByPid {
    $h = @{}
    foreach ($s in (Get-Counter '\GPU Process Memory(*)\Total Committed' -EA SilentlyContinue).CounterSamples) {
        $q = ([regex]::Match($s.InstanceName,'pid_(\d+)')).Groups[1].Value
        if ($q -and $s.CookedValue -gt 1GB) { $h[[int]$q] = [math]::Round($s.CookedValue/1GB,2) }
    }
    return $h
}

# ---- pre-flight: demand an empty GPU ------------------------------------------------------------
$held = Get-CommittedByPid
if ($held.Count) {
    Write-Host "REFUSING TO RUN -- the GPU is not empty:" -ForegroundColor Red
    foreach ($k in $held.Keys) {
        $p = Get-Process -Id $k -EA SilentlyContinue
        Write-Host ("  {0,7:N2} GiB  pid={1} {2}" -f $held[$k], $k, $(if($p){$p.ProcessName}else{'(exited)'})) -ForegroundColor Red
    }
    Write-Host "Any score produced now would be contaminated. Clear these first." -ForegroundColor Red
    exit 2
}

# ---- serve --------------------------------------------------------------------------------------
$env:GGML_VK_ENABLE_MEMORY_PRIORITY = '1'
$a = @('-m',$Model,'-ngl','999','--ctx-size',"$Ctx",'--batch-size','2048','--ubatch-size','1024',
       '-fa','on','-lm','none','--jinja','--parallel','1','--host','0.0.0.0','--port',"$Port",
       '--no-warmup','--cache-type-k','q8_0','--cache-type-v','q8_0',
       '--reasoning',$Reasoning,'--reasoning-preserve')
if ($Spec) { $a += @('--spec-type',$Spec,'--spec-draft-n-max',"$SpecNMax") }

Write-Host "=== $Label ===" -ForegroundColor Cyan
Write-Host ("serving: {0}`n  ctx={1} reasoning={2} spec={3}" -f (Split-Path $Model -Leaf), $Ctx, $Reasoning, $(if($Spec){$Spec}else{'none'})) -ForegroundColor DarkGray
$proc = Start-Process $bin -ArgumentList $a -WindowStyle Minimized -PassThru

$t0 = Get-Date; $ok = $false
do {
    Start-Sleep 10
    try { $ok = ((Invoke-RestMethod "http://127.0.0.1:$Port/health" -TimeoutSec 5).status -eq 'ok') } catch {}
    $el = [int]((Get-Date)-$t0).TotalSeconds
} while (-not $ok -and $el -lt 600)
if (-not $ok) { Write-Host "server never became healthy ($el s)" -ForegroundColor Red; if ($proc -and -not $proc.HasExited) { $proc.Kill() }; exit 3 }
Write-Host "ready in ${el}s" -ForegroundColor Green
$held = Get-CommittedByPid
Write-Host ("committed: {0:N2} GiB" -f (($held.Values | Measure-Object -Sum).Sum)) -ForegroundColor DarkGray

try {
    if (-not $SkipTools) {
        Write-Host "`n--- tool-calling ---" -ForegroundColor Cyan
        & powershell -NoProfile -ExecutionPolicy Bypass -File "$root\run-tools-eval.ps1" `
            -Endpoint "http://127.0.0.1:$Port/v1" -Label $Label 2>&1 | Write-Host
    }
    if (-not $SkipCode) {
        Write-Host "`n--- agentic coding ---" -ForegroundColor Cyan
        Push-Location "$root\code"
        $codeArgs = @('run-code-eval.py','--endpoint',"http://127.0.0.1:$Port/v1",'--label',$Label)
        if ($Tasks) { $codeArgs += @('--tasks',$Tasks) }
        & python $codeArgs 2>&1 | Write-Host
        Pop-Location
    }
} finally {
    Write-Host "`nstopping $Label" -ForegroundColor DarkGray
    Get-Process -Id $proc.Id -EA SilentlyContinue | Stop-Process -Force -EA SilentlyContinue
    Start-Sleep 5
}
Write-Host "=== $Label DONE ===" -ForegroundColor Green
