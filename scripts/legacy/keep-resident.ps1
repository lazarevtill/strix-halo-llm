<#
.SYNOPSIS
  Keep BOTH production models loaded + resident in VRAM forever, until you stop this daemon:
    :8080  MTP Qwen3.6-35B-A3B  (speculative draft-mtp + vision)
    :8081  Ornith-1.0-35B       (agentic coding, ngram-mod speculation)

  Each cycle, for each server:
    1. WATCHDOG  - if not healthy on its port, (re)launch it (survives crashes/sleep-resume).
    2. KEEP-WARM - if idle, send a tiny inference so WDDM never trims the model out of VRAM.
    3. LOG       - append per-port GPU-dedicated + RAM-free to keep-resident.log (warns on trim).

  NOTE: the box must NOT sleep (sleep suspends the GPU and drops all VRAM) - already disabled via
  powercfg. Both Q4 35B-MoE models (~25GB + ~22GB) fit the 96GB carve-out with room to spare.

.EXAMPLE
  .\keep-resident.ps1
  Start-Process powershell -ArgumentList '-File','D:\llamacpp-vulkan\keep-resident.ps1'   # background
#>
[CmdletBinding()]
param(
    [int] $IntervalSec = 45,
    [int] $Ctx         = 131072
)
$root   = $($PSScriptRoot | Split-Path -Parent | Split-Path -Parent)
$runner = Join-Path $root 'run-server.ps1'
$daemonLog = Join-Path $root 'keep-resident.log'

# --- the servers this daemon keeps alive + resident -------------------------------------------
$targets = @(
    @{ name='qwen36'; port=8080; args=@(
        '-Model', (Join-Path $root 'models\MTP-Qwen3.6-35B-A3B-UD-Q4_K_M.gguf'),
        '-Ctx', $Ctx, '-Port', 8080, '-Spec','draft-mtp',
        '-Temp','0.6','-TopP','0.95','-TopK','20','-MinP','0',
        '-Mmproj', (Join-Path $root 'models\mmproj-F16.gguf')) }
    @{ name='ornith'; port=8081; args=@(
        '-Model', (Join-Path $root 'models\ornith-1.0-35b-Q4_K_M.gguf'),
        '-Ctx', $Ctx, '-Port', 8081, '-Spec','ngram-mod',
        '-Temp','0.6','-TopP','0.95','-TopK','20','-MinP','0',
        '-Mmproj', (Join-Path $root 'models\mmproj-deepreinforce-ai_Ornith-1.0-35B-f16.gguf')) }
)

function Log($m){ $line = ('{0}  {1}' -f (Get-Date -Format 'MM-dd HH:mm:ss'), $m); Add-Content -Path $daemonLog -Value $line; Write-Host $line }
function Healthy($port){ try { return ((Invoke-RestMethod "http://127.0.0.1:$port/health" -TimeoutSec 4).status -eq 'ok') } catch { return $false } }
function SrvPid($port){ (Get-NetTCPConnection -LocalPort $port -State Listen -EA SilentlyContinue).OwningProcess }
function GpuGB($port){ $sp=SrvPid $port; if(-not $sp){return 0}; try { return (((Get-Counter '\GPU Process Memory(*)\Dedicated Usage' -EA Stop).CounterSamples | Where-Object { $_.InstanceName -like "*$sp*" } | Measure-Object CookedValue -Sum).Sum)/1GB } catch { return -1 } }
function Busy($port){ try { return (Invoke-RestMethod "http://127.0.0.1:$port/slots" -TimeoutSec 4 | Where-Object { $_.is_processing } | Measure-Object).Count } catch { return 0 } }
function Launch($t){
    Log ("[{0}] not healthy -> launching on :{1}" -f $t.name,$t.port)
    $err = Join-Path $env:TEMP ("{0}-srv.err.log" -f $t.name)
    $out = Join-Path $env:TEMP ("{0}-srv.out.log" -f $t.name)
    $a = @('-ExecutionPolicy','Bypass','-File',$runner) + $t.args
    Start-Process powershell -WindowStyle Hidden -RedirectStandardError $err -RedirectStandardOutput $out -ArgumentList $a | Out-Null
    for($i=0;$i -lt 60;$i++){ if(Healthy $t.port){ Log ("[{0}] up (PID {1})" -f $t.name,(SrvPid $t.port)); return }; Start-Sleep 3 }
    Log ("[{0}] FAILED to come up (see {1})" -f $t.name,$err)
}
function KeepWarm($port){
    $body = @{ messages=@(@{role='user';content='ok'}); max_tokens=12; temperature=0 } | ConvertTo-Json -Depth 4
    try { Invoke-RestMethod "http://127.0.0.1:$port/v1/chat/completions" -Method Post -Body $body -ContentType 'application/json' -TimeoutSec 90 | Out-Null } catch {}
}

Log ("=== keep-resident daemon started (interval={0}s, {1} servers) ===" -f $IntervalSec,$targets.Count)
while ($true) {
    # 1) relaunch any dead servers (sequential is fine here)
    foreach ($t in $targets) { if (-not (Healthy $t.port)) { Launch $t } }
    # 2) keep-warm all idle servers CONCURRENTLY. Sequential warming ping-pongs: reloading a trimmed
    #    model creates VRAM pressure that trims the other. Warming both at once lets them co-reside.
    $jobs = @()
    foreach ($t in $targets) {
        if ((Healthy $t.port) -and ((Busy $t.port) -eq 0)) {
            $jobs += Start-Job -ArgumentList $t.port {
                param($pt)
                $b = @{ messages=@(@{role='user';content='ok'}); max_tokens=12; temperature=0 } | ConvertTo-Json -Depth 4
                try { Invoke-RestMethod "http://127.0.0.1:$pt/v1/chat/completions" -Method Post -Body $b -ContentType 'application/json' -TimeoutSec 120 | Out-Null } catch {}
            }
        }
    }
    if ($jobs) { Wait-Job $jobs -Timeout 130 | Out-Null; Remove-Job $jobs -Force }
    $line = ($targets | ForEach-Object { '{0}:{1:N1}GB' -f $_.name,(GpuGB $_.port) }) -join '  '
    $warn = if ($targets | Where-Object { (GpuGB $_.port) -ge 0 -and (GpuGB $_.port) -lt 12 }) { '  <<< a model is trimmed' } else { '' }
    $ramFree = (Get-CimInstance Win32_OperatingSystem).FreePhysicalMemory/1MB
    Log ("resident  {0}  RAM_free={1:N1}GB{2}" -f $line,$ramFree,$warn)
    Start-Sleep -Seconds $IntervalSec
}
