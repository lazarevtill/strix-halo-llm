<#
.SYNOPSIS
  Build poolside's llama.cpp fork (branch `laguna`) with the Vulkan backend, for DFlash
  speculative decoding on Laguna-S-2.1.

.DESCRIPTION
  WHY BUILD AT ALL: upstream b10182 lists `draft-dflash` in --spec-type, but loading poolside's
  draft GGUF against it fails with
      done_getting_tensors: wrong number of tensors; expected 76, got 69
  The upstream enum entry does not match poolside's actual DFlash tensor layout. Their fork carries
  the real implementation ("block-diffusion drafting with a draft-side KV cache injection", in
  common/speculative.cpp). poolside publishes NO release binaries, so source is the only route.

  WHY IT MATTERS: Laguna Q4_K_M measured 14.1 t/s here (slower than Qwen3.5-122B despite fewer
  active params -- its 256-expert routing hits the known gfx1151 MUL_MAT_ID weakness). poolside run
  DFlash with `--spec-draft-n-max 15` vs llama.cpp's default 3, which implies a high acceptance rate.
  If it delivers even 2x, Laguna goes from unusable to competitive.

  The fork keeps laguna + deepseek4 + qwen35moe + glm-dsa arches (only `minimax` is missing, which
  does not fit this box anyway), so it can serve every model we have.

  BUILDS INTO A SIBLING DIR. Does not touch D:\llamacpp-vulkan\bin (b10182 production) or
  bin-b9771 (rollback). Compare, then choose.

.EXAMPLE
  .\build-poolside.ps1              # configure + build + stage into bin-poolside\
  .\build-poolside.ps1 -Clean       # wipe the build dir first
#>
[CmdletBinding()]
param(
    [string] $Src  = 'D:\src\llama.cpp-poolside',
    [string] $Dest = 'D:\llamacpp-vulkan\bin-poolside',
    [switch] $Clean,
    [int]    $Jobs = 0            # 0 = let cmake decide
)
$ErrorActionPreference = 'Stop'

if (-not (Test-Path $Src)) { Write-Error "source not found: $Src (git clone --branch laguna https://github.com/poolsideai/llama.cpp $Src)"; exit 1 }

# ---- locate the MSVC environment ---------------------------------------------------------------
$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
if (-not (Test-Path $vswhere)) { Write-Error "vswhere not found -- Visual Studio Build Tools not installed."; exit 1 }
$vsPath = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
if (-not $vsPath) { Write-Error "No MSVC C++ toolset found. Install Microsoft.VisualStudio.2022.BuildTools with the VCTools workload."; exit 1 }
$vcvars = Join-Path $vsPath 'VC\Auxiliary\Build\vcvars64.bat'
if (-not (Test-Path $vcvars)) { Write-Error "vcvars64.bat missing under $vsPath"; exit 1 }
Write-Host "MSVC: $vsPath" -ForegroundColor DarkGray

# ---- Vulkan SDK --------------------------------------------------------------------------------
$vk = $env:VULKAN_SDK
if (-not $vk) {
    $cand = Get-ChildItem 'C:\VulkanSDK' -Directory -EA SilentlyContinue | Sort-Object Name -Descending | Select-Object -First 1
    if ($cand) { $vk = $cand.FullName }
}
if (-not $vk -or -not (Test-Path (Join-Path $vk 'Bin\glslc.exe'))) {
    Write-Error "Vulkan SDK not found (need glslc.exe). Install KhronosGroup.VulkanSDK, then re-open the shell so VULKAN_SDK is set."
    exit 1
}
Write-Host "Vulkan SDK: $vk" -ForegroundColor DarkGray

# Resolve cmake/ninja ABSOLUTELY. A shell open before the winget install has a stale PATH, and
# ninja lands in a WinGet Packages dir that may not be on PATH at all -- so bare names fail
# spuriously even though both are installed.
$cmakeExe = (Get-Command cmake -EA SilentlyContinue).Source
if (-not $cmakeExe) { $cmakeExe = 'C:\Program Files\CMake\bin\cmake.exe' }
if (-not (Test-Path $cmakeExe)) { Write-Error "cmake not found (install Kitware.CMake)"; exit 1 }

$ninjaExe = (Get-Command ninja -EA SilentlyContinue).Source
if (-not $ninjaExe) {
    $ninjaExe = Get-ChildItem "$env:LOCALAPPDATA\Microsoft\WinGet\Packages" -Recurse -Filter 'ninja.exe' -EA SilentlyContinue |
                Select-Object -First 1 -Expand FullName
}
if (-not $ninjaExe -or -not (Test-Path $ninjaExe)) { Write-Error "ninja not found (install Ninja-build.Ninja)"; exit 1 }
Write-Host "cmake: $cmakeExe" -ForegroundColor DarkGray
Write-Host "ninja: $ninjaExe" -ForegroundColor DarkGray

$build = Join-Path $Src 'build'
if ($Clean -and (Test-Path $build)) { Write-Host "cleaning $build" -ForegroundColor Yellow; Remove-Item $build -Recurse -Force }

# GGML_NATIVE=ON lets it use this Zen5 host's ISA. LLAMA_CURL=OFF avoids a libcurl dependency we
# do not need (models are fetched by fetch-models.ps1, not by llama.cpp).
$cfgArgs = @(
    '-S', $Src, '-B', $build, '-G', 'Ninja',
    '-DCMAKE_BUILD_TYPE=Release',
    '-DGGML_VULKAN=ON',
    '-DGGML_NATIVE=ON',
    '-DLLAMA_CURL=OFF',
    '-DLLAMA_BUILD_TESTS=OFF',
    '-DLLAMA_BUILD_EXAMPLES=OFF',
    "-DCMAKE_MAKE_PROGRAM=`"$ninjaExe`"",
    "-DVulkan_GLSLC_EXECUTABLE=`"$vk\Bin\glslc.exe`""
) -join ' '

$buildArgs = if ($Jobs -gt 0) { "--build $build -j $Jobs" } else { "--build $build" }

# Everything must run inside the vcvars environment, so shell out through cmd once.
$script = @"
call "$vcvars" >nul
set VULKAN_SDK=$vk
set PATH=%PATH%;$(Split-Path $ninjaExe);$vk\Bin
echo === CONFIGURE ===
"$cmakeExe" $cfgArgs || exit /b 1
echo === BUILD ===
"$cmakeExe" $buildArgs || exit /b 1
"@
$tmp = Join-Path $env:TEMP 'build-poolside.cmd'
Set-Content -Path $tmp -Value $script -Encoding ASCII

Write-Host "`nBuilding (this takes a while -- Vulkan shader compilation dominates)..." -ForegroundColor Cyan
$sw = [Diagnostics.Stopwatch]::StartNew()
& cmd.exe /c $tmp
$code = $LASTEXITCODE
$sw.Stop()
if ($code -ne 0) { Write-Error "build failed (exit $code) after $([math]::Round($sw.Elapsed.TotalMinutes,1)) min"; exit $code }
Write-Host ("build OK in {0:N1} min" -f $sw.Elapsed.TotalMinutes) -ForegroundColor Green

# ---- stage the binaries ------------------------------------------------------------------------
New-Item -ItemType Directory -Force $Dest | Out-Null
$bin = Join-Path $build 'bin'
if (-not (Test-Path $bin)) { $bin = $build }
Copy-Item (Join-Path $bin '*.exe') $Dest -Force -EA SilentlyContinue
Copy-Item (Join-Path $bin '*.dll') $Dest -Force -EA SilentlyContinue
Write-Host ("staged {0} files -> {1}" -f (Get-ChildItem $Dest -File).Count, $Dest) -ForegroundColor Cyan

$srv = Join-Path $Dest 'llama-server.exe'
if (Test-Path $srv) {
    Write-Host "`n=== version ===" -ForegroundColor Cyan
    & $srv --version 2>&1 | Select-String 'version|built' | ForEach-Object { "  " + $_.Line.Trim() }
    Write-Host "=== spec-type options (expect draft-dflash) ===" -ForegroundColor Cyan
    & $srv --help 2>&1 | Select-String 'spec-type' | ForEach-Object { "  " + $_.Line.Trim() }
} else {
    Write-Warning "llama-server.exe not found in $bin -- check the build output layout."
}

Write-Host "`nNext: serve Laguna with DFlash (poolside run n-max 15, not the default 3):" -ForegroundColor Green
Write-Host "  $Dest\llama-server.exe -m D:\llamacpp-vulkan\models\laguna-s-2.1-Q4_K_M.gguf ``" -ForegroundColor DarkGray
Write-Host "    -md D:\llamacpp-vulkan\models\laguna-s-2.1-DFlash-BF16.gguf ``" -ForegroundColor DarkGray
Write-Host "    --spec-type draft-dflash --spec-draft-n-max 15 ``" -ForegroundColor DarkGray
Write-Host "    -ngl 999 -c 131072 -fa on -lm none --jinja --parallel 1 --port 8080" -ForegroundColor DarkGray
