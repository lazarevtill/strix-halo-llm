<#
.SYNOPSIS
  Test whether a pure K-quant prefills faster than Unsloth's mixed UD-Q4_K_XL.

.DESCRIPTION
  The per-op prefill profile (GGML_VK_PERF_LOGGER, 2026-08-14) showed that UD-Q4_K_XL is a MIXED
  quant, and that its iq4_xs tensors are by far the slowest matmul in the whole prefill:

      MUL_MAT iq4_xs m=17408 n=512 k=5120:  64 x 13720 us = 878 ms   6652 GFLOPS   <- slowest
      MUL_MAT q5_K   m=17408 n=512 k=5120:  64 x  7641 us = 489 ms  11944 GFLOPS
      MUL_MAT q5_K   m=5120  n=512 k=17408: 64 x  7902 us = 506 ms  11550 GFLOPS

  878 ms of a ~2990 ms ubatch, at roughly half the GFLOPS of the q5_K tensors beside it.

  HYPOTHESIS: a quant with no iq4_xs tensors (plain Q4_K_M / Q5_K_M) prefills faster.

  ⚠️ THIS IS NOT "Q4_K_XL WITH iq4_xs SWAPPED OUT". Q4_K_M is a different quant with different
  per-tensor assignments throughout -- it may use q4_K where XL uses q5_K, which could be slower
  overall. The naive projection is ~13% (389 ms of 2990 ms); treat that as an upper bound on the
  matmul term, not a prediction. Four similar projections were already refuted this session.

  Uses llama-bench rather than the server: no HTTP overhead, no prompt caching, and it reports
  prompt-processing and generation separately.
#>
[CmdletBinding()]
param(
    [string] $Bench = 'D:\src\llama.cpp-gdn\build\bin\Release\llama-bench.exe',
    [int]    $Ub    = 256,
    [switch] $Profile
)
$ErrorActionPreference = 'Continue'
$MDIR = 'D:\llamacpp-vulkan\models'
$RES  = 'D:\llamacpp-vulkan\evals\results'
New-Item -ItemType Directory -Force $RES | Out-Null
function Say([string]$m,[string]$c='Cyan'){ Write-Host $m -ForegroundColor $c }

if (Get-NetTCPConnection -LocalPort 8080 -State Listen -EA SilentlyContinue) {
    Say ":8080 is listening -- not solo. A second resident model shares the memory bus and every" Red
    Say "number below would be wrong. Aborting." Red
    exit 3
}
if (Get-Process llama-server -EA SilentlyContinue) { Say "llama-server is running -- aborting." Red; exit 3 }
if (-not (Test-Path $Bench)) { Say "llama-bench not found: $Bench" Red; exit 1 }

$models = @(
    @{ n='UD-Q4_K_XL (mixed, current)'; f="$MDIR\Qwen3.8-27B-UD-Q4_K_XL.gguf"; b=17923394624 },
    @{ n='Q4_K_M (pure K-quant)';       f="$MDIR\Qwen3.8-27B-Q4_K_M.gguf";     b=17106775008 },
    @{ n='Q5_K_M (pure K-quant)';       f="$MDIR\Qwen3.8-27B-Q5_K_M.gguf";     b=19834055648 },
    # Added 2026-08-16. Round 3 showed Q5_K_M is already past the peak, so these two are expected
    # to be slower still -- which is exactly why they are worth running rather than assuming. Four
    # projections have been refuted on this box this week, including the one that motivated THIS
    # script (13% of prefill predicted, 0.7% delivered). Q8_0 also barely dequantises, so if ALU
    # cost is the mechanism it is the one quant that could break the trend.
    @{ n='Q6_K (pure K-quant)';         f="$MDIR\Qwen3.8-27B-Q6_K.gguf";       b=22884408288 },
    @{ n='Q8_0 (near-lossless)';        f="$MDIR\Qwen3.8-27B-Q8_0.gguf";       b=29047086048 }
)

Say "`n=== prefill / generation by quant (llama-bench, -ub $Ub) ===" Cyan
Say "pp16384 is the number under test; tg128 is a control." DarkGray
foreach ($m in $models) {
    if (-not (Test-Path $m.f)) { Say ("`n--- {0}: NOT PRESENT, skipping" -f $m.n) Yellow; continue }
    $len = (Get-Item $m.f).Length
    if ($len -ne $m.b) { Say ("`n--- {0}: INCOMPLETE ({1:N0}/{2:N0}), skipping" -f $m.n,$len,$m.b) Yellow; continue }
    Say ("`n--- {0}" -f $m.n) Cyan
    $out = & $Bench -m $m.f -ngl 99 -fa 1 -ub $Ub -p 4096,16384 -n 128 -r 2 2>&1
    $out | Select-String -Pattern '\|\s*(pp|tg)\d+' | ForEach-Object { Write-Host ("    " + $_.Line.Trim()) -ForegroundColor Green }
    $out | Out-File (Join-Path $RES ("kquant-" + ($m.n -replace '[^A-Za-z0-9]','_') + ".txt")) -Encoding utf8
}

if ($Profile) {
    Say "`n=== per-op profile: which tensor types does each quant actually use? ===" Cyan
    $env:GGML_VK_PERF_LOGGER = '1'
    foreach ($m in $models) {
        if (-not (Test-Path $m.f)) { continue }
        Say ("`n--- {0}" -f $m.n) Cyan
        $p = & $Bench -m $m.f -ngl 99 -fa 1 -ub $Ub -p 4096 -n 0 -r 1 2>&1
        # one line per distinct MUL_MAT quant type, with its GFLOPS -- this is what the
        # hypothesis is actually about
        $p | Select-String -Pattern 'MUL_MAT (\w+) ' | ForEach-Object { $_.Line.Trim() } |
            Sort-Object -Unique | Select-Object -First 14 | ForEach-Object { Write-Host ("    " + $_) -ForegroundColor Gray }
    }
    Remove-Item Env:\GGML_VK_PERF_LOGGER -EA SilentlyContinue
}
Say "`ndone" Cyan
