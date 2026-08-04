<#
.SYNOPSIS
  Native tool-calling eval for local GGUFs. Measures whether a model picks the right tool, fills the
  right arguments, chains multiple calls, and — critically — knows when NOT to call a tool.

.DESCRIPTION
  WHY THIS EXISTS, given ornith-router already benchmarks tool calls:
  ornith-router constrains output with a GBNF grammar, so it measures FORMAT compliance on a fixed
  16-section catalog. Real coding agents don't do that — they pass an OpenAI `tools` array and read
  back `message.tool_calls`. That is a different code path (jinja tool template + the model's own
  tool-call tokens) and it fails differently: wrong tool, hallucinated tool, missing required arg,
  wrong enum value, or a tool call fired when plain prose was wanted.

  It is also PRIVATE. The sweep found that public agentic benchmarks are contaminated — decontaminated
  SWE-rebench scores A3B-class models ~4x below their self-reported SWE-bench numbers. These cases are
  written for this fleet and exist nowhere else, so no model has trained on them.

  SCORED CATEGORIES
    select   right tool chosen for an unambiguous request
    args     required + optional arguments extracted correctly (dates, ints, floats, booleans)
    enum     enum-valued params match the schema exactly
    multi    several independent calls in one turn
    chain    ordered, dependent calls
    abstain  NO tool call should be emitted (chat, out-of-scope, physically impossible)
    hard     relative dates, implied fields, under-specified requests

  ABSTAIN IS THE ONE MOST MODELS FAIL. A model that calls a tool for "thanks, that's all" will
  thrash in an agent loop. It is weighted equally here on purpose.

.EXAMPLE
  .\run-tools-eval.ps1 -Model D:\llamacpp-vulkan\models\ornith-1.0-35b-bf16.gguf -Label ornith-bf16
  .\run-tools-eval.ps1 -Endpoint http://127.0.0.1:8080/v1 -Label already-running
  .\run-tools-eval.ps1 -All          # sweep every model in the registry, one at a time
#>
[CmdletBinding()]
param(
    [string] $Model,
    [string] $Endpoint,
    [string] $Label = 'model',
    [switch] $All,
    [int]    $Port = 8094,
    [int]    $Ctx = 16384,
    [double] $Temp = 0.0,
    [string] $Bin = 'D:\llamacpp-vulkan\bin\llama-server.exe',
    [string] $Csv = 'D:\llamacpp-vulkan\evals\results-tools.csv',
    # Agent-loop depth. 4 is enough for every case here (longest chain is 2 calls + a summary turn)
    # while still bounding a model that loops on itself.
    [int]    $MaxTurns = 4,
    # 512 was far too tight: a thinking model spends its budget reasoning and emits no tool call,
    # which scored a FALSE PASS on abstain cases. Reasoning is billed against the same cap.
    [int]    $MaxTokens = 4096,
    # 300s was too tight: chain-01 died at 301.9s on Laguna with thinking enabled, and a timeout
    # scores identically to a wrong answer. Reasoning models need real headroom per turn.
    [int]    $TimeoutSec = 600,
    [switch] $Verbose_
)
$ErrorActionPreference = 'Continue'
$root = $PSScriptRoot
$gpu  = 'luid_0x00000000_0x01c3ed4a_phys_0'

$REG = [ordered]@{
    'ornith-q5'         = 'C:\llm-router\models\ornith-1.0-35b-Q5_K_M.gguf'
    'ornith-bf16'       = 'D:\llamacpp-vulkan\models\ornith-1.0-35b-bf16.gguf'
    'laguna'            = 'D:\llamacpp-vulkan\models\laguna-s-2.1-Q4_K_M.gguf'
    'qwen122b'          = 'D:\llamacpp-vulkan\models\Qwen3.5-122B-A10B-UD-Q4_K_XL-00001-of-00003.gguf'
    'deepseek-v4-flash' = 'D:\llamacpp-vulkan\models\DeepSeek-V4-Flash-UD-IQ2_M-00001-of-00003.gguf'
}

# Keep the tools as RAW JSON TEXT and splice it into the body. Do NOT round-trip through
# ConvertFrom-Json/ConvertTo-Json: PS 5.1 re-serialises the resulting collection as
# {"value":[...],"Count":n}, and llama-server rejects it with
#   500 Failed to parse tools: Expected 'tools' to be an array, got {"value":[...]}
# That silently turned an entire eval run into 0/24 on every tool case (2026-08-03).
$toolsJson = (Get-Content "$root\tools\tools.json" -Raw -Encoding UTF8).Trim()
$tools = $toolsJson | ConvertFrom-Json      # parsed copy, used only for the count in the banner
$cases = @(Get-Content "$root\tools\cases.jsonl" -Encoding UTF8 | Where-Object { $_.Trim() } | ForEach-Object { $_ | ConvertFrom-Json })
Write-Host ("loaded {0} tools, {1} cases" -f $tools.Count, $cases.Count) -ForegroundColor DarkGray

# --- live-GPU guard (exited processes keep stale counter instances; see bench-big.ps1) -------------
function Get-LiveGpuGB {
    $sum = 0.0
    try {
        foreach ($s in (Get-Counter '\GPU Process Memory(*)\Dedicated Usage' -EA Stop).CounterSamples) {
            if ($s.CookedValue -le 0) { continue }
            $q = ([regex]::Match($s.InstanceName,'pid_(\d+)')).Groups[1].Value
            if (-not $q) { continue }
            $pr = Get-Process -Id $q -EA SilentlyContinue
            if ($pr -and -not $pr.HasExited) { $sum += $s.CookedValue }
        }
    } catch { return -1 }
    return [math]::Round($sum/1GB,2)
}

# --- contamination guard -------------------------------------------------------------------------
# Read 'Total Committed', NOT 'Dedicated Usage'. WDDM trims an idle model's DEDICATED bytes to ~0
# while it still holds its committed reservation, so the dedicated counter can under-report a
# resident model by tens of GiB. On 2026-08-03 a stale elevated llama-server on :8088 committed
# 17.95 GiB, pushed the box to 114.28 GiB against its ~109 GiB ceiling, and every request from that
# moment on returned HTTP 500. In the output that is indistinguishable from a model that cannot
# call tools -- so the run gets labelled ENVIRONMENT instead of silently scoring as quality.
function Get-ForeignCommittedGiB([int]$selfPid) {
    $t = 0.0
    try {
        foreach ($s in (Get-Counter '\GPU Process Memory(*)\Total Committed' -EA Stop).CounterSamples) {
            $q = ([regex]::Match($s.InstanceName,'pid_(\d+)')).Groups[1].Value
            if (-not $q -or [int]$q -eq $selfPid) { continue }
            if ($s.CookedValue -gt 1GB) { $t += $s.CookedValue / 1GB }
        }
    } catch { return -1 }
    return [math]::Round($t,2)
}

function Get-PortPid([string]$ep) {
    $m = [regex]::Match($ep,':(\d+)')
    if (-not $m.Success) { return 0 }
    $c = Get-NetTCPConnection -LocalPort ([int]$m.Groups[1].Value) -State Listen -EA SilentlyContinue | Select-Object -First 1
    if ($c) { return [int]$c.OwningProcess }
    return 0
}

# Synthetic tool results for the multi-turn loop. Deliberately NEUTRAL: they confirm the call
# succeeded and return plausible shape, but never hint at what the next call should be -- otherwise
# the eval would be feeding the model its own answer.
function Get-ToolResult([string]$name) {
    switch ($name) {
        'list_hosts'       { '{"hosts":["box-1","box-2","box-3","box-4","laptop"]}' }
        'list_models'      { '{"models":[{"file":"laguna-s-2.1-Q4_K_M.gguf","gib":89.4},{"file":"ornith-1.0-35b-Q5_K_M.gguf","gib":24.1}]}' }
        'get_host_metrics' { '{"cpu_pct":31,"mem_pct":54,"gpu_pct":12}' }
        'search_logs'      { '{"matches":[]}' }
        default            { '{"status":"ok"}' }
    }
}

# Wilson score interval. Preferred over normal-approximation here because n is small (29) and the
# proportion is near 1.0, where the naive interval runs past 100% and understates uncertainty.
function Get-WilsonCI([int]$k, [int]$n, [double]$z = 1.96) {
    if ($n -le 0) { return @{ lo = 0.0; hi = 0.0 } }
    $p = $k / $n
    $d = 1 + ($z*$z)/$n
    $c = $p + ($z*$z)/(2*$n)
    $s = $z * [math]::Sqrt( ($p*(1-$p) + ($z*$z)/(4*$n)) / $n )
    # 0.0/1.0, NOT 0/1. With integer literals PowerShell binds [math]::Min(int,int), which ROUNDS
    # the double argument -- every interval collapsed to [100.0%, 100.0%] and the CI silently
    # reported certainty. Caught by sanity-checking 27/29 against its known value of [78.0, 98.1].
    return @{ lo = [math]::Max(0.0,($c - $s)/$d) * 100.0; hi = [math]::Min(1.0,($c + $s)/$d) * 100.0 }
}

# Record what the server under test is actually running. Model, quant, ctx, reasoning and spec-type
# all change the numbers; none of them were recorded before, so results from different entry points
# (this script standalone uses different defaults than run-model-suite.ps1) were indistinguishable.
function Get-ServerArgs([string]$ep) {
    try {
        $p = Invoke-RestMethod "$($ep -replace '/v1$','')/props" -TimeoutSec 10
        return ("model={0}; ctx={1}" -f (Split-Path ([string]$p.model_path) -Leaf), $p.default_generation_settings.n_ctx)
    } catch { return 'unavailable' }
}

# Arguments with no enum and no canonical phrasing. Scored by containment, not equality -- see the
# note in Score-Case. Anything with an enum, a number, or a hostname stays exact.
$FREETEXT_ARGS = @('reason','query','label','note','message')

function Norm([object]$v) {
    if ($null -eq $v) { return '' }
    if ($v -is [bool]) { return $v.ToString().ToLower() }
    $s = "$v".Trim().ToLower()
    # numeric normalisation so 8080 == "8080" and 40 == 40.0
    $d = 0.0
    if ([double]::TryParse($s, [ref]$d)) { if ($d -eq [math]::Floor($d)) { return [string][int]$d } else { return [string]$d } }
    return ($s -replace '\s+',' ')
}

# Score one case. Returns a hashtable of per-case outcome.
function Score-Case($case, $calls) {
    $exp = @($case.expect)
    $got = @($calls)

    if ($exp.Count -eq 0) {
        # abstain: success is emitting NO tool call at all
        return @{ ok = ($got.Count -eq 0); detail = if ($got.Count -eq 0) { 'correctly abstained' } else { "called $($got.Count): " + (($got | ForEach-Object { $_.name }) -join ',') } }
    }
    if ($got.Count -eq 0) { return @{ ok = $false; detail = 'no tool call emitted (expected ' + $exp.Count + ')' } }

    # names: every expected call must appear, with multiplicity; for 'chain' they must appear IN
    # ORDER (as a subsequence). EXTRA calls are tolerated -- the runner is multi-turn now, and a
    # good agent legitimately explores first (hard-02 must list_models before it can deploy the
    # "biggest" one). Demanding an exact count punished exactly the behaviour we want to reward.
    # Extras are still surfaced in the detail string so over-calling stays visible.
    $expNames = @($exp | ForEach-Object { $_.name })
    $gotNames = @($got | ForEach-Object { $_.name })
    $namesOk = if ($case.cat -eq 'chain') {
        $k = 0
        foreach ($n in $gotNames) { if ($k -lt $expNames.Count -and $n -eq $expNames[$k]) { $k++ } }
        $k -eq $expNames.Count
    } else {
        $pool = [System.Collections.ArrayList]@($gotNames)
        $ok = $true
        foreach ($n in $expNames) { $ix = $pool.IndexOf($n); if ($ix -lt 0) { $ok = $false; break }; $pool.RemoveAt($ix) }
        $ok
    }
    if (-not $namesOk) { return @{ ok = $false; detail = "tools: expected [$($expNames -join ',')] got [$($gotNames -join ',')]" } }

    # arguments: every EXPECTED key must be present and equal. Extra keys are tolerated.
    #
    # PAIRING MUST CONSUME. The old code picked @($got | Where-Object { $_.name -eq $e.name })[0]
    # for EVERY expectation, so when a case expects the same tool twice with different arguments
    # -- multi-01 wants get_host_metrics on box-1 AND box-2 -- both expectations compared against
    # the first returned call and the second could never match. It reported
    #   "get_host_metrics.hostname expected 'box-2' got 'box-1'"
    # no matter what the model actually emitted. That manufactured 2 of Laguna's 9 failures
    # (multi-01, multi-03) on 2026-08-03; the model had in fact returned both hosts correctly.
    # Now each expectation claims the best-matching UNCONSUMED call of that name.
    $bad  = @()
    $used = @{}
    for ($i = 0; $i -lt $exp.Count; $i++) {
        $e    = $exp[$i]
        $keys = @($e.args.PSObject.Properties.Name)
        $bestIdx = -1; $bestScore = -1
        for ($j = 0; $j -lt $got.Count; $j++) {
            if ($used.ContainsKey($j))      { continue }
            if ($got[$j].name -ne $e.name)  { continue }
            $sc = 0
            foreach ($k in $keys) { if ((Norm $e.args.$k) -eq (Norm $got[$j].args.$k)) { $sc++ } }
            if ($sc -gt $bestScore) { $bestScore = $sc; $bestIdx = $j }
        }
        if ($bestIdx -lt 0) { $bad += "$($e.name): missing"; continue }
        $used[$bestIdx] = $true
        $g = $got[$bestIdx]
        foreach ($k in $keys) {
            $want = Norm $e.args.$k
            $have = Norm ($g.args.$k)
            if ($want -eq $have) { continue }
            # FREE-TEXT FIELDS ARE NOT EXACT-MATCH. `reason`, `query` and `label` have no enum and no
            # canonical phrasing, so exact equality marks a perfect answer wrong: 'gpu is throttling'
            # failed against 'gpu throttling' and that single case decided the ranking between two
            # models on 2026-08-03. Accept either direction of containment for these, which still
            # catches a genuinely wrong topic while ignoring phrasing.
            if ($FREETEXT_ARGS -contains $k -and $have -and ($have -like "*$want*" -or $want -like "*$have*")) { continue }
            $bad += "$($e.name).$k expected '$want' got '$have'"
        }
    }
    return @{ ok = ($bad.Count -eq 0); detail = ($bad -join ' | ') }
}

function Invoke-Eval([string]$lbl, [string]$ep) {
    $rows = @(); $lat = @(); $tps = @()
    $selfPid   = Get-PortPid $ep
    $baseForeign = Get-ForeignCommittedGiB $selfPid
    Write-Host ("  server pid {0}; foreign GPU commit at start: {1} GiB" -f $selfPid, $baseForeign) -ForegroundColor DarkGray

    foreach ($c in $cases) {
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $calls = @(); $err = ''; $turnsUsed = 0; $firstTurnCalls = 0; $truncated = $false; $badArgs = $false

        # MULTI-TURN. The old runner sent one message and demanded every expected call come back in
        # that single response. For a chain case -- "deploy X to box-1, THEN benchmark it" -- a
        # correct agent deploys, reads the result, and only then benchmarks; it cannot know the
        # deploy succeeded otherwise. Scoring that single-turn marked correct sequential behaviour
        # as failure (chain-02, multi-02 on 2026-08-03). We now run the real agent loop and feed
        # synthetic tool results back, accumulating calls across turns.
        $msgs = @(
            @{ role='system'; content='You are a fleet operations assistant. Use the provided tools when the user asks you to inspect or change the fleet. If no tool applies, just answer in plain text. Never invent tools.' },
            @{ role='user';   content=$c.prompt }
        )

        for ($turn = 1; $turn -le $MaxTurns; $turn++) {
            $envelope = @{
                messages    = $msgs
                tool_choice = 'auto'
                temperature = $Temp
                max_tokens  = $MaxTokens
            } | ConvertTo-Json -Depth 30 -Compress
            # splice: {...}  ->  {"tools":[...],...}
            $body  = '{"tools":' + $toolsJson + ',' + $envelope.Substring(1)
            $bytes = [Text.Encoding]::UTF8.GetBytes($body)   # PS5.1 posts Latin1 otherwise -> corrupts UTF-8
            try {
                $r = Invoke-RestMethod "$ep/chat/completions" -Method Post -Body $bytes -ContentType 'application/json; charset=utf-8' -TimeoutSec $TimeoutSec -EA Stop
            } catch { $err = $_.Exception.Message; break }
            $turnsUsed = $turn
            $msg = $r.choices[0].message
            if ($r.timings.predicted_per_second) { $tps += [double]$r.timings.predicted_per_second }

            # TRUNCATION IS NEVER A PASS. A reasoning model cut off at max_tokens emits no
            # tool_calls -- which on an abstain case (where success IS emitting nothing) scores a
            # false PASS, resurrecting the exact bug that made a fully broken run read 5/29 = 17.2%.
            # On any other case it reads as "no tool call emitted", a false FAIL. 512 was far too
            # tight for a thinking model, hence $MaxTokens; but detect it regardless of the cap.
            if ($r.choices[0].finish_reason -eq 'length') { $truncated = $true; break }

            if (-not $msg.tool_calls) { break }
            if ($turn -eq 1) { $firstTurnCalls = @($msg.tool_calls).Count }

            # Echo the assistant turn back verbatim, INCLUDING reasoning_content. --reasoning-preserve
            # only does anything across turns, so without this the flag is never actually exercised.
            $asstCalls = @()
            foreach ($tc in $msg.tool_calls) {
                $a = @{}
                # Malformed argument JSON is a MODEL defect. Routing it through $err sent it to the
                # ENVIRONMENT/REQUEST-FAILED branch, where it could be blamed on the box if foreign
                # GPU commit happened to rise at the same moment. Score it as a normal failure.
                try { $a = $tc.function.arguments | ConvertFrom-Json } catch { $badArgs = $true }
                $calls += [pscustomobject]@{ name = $tc.function.name; args = $a }
                $asstCalls += @{ id = $tc.id; type = 'function'; function = @{ name = $tc.function.name; arguments = [string]$tc.function.arguments } }
            }
            $asst = @{ role='assistant'; content = [string]$msg.content; tool_calls = $asstCalls }
            if ($msg.reasoning_content) { $asst['reasoning_content'] = [string]$msg.reasoning_content }
            $msgs += $asst
            foreach ($tc in $msg.tool_calls) {
                $msgs += @{ role='tool'; tool_call_id = $tc.id; name = $tc.function.name; content = (Get-ToolResult $tc.function.name) }
            }
        }
        $sw.Stop(); $lat += $sw.Elapsed.TotalMilliseconds

        $s = Score-Case $c $calls
        # A FAILED REQUEST IS NEVER A PASS. Without this, an abstain case (which expects zero tool
        # calls) scores PASS when the server 500s -- so a totally broken run reported 5/29 instead
        # of 0/29 and looked like a real quality signal. Caught 2026-08-03.
        if ($err) {
            # Distinguish "the model got it wrong" from "the box fell over mid-run". Two ways that
            # happens here, both seen on 2026-08-03: a foreign llama-server appears and pushes past
            # the ~109 GiB ceiling (every later request 500s), or something restarts the old bench
            # stack, which kills the server under test outright (every later request refuses the
            # connection). Either way the run is worthless, and without this label a 0/29 caused by
            # a dead process reads exactly like a model that cannot call tools.
            $nowForeign = Get-ForeignCommittedGiB $selfPid
            $alive      = if ($selfPid) { [bool](Get-Process -Id $selfPid -EA SilentlyContinue) } else { $true }
            $tag =
                if (-not $alive)                          { "ENVIRONMENT (server pid $selfPid DIED mid-run)" }
                elseif ($nowForeign -gt ($baseForeign+1)) { "ENVIRONMENT (foreign GPU commit $baseForeign -> $nowForeign GiB)" }
                else                                      { 'REQUEST FAILED' }
            $s = @{ ok = $false; detail = "${tag}: $err" }
        }
        elseif ($truncated) {
            # Scored AFTER $err so a real transport failure keeps its own label.
            $s = @{ ok = $false; detail = "TRUNCATED @max_tokens=$MaxTokens (raise it; not a model verdict)" }
        }
        elseif ($badArgs) {
            $s = @{ ok = $false; detail = "MODEL: unparsable tool-call arguments JSON" }
        }
        $rows += [pscustomobject]@{ id=$c.id; cat=$c.cat; ok=$s.ok; detail=$s.detail; ms=[math]::Round($sw.Elapsed.TotalMilliseconds); turns=$turnsUsed; batch1=$firstTurnCalls; truncated=$truncated }
        $mark = if ($s.ok) { 'PASS' } else { 'FAIL' }
        $col  = if ($s.ok) { 'DarkGreen' } else { 'Red' }
        Write-Host ("  [{0}] {1,-10} {2}" -f $mark, $c.id, $(if($s.ok){''}else{$s.detail})) -ForegroundColor $col
    }

    $tot = $rows.Count; $pass = @($rows | Where-Object { $_.ok }).Count
    Write-Host ("`n  {0}: {1}/{2} = {3:N1}%" -f $lbl, $pass, $tot, (100*$pass/$tot)) -ForegroundColor Cyan
    $byCat = @{}
    foreach ($cat in ($rows | Select-Object -Expand cat -Unique)) {
        $cr = @($rows | Where-Object { $_.cat -eq $cat })
        $cp = @($cr | Where-Object { $_.ok }).Count
        $byCat[$cat] = "$cp/$($cr.Count)"
        Write-Host ("    {0,-8} {1}/{2}" -f $cat, $cp, $cr.Count) -ForegroundColor DarkGray
    }
    $medMs = if ($lat.Count) { [math]::Round((($lat | Sort-Object)[[int]($lat.Count/2)])) } else { 0 }
    $avgTps= if ($tps.Count) { [math]::Round((($tps | Measure-Object -Average).Average),1) } else { 0 }

    # Report PARALLEL BATCHING separately from correctness. Whether a model emits several tool calls
    # in ONE response, versus one per turn, is a real property that harnesses depend on -- but it is
    # not a wrong answer, so it must not be folded into the pass rate. Of the cases that genuinely
    # want >1 call, how many did the model batch into its first turn?
    $multiCases = @($rows | Where-Object { $_.cat -eq 'multi' -or $_.cat -eq 'chain' })
    $batched    = @($multiCases | Where-Object { $_.batch1 -ge 2 }).Count
    $envFails   = @($rows | Where-Object { $_.detail -like 'ENVIRONMENT*' }).Count
    Write-Host ("    parallel-batching: {0}/{1} multi+chain cases emitted >=2 calls in one turn" -f $batched, $multiCases.Count) -ForegroundColor DarkGray
    Write-Host ("    median turns used: {0}" -f (@($rows | Select-Object -Expand turns | Sort-Object)[[int]($rows.Count/2)])) -ForegroundColor DarkGray
    if ($envFails) { Write-Host ("    !! {0} case(s) failed for ENVIRONMENT reasons -- not a quality signal" -f $envFails) -ForegroundColor Yellow }

    # WILSON 95% CI, not a bare percentage. 27/29 and 26/29 look like a ranking and are not: their
    # intervals overlap almost completely (McNemar exact p = 1.0 on the paired cases). Printing the
    # interval next to the point estimate makes a meaningless ordering physically hard to read off.
    $ci = Get-WilsonCI $pass $tot
    Write-Host ("    95% CI: [{0:N1}%, {1:N1}%]  (n={2} -- overlapping intervals are NOT a ranking)" -f $ci.lo, $ci.hi, $tot) -ForegroundColor DarkGray

    $stamp = (Get-Date).ToString('o')
    $rows | Export-Csv "$root\percase-tools-$lbl-$($stamp -replace '[:.]','-').csv" -NoTypeInformation
    $rec = [ordered]@{
        ts=$stamp; label=$lbl; pass=$pass; total=$tot; pct=[math]::Round(100*$pass/$tot,1)
        ciLo=[math]::Round($ci.lo,1); ciHi=[math]::Round($ci.hi,1)
        select=$byCat['select']; args=$byCat['args']; enum=$byCat['enum']; multi=$byCat['multi']
        chain=$byCat['chain']; abstain=$byCat['abstain']; hard=$byCat['hard']
        medMs=$medMs; genTps=$avgTps; batch1="$batched/$($multiCases.Count)"; envFails=$envFails
        truncated=@($rows | Where-Object { $_.truncated }).Count
        # PROVENANCE. Without this, three harness vintages landed in one file and the numbers were
        # indistinguishable after the fact. Every row must say what produced it.
        harnessMTime=(Get-Item $PSCommandPath).LastWriteTime.ToString('o')
        casesMTime=(Get-Item "$root\tools\cases.jsonl").LastWriteTime.ToString('o')
        endpoint=$ep; maxTokens=$MaxTokens; maxTurns=$MaxTurns; temp=$Temp
        serverArgs=(Get-ServerArgs $ep)
        failedIds=(@($rows | Where-Object { -not $_.ok } | Select-Object -Expand id) -join ',')
    }
    # JSONL, not Export-Csv -Append: appending a row whose schema gained a column throws in PS 5.1,
    # and with ErrorActionPreference=Continue the run finishes while the summary is silently lost.
    # AppendAllText with an explicit BOM-less encoder. PS 5.1's `Add-Content -Encoding UTF8` writes
    # a BOM on first create, and json.load then dies with "Unexpected UTF-8 BOM" -- the results file
    # becomes unreadable by the very tooling meant to analyse it.
    [IO.File]::AppendAllText("$root\results-tools.jsonl",
        ($rec | ConvertTo-Json -Depth 6 -Compress) + "`n",
        (New-Object Text.UTF8Encoding($false)))
    [pscustomobject]$rec
}

$summary = @()

if ($Endpoint) {
    Write-Host "`n=== $Label (existing endpoint $Endpoint) ===" -ForegroundColor Cyan
    $summary += Invoke-Eval $Label $Endpoint
} else {
    $targets = if ($All) { $REG.GetEnumerator() | ForEach-Object { @{ l=$_.Key; m=$_.Value } } }
               elseif ($Model) { @(@{ l=$Label; m=$Model }) }
               else { Write-Error "Specify -Model, -Endpoint, or -All"; exit 1 }

    foreach ($t in $targets) {
        if (-not (Test-Path $t.m)) { Write-Host "SKIP $($t.l): missing $($t.m)" -ForegroundColor Yellow; continue }
        Write-Host "`n================= $($t.l) =================" -ForegroundColor Cyan
        Get-Process llama-server -EA SilentlyContinue | Where-Object { -not $_.HasExited } | Stop-Process -Force -EA SilentlyContinue
        Start-Sleep 6
        $lg = Get-LiveGpuGB
        for ($w=0; $w -lt 40 -and $lg -gt 3.0; $w++) { Start-Sleep 5; $lg = Get-LiveGpuGB }
        if ($lg -gt 3.0) { Write-Host "  ABORT - live GPU $lg GiB still held" -ForegroundColor Red; continue }

        $a = @('-m',$t.m,'-ngl',999,'--ctx-size',$Ctx,'--batch-size',2048,'--ubatch-size',1024,
               '-fa','on','--cache-type-k','q8_0','--cache-type-v','q8_0','--no-mmap','--jinja',
               '--parallel',1,'--host','127.0.0.1','--port',$Port,'--no-warmup')
        $p = Start-Process $Bin -ArgumentList $a -PassThru -WindowStyle Minimized `
                -RedirectStandardError "$env:TEMP\toolsev-$($t.l).err" -RedirectStandardOutput "$env:TEMP\toolsev-$($t.l).out"
        $up=$false
        for ($i=0;$i -lt 200;$i++) { if ($p.HasExited) { break }
            try { if ((Invoke-RestMethod "http://127.0.0.1:$Port/health" -TimeoutSec 3 -EA Stop).status -eq 'ok') { $up=$true;break } } catch {}
            Start-Sleep 3 }
        if (-not $up) {
            Write-Host "  FAILED to start" -ForegroundColor Red
            Get-Content "$env:TEMP\toolsev-$($t.l).err" -Tail 8 -EA SilentlyContinue | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }
            continue
        }
        $summary += Invoke-Eval $t.l "http://127.0.0.1:$Port/v1"
        Stop-Process -Id $p.Id -Force -EA SilentlyContinue
        Start-Sleep 5
    }
}

if ($summary.Count) {
    $summary | Export-Csv $Csv -NoTypeInformation -Append
    Write-Host "`n================ TOOL-CALLING SUMMARY ================" -ForegroundColor Green
    $summary | Sort-Object pct -Descending | Format-Table -AutoSize | Out-String -Width 190 | Write-Host
    Write-Host "per-case CSVs: $root\percase-tools-*.csv" -ForegroundColor DarkGray
}
