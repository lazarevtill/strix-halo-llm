<#
.SYNOPSIS
  DEPRECATED -- use `run-guarded.ps1`, which does this for any model and supports -Tasks/-SkipTools.
      .\run-guarded.ps1 -Models qwen122b
  Kept only because it documents the port-holding trick in its original single-model form.

  Clear the foreign bench stack, HOLD its ports so it cannot come back, then run the full eval
  suite on Qwen3.5-122B-A10B.

.DESCRIPTION
  Killing the squatters on :8082/:8088 does not stick -- a watchdog restores any missing member
  within ~2 minutes (measured 2026-08-03: killed 20:43, back 20:45). Qwen needs ~78 GiB of weights
  and cannot share the box with 42 GiB of them, so "kill and hope" is not good enough for a
  ~2 hour run.

  MEASURED: llama-server binds its port BEFORE loading the model -- with the port occupied it exits
  in 0.6s with code 1, having allocated no GPU memory at all. So we simply hold :8082 and :8088 for
  the duration. The watchdog's respawns die instantly and harmlessly.

  Ports are released in a finally block, so a crash or Ctrl-C still hands them back.
#>
[CmdletBinding()]
param(
    [int[]]  $HoldPorts = @(8082, 8088),
    [string] $Model = 'D:\llamacpp-vulkan\models\Qwen3.5-122B-A10B-UD-Q4_K_XL-00001-of-00003.gguf',
    [string] $Label = 'qwen122b',
    [int]    $Ctx   = 131072,
    [string] $Spec  = 'draft-mtp'
)
$ErrorActionPreference = 'Continue'
$root = $PSScriptRoot

# ---- 1) kill the squatters (elevated; needs UAC approval) ----------------------------------------
$foreign = @(Get-CimInstance Win32_Process -Filter "Name='llama-server.exe'" |
             Where-Object { $null -eq $_.CommandLine } | Select-Object -Expand ProcessId)
if ($foreign.Count) {
    Write-Host "killing foreign (elevated) llama-servers: $($foreign -join ',')" -ForegroundColor Yellow
    $a = @(); foreach ($t in $foreign) { $a += '/PID'; $a += "$t" }; $a += '/F'
    try { Start-Process taskkill.exe -ArgumentList $a -Verb RunAs -WindowStyle Hidden -Wait -EA Stop }
    catch { Write-Host "UAC declined -- cannot free the memory Qwen needs: $($_.Exception.Message)" -ForegroundColor Red; exit 2 }
    Start-Sleep 6
}

# ---- 2) hold the ports so the watchdog's respawns die on bind ------------------------------------
$listeners = @()
try {
    foreach ($p in $HoldPorts) {
        try {
            $l = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Any, $p)
            $l.Start(); $listeners += $l
            Write-Host "holding :$p" -ForegroundColor DarkGray
        } catch { Write-Host "could NOT hold :$p ($($_.Exception.Message)) -- respawns may still land" -ForegroundColor Yellow }
    }

    $still = @(Get-Process llama-server -EA SilentlyContinue)
    if ($still.Count) { Write-Host "WARNING: $($still.Count) llama-server(s) still alive" -ForegroundColor Yellow }

    # ---- 3) run the suite ------------------------------------------------------------------------
    & powershell -NoProfile -ExecutionPolicy Bypass -File "$root\run-model-suite.ps1" `
        -Label $Label -Model $Model -Ctx $Ctx -Spec $Spec 2>&1 | Write-Host
}
finally {
    foreach ($l in $listeners) { try { $l.Stop() } catch {} }
    Write-Host "released held ports" -ForegroundColor DarkGray
}
