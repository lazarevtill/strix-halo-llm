<#
.SYNOPSIS
  Hold :8082 and :8088 so the old bench stack cannot come back.

.DESCRIPTION
  WHY THIS EXISTS: an elevated process on this box restores the retired bench stack on those
  ports, stealing ~42 GiB. It has survived every attempt to remove it -- killing the servers,
  killing the supervising elevated PowerShell with `taskkill /T /F`, and removing the dead
  OpenClaw startup entry. Measured 2026-08-04: after a /T kill it was back in FOUR MINUTES,
  with two fresh elevated shells. The root process cannot be identified from a non-elevated
  shell (its command line is unreadable and its parent has always exited by the time it is
  seen).

  So this attacks the symptom instead, and it works reliably:

    MEASURED: llama-server binds its port BEFORE loading weights. With the port already
    taken it exits in 0.6s with code 1, having allocated NO GPU memory at all.

  Holding the two ports therefore makes every respawn a harmless no-op. This does not fix the
  root cause -- it makes the root cause stop mattering.

  Costs nothing: two idle TCP listeners, no CPU, no GPU.

.EXAMPLE
  # run detached, keep the daily server safe:
  Start-Process powershell -WindowStyle Hidden -ArgumentList `
    '-NoProfile','-ExecutionPolicy','Bypass','-File','D:\llamacpp-vulkan\scripts\windows\hold-ports.ps1'

  # stop holding:
  Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
    Where-Object { $_.CommandLine -like '*hold-ports*' } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force }
#>
[CmdletBinding()]
param(
    [int[]] $Ports = @(8082, 8088),
    [switch] $Once          # bind, report, release -- for testing the ports are free
)

$listeners = @()
try {
    foreach ($p in $Ports) {
        try {
            $l = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Any, $p)
            $l.Start()
            $listeners += $l
            Write-Host ("holding :{0}" -f $p) -ForegroundColor Green
        } catch {
            Write-Host ("could NOT hold :{0} -- something is already on it: {1}" -f $p, $_.Exception.Message) -ForegroundColor Yellow
        }
    }

    if ($listeners.Count -eq 0) { Write-Host "no ports held; nothing to do" -ForegroundColor Red; return }
    if ($Once) { Write-Host "-Once: releasing immediately"; return }

    Write-Host "holding $($listeners.Count) port(s). Respawns will now exit on bind. Ctrl-C or kill to stop." -ForegroundColor Cyan
    # Accept-and-drop anything that connects, so a stray client gets a clean refusal rather
    # than hanging on a half-open socket.
    while ($true) {
        foreach ($l in $listeners) {
            if ($l.Pending()) { try { $l.AcceptTcpClient().Close() } catch {} }
        }
        Start-Sleep -Milliseconds 500
    }
}
finally {
    foreach ($l in $listeners) { try { $l.Stop() } catch {} }
    Write-Host "released held ports" -ForegroundColor DarkGray
}
