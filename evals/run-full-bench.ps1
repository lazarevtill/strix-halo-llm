<#
.SYNOPSIS
  The whole stack, every model, one job at a time.

.DESCRIPTION
  Three phases, in this order on purpose:

    0  speed    llama-bench prefill/decode per model            ~25 min
    1  HARD     the 3 hard coding tasks (89 hidden tests)       the discriminator
    2  easy     the 4 original tasks (70 tests) + tool calling  the regression check

  PHASE ORDER IS THE POINT. The easy tier is known saturated -- every model measured has
  returned 70/70 on it -- and the tool suite sits at 27-29/29. Neither separates anything.
  The hard tier is the only part that has ever produced a spread (ornith: 10/10 -> 16/17 ->
  0/21 on hard_ratelimit), so it runs first. If this is interrupted at hour 9, what survives
  is a COMPLETE hard-tier table across every model rather than two models measured on
  everything and two not measured at all.

  Sequential by construction. Every model is the sole occupant of the GPU while it is scored:
  two servers on one memory bus do not produce a slightly wrong number, they produce a
  meaningless one. The GPU is verified empty between runs, and the whole thing aborts if
  :8080 starts serving -- a stray client request lands in the eval's own slot.

.NOTES
  Expect 18-24 hours. :8080 is down for the duration; the ornith stopgap does not come back
  on its own and the scheduled task is still disabled.
#>
[CmdletBinding()]
param(
    [ValidateSet('speed', 'hard', 'easy', 'all')] [string] $Phase = 'all',
    [int]    $Port = 8099,
    [int]    $Seed = 42,
    # Restrict to a subset of the labels below, e.g. -Only ornith,qwen38
    [string[]] $Only = @()
)
$ErrorActionPreference = 'Continue'
$root    = 'D:\llamacpp-vulkan\evals'
$bench   = 'D:\llamacpp-vulkan\bin\llama-bench.exe'
$outdir  = Join-Path $root 'results'
New-Item -ItemType Directory -Force -Path $outdir | Out-Null
$stamp   = '20260815-1630'          # fixed, not Get-Date: one run -> one directory
$log     = Join-Path $outdir "fullbench-$stamp.log"

$HARD = 'hard_ratelimit,hard_semver,hard_where'
$EASY = 'token_budget,shard_planner,window_merge,quant_pick'

# Ordered by cost. The four with prior data come first so the core comparison completes even
# if the run is cut short; DeepSeek-V4-Flash has never been served on this box and is last,
# where a failure to load costs nothing that mattered.
$MODELS = @(
    @{ label='ornith';   ctx=131072; spec='';          file='D:\llamacpp-vulkan\models\ornith-1.0-35b-Q5_K_M.gguf' }
    @{ label='qwen38';   ctx=131072; spec='draft-mtp'; file='D:\llamacpp-vulkan\models\Qwen3.8-27B-UD-Q4_K_XL.gguf' }
    @{ label='qwen122b'; ctx=131072; spec='draft-mtp'; file='D:\llamacpp-vulkan\models\Qwen3.5-122B-A10B-UD-Q4_K_XL-00001-of-00003.gguf' }
    @{ label='laguna';   ctx=131072; spec='';          file='D:\llamacpp-vulkan\models\laguna-s-2.1-Q4_K_M.gguf' }
    @{ label='deepseek'; ctx=32768;  spec='';          file='D:\llamacpp-vulkan\models\DeepSeek-V4-Flash-UD-IQ2_M-00001-of-00003.gguf' }
)
if ($Only.Count) { $MODELS = $MODELS | Where-Object { $Only -contains $_.label } }

function Say([string]$m, [string]$c = 'Cyan') {
    $line = "[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $m
    Write-Host $line -ForegroundColor $c
    Add-Content -Path $log -Value $line -Encoding utf8
}

function Assert-GpuFree {
    # Kill anything left over, then confirm nothing still holds GPU memory. An exited process
    # can keep its committed pages briefly, so this waits rather than trusting the kill.
    Get-Process llama-server, llama-bench -EA SilentlyContinue | Stop-Process -Force -EA SilentlyContinue
    for ($i = 0; $i -lt 12; $i++) {
        Start-Sleep -Seconds 5
        $held = @()
        foreach ($s in (Get-Counter '\GPU Process Memory(*)\Total Committed' -EA SilentlyContinue).CounterSamples) {
            if ($s.CookedValue -gt 1GB) { $held += ('{0} {1:N1}GiB' -f $s.InstanceName, ($s.CookedValue / 1GB)) }
        }
        if (-not $held.Count) { return $true }
        Say ("waiting for GPU to drain: {0}" -f ($held -join ', ')) DarkYellow
    }
    Say "GPU never drained -- refusing to start the next model" Red
    return $false
}

function Assert-8080Free {
    if (Get-NetTCPConnection -LocalPort 8080 -State Listen -EA SilentlyContinue) {
        Say "ABORT: :8080 is serving. Refusing to benchmark against live traffic." Red
        return $false
    }
    return $true
}

Say "=== full bench: phase=$Phase seed=$Seed models=$(($MODELS.label) -join ',') ===" Yellow
Say "log -> $log" DarkGray

# ---- phase 0: speed -----------------------------------------------------------------------
# -ub 256 is not a default: it measured 167 t/s prefill against 129 at ub 1024 on this part,
# a 29% difference that comes entirely from fitting the ubatch into 32 KB of shared memory.
if ($Phase -in 'speed', 'all') {
    foreach ($m in $MODELS) {
        if (-not (Test-Path $m.file)) { Say ("SKIP speed {0}: file missing" -f $m.label) Yellow; continue }
        if (-not (Assert-8080Free)) { exit 2 }
        if (-not (Assert-GpuFree))  { exit 3 }
        Say ("--- speed: {0} ---" -f $m.label)
        $csv = Join-Path $outdir ("speed-{0}-{1}.json" -f $m.label, $stamp)
        & $bench -m $m.file -ngl 999 -fa 1 -ub 256 -b 2048 -p 512 -n 128 -d 0 -r 3 -o json 2>&1 |
            Tee-Object -FilePath $csv | Out-String -Stream | ForEach-Object { Add-Content $log $_ -Encoding utf8 }
        Say ("speed {0} -> {1}" -f $m.label, $csv) DarkGray
    }
}

# ---- phases 1 and 2: quality --------------------------------------------------------------
function Invoke-Suite($m, [string]$tasks, [switch]$WithTools, [string]$suffix) {
    if (-not (Test-Path $m.file)) { Say ("SKIP {0}: file missing" -f $m.label) Yellow; return }
    if (-not (Assert-8080Free)) { exit 2 }
    if (-not (Assert-GpuFree))  { exit 3 }

    $label = "{0}-{1}" -f $m.label, $suffix
    Say ("--- {0} ({1}) ---" -f $label, $tasks)
    $t0 = Get-Date
    # NAMED PARAMETERS. Splatting an array binds POSITIONALLY -- an earlier runner built
    # @('-Label','x',...) and splatted it, so Ctx received the string '-Model' and every model
    # died instantly with "Cannot convert value '-Model' to type System.Int32".
    $p = @{
        Label = $label; Model = $m.file; Ctx = $m.ctx; Port = $Port; Seed = $Seed
        Tasks = $tasks; Bind = '127.0.0.1'
    }
    if ($m.spec) { $p.Spec = $m.spec; $p.SpecNMax = 3 }
    if (-not $WithTools) { $p.SkipTools = $true }

    Push-Location $root
    & "$root\run-model-suite.ps1" @p 2>&1 | Out-String -Stream | ForEach-Object {
        Write-Host $_; Add-Content $log $_ -Encoding utf8
    }
    Pop-Location
    Say ("{0} took {1:N0} min" -f $label, ((Get-Date) - $t0).TotalMinutes) Green
}

if ($Phase -in 'hard', 'all') {
    Say "=== PHASE 1: HARD TIER (the discriminator) ===" Yellow
    foreach ($m in $MODELS) { Invoke-Suite $m $HARD -suffix 'hard' }
}

if ($Phase -in 'easy', 'all') {
    Say "=== PHASE 2: EASY TIER + TOOL CALLING (regression check) ===" Yellow
    foreach ($m in $MODELS) { Invoke-Suite $m $EASY -WithTools -suffix 'easy' }
}

Assert-GpuFree | Out-Null
Say "=== FULL BENCH DONE ===" Yellow
Say "results: $outdir  |  code jsonl: $root\code\results-code.jsonl" DarkGray
