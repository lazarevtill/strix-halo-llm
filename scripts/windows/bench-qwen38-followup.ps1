<#
.SYNOPSIS
  Three questions the main Qwen3.8 sweep could not answer. Run AFTER bench-qwen38.ps1,
  in the same solo-occupancy window.

.DESCRIPTION
  1. DOES MTP STILL WIN UNDER LOAD?  The sweep found 3-slot aggregate (16.58 t/s) came in
     BELOW single-stream (20.27 t/s) with MTP on. Speculation consumes the batch dimension
     -- every draft token is verified in the same forward pass -- so it may be competing
     with concurrency rather than composing with it. If plain batching beats MTP at
     parallel 3, the daily config should differ from the single-user config. Nothing else
     in the sweep decides this, and this box serves 3 slots.

  2. WHAT IS PROMPT PROCESSING ACTUALLY?  The sweep reused one prompt, so after warmup the
     server re-evaluated only 4 tokens (LCP cache hit, f_sim_best = 1.000). A 4-token
     prefill measures overhead, not throughput. This sends a LONG, UNIQUE prompt each time
     so the prefill is real.

  3. WHAT DOES reasoning_effort COST?  The chat template defaults to 'xhigh'. For a user
     waiting on an answer, total latency = (thinking tokens + answer tokens) / tg. If xhigh
     triples the token count, it matters more than any flag measured so far.
#>
[CmdletBinding()]
param(
    [string] $Model = 'D:\llamacpp-vulkan\models\Qwen3.8-27B-UD-Q4_K_XL.gguf',
    [int]    $Port  = 8099
)
$ErrorActionPreference = 'Continue'
$Bin    = 'D:\llamacpp-vulkan\bin\llama-server.exe'
$LogDir = 'D:\llamacpp-vulkan\logs\bench-qwen38'
New-Item -ItemType Directory -Force $LogDir | Out-Null
function Say([string]$m,[string]$c='Gray'){ Write-Host $m -ForegroundColor $c }

if (Get-NetTCPConnection -LocalPort 8080 -State Listen -EA SilentlyContinue) {
    Say ":8080 is listening -- not solo. Aborting." Red; exit 3
}

function Start-Srv {
    param([string]$name,[string]$spec,[int]$nmax,[int]$ctx,[int]$par)
    Get-Process llama-server -EA SilentlyContinue | Stop-Process -Force -EA SilentlyContinue
    Start-Sleep -Milliseconds 800
    $err = Join-Path $LogDir "$name.err"
    $a = @('--model',$Model,'--host','127.0.0.1','--port',$Port,'-ngl','99','-c',$ctx,
           '--parallel',$par,'-fa','on','--no-mmproj','--temp','0')
    if ($spec) { $a += @('--spec-type',$spec,'--spec-draft-n-max',$nmax) }
    $p = Start-Process $Bin -ArgumentList $a -PassThru -WindowStyle Hidden `
         -RedirectStandardError $err -RedirectStandardOutput (Join-Path $LogDir "$name.out")
    for ($i=0;$i -lt 150;$i++){ Start-Sleep -Seconds 2; if($p.HasExited){return $null}
        try { if((Invoke-RestMethod "http://127.0.0.1:$Port/health" -TimeoutSec 4).status -eq 'ok'){return $p} } catch {} }
    return $null
}

$PROMPT = 'Implement a red-black tree in Python with insert, delete, search and an in-order iterator. Include docstrings and type hints. Write the complete implementation.'

# ---------------------------------------------------------- 1. concurrency, spec on vs off
Say "`n=== 1. Does MTP still win at parallel 3? ===" Cyan
foreach ($v in @(@{n='par3-nospec'; s=$null}, @{n='par3-mtp3'; s='draft-mtp'})) {
    $p = Start-Srv $v.n $v.s 3 98304 3
    if (-not $p) { Say "  $($v.n): FAILED TO START" Red; continue }
    $b = @{ messages=@(@{role='user';content=$PROMPT}); max_tokens=64 } | ConvertTo-Json -Depth 5 -Compress
    Invoke-RestMethod "http://127.0.0.1:$Port/v1/chat/completions" -Method Post -Body $b -ContentType 'application/json' -TimeoutSec 600 | Out-Null
    $jobs = 1..3 | ForEach-Object {
        Start-Job -ArgumentList $Port,$PROMPT,$_ -ScriptBlock {
            param($pt,$pr,$k)
            # unique suffix per job so the three requests do NOT share one cached prefix
            $b = @{ messages=@(@{role='user';content=("$pr (variant $k)")}); max_tokens=400 } | ConvertTo-Json -Depth 5 -Compress
            try { (Invoke-RestMethod "http://127.0.0.1:$pt/v1/chat/completions" -Method Post -Body $b -ContentType 'application/json' -TimeoutSec 900).usage.completion_tokens } catch { 0 }
        }
    }
    $sw=[Diagnostics.Stopwatch]::StartNew()
    $toks=($jobs | Wait-Job -Timeout 900 | Receive-Job); $sw.Stop()
    $jobs | Remove-Job -Force -EA SilentlyContinue
    $sum=($toks | Measure-Object -Sum).Sum
    Say ("  {0,-12} aggregate {1} tok / {2:N1}s = {3:N2} t/s   per-request {4:N2} t/s" -f `
        $v.n,$sum,$sw.Elapsed.TotalSeconds,($sum/$sw.Elapsed.TotalSeconds),($sum/3/$sw.Elapsed.TotalSeconds)) Green
}

# ---------------------------------------------------------- 2. real prompt processing
Say "`n=== 2. Prompt processing on a LONG, UNCACHED prompt ===" Cyan
$p = Start-Srv 'pp-real' 'draft-mtp' 3 131072 1
if ($p) {
    # ~6000 tokens of unique filler, different every call, so nothing is served from cache
    foreach ($n in @(2000,6000)) {
        $filler = (1..$n | ForEach-Object { "item$_ value$($_*7) " }) -join ''
        $b = @{ messages=@(@{role='user';content=("Summarise in one sentence: " + $filler)}); max_tokens=16 } | ConvertTo-Json -Depth 5 -Compress
        try { Invoke-RestMethod "http://127.0.0.1:$Port/v1/chat/completions" -Method Post -Body $b -ContentType 'application/json' -TimeoutSec 900 | Out-Null } catch {}
    }
    $lines = Get-Content (Join-Path $LogDir 'pp-real.err') | Select-String 'prompt eval time'
    foreach ($l in $lines) {
        if ($l.Line -match 'prompt eval time =\s+([\d.]+) ms /\s+(\d+) tokens \(\s*[\d.]+ ms per token,\s+([\d.]+) tokens per second\)') {
            Say ("  {0,6} tokens prefilled -> {1,8} t/s  ({2} ms)" -f $Matches[2],$Matches[3],$Matches[1]) Green
        }
    }
}

# ---------------------------------------------------------- 3. reasoning_effort cost
Say "`n=== 3. What does reasoning_effort cost in tokens (and therefore seconds)? ===" Cyan
$q = 'A train leaves at 14:05 and arrives at 17:40. It stops twice for 12 minutes each. What is its moving time? Give the answer.'
foreach ($eff in @('low','medium','xhigh')) {
    $b = @{ messages=@(@{role='user';content=$q}); max_tokens=4000; chat_template_kwargs=@{reasoning_effort=$eff} } | ConvertTo-Json -Depth 5 -Compress
    $sw=[Diagnostics.Stopwatch]::StartNew()
    try {
        $r = Invoke-RestMethod "http://127.0.0.1:$Port/v1/chat/completions" -Method Post -Body $b -ContentType 'application/json' -TimeoutSec 900
        $sw.Stop()
        $txt = ([string]$r.choices[0].message.content -replace '\s+',' ').Trim()
        $tail = $txt.Substring([math]::Max(0,$txt.Length-110))
        Say ("  {0,-7} {1,5} tokens  {2,6:N1}s   ...{3}" -f $eff,$r.usage.completion_tokens,$sw.Elapsed.TotalSeconds,$tail) Green
    } catch { $sw.Stop(); Say ("  {0,-7} FAILED" -f $eff) Red }
}
Get-Process llama-server -EA SilentlyContinue | Stop-Process -Force -EA SilentlyContinue
Say "`ndone" Cyan
