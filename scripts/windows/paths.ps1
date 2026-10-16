<#
  paths.ps1 -- the ONE place that knows where the serving system's parts live. Dot-source it:

      . (Join-Path $PSScriptRoot 'paths.ps1')           # from scripts\windows\
      . (Join-Path $PSScriptRoot '..\paths.ps1')        # from scripts\windows\legacy\
      . "$PSScriptRoot\..\scripts\windows\paths.ps1"    # from evals\

  Layout (everything under the checkout root; only scripts\, docs\, evals\ harness code are tracked):

      engines\llama.cpp\<build>\              llama-server.exe, llama-bench.exe, llama-cli.exe  (fetch-llamacpp.ps1)
      engines\stable-diffusion.cpp\<build>\   sd-server.exe, sd-cli.exe                          (image server)
      engines\poolside\                       poolside's llama.cpp fork                          (build-poolside.ps1)
      models\llm\                             LLM GGUFs, their draft models and mmproj files     (fetch-models.ps1)
      models\image\                           image / video weights, encoders, VAEs, and
                                              loras\ upscalers\ detectors\ embeddings\
      logs\llm\ images\ bench\ downloads\     server, benchmark and download logs
      outputs\                                generated images / edits / videos
      private\                                the private image/video server (its own repo)

  Overrides: $env:MODELS_DIR (LLM models), $env:IMAGE_MODELS_DIR (image models).
  The OLD locations (bin\, bin-<build>\, a flat models\, C:\llm-router\models) still resolve, so a script
  keeps working on a box that has not been reorganised; scripts\windows\check-layout.ps1 reports them.
  PowerShell 5.1: no ternary, no ??, no &&.
#>

$StrixRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
if ((Split-Path $PSScriptRoot -Leaf) -eq 'legacy') { $StrixRoot = Split-Path $StrixRoot -Parent }
if (-not (Test-Path (Join-Path $StrixRoot 'scripts\windows\paths.ps1'))) {
    # dot-sourced from evals\ or elsewhere: walk up until the checkout root is found
    $d = $PSScriptRoot
    while ($d -and -not (Test-Path (Join-Path $d 'scripts\windows\paths.ps1'))) { $d = Split-Path $d -Parent }
    if ($d) { $StrixRoot = $d }
}

# The published numbers were measured on this build; "bin" / "" mean it.
$StrixDefaultLlamaBuild = 'b10431'
$StrixDefaultSdBuild    = 'master-967-e47426c'

function Get-StrixEngine {
    <# An engine directory. -Name accepts: '' / 'bin' (the default build), 'b11414', 'bin-b11414', '.\bin-b11414',
       'engines\llama.cpp\b11414', 'master-968-8cd731e', 'bin-sd-master-968-8cd731e', 'poolside', or a full path.
       -Kind: llama.cpp (default) | stable-diffusion.cpp | poolside. Throws if nothing matches. #>
    param([string] $Name = '', [string] $Kind = 'llama.cpp', [switch] $Quiet)
    $n = ($Name -replace '^\.[\\/]', '').TrimEnd('\', '/')
    if ($n -and [IO.Path]::IsPathRooted($n)) { if (Test-Path $n) { return (Resolve-Path $n).Path } ; throw "engine not found: $n" }
    if ($n -match '^engines[\\/]') { $p = Join-Path $StrixRoot $n; if (Test-Path $p) { return $p }; throw "engine not found: $p" }
    if ($n -match '^(bin-)?sd-' -or $n -match '^master-\d') { $Kind = 'stable-diffusion.cpp' }
    if ($n -match '^(bin-)?poolside$') { $Kind = 'poolside' }
    $build = $n -replace '^bin-sd-', '' -replace '^bin-', ''
    if (-not $build -or $build -eq 'bin') { $build = if ($Kind -eq 'stable-diffusion.cpp') { $StrixDefaultSdBuild } else { $StrixDefaultLlamaBuild } }
    $cands = @()
    if ($Kind -eq 'poolside') { $cands += (Join-Path $StrixRoot 'engines\poolside'), (Join-Path $StrixRoot 'bin-poolside') }
    elseif ($Kind -eq 'stable-diffusion.cpp') { $cands += (Join-Path $StrixRoot "engines\stable-diffusion.cpp\$build"), (Join-Path $StrixRoot "bin-sd-$build") }
    else {
        $cands += (Join-Path $StrixRoot "engines\llama.cpp\$build"), (Join-Path $StrixRoot "bin-$build")
        if ($build -eq $StrixDefaultLlamaBuild) { $cands += (Join-Path $StrixRoot 'bin') }
    }
    foreach ($c in $cands) { if (Test-Path $c) { return $c } }
    if ($Quiet) { return $cands[0] }
    throw "engine '$Name' not found (looked in: $($cands -join '; ')). Fetch it: scripts\windows\fetch-llamacpp.ps1 -Build $build"
}

function Get-StrixModelsDir {
    <# The models folder for 'llm' (default) or 'image'. Env overrides win; then models\<kind>; then the old flat models\. #>
    param([ValidateSet('llm', 'image')] [string] $Kind = 'llm')
    $env1 = if ($Kind -eq 'llm') { $env:MODELS_DIR } else { $env:IMAGE_MODELS_DIR }
    if ($env1) { return $env1 }
    $p = Join-Path $StrixRoot "models\$Kind"
    if (Test-Path $p) { return $p }
    return (Join-Path $StrixRoot 'models')
}

function Find-StrixModel {
    <# Full path of a weight file by NAME (or a full path), searched in models\llm, models\image, the old flat
       models\ and C:\llm-router\models. Returns the models\<kind> path (missing) when nowhere, so a caller's
       "file not found" message points at where it SHOULD be. #>
    param([Parameter(Mandatory)] [string] $File, [ValidateSet('llm', 'image')] [string] $Kind = 'llm')
    if ([IO.Path]::IsPathRooted($File) -and (Test-Path $File)) { return $File }
    $name = Split-Path $File -Leaf
    foreach ($d in @((Get-StrixModelsDir $Kind), (Join-Path $StrixRoot 'models\llm'), (Join-Path $StrixRoot 'models\image'),
                     (Join-Path $StrixRoot 'models'), 'C:\llm-router\models')) {
        $p = Join-Path $d $name
        if (Test-Path $p) { return $p }
    }
    return (Join-Path (Get-StrixModelsDir $Kind) $name)
}

function Get-StrixLogDir {
    <# logs\<kind> (llm | images | bench | evals | downloads), created on first use. #>
    param([ValidateSet('llm', 'images', 'bench', 'evals', 'downloads')] [string] $Kind = 'llm')
    $p = Join-Path $StrixRoot "logs\$Kind"
    New-Item -ItemType Directory -Force -Path $p | Out-Null
    return $p
}
