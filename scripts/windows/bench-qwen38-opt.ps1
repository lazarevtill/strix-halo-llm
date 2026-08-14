<#
.SYNOPSIS
  Round 2 of Qwen3.8-27B optimisation: prefill tuning, quant/speed tradeoff, remaining flags.

.DESCRIPTION
  Round 1 (bench-qwen38.ps1) established: draft-mtp n=3 -> 20.27 t/s, 262K context ~free,
  q8_0 KV speed-neutral. It also exposed the real weak spot: PREFILL. A 44k prompt took
  7.5 minutes to ingest, and generation speed is irrelevant while a user waits for that.

  So this round attacks three things Round 1 left on the table:

    A. PREFILL (-b / --batch-size, -ub / --ubatch-size). docs/BENCHMARKS.md records
       `-b 2048 -ub 1024` as the gfx1151 sweet spot, but that was measured on MoE models.
       This is a DENSE hybrid with 48 linear-attention layers -- there is no reason to
       assume the same optimum transfers. Measured on a long UNCACHED prompt, fresh server
       per config so every prefill is genuinely cold.

    B. QUANT. Dense means tg ~ 1/filesize, so the quant IS a speed knob here in a way it is
       not for the MoE models in this repo. Memory is not the constraint (109 GiB ceiling);
       bandwidth is. Projected: IQ4_XS ~23 t/s, UD-Q3_K_XL ~27 t/s vs 20.27 measured.

    C. LEFTOVER FLAGS: flash-attn on/off, KV at q4_0, --spec-draft-n-min, mmap vs mlock.

  SOLO OCCUPANCY REQUIRED -- same reason as Round 1. Refuses to run if :8080 is up.

.EXAMPLE
  .\bench-qwen38-opt.ps1 -Phase A        # prefill only
  .\bench-qwen38-opt.ps1                 # everything
#>
[CmdletBinding()]
param(
    [ValidateSet('A','B','C','all')] [string] $Phase = 'all',
    [int] $Port = 8099,
    [int] $Reps = 3
)
$ErrorActionPreference = 'Continue'
$Bin    = 'D:\llamacpp-vulkan\bin\llama-server.exe'
$MDir   = 'D:\llamacpp-vulkan\models'
$LogDir = 'D:\llamacpp-vulkan\logs\bench-qwen38-opt'
$OutDir = 'D:\llamacpp-vulkan\evals\results'
New-Item -ItemType Directory -Force $LogDir | Out-Null
New-Item -ItemType Directory -Force $OutDir | Out-Null
$Stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$Jsonl = Join-Path $OutDir "qwen38-opt-$Stamp.jsonl"
function Say([string]$m,[string]$c='Gray'){ Write-Host $m -ForegroundColor $c }

$Q4  = Join-Path $MDir 'Qwen3.8-27B-UD-Q4_K_XL.gguf'
$IQ4 = Join-Path $MDir 'Qwen3.8-27B-IQ4_XS.gguf'
$Q3  = Join-Path $MDir 'Qwen3.8-27B-UD-Q3_K_XL.gguf'

if (Get-NetTCPConnection -LocalPort 8080 -State Listen -EA SilentlyContinue) {
    Say "`n:8080 is listening -- Ornith is up, so this is NOT solo. Two servers share one memory" Red
    Say "bus and every number below would be wrong. Open the maintenance window first." Red
    exit 3
}

# A long prompt built from a caller-supplied seed. Varying the seed guarantees a DIFFERENT
# prompt each call, so nothing is ever served from the prefix cache and prefill is real work.
function New-LongPrompt { param([int]$items,[int]$seed)
    $sb = New-Object Text.StringBuilder
    [void]$sb.Append("Read the following inventory and reply with only the word ok.`n")
    for ($i=1; $i -le $items; $i++) { [void]$sb.Append("sku$seed-$i qty$($i*3+$seed) loc$(($i*7+$seed)%97) ; ") }
    return $sb.ToString()
}

function Start-Srv {
    param([string]$name,[string]$model,[hashtable]$o)
    Get-Process llama-server -EA SilentlyContinue | Stop-Process -Force -EA SilentlyContinue
    Start-Sleep -Milliseconds 900
    $err = Join-Path $LogDir "$name.err"
    $a = @('--model',$model,'--host','127.0.0.1','--port',$Port,'-ngl','99',
           '-c',$o.ctx,'--parallel','1','--no-mmproj','--temp','0',
           '-ctk',$o.ctk,'-ctv',$o.ctv,'-fa',$o.fa,'-b',$o.b,'-ub',$o.ub)
    if ($o.spec)     { $a += @('--spec-type',$o.spec,'--spec-draft-n-max',$o.nmax) }
    if ($o.nmin -ne $null -and $o.nmin -gt 0) { $a += @('--spec-draft-n-min',$o.nmin) }
    if ($o.loadmode) { $a += @('--load-mode',$o.loadmode) }
    $p = Start-Process $Bin -ArgumentList $a -PassThru -WindowStyle Hidden `
         -RedirectStandardError $err -RedirectStandardOutput (Join-Path $LogDir "$name.out")
    for ($i=0;$i -lt 200;$i++){
        Start-Sleep -Seconds 2
        if ($p.HasExited) { Say "    server exited early (code $($p.ExitCode))" Red; return $null }
        try { if((Invoke-RestMethod "http://127.0.0.1:$Port/health" -TimeoutSec 4).status -eq 'ok'){ return $p } } catch {}
    }
    Say "    never healthy" Red; return $null
}

# Instantaneous, not cumulative. llama.cpp's progress lines report a running average to depth N;
# the final `prompt eval time` line is the whole-prompt figure, which is what we want per config.
function Get-LastPP { param([string]$name)
    $last = $null
    foreach ($l in (Get-Content (Join-Path $LogDir "$name.err") -EA SilentlyContinue)) {
        if ($l -match 'prompt eval time =\s+([\d.]+) ms /\s+(\d+) tokens \(\s*[\d.]+ ms per token,\s+([\d.]+) tokens per second\)') {
            $last = [pscustomobject]@{ ms=[double]$Matches[1]; tok=[int]$Matches[2]; tps=[double]$Matches[3] }
        }
    }
    return $last
}
function Get-TG { param([string]$name,[int]$skip=1)
    $tg=@(); $acc=@(); $len=@()
    foreach ($l in (Get-Content (Join-Path $LogDir "$name.err") -EA SilentlyContinue)) {
        if ($l -match 'eval time =\s+[\d.]+ ms /\s+(\d+) tokens \(\s*[\d.]+ ms per token,\s+([\d.]+) tokens per second\)') {
            $v=[double]$Matches[2]; if (-not $l.Contains('prompt eval time')) { $tg += $v }
        }
        # keep mean len too: in round 1 the acceptance/meanlen PAIR is what explained why n=3 won.
        # If a smaller quant shifts that profile, that is the finding -- raw t/s alone hides it.
        if ($l -match 'draft acceptance = ([\d.]+) .*mean len =\s+([\d.]+)') { $acc += [double]$Matches[1]; $len += [double]$Matches[2] }
    }
    if ($tg.Count -gt $skip) { $tg = $tg[$skip..($tg.Count-1)] }
    [pscustomobject]@{ tg = $(if($tg.Count){[math]::Round(($tg|Measure-Object -Average).Average,2)}else{0})
                       acc= $(if($acc.Count){[math]::Round(($acc|Measure-Object -Average).Average,3)}else{$null})
                       len= $(if($len.Count){[math]::Round(($len|Measure-Object -Average).Average,2)}else{$null})
                       n  = $tg.Count }
}
function Emit { param($row) $row | ConvertTo-Json -Compress -Depth 4 | Add-Content -LiteralPath $Jsonl -Encoding ASCII }

# =================================================================== PHASE A: prefill
if ($Phase -in 'A','all') {
    Say "`n=== PHASE A: prefill tuning (-b / -ub) on a cold ~16k prompt ===" Cyan
    Say "Round 1 measured 7.5 min to ingest 44k. This is the number worth moving." DarkGray
    $seed = 1000
    foreach ($cfg in @(
        @{ b=2048; ub=512  },   # llama.cpp default
        @{ b=2048; ub=1024 },   # the repo's recorded gfx1151 sweet spot (measured on MoE)
        @{ b=4096; ub=1024 },
        @{ b=4096; ub=2048 },
        @{ b=8192; ub=2048 }
    )) {
        $n = "pp-b$($cfg.b)-ub$($cfg.ub)"
        Say ("`n--- {0}" -f $n) Cyan
        # NO SPECULATION HERE ON PURPOSE. draft-mtp is a GENERATION mechanism -- during prefill it
        # does nothing useful, but it still alters graph construction and buffer layout. With
        # max_tokens=8 these runs generate almost nothing, so leaving MTP on would add a variable
        # while measuring none of its benefit. Isolate -b/-ub and nothing else.
        # NB: -ub must be <= -b, and larger -b/-ub grow the compute buffer; a config that fails to
        # start at ctx=131072 is an ALLOCATION failure, not an unsupported flag. Check the .err.
        $p = Start-Srv $n $Q4 @{ ctx=131072; ctk='f16'; ctv='f16'; fa='on'; b=$cfg.b; ub=$cfg.ub }
        if (-not $p) { continue }
        $seed++
        $body = @{ messages=@(@{role='user';content=(New-LongPrompt 1700 $seed)}); max_tokens=8 } | ConvertTo-Json -Depth 5 -Compress
        try { Invoke-RestMethod "http://127.0.0.1:$Port/v1/chat/completions" -Method Post -Body $body -ContentType 'application/json' -TimeoutSec 1800 | Out-Null } catch { Say "    request failed" Red }
        $r = Get-LastPP $n
        if ($r) {
            Say ("    prefill {0} tok in {1:N1}s = {2} t/s" -f $r.tok,($r.ms/1000),$r.tps) Green
            Emit ([pscustomobject]@{ phase='A'; name=$n; b=$cfg.b; ub=$cfg.ub; pp_tok=$r.tok; pp_ms=$r.ms; pp_tps=$r.tps })
        } else { Say "    no prefill timing captured" Yellow }
    }
}

# =================================================================== PHASE B: quant
if ($Phase -in 'B','all') {
    Say "`n=== PHASE B: quant vs speed (dense => tg ~ 1/filesize) ===" Cyan
    $GEN = 'Implement a red-black tree in Python with insert, delete, search and an in-order iterator. Include docstrings and type hints. Write the complete implementation.'
    foreach ($m in @(
        @{ n='q4kxl'; f=$Q4;  gib=16.69 },
        @{ n='iq4xs'; f=$IQ4; gib=14.63 },
        @{ n='q3kxl'; f=$Q3;  gib=12.52 }
    )) {
        if (-not (Test-Path $m.f)) { Say ("`n--- {0}: NOT DOWNLOADED, skipping" -f $m.n) Yellow; continue }
        $n = "quant-$($m.n)"
        Say ("`n--- {0}  ({1} GiB)" -f $n,$m.gib) Cyan
        $p = Start-Srv $n $m.f @{ ctx=32768; ctk='f16'; ctv='f16'; fa='on'; b=2048; ub=1024; spec='draft-mtp'; nmax=3 }
        if (-not $p) { continue }
        $b1 = @{ messages=@(@{role='user';content=$GEN}); max_tokens=64 } | ConvertTo-Json -Depth 5 -Compress
        Invoke-RestMethod "http://127.0.0.1:$Port/v1/chat/completions" -Method Post -Body $b1 -ContentType 'application/json' -TimeoutSec 900 | Out-Null
        for ($i=0;$i -lt $Reps;$i++){
            $b2 = @{ messages=@(@{role='user';content=$GEN}); max_tokens=400 } | ConvertTo-Json -Depth 5 -Compress
            $resp = $null
            try { $resp = Invoke-RestMethod "http://127.0.0.1:$Port/v1/chat/completions" -Method Post -Body $b2 -ContentType 'application/json' -TimeoutSec 900 } catch {}
            if ($i -eq 0 -and $resp) {
                $mm = $resp.choices[0].message
                # capture BOTH -- this model thinks by default, so .content is often empty
                [IO.File]::WriteAllText((Join-Path $LogDir "$n.raw.txt"),
                    ("=== content ===`r`n" + [string]$mm.content + "`r`n`r`n=== reasoning ===`r`n" + [string]$mm.reasoning_content),
                    (New-Object Text.UTF8Encoding($false)))
            }
        }
        $r = Get-TG $n 1
        $eff = if ($m.gib -gt 0) { [math]::Round($r.tg * $m.gib, 1) } else { 0 }

        # SANITY GATE. Q3 (and below) on a 27B DENSE model is exactly where quantisation damage
        # shows up, and a table reading "q3kxl: 27 t/s" is precisely the artifact someone acts on
        # later. This is NOT a quality eval -- it is a floor check. A quant that cannot multiply
        # two numbers is disqualified regardless of how fast it is. reasoning_effort=low so the
        # answers actually terminate instead of dying inside a think block.
        $checks = @(@{q='What is 17 * 24? Reply with only the number.'; a='408'},
                    @{q='Reply with only the capital city of Australia.'; a='Canberra'},
                    @{q='Complete the sequence with the next number only: 2, 4, 8, 16, 32,'; a='64'})
        $pass = 0
        foreach ($ck in $checks) {
            $bq = @{ messages=@(@{role='user';content=$ck.q}); max_tokens=1500; chat_template_kwargs=@{reasoning_effort='low'} } | ConvertTo-Json -Depth 5 -Compress
            try {
                $rr = Invoke-RestMethod "http://127.0.0.1:$Port/v1/chat/completions" -Method Post -Body $bq -ContentType 'application/json' -TimeoutSec 600
                $flat = (([string]$rr.choices[0].message.content) -replace '\s+',' ').Trim()
                if ($flat -match [regex]::Escape($ck.a)) { $pass++ }
            } catch {}
        }
        $col = if ($pass -eq 3) { 'Green' } else { 'Red' }
        Say ("    tg={0} t/s  accept={1} meanlen={2}  (implied GiB/s = {3})" -f $r.tg,$r.acc,$r.len,$eff) Green
        Say ("    sanity {0}/3 {1}" -f $pass, $(if($pass -eq 3){'(floor check only, NOT a quality eval)'}else{'<-- SUSPECT, do not serve this quant'})) $col
        Emit ([pscustomobject]@{ phase='B'; name=$n; gib=$m.gib; tg=$r.tg; accept=$r.acc; meanlen=$r.len; implied_gibps=$eff; sanity_pass=$pass; samples=$r.n })
    }
}

# =================================================================== PHASE C: leftover flags
if ($Phase -in 'C','all') {
    Say "`n=== PHASE C: flash-attn, aggressive KV quant, n-min, load-mode ===" Cyan
    $GEN = 'Write a detailed technical explanation of how B-trees work, including insertion and deletion.'
    # DELIBERATELY ONLY TWO ROWS. Dropped, because neither can pay for the downtime it costs:
    #   --spec-draft-n-min : interacts with n-max=3 across a range too narrow to resolve at 3 reps.
    #   --load-mode mmap   : affects LOAD TIME, not steady-state tg, and round 1 already has
    #                        load_s (8-23 s, mostly page-cache variance). Nothing to learn.
    # That time goes to Phase A instead, which is where the 7.5-minute prefill number lives.
    foreach ($v in @(
        @{ n='fa-off';  o=@{ ctx=32768; ctk='f16';  ctv='f16';  fa='off'; b=2048; ub=1024; spec='draft-mtp'; nmax=3 } },
        @{ n='kv-q4_0'; o=@{ ctx=32768; ctk='q4_0'; ctv='q4_0'; fa='on';  b=2048; ub=1024; spec='draft-mtp'; nmax=3 } }
    )) {
        $n = "flag-$($v.n)"
        Say ("`n--- {0}" -f $n) Cyan
        $p = Start-Srv $n $Q4 $v.o
        if (-not $p) { continue }
        $b1 = @{ messages=@(@{role='user';content=$GEN}); max_tokens=64 } | ConvertTo-Json -Depth 5 -Compress
        Invoke-RestMethod "http://127.0.0.1:$Port/v1/chat/completions" -Method Post -Body $b1 -ContentType 'application/json' -TimeoutSec 900 | Out-Null
        for ($i=0;$i -lt $Reps;$i++){
            $b2 = @{ messages=@(@{role='user';content=$GEN}); max_tokens=400 } | ConvertTo-Json -Depth 5 -Compress
            try { Invoke-RestMethod "http://127.0.0.1:$Port/v1/chat/completions" -Method Post -Body $b2 -ContentType 'application/json' -TimeoutSec 900 | Out-Null } catch {}
        }
        $r = Get-TG $n 1
        Say ("    tg={0} t/s  accept={1}" -f $r.tg,$r.acc) Green
        Emit ([pscustomobject]@{ phase='C'; name=$n; tg=$r.tg; accept=$r.acc; samples=$r.n })
    }
}

Get-Process llama-server -EA SilentlyContinue | Stop-Process -Force -EA SilentlyContinue
Say "`nJSONL: $Jsonl" DarkGray
Say "Reminder: close the maintenance window to bring Ornith back." Yellow
