<#
.SYNOPSIS
  Safely test-load a pending next-gen model on an ISOLATED port with a separate engine build, and
  run the Vulkan-correctness check that is actually feasible on this box.

.DESCRIPTION
  For the "not yet runnable" models in docs/ROADMAP.md (Flash-Next qwen4exp, GLM glm5_next, and the
  DFlash2 draft). Given an engine dir (e.g. bin-b10665) and a GGUF, it:

    1. reads the GGUF's arch and confirms THIS engine actually knows it (else aborts) -- a merge is
       not a release; a release is not Vulkan-correct;
    2. decides co-residency: if the model can't fit alongside the live :8080 router under the ~109 GB
       ceiling, it STOPS the router first and ALWAYS RESTARTS it afterwards (try/finally) -- the
       Startup-folder autostart only fires at logon, so an aborted test must not leave the box
       serverless;
    3. loads the model on an isolated port (default :8099) with the tuned flags;
    4. runs the #27805 Vulkan-correctness check that is POSSIBLE here: a full CPU reference is
       infeasible (87-93 GB GGUF vs ~32 GB system RAM), so instead it fires ONE fixed-seed / temp-0
       raw completion N times and diffs -- byte-identical = safe, any divergence = silent corruption
       (this is the exact #27805 signature; plain draft-mtp passed it 6/6 on 2026-08-28);
    5. prints a sample of the output to eyeball, tears down the test server, restarts the router.

  It NEVER edits the live router config or the pinned b10431 engine. It is a measurement tool.

.EXAMPLE
  # Flash-Next (needs router down -- 87 GB can't co-reside):
  .\stage-nextgen.ps1 -Bin .\bin-b10665 -Model .\models\Qwen3.8-Flash-Next-UD-IQ4_XS-00001-of-00003.gguf

  # DFlash2 draft as a speculative draft for qwen38 (small -- co-resides), once #27805 is fixed.
  # NOTE: --model-draft / draft-dflash are this script's reading of the model card's -hfd usage,
  # UNVERIFIED on llama.cpp (untestable until #27805 lands). Confirm the flag names against the
  # engine's --help before trusting this line.
  .\stage-nextgen.ps1 -Bin .\bin-<build> -Model .\models\Qwen3.8-27B-UD-Q4_K_XL.gguf `
      -Draft .\models\Qwen3.8-27B-DFlash2-Q4_K_M.gguf -SpecType draft-dflash
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $Bin,        # engine dir containing llama-server.exe + llama.dll
    [Parameter(Mandatory)][string] $Model,      # GGUF to load (shard-1 for a multi-shard model)
    [int]    $Port     = 8099,
    [int]    $Runs     = 12,
    [int]    $Ctx      = 8192,                   # modest ctx -- this is a load + determinism test, not a bench
    [string] $Draft    = '',                     # optional draft GGUF (e.g. DFlash2)
    [string] $SpecType = '',                     # e.g. draft-dflash / draft-mtp
    [int]    $NPredict = 128,
    [int]    $CeilingGB = 100                    # leave ~9 GB slack under the ~109 GB ceiling
)
$ErrorActionPreference = 'Stop'
$repoRoot = $PSScriptRoot | Split-Path -Parent | Split-Path -Parent
$srv = Join-Path $Bin 'llama-server.exe'
$dll = Join-Path $Bin 'llama.dll'
if (-not (Test-Path $srv)) { Write-Error "no llama-server.exe in $Bin"; exit 1 }
if (-not (Test-Path $Model)) { Write-Error "model not found: $Model"; exit 1 }

function Get-GgufArch([string]$path) {
    $fs = [IO.File]::Open($path, 'Open', 'Read', 'ReadWrite')
    $buf = New-Object byte[] 262144
    $n = $fs.Read($buf, 0, $buf.Length); $fs.Close()
    $txt = [Text.Encoding]::ASCII.GetString($buf, 0, $n)
    $key = 'general.architecture'; $i = $txt.IndexOf($key)
    if ($i -lt 0) { return '(unknown)' }
    $len = [BitConverter]::ToUInt32($buf, $i + $key.Length + 4)
    if ($len -gt 0 -and $len -lt 40) { return [Text.Encoding]::ASCII.GetString($buf, $i + $key.Length + 12, $len) }
    return '(unknown)'
}
function Committed-GB {
    $s = (Get-Counter '\GPU Process Memory(*)\Total Committed' -EA SilentlyContinue).CounterSamples
    if (-not $s) { return 0 }
    return (($s | Measure-Object CookedValue -Sum).Sum / 1GB)
}

# ---- 1. arch known to THIS engine? --------------------------------------------------------------
$arch = Get-GgufArch $Model
$dllTxt = [Text.Encoding]::ASCII.GetString([IO.File]::ReadAllBytes($dll))
$archOk = $dllTxt.Contains("models/$arch.cpp") -or ($dllTxt -match [regex]::Escape($arch))
Write-Host ("model arch : {0}" -f $arch) -ForegroundColor Cyan
Write-Host ("engine     : {0} ({1})" -f $Bin, $(if ($archOk) { "knows '$arch'  OK" } else { "does NOT know '$arch'" }))
if (-not $archOk) { Write-Error "engine $Bin cannot load arch '$arch' -- fetch a build that includes it first."; exit 1 }

# ---- 2. co-residency decision -------------------------------------------------------------------
# sum on-disk size of the model (all shards sharing the -0000N-of- stem)
$mi = Get-Item $Model
$shardGlob = ($mi.Name -replace '-0*\d+-of-\d+\.gguf$', '')
$modelGB = ((Get-ChildItem $mi.Directory -Filter ($shardGlob + '*') -EA SilentlyContinue | Measure-Object Length -Sum).Sum) / 1GB
if ($modelGB -le 0) { $modelGB = $mi.Length / 1GB }
if ($Draft -and (Test-Path $Draft)) { $modelGB += (Get-Item $Draft).Length / 1GB }
$routerGB = Committed-GB
$needStop = ($modelGB + $routerGB + 2) -gt $CeilingGB
Write-Host ("model ~{0:N1} GB  +  resident ~{1:N1} GB  ->  {2}" -f $modelGB, $routerGB, $(if ($needStop) { "STOP router first (won't co-reside)" } else { "co-resident OK" })) -ForegroundColor Yellow

$stoppedRouter = $false
$testPid = $null
try {
    if ($needStop) {
        $running = @(Get-Process llama-server -EA SilentlyContinue)
        foreach ($p in $running) {
            $busy = 0
            try { $busy = @((Invoke-RestMethod "http://127.0.0.1:8080/slots" -TimeoutSec 3) | Where-Object { $_.is_processing }).Count } catch {}
            if ($busy -gt 0) { Write-Error "router has $busy request(s) in flight -- aborting rather than interrupt."; exit 1 }
            Write-Host "  stopping router PID $($p.Id)" -ForegroundColor Yellow
            Stop-Process -Id $p.Id -Force
        }
        if ($running.Count) { $stoppedRouter = $true; Start-Sleep 6 }  # let WDDM drain VRAM
    }

    # ---- 3. launch the test server on the isolated port -----------------------------------------
    $env:GGML_VK_ENABLE_MEMORY_PRIORITY = '1'
    $a = @('-m', $Model, '-ngl', 999, '--ctx-size', $Ctx, '-fa', 'on',
           '--cache-type-k', 'q8_0', '--cache-type-v', 'q8_0', '-b', 2048, '-ub', 256,
           '--host', '127.0.0.1', '--port', $Port)
    # NB: --model-draft / --spec-type flag names are UNVERIFIED for draft-dflash (from the model card's
    # -hfd usage; untestable until #27805 lands). Verify against `llama-server --help` before relying on this.
    if ($Draft -and (Test-Path $Draft)) { $a += @('--model-draft', $Draft) }
    if ($SpecType) { $a += @('--spec-type', $SpecType) }
    Write-Host "  launching test server on :$Port ..." -ForegroundColor DarkGray
    $proc = Start-Process -FilePath $srv -ArgumentList $a -PassThru -WindowStyle Hidden `
              -RedirectStandardOutput (Join-Path $repoRoot "logs\stage-nextgen-$Port.out") `
              -RedirectStandardError  (Join-Path $repoRoot "logs\stage-nextgen-$Port.err")
    $testPid = $proc.Id

    $up = $false
    for ($i = 0; $i -lt 120; $i++) {
        try { Invoke-RestMethod "http://127.0.0.1:$Port/health" -TimeoutSec 3 | Out-Null; $up = $true; break } catch { Start-Sleep 2 }
        if ($proc.HasExited) { Write-Error "test server exited during load (code $($proc.ExitCode)) -- see logs\stage-nextgen-$Port.err"; break }
    }
    if (-not $up) { Write-Error "test server did not come up on :$Port (arch load failed, or OOM)."; }
    else {
        Write-Host "  loaded." -ForegroundColor Green
        $body = @{ prompt = "The capital of France is Paris. Here are five facts about it:`n1."; temperature = 0; seed = 42; n_predict = $NPredict; cache_prompt = $false } | ConvertTo-Json
        # Warm up first: cold Vulkan compiles shaders/pipelines lazily, so the FIRST few greedy runs vary
        # even at temp 0 -- that is cold-start, NOT #27805 (measured: qwen35 gave 4 distinct then settled).
        # Discard a few so the determinism check reflects steady-state serving, which is how the live
        # router always runs (and why warm draft-mtp tested 6/6 identical).
        Write-Host "  warming up (3 discarded runs)..." -ForegroundColor DarkGray
        for ($w = 0; $w -lt 3; $w++) { try { Invoke-RestMethod "http://127.0.0.1:$Port/v1/completions" -Method Post -Body $body -ContentType 'application/json' -TimeoutSec 60 | Out-Null } catch {} }
        Write-Host "  running $Runs fixed-seed temp-0 raw completions (Vulkan #27805 check)..." -ForegroundColor Green
        $hashes = @{}; $sample = ''
        for ($i = 1; $i -le $Runs; $i++) {
            try {
                $r = Invoke-RestMethod "http://127.0.0.1:$Port/v1/completions" -Method Post -Body $body -ContentType 'application/json' -TimeoutSec 60
                $t = $r.choices[0].text
            } catch { $t = "<request failed: $($_.Exception.Message)>" }
            if (-not $sample) { $sample = $t }
            $sha = [BitConverter]::ToString(([Security.Cryptography.SHA256]::Create().ComputeHash([Text.Encoding]::UTF8.GetBytes([string]$t)))).Replace('-', '').Substring(0, 12)
            if ($hashes.ContainsKey($sha)) { $hashes[$sha]++ } else { $hashes[$sha] = 1 }
            Write-Host ("    run {0,2}: {1}  (len {2})" -f $i, $sha, ([string]$t).Length)
        }
        Write-Host ""
        $distinct = $hashes.Keys.Count
        if ($distinct -eq 1) { Write-Host "  RESULT: 1 distinct output over $Runs runs -> DETERMINISTIC. Vulkan looks correct for '$arch'." -ForegroundColor Green }
        else { Write-Host "  RESULT: $distinct distinct outputs over $Runs runs -> NON-DETERMINISTIC. Likely #27805 silent corruption on Vulkan for '$arch'. DO NOT trust this config." -ForegroundColor Red }
        Write-Host "`n  --- sample output (first 300 chars) ---" -ForegroundColor DarkGray
        Write-Host ("  " + ([string]$sample).Substring(0, [Math]::Min(300, ([string]$sample).Length)))
    }
}
finally {
    # ---- 5. teardown: kill the test server, ALWAYS restore the router if we stopped it ----------
    if ($testPid) { Stop-Process -Id $testPid -Force -EA SilentlyContinue; Write-Host "`n  stopped test server PID $testPid" -ForegroundColor DarkGray }
    if ($stoppedRouter) {
        Start-Sleep 4
        Write-Host "  restarting the live router (qwen38 + ornith)..." -ForegroundColor Yellow
        & (Join-Path $PSScriptRoot 'run-router.ps1') -Models qwen38, ornith
        # confirm it actually came back -- a failed restart here is the exact serverless outcome this block exists to prevent
        Start-Sleep 3
        $back = 0
        try { $back = @((Invoke-RestMethod "http://127.0.0.1:8080/models" -TimeoutSec 5).data | Where-Object { $_.status.value -eq 'loaded' }).Count } catch {}
        if ($back -ge 2) { Write-Host "  router restored ($back models loaded)." -ForegroundColor Green }
        else { Write-Warning "ROUTER DID NOT COME BACK ($back/2 loaded). Re-run: .\scripts\windows\run-router.ps1 -Models qwen38,ornith" }
    }
}
