<#
.SYNOPSIS
  Download a prebuilt llama.cpp Vulkan binary release into bin\.

.DESCRIPTION
  This is step zero. Everything else in this repo -- run-solo.ps1, the benchmarks, the eval
  harness -- calls bin\llama-server.exe, and nothing else here puts it there. Until now the
  README simply assumed you had it.

  Vulkan, not ROCm: on gfx1151 the Vulkan build measured 1.79x faster token generation, and
  the prebuilt Vulkan release works without installing a toolchain. You do not need to compile
  anything.

  Pinning matters. Benchmark numbers move between builds, so every result in this repo names
  the build it came from (currently b10431). -Build lets you reproduce against exactly that
  one rather than whatever is newest today.

.PARAMETER Build
  Build tag such as b10431. Default 'latest' resolves whatever GitHub currently publishes.

.PARAMETER Dest
  Where to unpack. Defaults to bin\ at the repo root.

.PARAMETER Force
  Overwrite an existing install instead of stopping.

.EXAMPLE
  .\scripts\windows\fetch-llamacpp.ps1
  .\scripts\windows\fetch-llamacpp.ps1 -Build b10431      # the build this repo's numbers use
#>
[CmdletBinding()]
param(
    [string] $Build = 'latest',
    [string] $Dest,
    [switch] $Force
)
$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'   # Invoke-WebRequest is ~10x slower with the bar on

if (-not $Dest) { $Dest = Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) 'bin' }

# TLS 1.2 is not the default in PowerShell 5.1 on older builds, and github.com refuses anything
# less -- the failure is an opaque "underlying connection was closed", so set it up front.
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$api = if ($Build -eq 'latest') {
    'https://api.github.com/repos/ggml-org/llama.cpp/releases/latest'
} else {
    "https://api.github.com/repos/ggml-org/llama.cpp/releases/tags/$Build"
}

Write-Host "querying $api" -ForegroundColor DarkGray
try {
    $rel = Invoke-RestMethod -Uri $api -Headers @{ 'User-Agent' = 'strix-halo-llm' }
} catch {
    throw "could not reach the GitHub releases API: $($_.Exception.Message)"
}

# Match on the asset name rather than a hardcoded filename: the naming has changed more than once
# (win-vulkan-x64, bin-win-vulkan-x64), and a hardcoded string turns a rename into a 404.
$asset = $rel.assets | Where-Object { $_.name -match 'win.*vulkan.*x64.*\.zip$' } | Select-Object -First 1
if (-not $asset) {
    Write-Host "no Windows Vulkan x64 asset in release $($rel.tag_name). Assets present:" -ForegroundColor Red
    $rel.assets | ForEach-Object { Write-Host "  $($_.name)" }
    throw "nothing to download"
}

Write-Host ("release {0}  ->  {1} ({2:N1} MB)" -f $rel.tag_name, $asset.name, ($asset.size / 1MB)) -ForegroundColor Cyan

if ((Test-Path (Join-Path $Dest 'llama-server.exe')) -and -not $Force) {
    Write-Host "$Dest already contains llama-server.exe -- re-run with -Force to replace it." -ForegroundColor Yellow
    exit 0
}

$tmp = Join-Path $env:TEMP $asset.name
Write-Host "downloading..." -ForegroundColor DarkGray
Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $tmp -UseBasicParsing

# Verify the byte count before unpacking. A truncated download unzips to a plausible-looking tree
# and then fails much later with a missing-DLL error that looks like a driver problem.
$got = (Get-Item $tmp).Length
if ($got -ne $asset.size) {
    Remove-Item $tmp -Force -EA SilentlyContinue
    throw "download is $got bytes, expected $($asset.size) -- discarded"
}

New-Item -ItemType Directory -Force -Path $Dest | Out-Null
Write-Host "unpacking -> $Dest" -ForegroundColor DarkGray
Expand-Archive -Path $tmp -DestinationPath $Dest -Force
Remove-Item $tmp -Force -EA SilentlyContinue

# Some releases nest everything under a build\bin\ directory; flatten it so the paths the rest of
# the repo uses (bin\llama-server.exe) are correct either way.
if (-not (Test-Path (Join-Path $Dest 'llama-server.exe'))) {
    $found = Get-ChildItem $Dest -Recurse -Filter 'llama-server.exe' -EA SilentlyContinue | Select-Object -First 1
    if ($found) {
        Write-Host "flattening $($found.DirectoryName)" -ForegroundColor DarkGray
        Get-ChildItem $found.DirectoryName -File | Move-Item -Destination $Dest -Force
    }
}

$srv = Join-Path $Dest 'llama-server.exe'
if (-not (Test-Path $srv)) { throw "unpacked, but no llama-server.exe under $Dest" }

Write-Host "`nchecking it runs and can see the GPU..." -ForegroundColor DarkGray
& $srv --version 2>&1 | Select-Object -First 6 | ForEach-Object { Write-Host "  $_" -ForegroundColor DarkGray }

Write-Host "`nllama.cpp $($rel.tag_name) is in $Dest" -ForegroundColor Green
Write-Host "next:  .\scripts\windows\fetch-models.ps1 -Only qwen38    then    .\scripts\windows\run-solo.ps1" -ForegroundColor Cyan
Write-Host "If the version banner above did not list a Vulkan device, your GPU driver is too old --" -ForegroundColor DarkGray
Write-Host "install the current AMD Adrenalin driver; nothing else in this repo will work until it does." -ForegroundColor DarkGray
