<#
.SYNOPSIS
  Keep the daily-driver model serving 24/7: boot autostart (no login) + watchdog, as a SYSTEM task.

.DESCRIPTION
  Same mechanism as the retired `remote-host-setup.ps1`, pointed at the CURRENT model and the
  measured-optimal flags, and made findable.

  WHY "FINDABLE" IS A REQUIREMENT, NOT A NICETY: the old task was called `llm-router-autostart`
  and its action was `powershell.exe -File ...\remote-host-setup.ps1`. Searching scheduled tasks
  for `llama|serve|warm|ornith` matched NEITHER the name NOR the action, and `Get-ScheduledTask`
  hides a SYSTEM task's details from a non-elevated query -- so it read as "no such task" for
  hours while it restarted a retired model stack every 15 minutes, stealing 42 GiB.

  So this task is named `llama-ornith-daily`, its action path contains `llamacpp-vulkan` and
  `serve-daily`, and `-Status` prints everything a future investigator needs. If you ever hunt a
  mystery respawn again, run:
      Get-ScheduledTask | ? { ($_.Actions | % { "$($_.Execute) $($_.Arguments)" }) -match 'llama|llm|serve' }
  ELEVATED -- a non-elevated query silently returns nothing for SYSTEM tasks.

  WHAT IT SERVES: Ornith-1.0-35B Q5_K_M at full 262144 ctx with the flags measured optimal on
  gfx1151 (see docs/OPTIMIZATION.md). Chosen because it TIES Laguna-S-2.1 and Qwen3.5-122B on both
  private eval suites at a quarter the size and ~4x the speed.

.EXAMPLE
  .\serve-daily.ps1 -Install      # register the task + firewall, then start serving (needs admin)
  .\serve-daily.ps1 -Status       # what is registered, what is running, is it healthy
  .\serve-daily.ps1 -Uninstall    # remove task + firewall rule, stop the server (needs admin)
  .\serve-daily.ps1               # one-shot: start it if it is not healthy (what the task runs)
#>
[CmdletBinding()]
param(
    [string] $Model = 'D:\llamacpp-vulkan\models\ornith-1.0-35b-Q5_K_M.gguf',
    [int]    $Ctx   = 262144,
    [int]    $Port  = 8080,
    [string] $Reasoning = 'auto',
    [switch] $Install,
    [switch] $Uninstall,
    [switch] $Status,
    [switch] $FromTask
)
$ErrorActionPreference = 'Continue'

$TaskName = 'llama-ornith-daily'          # greppable on purpose: contains 'llama' AND 'ornith'
$RepoRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$Bin      = Join-Path $RepoRoot 'bin\llama-server.exe'
$LogDir   = Join-Path $RepoRoot 'logs'
$Self     = $PSCommandPath
New-Item -ItemType Directory -Force $LogDir | Out-Null
$LogFile  = Join-Path $LogDir 'serve-daily.log'
$OutLog   = Join-Path $LogDir "server-$Port.out"
$ErrLog   = Join-Path $LogDir "server-$Port.err"
$FlagFile = Join-Path $LogDir "unhealthy-$Port.flag"

function Log([string]$m, [string]$lvl='INFO') {
    $line = "{0} [{1,-4}] {2}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $lvl, $m
    $c = @{ INFO='Gray'; OK='Green'; WARN='Yellow'; ERR='Red'; STEP='Cyan' }[$lvl]
    Write-Host $line -ForegroundColor $c
    try {
        if ((Test-Path $LogFile) -and ((Get-Item $LogFile).Length -gt 5MB)) { Move-Item $LogFile "$LogFile.old" -Force }
        Add-Content $LogFile $line -Encoding UTF8
    } catch {}
}
function Test-Admin {
    ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
     ).IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)
}
function Test-Healthy {
    try { return ((Invoke-RestMethod "http://127.0.0.1:$Port/health" -TimeoutSec 5).status -eq 'ok') } catch { return $false }
}

# ---------------------------------------------------------------- STATUS
if ($Status) {
    Write-Host "`n=== $TaskName ===" -ForegroundColor Cyan
    $t = Get-ScheduledTask -TaskName $TaskName -EA SilentlyContinue
    if ($t) {
        $i = $t | Get-ScheduledTaskInfo -EA SilentlyContinue
        "  registered : yes   state=$($t.State)  user=$($t.Principal.UserId)/$($t.Principal.RunLevel)"
        "  last run   : $($i.LastRunTime)  (result $($i.LastTaskResult))"
        "  next run   : $($i.NextRunTime)"
        foreach ($tr in $t.Triggers) { "  trigger    : $($tr.CimClass.CimClassName) repeat=$($tr.Repetition.Interval)" }
        if (-not $t.Actions) { "  actions    : HIDDEN -- re-run this ELEVATED to see them" }
        else { foreach ($a in $t.Actions) { "  action     : $($a.Execute) $($a.Arguments)" } }
    } else {
        "  registered : NO" + $(if (-not (Test-Admin)) { "  (note: a SYSTEM task is INVISIBLE to a non-elevated query -- re-run elevated to be sure)" } else { "" })
    }
    $c = Get-NetTCPConnection -LocalPort $Port -State Listen -EA SilentlyContinue | Select-Object -First 1
    "  port $Port    : " + $(if ($c) { "listening on $($c.LocalAddress) (pid $($c.OwningProcess))" } else { 'not listening' })
    "  health     : " + $(if (Test-Healthy) { 'ok' } else { 'FAILING' })
    if (Test-Healthy) {
        try { $p = Invoke-RestMethod "http://127.0.0.1:$Port/props" -TimeoutSec 10
              "  model      : $(Split-Path $p.model_path -Leaf)"
              "  ctx        : $($p.default_generation_settings.n_ctx)" } catch {}
    }
    "  log        : $LogFile"
    return
}

# ---------------------------------------------------------------- UNINSTALL
if ($Uninstall) {
    if (-not (Test-Admin)) { Log "must run ELEVATED to unregister a SYSTEM task" ERR; return }
    if (Get-ScheduledTask -TaskName $TaskName -EA SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -EA SilentlyContinue
        Log "unregistered task '$TaskName'" OK
    } else { Log "task '$TaskName' was not registered" INFO }
    $fw = Get-NetFirewallRule -EA SilentlyContinue | Where-Object { $_.DisplayName -eq "llama-ornith :$Port" }
    if ($fw) { $fw | Remove-NetFirewallRule -EA SilentlyContinue; Log "removed firewall rule" OK }
    Get-Process llama-server -EA SilentlyContinue | Stop-Process -Force -EA SilentlyContinue
    Log "stopped llama-server; daily serving is OFF" OK
    return
}

# ---------------------------------------------------------------- INSTALL
if ($Install) {
    if (-not (Test-Admin)) { Log "must run ELEVATED to register a SYSTEM task + firewall rule" ERR; return }
    if (-not (Test-Path $Bin))   { Log "llama-server not found: $Bin" ERR; return }
    if (-not (Test-Path $Model)) { Log "model not found: $Model" ERR; return }

    $name = "llama-ornith :$Port"
    if (-not (Get-NetFirewallRule -EA SilentlyContinue | Where-Object { $_.DisplayName -eq $name })) {
        New-NetFirewallRule -DisplayName $name -Direction Inbound -Action Allow -Protocol TCP -LocalPort $Port | Out-Null
        Log "firewall rule added: $name" OK
    } else { Log "firewall rule already present" INFO }
    Log "NOTE: :$Port is open to ANY address and llama-server has NO AUTH. Keep this box on a trusted LAN/overlay." WARN

    $psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $args  = "-NoProfile -ExecutionPolicy Bypass -File `"$Self`" -Model `"$Model`" -Ctx $Ctx -Port $Port -Reasoning $Reasoning -FromTask"
    $action = New-ScheduledTaskAction -Execute $psExe -Argument $args
    $trigBoot = New-ScheduledTaskTrigger -AtStartup
    $trigBoot.Delay = 'PT45S'          # let the GPU driver settle before loading ~23 GB
    # Omit -RepetitionDuration entirely = repeat forever. [TimeSpan]::MaxValue is REJECTED by the
    # Win11 Task Scheduler schema.
    $trigTick = New-ScheduledTaskTrigger -Once -At (Get-Date).Date -RepetitionInterval (New-TimeSpan -Minutes 15)
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    # Priority 5 = Normal (the task default of 7 would run llama-server BelowNormal).
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
                  -StartWhenAvailable -MultipleInstances IgnoreNew -ExecutionTimeLimit ([TimeSpan]::Zero) -Priority 5
    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigBoot,$trigTick `
        -Principal $principal -Settings $settings -Force | Out-Null
    Log "task '$TaskName' registered: at boot (+45s, no login) + watchdog every 15 min" OK
    Log "to inspect later:  .\serve-daily.ps1 -Status     to remove:  .\serve-daily.ps1 -Uninstall" INFO
    # fall through and start serving now
}

# ---------------------------------------------------------------- SERVE (one-shot / watchdog tick)
# Only one instance may act at a time: a manual run and a watchdog tick can overlap.
$mutex = New-Object Threading.Mutex($false, 'Global\llama-ornith-daily')
$got = $false
try { $got = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $got = $true } catch { $got = $false }
if (-not $got) { Log "another instance is already acting (manual run or watchdog tick) - exiting" INFO; return }

try {
    if (-not (Test-Path $Model)) { Log "model missing: $Model" ERR; return }

    $listen = Get-NetTCPConnection -LocalPort $Port -State Listen -EA SilentlyContinue | Select-Object -First 1
    if ($listen) {
        $owner = $null; try { $owner = Get-Process -Id $listen.OwningProcess -EA Stop } catch {}
        if ($owner -and $owner.Name -ne 'llama-server') {
            Log ":$Port is held by '$($owner.Name)' (pid $($owner.Id)), not llama-server - refusing to touch it" ERR
            return
        }
        if (Test-Healthy) {
            Remove-Item $FlagFile -Force -EA SilentlyContinue
            if (-not $FromTask) { Log ":$Port already serving and healthy (pid $($listen.OwningProcess))" OK }
            return
        }
        # Bound but not healthy. Two-strike rule: a model mid-load also fails /health, and killing
        # it every 15 min would guarantee it never finishes loading.
        if (-not (Test-Path $FlagFile)) {
            Set-Content $FlagFile (Get-Date -Format 's') -Encoding ASCII
            Log ":$Port bound but /health FAILED - flagged; will restart if still dead next tick" WARN
            return
        }
        Log ":$Port failed /health twice in a row - restarting the wedged server" ERR
        Remove-Item $FlagFile -Force -EA SilentlyContinue
        try { Stop-Process -Id $listen.OwningProcess -Force -EA Stop } catch { Log "cannot stop pid $($listen.OwningProcess): $_" ERR; return }
        for ($j=0; $j -lt 15; $j++) { if (-not (Get-NetTCPConnection -LocalPort $Port -State Listen -EA SilentlyContinue)) { break }; Start-Sleep 1 }
    }

    foreach ($f in @($OutLog,$ErrLog)) { if ((Test-Path $f) -and ((Get-Item $f).Length -gt 2MB)) { try { Move-Item $f "$f.old" -Force } catch {} } }

    # Measured-optimal flags for gfx1151 -- see docs/OPTIMIZATION.md. -lm none replaces the
    # DEPRECATED --no-mmap (--load-mode defaults to mmap, so the old flag silently did nothing).
    $argline = "-m `"$Model`" -ngl 999 --ctx-size $Ctx --batch-size 2048 --ubatch-size 1024 " +
               "-fa on --cache-type-k q8_0 --cache-type-v q8_0 -lm none --jinja --parallel 1 " +
               "--host 0.0.0.0 --port $Port --no-warmup --reasoning $Reasoning --reasoning-preserve"
    Log "starting llama-server on :$Port ($(Split-Path $Model -Leaf), ctx=$Ctx)" STEP
    $env:GGML_VK_ENABLE_MEMORY_PRIORITY = '1'
    $p = Start-Process -FilePath $Bin -ArgumentList $argline -RedirectStandardOutput $OutLog `
             -RedirectStandardError $ErrLog -WindowStyle Minimized -PassThru
    $null = $p.Handle    # PS 5.1: without touching .Handle, .ExitCode stays empty when streams are redirected

    $healthy = $false
    for ($i=0; $i -lt 120; $i++) {
        if ($p.HasExited) { Log "llama-server EXITED early (code $($p.ExitCode)) - see $ErrLog" ERR; break }
        if (Test-Healthy) { $healthy = $true; break }
        Start-Sleep 3
    }
    if (-not $healthy) { Log "NOT healthy after 6 min - see $ErrLog" ERR; return }

    Remove-Item $FlagFile -Force -EA SilentlyContinue
    Log "healthy on :$Port (pid $($p.Id))" OK

    # CPU-fallback detection: /health passes even when Vulkan found no device. Boot-time SYSTEM
    # runs are the classic case -- some drivers expose no Vulkan to session 0 that early.
    try {
        $head = @()
        foreach ($f in @($ErrLog,$OutLog)) { if (Test-Path $f) { $head += @(Get-Content $f -TotalCount 150 -EA SilentlyContinue) } }
        if (($head -join "`n") -match '(?i)found 0 vulkan|no vulkan device|failed to initialize vulkan') {
            Log "running WITHOUT a GPU (Vulkan found no device) - CPU fallback, ~10x slower!" ERR
        }
    } catch {}
}
finally { if ($got) { try { $mutex.ReleaseMutex() } catch {} } }
