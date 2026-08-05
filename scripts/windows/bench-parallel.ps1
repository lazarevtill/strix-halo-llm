<#
.SYNOPSIS
  Measure what `--parallel N` actually buys on this box: aggregate vs per-request throughput.

.DESCRIPTION
  WHY THIS IS NOT OBVIOUS. Token generation here is MEMORY-BANDWIDTH-bound, not compute-bound
  (docs/OPTIMIZATION.md). That cuts both ways for concurrency:

    - AGAINST: two requests share one memory bus, so each one gets slower.
    - FOR:     a decode step reads the weights ONCE and can produce a token for every active
               sequence in the same pass. Batching therefore amortises the expensive part, and
               AGGREGATE throughput can rise well above the single-request rate.

  Which effect dominates is an empirical question, so measure rather than argue.

  IMPORTANT, and easy to get wrong: `--ctx-size` is the TOTAL context and is SPLIT across slots.
  `--parallel 3 --ctx-size 262144` gives three ~87K slots, NOT three 262K slots. Size the total
  as (per-slot ctx x N).

  Reports:
    per-request t/s  - what one user feels
    aggregate t/s    - total tokens/sec the box delivers across all in-flight requests
    scaling          - aggregate at N divided by aggregate at 1

.EXAMPLE
  .\bench-parallel.ps1                        # sweep concurrency 1,2,3 against :8080
  .\bench-parallel.ps1 -Concurrency 1,2,4,8 -Tokens 300
#>
[CmdletBinding()]
param(
    [string] $Endpoint = 'http://127.0.0.1:8080',
    [int[]]  $Concurrency = @(1,2,3),
    [int]    $Tokens = 200,
    [int]    $Repeats = 2,
    [int]    $TimeoutSec = 600,
    # This box serves real users. The guard below refuses to run against a busy endpoint.
    [switch] $Force
)
$ErrorActionPreference = 'Continue'

# powershell.exe -File hands "-Concurrency 1,2,3" over as a SINGLE string, not a 3-element array,
# and [int[]] then coerces "1,2,3" into nonsense (observed: concurrency became 200). Split
# defensively so the script behaves the same however it is invoked.
$Concurrency = @($Concurrency | ForEach-Object { "$_" -split ',' } | ForEach-Object { $_.Trim() } |
                 Where-Object { $_ -match '^\d+$' } | ForEach-Object { [int]$_ })
if (-not $Concurrency) { $Concurrency = @(1,2,3) }

Add-Type -AssemblyName System.Net.Http

# Distinct prompts on purpose: identical prompts would share the prefix cache and the second
# request would answer almost instantly, flattering the concurrency numbers.
$prompts = @(
  'Explain in about 120 words why memory bandwidth limits token generation on a unified-memory APU.',
  'Write a Python function that merges overlapping integer intervals. Include a short docstring.',
  'List six practical differences between prompt processing and token generation. One line each.',
  'Describe in about 120 words what a KV cache is and why quantising it to 8 bits saves memory.',
  'Write a bash one-liner that finds the ten largest files under a directory, and explain it.',
  'Explain in about 120 words when speculative decoding helps and when it does not.',
  'Write a Python dataclass modelling a GPU memory budget, with a fits() method.',
  'Explain in about 120 words the difference between a mixture-of-experts and a dense model.'
)

function Invoke-Batch {
    param([int]$N, [int]$MaxTokens)
    $client = New-Object System.Net.Http.HttpClient
    $client.Timeout = [TimeSpan]::FromSeconds($TimeoutSec)
    try {
        $tasks = @()
        for ($i = 0; $i -lt $N; $i++) {
            $body = @{
                messages    = @(@{ role='user'; content = $prompts[$i % $prompts.Count] })
                max_tokens  = $MaxTokens
                temperature = 0.6
                top_p       = 0.95
                # cache_prompt off: a shared prefix would let later requests skip prefill and
                # inflate the apparent gain from concurrency.
                cache_prompt = $false
            } | ConvertTo-Json -Depth 6 -Compress
            $content = New-Object System.Net.Http.StringContent($body, [Text.Encoding]::UTF8, 'application/json')
            $tasks += $client.PostAsync("$Endpoint/v1/chat/completions", $content)
        }
        $sw = [Diagnostics.Stopwatch]::StartNew()
        [Threading.Tasks.Task]::WaitAll($tasks)
        $sw.Stop()

        $genTokens = 0; $perReq = @(); $failed = 0
        foreach ($t in $tasks) {
            try {
                $resp = $t.Result
                if (-not $resp.IsSuccessStatusCode) { $failed++; continue }
                $j = $resp.Content.ReadAsStringAsync().Result | ConvertFrom-Json
                $n = 0
                if ($j.usage -and $j.usage.completion_tokens) { $n = [int]$j.usage.completion_tokens }
                elseif ($j.timings -and $j.timings.predicted_n) { $n = [int]$j.timings.predicted_n }
                $genTokens += $n
                if ($j.timings -and $j.timings.predicted_per_second) { $perReq += [double]$j.timings.predicted_per_second }
            } catch { $failed++ }
        }
        return [pscustomobject]@{
            Conc       = $N
            WallSec    = [math]::Round($sw.Elapsed.TotalSeconds, 2)
            GenTokens  = $genTokens
            Aggregate  = if ($sw.Elapsed.TotalSeconds -gt 0) { [math]::Round($genTokens / $sw.Elapsed.TotalSeconds, 1) } else { 0 }
            PerReqAvg  = if ($perReq.Count) { [math]::Round(($perReq | Measure-Object -Average).Average, 1) } else { 0 }
            Failed     = $failed
        }
    } finally { $client.Dispose() }
}

# ---- preflight ---------------------------------------------------------------------------------
try { $props = Invoke-RestMethod "$Endpoint/props" -TimeoutSec 15 } catch { Write-Host "cannot reach $Endpoint" -ForegroundColor Red; exit 1 }
$slotsRaw = Invoke-RestMethod "$Endpoint/slots" -TimeoutSec 15
$slots = @($slotsRaw | ForEach-Object { $_ })   # /slots returns a JSON array; force real enumeration
$nCtx  = $props.default_generation_settings.n_ctx
Write-Host ("model   : {0}" -f (Split-Path $props.model_path -Leaf)) -ForegroundColor Cyan
Write-Host ("slots   : {0}   n_ctx per slot: {1}" -f $slots.Count, $nCtx) -ForegroundColor Cyan
Write-Host ("tokens  : {0} per request, {1} repeat(s), prompts are DISTINCT and cache_prompt=false" -f $Tokens, $Repeats) -ForegroundColor DarkGray
# ---- LIVE-TRAFFIC GUARD ------------------------------------------------------------------------
# This box serves REAL USERS. Benchmarking is destructive to them in two ways that are easy to
# forget: (1) the load itself steals memory bandwidth, and (2) a second llama-server started for
# "isolation" is WORSE, because both processes then compete -- measured 2026-08-05, a test server
# on :8081 cut the production endpoint from ~61 t/s to 24.7 t/s while it ran.
# Never benchmark a port with live sessions on it; wait for a quiet window or use -Force knowingly.
$busy   = @($slots | Where-Object { $_.is_processing }).Count
$warmed = @($slots | Where-Object { $_.n_prompt_tokens -and [int]$_.n_prompt_tokens -gt 500 }).Count
if ($busy -gt 0 -or $warmed -gt 0) {
    Write-Host ""
    Write-Host "REFUSING TO BENCHMARK: this endpoint looks IN USE." -ForegroundColor Red
    Write-Host ("  slots generating right now      : {0}" -f $busy) -ForegroundColor Red
    Write-Host ("  slots holding a real conversation: {0}  (>500 cached prompt tokens)" -f $warmed) -ForegroundColor Red
    Write-Host "  Benchmarking will slow those users down, and any restart wipes their cached context." -ForegroundColor Yellow
    Write-Host "  Wait for a quiet window, or pass -Force if you accept the impact." -ForegroundColor Yellow
    if (-not $Force) { exit 3 }
    Write-Host "  -Force given: proceeding anyway." -ForegroundColor Yellow
}

$over = @($Concurrency | Where-Object { $_ -gt $slots.Count })
if ($over) {
    Write-Host ("WARNING: concurrency {0} exceeds {1} slot(s) - the excess QUEUES rather than running in parallel," -f ($over -join ','), $slots.Count) -ForegroundColor Yellow
    Write-Host "         so those rows measure queueing, not concurrency. Restart with --parallel >= max concurrency." -ForegroundColor Yellow
}
Write-Host ""

# ---- sweep -------------------------------------------------------------------------------------
$results = @()
foreach ($n in $Concurrency) {
    $best = $null
    for ($r = 1; $r -le $Repeats; $r++) {
        $x = Invoke-Batch -N $n -MaxTokens $Tokens
        # keep the best run: background noise only ever makes a throughput number worse
        if (-not $best -or $x.Aggregate -gt $best.Aggregate) { $best = $x }
        Start-Sleep -Seconds 2
    }
    # Carry the concurrency from the LOOP variable, not from the returned object. An earlier
    # version read it back off the result and printed the token count instead -- the throughput
    # numbers were right but every row was labelled wrong, which made the scaling column read
    # 0.00x. Cheaper to hold the value locally than to trust a round-trip.
    $row = [pscustomobject]@{
        Conc      = [int]$n
        WallSec   = $best.WallSec
        GenTokens = $best.GenTokens
        Aggregate = $best.Aggregate
        PerReqAvg = $best.PerReqAvg
        Failed    = $best.Failed
    }
    $results += $row
    Write-Host ("conc={0}  wall {1,6:N2}s  gen {2,5} tok  aggregate {3,6:N1} t/s  per-request {4,5:N1} t/s{5}" -f `
        $row.Conc, $row.WallSec, $row.GenTokens, $row.Aggregate, $row.PerReqAvg,
        $(if ($row.Failed) { "  FAILED=$($row.Failed)" } else { '' })) -ForegroundColor Green
}

# ---- verdict -----------------------------------------------------------------------------------
$base = ($results | Where-Object { $_.Conc -eq 1 } | Select-Object -First 1)
Write-Host "`n================ SUMMARY ================" -ForegroundColor Cyan
Write-Host ("{0,3}  {1,12}  {2,14}  {3,10}  {4}" -f 'N','aggregate','per-request','scaling','note')
foreach ($r in $results) {
    $scale = if ($base -and $base.Aggregate -gt 0) { $r.Aggregate / $base.Aggregate } else { 0 }
    $note = ''
    if ($r.Conc -gt 1) {
        if     ($scale -ge ($r.Conc * 0.8)) { $note = 'near-linear: big win' }
        elseif ($scale -ge 1.3)          { $note = 'real aggregate gain' }
        elseif ($scale -ge 1.05)         { $note = 'marginal' }
        else                             { $note = 'NO GAIN - bandwidth saturated' }
    }
    Write-Host ("{0,3}  {1,9:N1} t/s  {2,11:N1} t/s  {3,9:N2}x  {4}" -f $r.Conc, $r.Aggregate, $r.PerReqAvg, $scale, $note)
}
Write-Host ("`nRead it this way: per-request t/s is what ONE user feels; aggregate is what the box delivers.") -ForegroundColor DarkGray
Write-Host ("Concurrency is worth it when aggregate rises faster than per-request falls.") -ForegroundColor DarkGray
