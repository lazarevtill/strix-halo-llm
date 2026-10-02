<#
.SYNOPSIS
  Prometheus exporter for the llama.cpp router on :8080. Serves merged metrics on ONE fixed port.

.DESCRIPTION
  llama-server has a native Prometheus endpoint, but in ROUTER MODE it is unusable as a scrape
  target for two reasons, both of which this script exists to solve:

    1. The router parent (:8080) does not serve /metrics at all -- it 400s. Only the per-model
       CHILD processes do.
    2. Each child listens on a RANDOM port chosen at launch (51955, 59026, ... different every
       restart), so there is no stable address to put in prometheus.yml.

  So this exporter discovers the children through the router's own /v1/models (each entry carries
  the child's full argv, including --port), scrapes each child's /metrics, relabels every series
  with model="<id>", and serves the merged result on a FIXED port. Point Prometheus here:

      scrape_configs:
        - job_name: llamacpp
          static_configs:
            - targets: ['127.0.0.1:9114']

  It also synthesises gauges that llama.cpp does not export but which are the ones you actually
  want when apps are hitting the box: how many slots are busy, how full each slot's context is,
  and whether the model is loaded at all.

  REQUIREMENT: children must be started with `metrics = 1` in the preset. run-router.ps1 puts that
  in $common as of 2026-10-02, so any router it launches is already exporting. A child started
  without it answers /metrics with 501 and is reported here as up=0 with a note.

.PARAMETER Port
  Fixed port to serve merged metrics on. Default 9114 (unused by the common exporters).

.PARAMETER RouterUrl
  Router base URL to discover children through. Default http://127.0.0.1:8080

.PARAMETER Once
  Print the metrics text once to stdout and exit, instead of serving. For testing and for
  piping into a file.

.EXAMPLE
  .\metrics-exporter.ps1                 # serve on :9114 until Ctrl-C
  .\metrics-exporter.ps1 -Once           # dump one scrape and exit
  .\metrics-exporter.ps1 -Port 9999
#>
[CmdletBinding()]
param(
    [int]    $Port      = 9114,
    [string] $RouterUrl = 'http://127.0.0.1:8080',
    # Listen address. '+' = all interfaces (0.0.0.0), so Prometheus/Grafana on another host can
    # scrape this box. Binding '+' needs either an elevated shell or a one-time URL ACL.
    # In an ELEVATED shell, pass the account LITERALLY -- `whoami` gives the right string:
    #     netsh http add urlacl url=http://+:9114/ user="DOMAIN\user"
    #     netsh advfirewall firewall add rule name="llamacpp-metrics" dir=in action=allow protocol=TCP localport=9114
    # DO NOT copy %USERDOMAIN%\%USERNAME% into PowerShell -- those are cmd.exe variables and are NOT
    # expanded there, so netsh receives the literal text and fails with
    #     "Create SDDL failed, Error: 1332 The parameter is incorrect."
    # (In PowerShell use "$env:USERDOMAIN\$env:USERNAME" or just paste the output of whoami.)
    # Without the ACL, HttpListener throws Access Denied and this falls back to 127.0.0.1.
    # NOTE: these metrics are UNAUTHENTICATED. On all-interfaces they expose model names, slot
    # occupancy, context sizes and token counts to anyone who can reach the port. Fine on a trusted
    # LAN; put it behind the firewall otherwise. No prompt or completion text is ever exposed.
    [string] $Bind      = '+',
    [switch] $Once
)
$ErrorActionPreference = 'Continue'

function Get-Children {
    # Returns @( @{ id; port; loaded } ) by reading the router's model list. The child argv is in
    # status.args, which is also how run-router verifies tuned flags -- same source of truth.
    $out = @()
    # Invoke-WebRequest + ConvertFrom-Json for the same PS 5.1 array-collapsing reason as /slots.
    try { $models = @(((Invoke-WebRequest "$RouterUrl/v1/models" -TimeoutSec 5 -UseBasicParsing).Content | ConvertFrom-Json).data) }
    catch { return $out }
    foreach ($m in $models) {
        $a = $m.status.args
        $p = $null
        if ($a -and ($a -contains '--port')) { $p = $a[[array]::IndexOf($a, '--port') + 1] }
        $out += @{ id = $m.id; port = $p; loaded = ($m.status.value -eq 'loaded') }
    }
    return $out
}

function Esc([string]$s) { ($s -replace '\\', '\\\\') -replace '"', '\"' }

function Build-Metrics {
    $sb = New-Object System.Text.StringBuilder
    $null = $sb.AppendLine('# HELP llamacpp_exporter_up 1 if the exporter reached the router.')
    $null = $sb.AppendLine('# TYPE llamacpp_exporter_up gauge')

    $kids = @(Get-Children)
    if (-not $kids.Count) {
        $null = $sb.AppendLine('llamacpp_exporter_up 0')
        return $sb.ToString()
    }
    $null = $sb.AppendLine('llamacpp_exporter_up 1')

    $null = $sb.AppendLine('# HELP llamacpp_model_loaded 1 if the model child is loaded and serving.')
    $null = $sb.AppendLine('# TYPE llamacpp_model_loaded gauge')
    $null = $sb.AppendLine('# HELP llamacpp_slots_total Configured server slots (--parallel).')
    $null = $sb.AppendLine('# TYPE llamacpp_slots_total gauge')
    $null = $sb.AppendLine('# HELP llamacpp_slots_busy Slots currently processing a request.')
    $null = $sb.AppendLine('# TYPE llamacpp_slots_busy gauge')
    $null = $sb.AppendLine('# HELP llamacpp_slot_ctx_used_tokens Prompt tokens currently held in a slot.')
    $null = $sb.AppendLine('# TYPE llamacpp_slot_ctx_used_tokens gauge')
    $null = $sb.AppendLine('# HELP llamacpp_slot_ctx_size_tokens Per-slot context window.')
    $null = $sb.AppendLine('# TYPE llamacpp_slot_ctx_size_tokens gauge')

    foreach ($k in $kids) {
        $lbl = 'model="' + (Esc $k.id) + '"'
        $null = $sb.AppendLine("llamacpp_model_loaded{$lbl} " + $(if ($k.loaded) { 1 } else { 0 }))
        if (-not $k.port) { continue }

        # ---- slot state (always available; --slots defaults to enabled) -------------------------
        try {
            # NOT Invoke-RestMethod. In PS 5.1 it collapses this JSON array into ONE object whose
            # properties are arrays, so .Count reads 1 while the data holds every slot -- the gauge
            # silently reported "1 slot, 1 busy" on a 4-slot server. Invoke-WebRequest +
            # ConvertFrom-Json returns a real Object[]. (Same family as the ConvertTo-Json
            # collection-rewrapping gotcha in CLAUDE.md.)
            $slotsRaw = (Invoke-WebRequest "http://127.0.0.1:$($k.port)/slots" -TimeoutSec 5 -UseBasicParsing).Content
            # Rebuild into an explicit ArrayList. Neither @() nor .Count can be trusted to survive
            # the PS 5.1 JSON pipeline here: an earlier version read "1 slot, 1 busy" off a 4-slot
            # server, which is exactly the believable-wrong-number this repo keeps catching.
            # Count by iterating, never by asking a possibly-collapsed object for .Count.
            $slots = New-Object System.Collections.ArrayList
            foreach ($item in ($slotsRaw | ConvertFrom-Json)) { $null = $slots.Add($item) }
            $total = 0; $busy = 0
            foreach ($s in $slots) { $total++; if ($s.is_processing) { $busy++ } }
            $null = $sb.AppendLine("llamacpp_slots_total{$lbl} $total")
            $null = $sb.AppendLine("llamacpp_slots_busy{$lbl} $busy")
            foreach ($s in $slots) {
                $sl = $lbl + ',slot="' + $s.id + '"'
                $used = 0
                if ($null -ne $s.n_prompt_tokens) { $used = [int]$s.n_prompt_tokens }
                $null = $sb.AppendLine("llamacpp_slot_ctx_used_tokens{$sl} $used")
                $null = $sb.AppendLine("llamacpp_slot_ctx_size_tokens{$sl} $([int]$s.n_ctx)")
            }
        } catch { }

        # ---- native llama.cpp prometheus metrics, relabelled with model= ------------------------
        # These are the real counters (tokens processed/generated, prompt+gen seconds, queue depth).
        # A child started WITHOUT `metrics = 1` answers 501 here; surface that rather than hiding it.
        try {
            $raw = (Invoke-WebRequest "http://127.0.0.1:$($k.port)/metrics" -TimeoutSec 5 -UseBasicParsing).Content
            foreach ($line in ($raw -split "`n")) {
                $t = $line.TrimEnd("`r")
                if ($t -match '^\s*$') { continue }
                if ($t.StartsWith('#')) { $null = $sb.AppendLine($t); continue }
                # inject model= into the label set (or create one) without disturbing the value
                if ($t -match '^([a-zA-Z_:][a-zA-Z0-9_:]*)\{([^}]*)\}(.*)$') {
                    $null = $sb.AppendLine($Matches[1] + '{' + $lbl + ',' + $Matches[2] + '}' + $Matches[3])
                } elseif ($t -match '^([a-zA-Z_:][a-zA-Z0-9_:]*)\s+(.*)$') {
                    $null = $sb.AppendLine($Matches[1] + '{' + $lbl + '} ' + $Matches[2])
                } else {
                    $null = $sb.AppendLine($t)
                }
            }
        } catch {
            $null = $sb.AppendLine("# NOTE model=$($k.id) /metrics unavailable ($($_.Exception.Message.Split([char]10)[0])) -- child needs `metrics = 1` in the preset")
        }
    }
    return $sb.ToString()
}

if ($Once) { Build-Metrics; exit 0 }

$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add("http://${Bind}:$Port/")
$boundAll = ($Bind -eq '+' -or $Bind -eq '0.0.0.0')
try { $listener.Start() }
catch {
    # '+' needs an elevated shell or a URL ACL. Fall back to loopback rather than dying, but say
    # loudly what was lost and exactly how to fix it -- a silent downgrade to 127.0.0.1 would look
    # like "Prometheus can't reach the box" from the other machine.
    Write-Warning "Could not bind http://${Bind}:$Port/ ($($_.Exception.Message.Split([char]10)[0]))"
    Write-Host   "  -> falling back to 127.0.0.1 (LOCAL ONLY). To expose on all interfaces, run ONCE as admin:" -ForegroundColor Yellow
    # Resolve the account here so the printed command can be pasted verbatim. Printing the
    # cmd.exe form (%USERDOMAIN%\%USERNAME%) fails in PowerShell with "Create SDDL failed, 1332"
    # because those are not expanded there.
    $acct = try { (whoami).Trim() } catch { "$env:USERDOMAIN\$env:USERNAME" }
    Write-Host   "     netsh http add urlacl url=http://+:$Port/ user=`"$acct`"" -ForegroundColor Yellow
    Write-Host   "     netsh advfirewall firewall add rule name=`"llamacpp-metrics`" dir=in action=allow protocol=TCP localport=$Port" -ForegroundColor Yellow
    $listener = New-Object System.Net.HttpListener
    $listener.Prefixes.Add("http://127.0.0.1:$Port/")
    $listener.Start()
    $boundAll = $false
}
if ($boundAll) {
    $ips = @(Get-NetIPAddress -AddressFamily IPv4 -EA SilentlyContinue |
             Where-Object { $_.IPAddress -notlike '127.*' -and $_.IPAddress -notlike '169.254.*' } |
             Select-Object -Expand IPAddress)
    Write-Host "llama.cpp Prometheus exporter -> ALL INTERFACES :$Port/metrics" -ForegroundColor Green
    foreach ($ip in $ips) { Write-Host "    http://${ip}:$Port/metrics" -ForegroundColor Green }
    Write-Host "  UNAUTHENTICATED -- anyone who can reach this port sees model/slot/token stats (never prompt text)." -ForegroundColor DarkYellow
} else {
    Write-Host "llama.cpp Prometheus exporter -> http://127.0.0.1:$Port/metrics (local only)" -ForegroundColor Green
}
Write-Host "  discovering children through $RouterUrl/v1/models" -ForegroundColor DarkGray
Write-Host "  Ctrl-C to stop" -ForegroundColor DarkGray

try {
    while ($listener.IsListening) {
        $ctx = $listener.GetContext()
        $body = ''
        if ($ctx.Request.Url.AbsolutePath -eq '/metrics') {
            $body = Build-Metrics
            $ctx.Response.StatusCode = 200
            $ctx.Response.ContentType = 'text/plain; version=0.0.4; charset=utf-8'
        } else {
            $body = "llama.cpp exporter. Metrics at /metrics`n"
            $ctx.Response.StatusCode = 200
            $ctx.Response.ContentType = 'text/plain; charset=utf-8'
        }
        $bytes = [Text.Encoding]::UTF8.GetBytes($body)
        $ctx.Response.ContentLength64 = $bytes.Length
        $ctx.Response.OutputStream.Write($bytes, 0, $bytes.Length)
        $ctx.Response.OutputStream.Close()
    }
} finally {
    $listener.Stop(); $listener.Close()
}
