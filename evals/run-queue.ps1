<#
.SYNOPSIS
  Run the three outstanding GPU jobs back to back, one at a time, GPU verified empty between each.

.DESCRIPTION
  A: easy tier + tool calling for all five models. ornith-easy is re-run deliberately -- its only
     existing result was served at --ubatch-size 1024, and mixing that with 256 would split the
     tier across two batch settings for no reason.
  B: qwen38 with anti-repetition sampling on hard_semver + hard_where. Tests whether those two
     zeroes were the model or our missing repetition penalty (bug 13).
  C: laguna and deepseek hard tier, re-run IN FULL. Both aborted tasks on the 1800s timeout that
     was fixed in 573641a.

  WHY C RE-RUNS ALL THREE TASKS rather than only the aborted ones: rescore.py and summarize-bench.py
  both keep the LAST row per label, so a partial row appended under an existing label would silently
  replace a complete one. deepseek would lose its 25/25 and 26/27. An extra hour buys a row that
  cannot be misread.

  Each phase prints a QUEUE PHASE marker so progress can be followed from the log alone.

.EXAMPLE
  .\evals\run-queue.ps1
  .\evals\run-queue.ps1 -SkipA          # start at the sampler experiment
#>
[CmdletBinding()]
param(
    [switch] $SkipA,
    [switch] $SkipB,
    [switch] $SkipD,
    [switch] $SkipC,
    [int]    $Port = 8099,
    [int]    $Seed = 42
)
$ErrorActionPreference = 'Continue'
$root  = $PSScriptRoot
$stamp = Get-Date -Format 'yyyyMMdd-HHmm'
$log   = Join-Path $root "results\queue-$stamp.log"
New-Item -ItemType Directory -Force -Path (Split-Path $log) | Out-Null

function Say($m, $c = 'White') {
    $line = "[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $m
    Write-Host $line -ForegroundColor $c
    Add-Content $log $line -Encoding utf8
}

# One model at a time. On unified memory a second resident model does not merely slow things down,
# it changes what fits -- and a contended measurement is not slightly wrong, it is meaningless.
function Wait-GpuFree([int]$MaxWaitSec = 180) {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.Elapsed.TotalSeconds -lt $MaxWaitSec) {
        $p = Get-Process -Name llama-server -ErrorAction SilentlyContinue
        if (-not $p) {
            $os = Get-CimInstance Win32_OperatingSystem
            $gb = [math]::Round(($os.TotalVisibleMemorySize - $os.FreePhysicalMemory) / 1MB, 2)
            Say ("GPU clear (committed {0} GiB)" -f $gb) DarkGray
            return $true
        }
        Start-Sleep -Seconds 5
    }
    Say "REFUSING TO CONTINUE -- llama-server still resident after ${MaxWaitSec}s" Red
    Get-Process -Name llama-server -EA SilentlyContinue |
        ForEach-Object { Say ("  pid={0} started={1}" -f $_.Id, $_.StartTime) Red }
    return $false
}

Say "=== QUEUE START  A=$(!$SkipA) B=$(!$SkipB) C=$(!$SkipC)  log=$log ===" Yellow

# ---- A: easy tier + tools, all five models -------------------------------------------------------
if (-not $SkipA) {
    Say "=== QUEUE PHASE A: easy tier + tool calling, all 5 models ===" Yellow
    if (-not (Wait-GpuFree)) { exit 3 }
    & "$root\run-full-bench.ps1" -Phase easy -Port $Port -Seed $Seed 2>&1 |
        Out-String -Stream | ForEach-Object { Write-Host $_; Add-Content $log $_ -Encoding utf8 }
    Say "=== QUEUE PHASE A DONE ===" Green
}

# ---- B: qwen38 anti-repetition -------------------------------------------------------------------
if (-not $SkipB) {
    Say "=== QUEUE PHASE B: qwen38 anti-repetition (bug 13) ===" Yellow
    if (-not (Wait-GpuFree)) { exit 3 }
    & "$root\rerun-sampler.ps1" -Label qwen38-drytest -Port $Port -Seed $Seed 2>&1 |
        Out-String -Stream | ForEach-Object { Write-Host $_; Add-Content $log $_ -Encoding utf8 }
    Say "=== QUEUE PHASE B DONE ===" Green
}

# ---- D: determinism control, and it must run BEFORE C --------------------------------------------
# ornith-easy scored 70/70 at --ubatch-size 1024 and 65/70 at 256, on the SAME seed, temperature and
# token budget. token_budget went 20/20 -> 15/20 on turns 2 and 3, with no FRAGMENT flags in either
# run, so the model genuinely emitted different code. Two explanations fit, and they are not close
# to equivalent:
#
#   1. -ub changes the numerics (different prompt batching -> different logits -> different tokens).
#   2. The harness was never run-to-run deterministic, and every single-run number in this repo
#      carries an error bar nobody has measured.
#
# This re-runs ornith's easy tier at the ORIGINAL 1024. Returning 70/70 implicates -ub; returning a
# third number implicates determinism itself, and then the hard-tier gaps need error bars before any
# of them can be published. Distinct label -- it is a control, not a replacement.
if (-not $SkipD) {
    Say "=== QUEUE PHASE D: determinism control, ornith easy @ ub 1024 ===" Yellow
    if (-not (Wait-GpuFree)) { exit 3 }
    $p = @{
        Label = 'ornith-easy-ub1024'
        Model = 'D:\llamacpp-vulkan\models\ornith-1.0-35b-Q5_K_M.gguf'
        Ctx = 131072; Port = $Port; Seed = $Seed; UBatch = 1024; Bind = '127.0.0.1'
        Tasks = 'token_budget,shard_planner,window_merge,quant_pick'
        SkipTools = $true
    }
    & "$root\run-model-suite.ps1" @p 2>&1 |
        Out-String -Stream | ForEach-Object { Write-Host $_; Add-Content $log $_ -Encoding utf8 }
    Say "=== QUEUE PHASE D DONE -- compare against ornith-easy 70/70 (ub1024) and 65/70 (ub256) ===" Green
}

# ---- C: laguna + deepseek hard tier, in full -----------------------------------------------------
# Pinned to 1024 so all five hard-tier rows share one batch setting. The other three were recorded
# at 1024 on 2026-08-15; re-running two at 256 would make them incomparable with the three we
# already have, which costs more than the prefill saving is worth.
if (-not $SkipC) {
    Say "=== QUEUE PHASE C: laguna + deepseek hard tier, full re-run @ ub 1024 ===" Yellow
    if (-not (Wait-GpuFree)) { exit 3 }
    & "$root\run-full-bench.ps1" -Phase hard -Only laguna,deepseek -Port $Port -Seed $Seed -UBatch 1024 2>&1 |
        Out-String -Stream | ForEach-Object { Write-Host $_; Add-Content $log $_ -Encoding utf8 }
    Say "=== QUEUE PHASE C DONE ===" Green
}

Say "=== QUEUE COMPLETE ===" Green
Say "rescore:  python evals\rescore.py --tier hard   /   --tier easy" Cyan
