<#
.SYNOPSIS
  Hold the foreign bench-stack ports, then run the eval suite on one or more models back to back.

.DESCRIPTION
  A watchdog on this box restores any missing member of the old bench stack on :8082/:8088 within
  ~2 minutes (measured 2026-08-03: killed 20:43, back 20:45), stealing ~42 GiB. Qwen alone needs
  ~78 GiB, so a multi-hour comparison cannot survive that.

  MEASURED: llama-server binds its port BEFORE loading weights -- with the port occupied it exits in
  0.6s with code 1, having touched no GPU memory. So we hold :8082 and :8088 for the WHOLE sweep,
  not per-model: releasing between models would leave a window for the watchdog to slip back in.

  Ports are released in a finally block, so a crash still hands them back.

.EXAMPLE
  .\run-guarded.ps1 -Models 'ornith-q5','qwen122b' -SkipTools
#>
[CmdletBinding()]
param(
    [string[]] $Models = @('ornith-q5','qwen122b'),
    [int[]]    $HoldPorts = @(8082, 8088),
    [switch]   $SkipTools,
    [switch]   $SkipCode,
    [string]   $Tasks = ''
)
$ErrorActionPreference = 'Continue'
$root = $PSScriptRoot

# powershell.exe -File hands "-Models a,b" over as a SINGLE string, not a 2-element array, so the
# lookup fails with "unknown model 'a,b'". Split defensively.
$Models = @($Models | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })

$REG = @{
    'ornith-q5' = @{ model='C:\llm-router\models\ornith-1.0-35b-Q5_K_M.gguf'; ctx=131072; spec='' }
    # ctx is 131072 for ALL THREE on purpose. Laguna previously ran its coding eval at 32768 (KV was
    # shrunk to fit alongside a squatter), which made it the only model whose 3-turn conversation --
    # reasoning echoed into history, 16384 tokens/turn -- could approach its window. Equal ctx
    # removes that as a confound; it costs nothing since each model is the sole occupant.
    'laguna'    = @{ model='D:\llamacpp-vulkan\models\laguna-s-2.1-Q4_K_M.gguf'; ctx=131072; spec='ngram-mod' }
    'qwen122b'  = @{ model='D:\llamacpp-vulkan\models\Qwen3.5-122B-A10B-UD-Q4_K_XL-00001-of-00003.gguf'; ctx=131072; spec='draft-mtp' }
}

# ---- kill the squatters (elevated; needs UAC) ----------------------------------------------------
$foreign = @(Get-CimInstance Win32_Process -Filter "Name='llama-server.exe'" |
             Where-Object { $null -eq $_.CommandLine } | Select-Object -Expand ProcessId)
if ($foreign.Count) {
    Write-Host "killing foreign (elevated) llama-servers: $($foreign -join ',')" -ForegroundColor Yellow
    $a = @(); foreach ($t in $foreign) { $a += '/PID'; $a += "$t" }; $a += '/F'
    try { Start-Process taskkill.exe -ArgumentList $a -Verb RunAs -WindowStyle Hidden -Wait -EA Stop }
    catch { Write-Host "UAC declined: $($_.Exception.Message)" -ForegroundColor Red; exit 2 }
    Start-Sleep 6
}
# anything of ours still up would break solo occupancy
Get-Process llama-server -EA SilentlyContinue | Stop-Process -Force -EA SilentlyContinue
Start-Sleep 4

# ---- prove the harness works BEFORE spending hours on models -------------------------------------
# Every bug found on 2026-08-03 was caught only AFTER a run had produced a believable number. The
# smoke test asserts the sandbox discriminates good from bad, that extraction classifies prose as
# "no code", and that every task prompt is satisfiable by a reference solution -- the last of which
# is what finally exposed token_budget's self-contradictory turn 3.
if (-not $SkipCode) {
    Write-Host "running harness smoke test..." -ForegroundColor Cyan
    Push-Location "$root\code"
    & python smoke.py 2>&1 | Write-Host
    $smokeOk = ($LASTEXITCODE -eq 0)
    Pop-Location
    if (-not $smokeOk) { Write-Host "SMOKE TEST FAILED -- refusing to start a multi-hour run on a harness that cannot score itself." -ForegroundColor Red; exit 4 }
}

$listeners = @()
try {
    foreach ($p in $HoldPorts) {
        try {
            $l = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Any, $p)
            $l.Start(); $listeners += $l
            Write-Host "holding :$p" -ForegroundColor DarkGray
        } catch { Write-Host "could NOT hold :$p -- respawns may still land" -ForegroundColor Yellow }
    }

    foreach ($name in $Models) {
        if (-not $REG.ContainsKey($name)) { Write-Host "unknown model '$name'" -ForegroundColor Red; continue }
        $m = $REG[$name]
        # NOT $args -- that is an automatic variable in PowerShell and shadowing it at script scope
        # is a foot-gun even though 5.1 tolerates it here.
        $psArgs = @('-NoProfile','-ExecutionPolicy','Bypass','-File',"$root\run-model-suite.ps1",
                    '-Label',$name,'-Model',$m.model,'-Ctx',"$($m.ctx)")
        if ($m.spec)    { $psArgs += @('-Spec',$m.spec) }
        if ($SkipTools) { $psArgs += '-SkipTools' }
        if ($SkipCode)  { $psArgs += '-SkipCode' }
        if ($Tasks)     { $psArgs += @('-Tasks',$Tasks) }
        & powershell $psArgs 2>&1 | Write-Host
        Start-Sleep 5
    }
}
finally {
    foreach ($l in $listeners) { try { $l.Stop() } catch {} }
    Write-Host "released held ports" -ForegroundColor DarkGray
}
