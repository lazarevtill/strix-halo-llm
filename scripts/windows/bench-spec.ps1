<#
.SYNOPSIS
  Measure speculative-decoding (token-prediction) speedup: baseline vs --spec-type.
  Generation-time feature, so uses llama-cli (not llama-bench).

.PARAMETER Spec
  Speculative method to test against baseline:
    draft-mtp   = Multi-Token Prediction (model GGUF must be an MTP-preserved variant)
    ngram-mod   = n-gram self-speculation (works on ANY model, great for code/repetitive text)
    draft-eagle3= EAGLE-3 (needs an eagle3 draft model via -DraftModel)

.EXAMPLE
  .\bench-spec.ps1 -Model .\models\Qwopus3.6-27B-Coder-MTP-Q8_0.gguf -Spec draft-mtp
  .\bench-spec.ps1 -Model .\models\gpt-oss-20b-mxfp4.gguf -Spec ngram-mod
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $Model,
    [string] $Spec = 'draft-mtp',
    [int]    $NMax = 3,
    [int]    $NPredict = 256,
    [string] $DraftModel = '',
    [string] $Prompt = "Write a complete, well-documented Python implementation of an LRU cache class with get, put, and eviction. Then write 8 unit tests for it."
)
$bin = "$($PSScriptRoot | Split-Path -Parent | Split-Path -Parent)\bin\llama-cli.exe"
# Write prompt to a file so no spaced argument gets split by Start-Process.
$pf = "$($PSScriptRoot | Split-Path -Parent | Split-Path -Parent)\_prompt.txt"
Set-Content -Path $pf -Value $Prompt -Encoding UTF8 -NoNewline
function RunOne($extra,$label){
    $a = @('-m',$Model,'-ngl','99','-fa','1','-n',"$NPredict",'-f',$pf,'--no-warmup','-no-cnv','--simple-io','-st','--seed','42') + $extra
    $err = "$($PSScriptRoot | Split-Path -Parent | Split-Path -Parent)\spec_$label.err"
    $out = "$($PSScriptRoot | Split-Path -Parent | Split-Path -Parent)\spec_$label.out"
    Start-Process $bin -ArgumentList $a -NoNewWindow -Wait -RedirectStandardError $err -RedirectStandardOutput $out
    # --simple-io prints "[ Prompt: X t/s | Generation: Y t/s ]" to stdout
    $genline = (Get-Content $out -EA SilentlyContinue | Select-String 'Generation:\s*([\d\.]+)\s*t/s' | Select-Object -Last 1) -join ''
    $tps = if ($genline -match 'Generation:\s*([\d\.]+)\s*t/s') { [double]$Matches[1] }
           elseif ((Get-Content $err -EA SilentlyContinue | Out-String) -match '([\d\.]+)\s*tokens per second') { [double]$Matches[1] }
           else { 0 }
    $accept = (Get-Content $err -EA SilentlyContinue | Select-String 'accept|draft|n_drafted' | Select-Object -Last 2) -join '  '
    [pscustomobject]@{ Label=$label; Tps=[math]::Round($tps,2); Accept=$accept }
}
Write-Host "Model: $([IO.Path]::GetFileName($Model))   Spec: $Spec" -ForegroundColor Cyan
$base = RunOne @() 'baseline'
$extra = @('--spec-type',$Spec,'--spec-draft-n-max',$NMax)
if ($DraftModel) { $extra += @('--spec-draft-model',$DraftModel) }
$spec = RunOne $extra "spec_$Spec"
$mult = if ($base.Tps -gt 0) { [math]::Round($spec.Tps/$base.Tps,2) } else { 0 }
Write-Host ""
Write-Host ("baseline        : {0} t/s" -f $base.Tps) -ForegroundColor Gray
Write-Host ("{0,-15} : {1} t/s   => {2}x speedup" -f $Spec,$spec.Tps,$mult) -ForegroundColor Green
if ($spec.Accept) { Write-Host ("draft/accept: {0}" -f $spec.Accept) -ForegroundColor DarkGray }
