<#
.SYNOPSIS
  Extend the prefill -ub sweep DOWNWARD. Run after bench-qwen38-opt.ps1, same solo window.

.DESCRIPTION
  Round 2 Phase A swept -ub 512/1024/2048 and found prefill throughput is MONOTONICALLY better
  at smaller -ub on this model:

      -b 2048 -ub  512   159.0 t/s   <- llama.cpp default, best of the five tested
      -b 2048 -ub 1024   129.5 t/s
      -b 4096 -ub 1024   129.8 t/s
      -b 4096 -ub 2048   107.8 t/s

  Every configuration tested was at or above 512, so the sweep never established whether 512 is a
  PEAK or merely the smallest value tried. This script tests below it.

  It also RE-RUNS -ub 512 as a control. Without that, a difference between this script's numbers
  and Phase A's could be a run-to-run effect (thermal, driver state) rather than the flag, and
  there would be no way to tell.

  Same prompt generator and same ~31k token size as Phase A, so numbers are directly comparable.

  RESULT: 512 was NOT a peak -- prefill keeps improving below it, then flattens.

      -ub 512  159.2 t/s  (control; matches Phase A's 159.0 to 0.1%, so the sweep is reproducible)
      -ub 256  167.4 t/s  <- shipped default
      -ub 128  169.0 t/s  <- fastest measured, +0.9% over 256

  128 edges 256, but each point is n=1 and 0.9% is too small for this design to call. The solid
  finding is the FLATTENING: everything at 256 and below lands in 167.4-169.0, while 512->256 is
  worth 5%. That is why 256 ships -- it is the knee, not the maximum. Resolving 128 vs 256 needs
  repeated runs per point, which this script does not do.
#>
[CmdletBinding()]
param(
    [string] $Model = 'D:\llamacpp-vulkan\models\Qwen3.8-27B-UD-Q4_K_XL.gguf',
    [int]    $Port  = 8099
)
$ErrorActionPreference = 'Continue'
$Bin    = 'D:\llamacpp-vulkan\bin\llama-server.exe'
$LogDir = 'D:\llamacpp-vulkan\logs\bench-qwen38-opt'
$OutDir = 'D:\llamacpp-vulkan\evals\results'
New-Item -ItemType Directory -Force $LogDir | Out-Null
New-Item -ItemType Directory -Force $OutDir | Out-Null
$Jsonl = Join-Path $OutDir ("qwen38-ubatch-" + (Get-Date -Format 'yyyyMMdd-HHmmss') + ".jsonl")
function Say([string]$m,[string]$c='Gray'){ Write-Host $m -ForegroundColor $c }

if (Get-NetTCPConnection -LocalPort 8080 -State Listen -EA SilentlyContinue) {
    Say ":8080 is listening -- not solo, aborting." Red; exit 3
}

function New-LongPrompt { param([int]$items,[int]$seed)
    $sb = New-Object Text.StringBuilder
    [void]$sb.Append("Read the following inventory and reply with only the word ok.`n")
    for ($i=1; $i -le $items; $i++) { [void]$sb.Append("sku$seed-$i qty$($i*3+$seed) loc$(($i*7+$seed)%97) ; ") }
    return $sb.ToString()
}

# control first, then downward. seeds continue from Phase A's range so prompts stay ~31k tokens
# but are never identical (a repeated prompt would be served from cache and measure nothing).
$cfgs = @(
    @{ b=2048; ub=512; seed=2001; tag='control-512' },
    @{ b=2048; ub=256; seed=2002; tag='ub-256'      },
    @{ b=2048; ub=128; seed=2003; tag='ub-128'      },
    @{ b=1024; ub=256; seed=2004; tag='b1024-ub256' }
)

Say "`n=== prefill sweep BELOW -ub 512 (plus a 512 control) ===" Cyan
foreach ($c in $cfgs) {
    $n = "pp-$($c.tag)"
    Say ("`n--- {0}   (-b {1} -ub {2})" -f $n,$c.b,$c.ub) Cyan
    Get-Process llama-server -EA SilentlyContinue | Stop-Process -Force -EA SilentlyContinue
    Start-Sleep -Milliseconds 900
    $err = Join-Path $LogDir "$n.err"
    $a = @('--model',$Model,'--host','127.0.0.1','--port',$Port,'-ngl','99','-c','131072',
           '--parallel','1','--no-mmproj','--temp','0','-ctk','f16','-ctv','f16','-fa','on',
           '-b',$c.b,'-ub',$c.ub)
    $p = Start-Process $Bin -ArgumentList $a -PassThru -WindowStyle Hidden `
         -RedirectStandardError $err -RedirectStandardOutput (Join-Path $LogDir "$n.out")
    $ok=$false
    for ($i=0;$i -lt 200;$i++){ Start-Sleep -Seconds 2; if($p.HasExited){break}
        try { if((Invoke-RestMethod "http://127.0.0.1:$Port/health" -TimeoutSec 4).status -eq 'ok'){$ok=$true;break} } catch {} }
    if (-not $ok) { Say "    failed to start (exited=$($p.HasExited))" Red; continue }

    $body = @{ messages=@(@{role='user';content=(New-LongPrompt 1700 $c.seed)}); max_tokens=8 } | ConvertTo-Json -Depth 5 -Compress
    try { Invoke-RestMethod "http://127.0.0.1:$Port/v1/chat/completions" -Method Post -Body $body -ContentType 'application/json' -TimeoutSec 2400 | Out-Null }
    catch { Say "    request failed: $($_.Exception.Message)" Red }

    $last=$null
    foreach ($l in (Get-Content $err -EA SilentlyContinue)) {
        if ($l -match 'prompt eval time =\s+([\d.]+) ms /\s+(\d+) tokens \(\s*[\d.]+ ms per token,\s+([\d.]+) tokens per second\)') {
            $last = [pscustomobject]@{ ms=[double]$Matches[1]; tok=[int]$Matches[2]; tps=[double]$Matches[3] }
        }
    }
    if ($last) {
        Say ("    prefill {0} tok in {1:N1}s = {2} t/s" -f $last.tok,($last.ms/1000),$last.tps) Green
        [pscustomobject]@{ name=$n; b=$c.b; ub=$c.ub; pp_tok=$last.tok; pp_ms=$last.ms; pp_tps=$last.tps } |
            ConvertTo-Json -Compress | Add-Content -LiteralPath $Jsonl -Encoding ASCII
    } else { Say "    no timing captured" Yellow }
}
Get-Process llama-server -EA SilentlyContinue | Stop-Process -Force -EA SilentlyContinue
Say "`nJSONL: $Jsonl" DarkGray
