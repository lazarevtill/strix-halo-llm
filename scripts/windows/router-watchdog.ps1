<#
.SYNOPSIS
  Restart the :8080 router when its model child stops answering -- the failure the router itself
  cannot recover from.

.DESCRIPTION
  The router parent already reloads a child that CRASHES. It does nothing about a child that
  FREEZES: on 2026-10-05 the ornith15 child deadlocked (0% GPU, 0% CPU, 18 connections stuck in
  CLOSE_WAIT) while the parent kept answering /models, and every request hung until a human
  noticed. This loop probes each loaded child's /health directly (the parent's /health says
  nothing about the children) and restarts the router with the given config when a child has
  been unresponsive for -FailAfter consecutive probes.

  What counts as FROZEN: no HTTP answer at all within -TimeoutSec. A 503 is a child that is
  loading -- it answered -- and is never treated as frozen. /health is served by the HTTP layer in
  milliseconds and does not queue behind generation, so a busy server still passes.

  Also restarts when the router PARENT is gone (nothing listening on :Port).

  Guards against a restart loop: after a restart it waits -GraceSec before probing again, and it
  stops restarting (logs and keeps watching) after -MaxRestartsPerHour.

  Runs in the interactive session, like the router (Vulkan/WDDM needs it) -- start it from the
  same Startup-folder launcher. Logs to logs\router-watchdog.log.

.EXAMPLE
  .\router-watchdog.ps1 -Models ornith15 -Bin .\bin-b11414 -Parallel 2 -PerSlotCtx 262144
  .\router-watchdog.ps1 -Models ornith15 -Bin .\bin-b11414 -Parallel 2 -PerSlotCtx 262144 -Once   # one probe, report, exit
#>
[CmdletBinding()]
param(
    # The config to RESTART with -- must match the Startup-folder launcher, like stage-nextgen's
    # restore defaults. Passed straight through to run-router.ps1.
    [string[]] $Models     = @('ornith15'),
    [string]   $Bin        = '.\bin-b11414',
    [int]      $Parallel   = 2,
    [int]      $PerSlotCtx = 262144,
    [switch]   $NoSpec,
    [int]      $Port       = 8080,
    [int]      $IntervalSec = 30,
    [int]      $TimeoutSec  = 10,   # generous: /health normally answers in ~16 ms
    [int]      $FailAfter   = 4,    # consecutive misses before acting (~2 min at 30 s)
    [int]      $GraceSec    = 600,  # after a restart: model load + warm-up before judging again
    [int]      $StartupGraceSec = 120,  # at logon the router is still starting when this starts
    [int]      $MaxRestartsPerHour = 3,
    # Detect and log, never restart. For testing against a fake/foreign endpoint: a test that can
    # reach Restart-Router WILL stop the real llama-server processes on this box.
    [switch]   $NoAct,
    [switch]   $Once
)
$ErrorActionPreference = 'Continue'
$repoRoot = $PSScriptRoot | Split-Path -Parent | Split-Path -Parent
$logDir = Join-Path $repoRoot 'logs'
New-Item -ItemType Directory -Force -Path $logDir | Out-Null
$log = Join-Path $logDir 'router-watchdog.log'

function Log([string]$msg, [string]$colour = 'Gray') {
    $line = "{0:s}  {1}" -f (Get-Date), $msg
    Write-Host $line -ForegroundColor $colour
    # UTF-8 without BOM, appended: Add-Content -Encoding UTF8 in PS 5.1 writes a BOM (CLAUDE.md).
    [IO.File]::AppendAllText($log, $line + "`r`n", (New-Object Text.UTF8Encoding($false)))
}

function Get-State {
    # Returns @{ router = $true/$false; children = @( @{ id; port; status; alive } ) }.
    # Invoke-WebRequest + ConvertFrom-Json, not Invoke-RestMethod (PS 5.1 array collapse).
    $st = @{ router = $false; children = @() }
    try {
        $models = @(((Invoke-WebRequest "http://127.0.0.1:$Port/v1/models" -TimeoutSec $TimeoutSec -UseBasicParsing).Content | ConvertFrom-Json).data)
        $st.router = $true
    } catch { return $st }
    foreach ($m in $models) {
        $a = $m.status.args
        $p = $null
        if ($a -and ($a -contains '--port')) { $p = $a[[array]::IndexOf($a, '--port') + 1] }
        $c = @{ id = $m.id; port = $p; status = $m.status.value; alive = $null }
        # Only a LOADED child is judged. loading/unloaded children are the router's business.
        if ($p -and $c.status -eq 'loaded') {
            $c.alive = $false
            try {
                $null = Invoke-WebRequest "http://127.0.0.1:$p/health" -TimeoutSec $TimeoutSec -UseBasicParsing
                $c.alive = $true
            } catch {
                $resp = $_.Exception.Response
                if ($resp -and [int]$resp.StatusCode -eq 503) { $c.alive = $true }   # answered: loading
            }
        }
        $st.children += $c
    }
    return $st
}

function Restart-Router([string]$why) {
    if ($NoAct) { Log "WOULD RESTART router (-NoAct): $why" 'Yellow'; return }
    Log "RESTARTING router: $why" 'Yellow'
    $args_ = @{ Models = $Models; Bin = $Bin; Parallel = $Parallel; PerSlotCtx = $PerSlotCtx; Force = $true }
    if ($NoSpec) { $args_.NoSpec = $true }
    try {
        # run-router stops every llama-server (a frozen child included), relaunches with logs on,
        # and pre-loads. Its console output goes into our log for the post-mortem.
        $out = & (Join-Path $PSScriptRoot 'run-router.ps1') @args_ *>&1 | ForEach-Object { "$_" }
        foreach ($l in $out) { if ($l.Trim()) { Log ("  run-router: " + $l.Trim()) 'DarkGray' } }
    } catch {
        Log "  run-router threw: $($_.Exception.Message)" 'Red'
    }
}

$misses   = @{}                                  # model id -> consecutive misses
$restarts = New-Object System.Collections.ArrayList   # timestamps
$graceUntil = if ($Once) { Get-Date } else { (Get-Date).AddSeconds($StartupGraceSec) }

Log ("watchdog start: :{0} every {1}s, act after {2} misses, restart config = -Models {3} -Bin {4} -Parallel {5} -PerSlotCtx {6}{7}" -f `
     $Port, $IntervalSec, $FailAfter, ($Models -join ','), $Bin, $Parallel, $PerSlotCtx, $(if ($NoSpec) { ' -NoSpec' } else { '' })) 'Cyan'

while ($true) {
    if ((Get-Date) -ge $graceUntil) {
        $st = Get-State
        $reason = $null
        if (-not $st.router) {
            $misses['__router__'] = 1 + [int]$misses['__router__']
            Log ("router :$Port not answering ({0}/{1})" -f $misses['__router__'], $FailAfter) 'DarkYellow'
            if ($misses['__router__'] -ge $FailAfter) { $reason = "router parent on :$Port unreachable for $FailAfter probes" }
        } else {
            $misses['__router__'] = 0
            foreach ($c in $st.children) {
                if ($null -eq $c.alive) { continue }
                if ($c.alive) {
                    if ([int]$misses[$c.id] -gt 0) { Log "$($c.id) responsive again after $($misses[$c.id]) miss(es)" 'Green' }
                    $misses[$c.id] = 0
                } else {
                    $misses[$c.id] = 1 + [int]$misses[$c.id]
                    Log ("{0} (child :{1}) did not answer /health within {2}s ({3}/{4})" -f $c.id, $c.port, $TimeoutSec, $misses[$c.id], $FailAfter) 'DarkYellow'
                    if ($misses[$c.id] -ge $FailAfter) { $reason = "$($c.id) child frozen: $FailAfter consecutive /health timeouts" }
                }
            }
        }
        if ($Once) {
            foreach ($c in $st.children) { Log ("once: {0} status={1} port={2} responsive={3}" -f $c.id, $c.status, $c.port, $c.alive) }
            if (-not $st.router) { Log "once: router :$Port unreachable" 'Red' }
            exit 0
        }
        if ($reason) {
            $hourAgo = (Get-Date).AddHours(-1)
            $recent = @($restarts | Where-Object { $_ -gt $hourAgo }).Count
            if ($recent -ge $MaxRestartsPerHour) {
                # Restarting again would only hide a persistent fault behind churn. Keep watching and
                # say so; a human needs to look at logs\router-*.err.
                Log "NOT restarting: already $recent restart(s) in the last hour (limit $MaxRestartsPerHour). Check logs\router-*.err" 'Red'
            } else {
                Restart-Router $reason
                $null = $restarts.Add((Get-Date))
                $misses = @{}
                $graceUntil = (Get-Date).AddSeconds($GraceSec)
                Log "grace period: next probe after $($graceUntil.ToString('s'))" 'DarkGray'
            }
        }
    }
    Start-Sleep -Seconds $IntervalSec
}
