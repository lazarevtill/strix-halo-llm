<#
.SYNOPSIS
  Download a GGUF model from Hugging Face into .\models\ (standard GGUF — loads in stock llama.cpp).
.EXAMPLE
  .\download-model.ps1 -Repo ggml-org/gpt-oss-120b-GGUF -File gpt-oss-120b-mxfp4-00001-of-00003.gguf
  .\download-model.ps1 -Repo unsloth/Qwen3-30B-A3B-GGUF -File Qwen3-30B-A3B-Q4_K_M.gguf
.NOTES
  Use standard community GGUFs (ggml-org, unsloth, bartowski) — NOT Ollama's blobs, which use
  Ollama-specific architecture names (gptoss/gemma4/qwen3.6) that upstream llama.cpp can't load.
  For split GGUFs, download every -0000N-of-0000M part into models\; llama.cpp auto-joins them.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $Repo,
    [Parameter(Mandatory)] [string] $File,
    [string] $Branch = 'main'
)
$out = "$PSScriptRoot\models\$([System.IO.Path]::GetFileName($File))"
$url = "https://huggingface.co/$Repo/resolve/$Branch/$File"
Write-Host "Downloading $url" -ForegroundColor Green
$ProgressPreference='SilentlyContinue'
$sw=[Diagnostics.Stopwatch]::StartNew()
Invoke-WebRequest $url -OutFile $out -UseBasicParsing
$sw.Stop()
Write-Host ("Done: {0} GB in {1} min -> {2}" -f [math]::Round((Get-Item $out).Length/1GB,2),[math]::Round($sw.Elapsed.TotalMinutes,1),$out) -ForegroundColor Cyan
