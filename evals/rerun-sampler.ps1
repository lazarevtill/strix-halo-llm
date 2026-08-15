<#
.SYNOPSIS
  Serve qwen38 exactly as the sweep did, re-run the two looped tasks with anti-repetition sampling,
  then stop the server.

.DESCRIPTION
  Tests one thing: whether qwen38's 0/27 and 0/37 were the model or our sampler configuration.
  See evals/rerun-sampler.py for the argument, and evals/README.md bug 13 for the evidence.

  THE SERVER FLAGS DELIBERATELY MATCH run-model-suite.ps1 EXACTLY, including --ubatch-size 1024.
  1024 is NOT the measured-optimal 256 -- that is a real inefficiency in the eval path, worth
  fixing separately. It is kept here because changing it would alter prefill timing in the same
  run that changes the sampler, and then neither result would mean anything. One variable.

  The control is the existing `qwen38-hard` row: same model, seed, temperature and flags, with no
  anti-repetition. No control arm is run, which is what keeps this to about an hour.

.PARAMETER Label
  Result label. Must be new -- the python script refuses to overwrite transcripts.

.EXAMPLE
  .\evals\rerun-sampler.ps1
  .\evals\rerun-sampler.ps1 -DryAllowedLength 4 -Label qwen38-dry4
#>
[CmdletBinding()]
param(
    [string] $Label   = 'qwen38-drytest',
    [string] $Tasks   = 'hard_semver,hard_where',
    [string] $Model   = 'D:\llamacpp-vulkan\models\Qwen3.8-27B-UD-Q4_K_XL.gguf',
    [int]    $Ctx     = 131072,
    [int]    $Port    = 8099,
    [string] $Bind    = '127.0.0.1',
    [double] $DryMultiplier    = 0.8,
    [int]    $DryAllowedLength = 8,
    [double] $RepeatPenalty    = 1.0,
    [double] $Temp    = 0.3,
    [int]    $Seed    = 42
)
$ErrorActionPreference = 'Stop'
$bin  = 'D:\llamacpp-vulkan\bin\llama-server.exe'
$root = Split-Path $PSScriptRoot -Parent

# ---- the GPU must be empty ----------------------------------------------------------------------
# A second resident model does not merely slow this down; on unified memory it changes what fits,
# and a contended measurement is not slightly wrong, it is meaningless. The sweep enforces the same
# rule -- this is not a place to be clever.
$busy = Get-Process -Name llama-server -ErrorAction SilentlyContinue
if ($busy) {
    Write-Host "REFUSING TO RUN -- llama-server is already up:" -ForegroundColor Red
    $busy | ForEach-Object {
        Write-Host ("  pid={0} started={1}" -f $_.Id, $_.StartTime) -ForegroundColor Red }
    Write-Host "Wait for the sweep to finish, or stop it deliberately. Do not run both." -ForegroundColor Red
    exit 2
}

if (-not (Test-Path $Model)) { throw "model not found: $Model" }

# ---- serve: byte-for-byte the sweep's flags ------------------------------------------------------
$env:GGML_VK_ENABLE_MEMORY_PRIORITY = '1'
$a = @('-m',$Model,'-ngl','999','--ctx-size',"$Ctx",'--batch-size','2048','--ubatch-size','1024',
       '-fa','on','-lm','none','--jinja','--parallel','1','--host',$Bind,'--port',"$Port",
       '--no-warmup','--cache-type-k','q8_0','--cache-type-v','q8_0',
       '--reasoning','auto','--reasoning-preserve',
       '--spec-type','draft-mtp','--spec-draft-n-max','3')

Write-Host "=== $Label ===" -ForegroundColor Cyan
Write-Host ("serving {0}  ctx={1}  spec=draft-mtp/3  ub=1024 (matches the sweep)" -f `
            (Split-Path $Model -Leaf), $Ctx) -ForegroundColor DarkGray
$proc = Start-Process $bin -ArgumentList $a -WindowStyle Minimized -PassThru

try {
    $sw = [Diagnostics.Stopwatch]::StartNew(); $ok = $false
    while ($sw.Elapsed.TotalSeconds -lt 600) {
        try {
            if ((Invoke-RestMethod "http://127.0.0.1:$Port/health" -TimeoutSec 5).status -eq 'ok') {
                $ok = $true; break }
        } catch { Start-Sleep -Seconds 3 }
    }
    if (-not $ok) { throw "server never became healthy after $([int]$sw.Elapsed.TotalSeconds)s" }
    Write-Host ("ready in {0}s" -f [int]$sw.Elapsed.TotalSeconds) -ForegroundColor Green

    $py = @(
        (Join-Path $PSScriptRoot 'rerun-sampler.py')
        '--endpoint', "http://127.0.0.1:$Port/v1"
        '--label',    $Label
        '--tasks',    $Tasks
        '--temp',     "$Temp"
        '--seed',     "$Seed"
        '--dry-multiplier',     "$DryMultiplier"
        '--dry-allowed-length', "$DryAllowedLength"
        '--repeat-penalty',     "$RepeatPenalty"
    )
    & python $py 2>&1 | Write-Host
}
finally {
    Write-Host "`nstopping $Label" -ForegroundColor DarkGray
    if ($proc -and -not $proc.HasExited) { $proc.Kill(); $proc.WaitForExit(30000) | Out-Null }
}
Write-Host "=== $Label DONE ===" -ForegroundColor Green
Write-Host "compare against the qwen38-hard row: python evals/rescore.py --tier hard" -ForegroundColor Cyan
