<#
.SYNOPSIS
  Benchmark a GGUF model on the Vulkan backend (prompt-processing pp + token-gen tg t/s).
.EXAMPLE
  .\bench.ps1                                       # benches the default gpt-oss-20b
  .\bench.ps1 -Model .\models\Qwen3-30B-A3B-Q4_K_M.gguf
#>
[CmdletBinding()]
param(
    [string] $Model = "$PSScriptRoot\models\gpt-oss-20b-mxfp4.gguf",
    [int]    $NGL   = 999
)
$bench = "$PSScriptRoot\bin\llama-bench.exe"
$out = "$PSScriptRoot\bench-$([System.IO.Path]::GetFileNameWithoutExtension($Model)).txt"
Start-Process -FilePath $bench -ArgumentList @('-m',$Model,'-ngl',$NGL) -NoNewWindow -Wait `
  -RedirectStandardOutput $out -RedirectStandardError "$out.err"
Write-Host "===== Vulkan benchmark: $([System.IO.Path]::GetFileName($Model)) ====="
Get-Content $out
if ((Get-Item $out).Length -lt 200) { Write-Host "(load error — see $out.err)" -ForegroundColor Yellow; Get-Content "$out.err" | Select-Object -Last 5 }
