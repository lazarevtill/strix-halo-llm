<#
.SYNOPSIS
  Find the fastest serving config for Qwen3.8-27B on this box, empirically.

.DESCRIPTION
  Qwen3.8-27B is DENSE, so token generation is bandwidth-bound: every token reads all
  ~16.7 GiB of weights. The only ways to beat that ceiling are (a) speculative decoding,
  which emits >1 token per weight-read, and (b) batching, which amortises one weight-read
  across several sequences. This script measures both instead of guessing.

  MTP is BUILT INTO the GGUF -- there is no separate draft file, unlike laguna/glimmer.
  b10431 takes a COMMA-SEPARATED --spec-type, so speculators can be stacked (draft-mtp
  plus ngram-mod), which is worth a measurement rather than an assumption.

  PHASE A sweeps --spec-draft-n-max to find the acceptance/overhead sweet spot.
  PHASE B takes the winner and tries stacking, KV quantisation, concurrency and max context.

  SOLO OCCUPANCY IS ENFORCED. A second llama-server on this box does not just skew the
  result, it invalidates it -- both processes contend for the same memory bandwidth. This
  script REFUSES TO RUN if :8080 is listening. Stop the daily server AND disable its
  15-minute watchdog first, or the watchdog will silently restart Ornith mid-sweep and
  every number after that point will be wrong.

.EXAMPLE
  .\bench-qwen38.ps1                  # full sweep
  .\bench-qwen38.ps1 -QuickPass       # phase A only
#>
[CmdletBinding()]
param(
    [string] $Model   = 'D:\llamacpp-vulkan\models\Qwen3.8-27B-UD-Q4_K_XL.gguf',
    [int]    $Port    = 8099,
    [int]    $Reps    = 3,
    [int]    $MaxTok  = 400,
    [switch] $QuickPass,
    [switch] $Force
)
$ErrorActionPreference = 'Continue'

$Root   = 'D:\llamacpp-vulkan'
$Bin    = Join-Path $Root 'bin\llama-server.exe'
$OutDir = Join-Path $Root 'evals\results'
$LogDir = Join-Path $Root 'logs\bench-qwen38'
New-Item -ItemType Directory -Force $OutDir | Out-Null
New-Item -ItemType Directory -Force $LogDir | Out-Null
$Stamp  = Get-Date -Format 'yyyyMMdd-HHmmss'
$Jsonl  = Join-Path $OutDir "qwen38-speed-$Stamp.jsonl"

function Say([string]$m,[string]$c='Gray'){ Write-Host $m -ForegroundColor $c }

# A prompt that produces a long, code-shaped continuation: speculative acceptance is
# content-dependent, and code is the workload this box actually serves.
$PROMPT = 'Implement a red-black tree in Python with insert, delete, search and an in-order iterator. Include docstrings and type hints. Write the complete implementation.'

# ---------------------------------------------------------------- guards
if (-not (Test-Path $Model)) { Say "model not found: $Model" Red; exit 1 }
$expect = 17923394624
$actual = (Get-Item $Model).Length
if ($actual -ne $expect) { Say ("model INCOMPLETE: {0:N0} of {1:N0} bytes -- wait for the download" -f $actual,$expect) Red; exit 1 }

$live = Get-NetTCPConnection -LocalPort 8080 -State Listen -EA SilentlyContinue
if ($live -and -not $Force) {
    Say "" ; Say ":8080 IS LISTENING -- the daily Ornith server is still up." Red
    Say "Two servers share one memory bus; every number from this sweep would be wrong." Yellow
    Say "Stop it AND disable the watchdog (elevated), then re-run:" Yellow
    Say '  schtasks /change /tn llama-ornith-daily /disable' DarkGray
    Say '  Get-Process llama-server | Stop-Process -Force' DarkGray
    exit 3
}
if (Get-ScheduledTask -TaskName 'llama-ornith-daily' -EA SilentlyContinue | Where-Object { $_.State -ne 'Disabled' }) {
    if (-not $Force) {
        Say "watchdog task 'llama-ornith-daily' is still ENABLED -- it restarts Ornith every 15 min." Red
        Say "It would boot Ornith into the middle of this sweep. Disable it first (elevated):" Yellow
        Say '  schtasks /change /tn llama-ornith-daily /disable' DarkGray
        exit 3
    }
}

# ---------------------------------------------------------------- server control
function Start-Srv {
    param([hashtable]$c)
    Get-Process llama-server -EA SilentlyContinue | Stop-Process -Force -EA SilentlyContinue
    Start-Sleep -Milliseconds 800
    $errLog = Join-Path $LogDir "$($c.name).err"
    $outLog = Join-Path $LogDir "$($c.name).out"
    Remove-Item $errLog,$outLog -Force -EA SilentlyContinue

    $a = @(
        '--model', $Model, '--host','0.0.0.0','--port', $Port,
        '-ngl','99', '--load-mode','mlock',
        '-c', $c.ctx, '--parallel', $c.par,
        '-ctk', $c.ctk, '-ctv', $c.ctv,
        '-fa','on',
        '--no-mmproj',                      # text-only bench: skip the vision tower
        # SAMPLER PINNED TO GREEDY ON PURPOSE. Qwen's recommended thinking-mode sampler is
        # temp 1.0 / top-p 0.95, but this sweep compares CONFIGS, not quality: at temp 1.0 every
        # rep generates different text, and speculative acceptance is content-dependent, so
        # mtp-n3 vs mtp-n4 would differ because of what was generated rather than draft depth.
        # Greedy makes the workload identical across every row. Quality is a separate question.
        '--temp','0'
    )
    if ($c.spec) { $a += @('--spec-type', $c.spec, '--spec-draft-n-max', $c.nmax) }

    $p = Start-Process -FilePath $Bin -ArgumentList $a -PassThru -WindowStyle Hidden `
                       -RedirectStandardError $errLog -RedirectStandardOutput $outLog
    for ($i=0; $i -lt 200; $i++) {
        Start-Sleep -Seconds 2
        if ($p.HasExited) { Say "  server exited early (code $($p.ExitCode)) -- see $errLog" Red; return $null }
        try { if ((Invoke-RestMethod "http://127.0.0.1:$Port/health" -TimeoutSec 4).status -eq 'ok') { return $p } } catch {}
    }
    Say "  server never became healthy" Red
    try { $p | Stop-Process -Force } catch {}
    return $null
}
function Stop-Srv { Get-Process llama-server -EA SilentlyContinue | Stop-Process -Force -EA SilentlyContinue; Start-Sleep -Milliseconds 800 }

# Parse llama-server's OWN timing lines: more trustworthy than wall-clock, which includes
# HTTP and JSON overhead. Also yields draft acceptance, which explains WHY a config wins.
function Read-Timings {
    param([string]$errLog,[int]$skip=0)
    $lines = Get-Content $errLog -EA SilentlyContinue
    $tg = @(); $pp = @(); $acc = @()
    foreach ($l in $lines) {
        if ($l -match 'eval time =\s+[\d.]+ ms /\s+(\d+) tokens \(\s*[\d.]+ ms per token,\s+([\d.]+) tokens per second\)') {
            # CAPTURE BEFORE CLASSIFYING. A nested -match overwrites the automatic $Matches
            # variable, so `if ($l -match 'prompt eval time') { $Matches[2] }` reads group 2 of
            # the INNER pattern -- which has no groups -- yielding $null, and [double]$null = 0.
            # That silently recorded every prompt-eval sample as 0.0 instead of its real value.
            # Use .Contains() for the classification: it does not touch $Matches.
            $val = [double]$Matches[2]
            if ($l.Contains('prompt eval time')) { $pp += $val } else { $tg += $val }
        }
        if ($l -match 'draft acceptance = ([\d.]+) .*mean len =\s+([\d.]+)') { $acc += [pscustomobject]@{ rate=[double]$Matches[1]; len=[double]$Matches[2] } }
    }
    if ($tg.Count -gt $skip) { $tg = $tg[$skip..($tg.Count-1)] }
    if ($pp.Count -gt $skip) { $pp = $pp[$skip..($pp.Count-1)] }
    [pscustomobject]@{
        tg  = if ($tg.Count) { [math]::Round(($tg | Measure-Object -Average).Average,2) } else { 0 }
        pp  = if ($pp.Count) { [math]::Round(($pp | Measure-Object -Average).Average,2) } else { 0 }
        acc = if ($acc.Count) { [math]::Round(($acc | Measure-Object rate -Average).Average,3) } else { $null }
        len = if ($acc.Count) { [math]::Round(($acc | Measure-Object len  -Average).Average,2) } else { $null }
        n   = $tg.Count
    }
}

function Invoke-One {
    param([int]$maxTok)
    $body = @{ messages=@(@{role='user'; content=$PROMPT}); max_tokens=$maxTok; stream=$false } | ConvertTo-Json -Depth 5 -Compress
    try { return Invoke-RestMethod "http://127.0.0.1:$Port/v1/chat/completions" -Method Post -Body $body -ContentType 'application/json' -TimeoutSec 900 }
    catch { return $null }
}

function Measure-Cfg {
    param([hashtable]$c)
    Say ("`n--- {0}" -f $c.name) Cyan
    Say ("    ctx={0} par={1} kv={2} spec={3} nmax={4}" -f $c.ctx,$c.par,$c.ctk,($(if($c.spec){$c.spec}else{'none'})),$c.nmax) DarkGray
    $t0 = [Diagnostics.Stopwatch]::StartNew()
    $p = Start-Srv $c
    $t0.Stop()
    if (-not $p) { return [pscustomobject]@{ name=$c.name; ok=$false } }
    Say ("    loaded in {0:N0}s" -f $t0.Elapsed.TotalSeconds) DarkGray

    $errLog = Join-Path $LogDir "$($c.name).err"
    $agg = $null
    if ($c.par -gt 1) {
        # concurrency: fire par requests at once, aggregate = total completion tokens / wall
        Invoke-One 64 | Out-Null                                     # warm
        $jobs = 1..$c.par | ForEach-Object {
            Start-Job -ArgumentList $Port,$PROMPT,$MaxTok -ScriptBlock {
                param($pt,$pr,$mt)
                $b = @{ messages=@(@{role='user'; content=$pr}); max_tokens=$mt; stream=$false } | ConvertTo-Json -Depth 5 -Compress
                try { (Invoke-RestMethod "http://127.0.0.1:$pt/v1/chat/completions" -Method Post -Body $b -ContentType 'application/json' -TimeoutSec 900).usage.completion_tokens } catch { 0 }
            }
        }
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $toks = ($jobs | Wait-Job -Timeout 900 | Receive-Job)
        $sw.Stop()
        $jobs | Remove-Job -Force -EA SilentlyContinue
        $sum = ($toks | Measure-Object -Sum).Sum
        $agg = [math]::Round($sum / $sw.Elapsed.TotalSeconds, 2)
        Say ("    aggregate {0} tok / {1:N1}s = {2} t/s across {3} slots" -f $sum,$sw.Elapsed.TotalSeconds,$agg,$c.par) Green
        $r = Read-Timings $errLog 1
    } else {
        Invoke-One 64 | Out-Null                                     # warm (excluded via skip=1)
        for ($i=0; $i -lt $Reps; $i++) {
            $resp = Invoke-One $MaxTok
            # Keep the FIRST completion of every config on disk. A mis-mapped arch can load
            # cleanly and emit fluent nonsense at a perfectly respectable t/s -- speed alone
            # cannot detect that, so the text has to be inspectable after the fact.
            if ($i -eq 0 -and $resp) {
                # MUST capture reasoning_content too. This model thinks by default at
                # reasoning_effort=xhigh, so at a few hundred max_tokens it never leaves the
                # think block and message.content is EMPTY -- the first version of this dump
                # wrote 0-byte files for all 9 configs and would have "verified" nothing.
                $m = $resp.choices[0].message
                $txt = "=== content ===`r`n"   + ([string]$m.content) +
                       "`r`n`r`n=== reasoning ===`r`n" + ([string]$m.reasoning_content)
                [IO.File]::WriteAllText((Join-Path $LogDir "$($c.name).raw.txt"), $txt, (New-Object Text.UTF8Encoding($false)))
            }
        }
        $r = Read-Timings $errLog 1
    }
    Stop-Srv
    if ($r.n -ne $Reps -and $c.par -eq 1) {
        Say ("    WARNING: parsed {0} timing samples, expected {1} -- treat this row with suspicion" -f $r.n,$Reps) Yellow
    }

    $row = [pscustomobject]@{
        name=$c.name; ok=$true; ctx=$c.ctx; par=$c.par; kv=$c.ctk
        spec=$(if($c.spec){$c.spec}else{'none'}); nmax=$c.nmax
        tg=$r.tg; pp=$r.pp; aggregate=$agg; accept=$r.acc; meanlen=$r.len; samples=$r.n
        load_s=[math]::Round($t0.Elapsed.TotalSeconds,1)
    }
    Say ("    tg={0} t/s  pp={1} t/s  accept={2} meanlen={3}" -f $r.tg,$r.pp,$r.acc,$r.len) Green
    $row | ConvertTo-Json -Compress -Depth 4 | Add-Content -LiteralPath $Jsonl -Encoding ASCII
    return $row
}

# ---------------------------------------------------------------- PHASE A
Say "`n=== PHASE A: does MTP beat the bandwidth ceiling, and at what depth? ===" Cyan
$CTX_A = 32768
$phaseA = @(
    @{ name='base-nospec'; spec=$null;      nmax=0; ctx=$CTX_A; par=1; ctk='f16'; ctv='f16' }
    @{ name='mtp-n1';      spec='draft-mtp'; nmax=1; ctx=$CTX_A; par=1; ctk='f16'; ctv='f16' }
    @{ name='mtp-n2';      spec='draft-mtp'; nmax=2; ctx=$CTX_A; par=1; ctk='f16'; ctv='f16' }
    @{ name='mtp-n3';      spec='draft-mtp'; nmax=3; ctx=$CTX_A; par=1; ctk='f16'; ctv='f16' }
    @{ name='mtp-n4';      spec='draft-mtp'; nmax=4; ctx=$CTX_A; par=1; ctk='f16'; ctv='f16' }
    @{ name='mtp-n5';      spec='draft-mtp'; nmax=5; ctx=$CTX_A; par=1; ctk='f16'; ctv='f16' }
)
$rows = @()
foreach ($c in $phaseA) { $rows += Measure-Cfg $c }

$best = $rows | Where-Object { $_.ok -and $_.spec -ne 'none' } | Sort-Object tg -Descending | Select-Object -First 1
if (-not $best) { Say "`nno MTP config succeeded -- stopping" Red; $rows | Format-Table -AutoSize; exit 1 }
$bestN = $best.nmax
Say ("`n>>> best MTP depth: n-max={0} at {1} t/s" -f $bestN,$best.tg) Green

if ($QuickPass) { $rows | Format-Table -AutoSize; Say "`nJSONL: $Jsonl" DarkGray; return }

# ---------------------------------------------------------------- PHASE B
Say "`n=== PHASE B: stacking, KV quant, concurrency, max context ===" Cyan
$phaseB = @(
    @{ name='mtp+ngram';   spec='draft-mtp,ngram-mod'; nmax=$bestN; ctx=$CTX_A;  par=1; ctk='f16';  ctv='f16'  }
    @{ name='mtp-q8kv';    spec='draft-mtp';           nmax=$bestN; ctx=$CTX_A;  par=1; ctk='q8_0'; ctv='q8_0' }
    @{ name='mtp-par3';    spec='draft-mtp';           nmax=$bestN; ctx=98304;   par=3; ctk='f16';  ctv='f16'  }
    @{ name='mtp-ctx262k'; spec='draft-mtp';           nmax=$bestN; ctx=262144;  par=1; ctk='f16';  ctv='f16'  }
)
foreach ($c in $phaseB) { $rows += Measure-Cfg $c }

Say "`n=== RESULTS ===" Cyan
$rows | Where-Object ok | Format-Table name,tg,pp,aggregate,accept,meanlen,ctx,par,kv,spec,nmax,load_s -AutoSize
Say "JSONL: $Jsonl" DarkGray
Say "`nReminder: re-enable the daily server when done:" Yellow
Say '  schtasks /change /tn llama-ornith-daily /enable ; schtasks /run /tn llama-ornith-daily' DarkGray
