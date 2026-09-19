<#
.SYNOPSIS
  Measure speculative-decoding (token-prediction) speedup: baseline vs --spec-type.
  Generation-time feature, so uses llama-cli (not llama-bench).

.PARAMETER Spec
  Speculative method to test against baseline:
    draft-mtp   = Multi-Token Prediction (model GGUF must be an MTP-preserved variant)
    ngram-mod   = n-gram self-speculation (works on ANY model, great for code/repetitive text)
    draft-eagle3= EAGLE-3 (needs an eagle3 draft model via -DraftModel)

.PARAMETER NMax
  Draft depth(s) for --spec-draft-n-max. Pass a LIST to sweep: -NMax 1,2,3,4. Baseline is measured
  once and every depth is compared against it. **Depth is NOT monotonic** -- on Qwen3.8-27B n=3 peaked
  at 1.79x while n=5 collapsed to 0.68x, i.e. WORSE than no speculation. Always sweep, never assume
  a vendor's recommended depth is the local optimum.

.PARAMETER Bin
  Engine dir holding llama-cli.exe. Defaults to bin\ (the pinned b10431). New arches need a newer
  build -- e.g. -Bin .\bin-b11003 for nemotron_h_moe / qwen3next, which do NOT load in bin\ at all.

.EXAMPLE
  .\bench-spec.ps1 -Model .\models\Qwopus3.6-27B-Coder-MTP-Q8_0.gguf -Spec draft-mtp
  .\bench-spec.ps1 -Model .\models\gpt-oss-20b-mxfp4.gguf -Spec ngram-mod
  .\bench-spec.ps1 -Model .\models\Nemotron-3-Puzzle-75B-A9B-Q6_K.gguf -Bin .\bin-b11003 -NMax 1,2,3,4
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $Model,
    [string] $Spec = 'draft-mtp',
    [int[]]  $NMax = @(3),
    [int]    $NPredict = 256,
    [string] $DraftModel = '',
    [string] $Bin = '',
    [string] $Csv = '',
    [string] $Prompt = "Write a complete, well-documented Python implementation of an LRU cache class with get, put, and eviction. Then write 8 unit tests for it."
)
$repoRoot = $PSScriptRoot | Split-Path -Parent | Split-Path -Parent
if (-not $Bin) { $binDir = "$repoRoot\bin" }
elseif ([IO.Path]::IsPathRooted($Bin)) { $binDir = $Bin }
else { $binDir = Join-Path $repoRoot $Bin }
$bin = Join-Path $binDir 'llama-cli.exe'
if (-not (Test-Path $bin)) { Write-Error "llama-cli.exe not found: $bin"; exit 1 }
# Write prompt to a file so no spaced argument gets split by Start-Process.
$pf = "$($PSScriptRoot | Split-Path -Parent | Split-Path -Parent)\_prompt.txt"
Set-Content -Path $pf -Value $Prompt -Encoding UTF8 -NoNewline
function RunOne($extra,$label){
    # NB: '-no-cnv' was REMOVED from llama-cli (b11046 rejects it outright: "invalid argument: -no-cnv").
    # It used to sit here alongside '-st'. Because every run then died in <1 s and the t/s parser falls
    # back to 0, the whole 2026-09-19 sweep reported "0 t/s => 0x" for baseline AND all four depths --
    # and still printed a confident "best: n=3" plus the non-monotonic warning. '-st/--single-turn'
    # already gives the non-conversation behaviour that '-no-cnv' was there for.
    $a = @('-m',$Model,'-ngl','99','-fa','1','-n',"$NPredict",'-f',$pf,'--no-warmup','--simple-io','-st','--seed','42') + $extra
    $err = "$($PSScriptRoot | Split-Path -Parent | Split-Path -Parent)\spec_$label.err"
    $out = "$($PSScriptRoot | Split-Path -Parent | Split-Path -Parent)\spec_$label.out"
    Start-Process $bin -ArgumentList $a -NoNewWindow -Wait -RedirectStandardError $err -RedirectStandardOutput $out
    # --simple-io prints "[ Prompt: X t/s | Generation: Y t/s ]" to stdout
    $genline = (Get-Content $out -EA SilentlyContinue | Select-String 'Generation:\s*([\d\.]+)\s*t/s' | Select-Object -Last 1) -join ''
    $tps = if ($genline -match 'Generation:\s*([\d\.]+)\s*t/s') { [double]$Matches[1] }
           elseif ((Get-Content $err -EA SilentlyContinue | Out-String) -match '([\d\.]+)\s*tokens per second') { [double]$Matches[1] }
           else { 0 }
    $accept = (Get-Content $err -EA SilentlyContinue | Select-String 'accept|draft|n_drafted' | Select-Object -Last 2) -join '  '
    # FAIL LOUDLY on a dead run. 0 t/s is not a measurement, it is the parser's fallback when llama-cli
    # never produced a timing line -- which is what a rejected CLI flag looks like. Reporting it as a
    # ratio produced a fully-formed but entirely fictitious sweep on 2026-09-19. Never again.
    if ($tps -le 0) {
        $why = (Get-Content $err -EA SilentlyContinue | Select-String 'error|invalid|failed' | Select-Object -First 1)
        Write-Error ("[$label] produced NO timing line -- this is a harness/CLI failure, not a 0 t/s result. " +
                     "First error from llama-cli: " + $(if ($why) { $why.ToString().Trim() } else { '(none captured; see ' + $err + ')' }))
        exit 1
    }
    [pscustomobject]@{ Label=$label; Tps=[math]::Round($tps,2); Accept=$accept }
}
Write-Host "Model: $([IO.Path]::GetFileName($Model))   Spec: $Spec   Engine: $(Split-Path $binDir -Leaf)" -ForegroundColor Cyan
Write-Host ("Depths: {0}" -f ($NMax -join ', ')) -ForegroundColor Cyan

# Cold Vulkan compiles shaders/pipelines lazily, so the FIRST run of a session is slow for reasons
# that have nothing to do with speculation. Measuring baseline first without this would hand the
# baseline the entire compile cost and inflate EVERY speedup in the sweep. Discard one run first.
Write-Host "warming up (1 discarded run -- cold Vulkan pays shader compilation)..." -ForegroundColor DarkGray
RunOne @() 'warmup' | Out-Null

$base = RunOne @() 'baseline'
$rows = @([pscustomobject]@{ config='baseline'; n=''; tps=$base.Tps; mult=1.0 })
Write-Host ("baseline          : {0} t/s" -f $base.Tps) -ForegroundColor Gray

foreach ($n in $NMax) {
    $extra = @('--spec-type',$Spec,'--spec-draft-n-max',$n)
    if ($DraftModel) { $extra += @('--spec-draft-model',$DraftModel) }
    $s = RunOne $extra "spec_${Spec}_n$n"
    $mult = 0.0
    if ($base.Tps -gt 0) { $mult = [math]::Round($s.Tps / $base.Tps, 2) }
    $colour = 'Green'
    if ($mult -lt 1.0) { $colour = 'Red' }   # slower than no speculation at all -- the n=5 trap
    Write-Host ("{0,-12} n={1,-3}: {2} t/s   => {3}x" -f $Spec,$n,$s.Tps,$mult) -ForegroundColor $colour
    if ($s.Accept) { Write-Host ("    draft/accept: {0}" -f $s.Accept) -ForegroundColor DarkGray }
    $rows += [pscustomobject]@{ config=$Spec; n=$n; tps=$s.Tps; mult=$mult }
}

Write-Host "`n--- summary (engine $(Split-Path $binDir -Leaf), greedy, seed 42, n_predict $NPredict) ---" -ForegroundColor Cyan
$rows | Format-Table -AutoSize | Out-String -Width 120 | Write-Host
$best = $rows | Sort-Object tps -Descending | Select-Object -First 1
Write-Host ("best: {0} n={1} at {2} t/s ({3}x)" -f $best.config,$best.n,$best.tps,$best.mult) -ForegroundColor Green
if (($rows | Where-Object { $_.mult -lt 1.0 })) {
    Write-Host "NOTE: at least one depth is SLOWER than no speculation -- depth is not monotonic; do not extrapolate upward." -ForegroundColor Yellow
}
if ($Csv) { $rows | Export-Csv $Csv -NoTypeInformation; Write-Host "csv -> $Csv" -ForegroundColor DarkGray }
