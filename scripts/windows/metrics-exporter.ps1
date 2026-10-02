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

# Child-restart tracking. The KNOWN failure mode on this box (CLAUDE.md, multi-slot stability) is a
# child crash that the router parent silently auto-reloads: clients see an intermittent HTTP 500
# "proxy error" while the parent stays alive, so "is llama-server running?" says yes. A reload
# always lands on a NEW random port and a NEW pid, so remembering the last child identity per model
# turns that hand-diagnosis (counting PID churn) into a counter Prometheus can alert on:
#     increase(llamacpp_child_restarts_total[1h]) > 0
# The counter only covers this exporter's lifetime; llamacpp_child_start_time_seconds survives an
# exporter restart, so `changes(llamacpp_child_start_time_seconds[1h])` is the durable form.
$script:LastChild = @{}   # model id -> "pid:port"
$script:Restarts  = @{}   # model id -> int

function Get-ChildProcess([string]$port) {
    # The process LISTENING on the child's port. Get-NetTCPConnection is the only PS 5.1 way to map
    # a port to a pid without parsing netstat text.
    try {
        $c = @(Get-NetTCPConnection -LocalPort ([int]$port) -State Listen -ErrorAction Stop)
        if ($c.Count -gt 0) { return Get-Process -Id $c[0].OwningProcess -ErrorAction Stop }
    } catch { }
    return $null
}

function Build-Metrics {
    # Samples are collected PER METRIC FAMILY and emitted grouped at the end. The Prometheus text
    # format requires every sample of a family to be contiguous and its # HELP / # TYPE to appear
    # once, before them. Emitting child-by-child (as an earlier version did) is only valid while a
    # single model is loaded: with two, the families interleave and the native # TYPE lines repeat,
    # and Prometheus rejects the WHOLE scrape on "second TYPE line" -- every series goes dark at
    # once, which looks like the box died rather than like an exporter bug.
    $order = New-Object System.Collections.ArrayList   # family names, first-seen order
    $meta  = @{}                                        # family -> ArrayList of # lines
    $data  = @{}                                        # family -> ArrayList of sample lines
    function Add-Fam([string]$f) {
        if (-not $data.ContainsKey($f)) {
            $null = $order.Add($f)
            $data[$f] = New-Object System.Collections.ArrayList
            $meta[$f] = New-Object System.Collections.ArrayList
        }
    }
    function Add-Meta([string]$f, [string]$type, [string]$help) {
        Add-Fam $f
        if ($meta[$f].Count -eq 0) {
            $null = $meta[$f].Add("# HELP $f $help")
            $null = $meta[$f].Add("# TYPE $f $type")
        }
    }
    function Add-Sample([string]$f, [string]$line) { Add-Fam $f; $null = $data[$f].Add($line) }

    Add-Meta 'llamacpp_exporter_up'             'gauge'   '1 if the exporter reached the router.'
    Add-Meta 'llamacpp_model_loaded'            'gauge'   '1 if the model child is loaded and serving.'
    Add-Meta 'llamacpp_child_restarts_total'    'counter' 'Child (re)starts seen by this exporter after its first scrape -- a crash the router auto-reloaded counts here.'
    Add-Meta 'llamacpp_child_start_time_seconds' 'gauge'  'Unix start time of the model child process.'
    Add-Meta 'llamacpp_slots_total'             'gauge'   'Configured server slots (--parallel).'
    Add-Meta 'llamacpp_slots_busy'              'gauge'   'Slots currently processing a request.'
    Add-Meta 'llamacpp_slot_ctx_used_tokens'    'gauge'   'Prompt tokens currently held in a slot.'
    Add-Meta 'llamacpp_slot_ctx_size_tokens'    'gauge'   'Per-slot context window.'
    $notes = New-Object System.Collections.ArrayList

    $kids = @(Get-Children)
    if (-not $kids.Count) {
        Add-Sample 'llamacpp_exporter_up' 'llamacpp_exporter_up 0'
    } else {
        Add-Sample 'llamacpp_exporter_up' 'llamacpp_exporter_up 1'
    }

    foreach ($k in $kids) {
        $lbl = 'model="' + (Esc $k.id) + '"'
        Add-Sample 'llamacpp_model_loaded' ("llamacpp_model_loaded{$lbl} " + $(if ($k.loaded) { 1 } else { 0 }))
        if (-not $script:Restarts.ContainsKey($k.id)) { $script:Restarts[$k.id] = 0 }

        # ---- child identity: restart detection + start time ------------------------------------
        if ($k.port) {
            $proc = Get-ChildProcess $k.port
            if ($proc) {
                $ident = "$($proc.Id):$($k.port)"
                $prev  = $script:LastChild[$k.id]
                # First sighting establishes the baseline; only a CHANGE of identity is a restart.
                if ($prev -and $prev -ne $ident) { $script:Restarts[$k.id]++ }
                $script:LastChild[$k.id] = $ident
                try {
                    $epoch = [int64](($proc.StartTime.ToUniversalTime() - [datetime]'1970-01-01').TotalSeconds)
                    Add-Sample 'llamacpp_child_start_time_seconds' "llamacpp_child_start_time_seconds{$lbl} $epoch"
                } catch { }
            }
        }
        Add-Sample 'llamacpp_child_restarts_total' "llamacpp_child_restarts_total{$lbl} $($script:Restarts[$k.id])"
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
            Add-Sample 'llamacpp_slots_total' "llamacpp_slots_total{$lbl} $total"
            Add-Sample 'llamacpp_slots_busy'  "llamacpp_slots_busy{$lbl} $busy"
            foreach ($s in $slots) {
                $sl = $lbl + ',slot="' + $s.id + '"'
                $used = 0
                if ($null -ne $s.n_prompt_tokens) { $used = [int]$s.n_prompt_tokens }
                Add-Sample 'llamacpp_slot_ctx_used_tokens' "llamacpp_slot_ctx_used_tokens{$sl} $used"
                Add-Sample 'llamacpp_slot_ctx_size_tokens' "llamacpp_slot_ctx_size_tokens{$sl} $([int]$s.n_ctx)"
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
                if ($t -match '^#\s+(HELP|TYPE)\s+([a-zA-Z_:][a-zA-Z0-9_:]*)') {
                    $f = $Matches[2]
                    Add-Fam $f
                    # one HELP and one TYPE per family, however many children report it
                    $kind = $Matches[1]
                    $dup = $false
                    foreach ($m in $meta[$f]) { if ($m -match "^#\s+$kind\s") { $dup = $true } }
                    if (-not $dup) { $null = $meta[$f].Add($t) }
                    continue
                }
                if ($t.StartsWith('#')) { continue }
                # inject model= into the label set (or create one) without disturbing the value
                if ($t -match '^([a-zA-Z_:][a-zA-Z0-9_:]*)\{([^}]*)\}(.*)$') {
                    Add-Sample $Matches[1] ($Matches[1] + '{' + $lbl + ',' + $Matches[2] + '}' + $Matches[3])
                } elseif ($t -match '^([a-zA-Z_:][a-zA-Z0-9_:]*)\s+(.*)$') {
                    Add-Sample $Matches[1] ($Matches[1] + '{' + $lbl + '} ' + $Matches[2])
                }
            }
        } catch {
            $null = $notes.Add("# NOTE model=$($k.id) /metrics unavailable ($($_.Exception.Message.Split([char]10)[0])) -- child needs ``metrics = 1`` in the preset")
        }
    }

    $sb = New-Object System.Text.StringBuilder
    foreach ($f in $order) {
        if ($data[$f].Count -eq 0) { continue }   # no HELP/TYPE for a family with no samples
        foreach ($m in $meta[$f]) { $null = $sb.AppendLine($m) }
        foreach ($d in $data[$f]) { $null = $sb.AppendLine($d) }
    }
    foreach ($n in $notes) { $null = $sb.AppendLine($n) }
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

# The prefix that actually bound (all-interfaces, or the loopback fallback) -- reused on rebind.
$prefix = $listener.Prefixes | Select-Object -First 1

# SELF-SUPERVISING. Nothing restarts this process: it is launched from the Startup folder, so if it
# dies, :9114 stays dark until the next logon. The per-request try below covers a bad client; this
# outer loop covers everything else (GetContext failing, the listener being torn down by a network
# change) by logging, waiting, and rebinding the same prefix. Only Ctrl-C ends it.
# Alert on the exporter itself with `up{job="llamacpp"} == 0` -- a dead exporter shows no restarts.
while ($true) {
    try {
        if (-not $listener.IsListening) {
            $listener = New-Object System.Net.HttpListener
            $listener.Prefixes.Add($prefix)
            $listener.Start()
            Write-Host ("{0:s} listener re-bound on {1}" -f (Get-Date), $prefix) -ForegroundColor Yellow
        }
        while ($listener.IsListening) {
            $ctx = $listener.GetContext()
                # EVERY request is isolated. A scraper that disconnects mid-response (timeout, Grafana tab
                # closed) makes OutputStream.Write throw "The specified network name is no longer
                # available". Uncaught, that unwound the loop and ENDED THE EXPORTER -- it ran from the
                # Startup folder with no supervisor, so :9114 stayed dark until the next logon (observed
                # 2026-10-02: dead from 07:50, found hours later by review). One bad client must cost one
                # response, never the process.
                try {
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
                } catch {
                    Write-Warning ("{0:s} request failed: {1}" -f (Get-Date), $_.Exception.Message.Split([char]10)[0])
                } finally {
                    try { $ctx.Response.OutputStream.Close() } catch { }
                }
        }
    } catch {
        Write-Warning ("{0:s} listener failed, rebinding in 5 s: {1}" -f (Get-Date), $_.Exception.Message.Split([char]10)[0])
        try { $listener.Close() } catch { }
        Start-Sleep -Seconds 5
    }
}
