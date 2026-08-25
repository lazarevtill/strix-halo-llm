<#
.SYNOPSIS
  Serve MULTIPLE models from ONE endpoint on :8080 using llama.cpp router mode (b10431+).

.DESCRIPTION
  Router mode: start llama-server with NO -m and it becomes a coordinator that spawns a child
  llama-server per model and routes each request by the OpenAI `model` field. Verified on b10431
  2026-08-18: both models stay co-resident (models-max 2), and per-model tuned flags survive into
  each child (checked via GET /models -> status.args).

  Why this over two hand-run servers: one port, one process tree, LRU eviction if you ever exceed
  models-max, and no manual juggling. Route coding -> "qwen38", big-text -> "ornith" (MoE, ~2.5x the
  dense 27B's generation speed).

  ASKS ON START which models to serve. With no -Models it scans MODELS_DIR and, when run
  interactively, prints a numbered menu and prompts (Enter = the tuned default qwen38 + ornith).
  Non-interactive (a task/pipe) uses the default. The two published models carry their exact tuning;
  ANY other gguf on the box is offered too and auto-tuned -- spec read from its own GGUF header
  (draft-mtp when it has an MTP head), vision projector matched by sibling filename -- so a private
  or newly-downloaded model is servable without being named in this committed script.

  MEASURED GOTCHAS baked in here:
    * load-mode = none per model. The dual setup's real trap: default mmap pins a ~15 GB host
      file-cache mirror PER model, and this box has only ~32 GB system RAM -- two mirrors would
      exhaust it. `none` keeps weights in the VRAM carve-out, host copy paged out (the old -lm none).
    * Pre-load. Autoload does NOT fire on the first /v1/chat/completions call -- it 400s
      ("model is not loaded"). We POST /models/load for each model at startup so clients never see it.
    * Context is 131072 per model, NOT the 262144 a solo model gets: two resident models split the
      ~109 GB budget. 131072 x2 (q8_0 KV) fits with room to spare (~54 GB measured).

.EXAMPLE
  .\run-router.ps1                              # ask on start (menu); Enter = qwen38 + ornith
  .\run-router.ps1 -Models qwen38,ornith        # non-interactive: serve exactly these
  .\run-router.ps1 -Models cyberstrike-offsec-35b -ModelsMax 1   # a single on-demand model
  .\run-router.ps1 -DryRun                       # print the cmdline + generated preset, launch nothing
#>
[CmdletBinding()]
param(
    [string[]] $Models    = @(),   # which models to serve. Empty => ASK on start (interactive), or the
                                   # tuned default (qwen38, ornith) when non-interactive. Names or the
                                   # menu numbers; any gguf in MODELS_DIR is offered, auto-tuned.
    [int]      $Port      = 8080,
    [int]      $Ctx       = 131072,
    [int]      $ModelsMax = 2,
    [string[]] $Preload   = @(),   # empty => pre-load exactly the selected set
    [switch]   $DryRun,
    [switch]   $Force        # stop other servers even if one has a request in flight
)
$ErrorActionPreference = 'Stop'
$repoRoot = $PSScriptRoot | Split-Path -Parent | Split-Path -Parent
$bin = "$repoRoot\bin\llama-server.exe"
if (-not (Test-Path $bin)) { Write-Error "llama-server.exe not found: $bin"; exit 1 }

$modelsDir = $env:MODELS_DIR
if (-not $modelsDir) { $modelsDir = "$repoRoot\models" }

# ---- KNOWN tuning for the box's published models -------------------------------------------------
# Exact tuning for the public models (their projectors are generically named, so they need the map).
# Any OTHER gguf in MODELS_DIR is discovered and AUTO-tuned below (spec read from its own GGUF header,
# projector matched by sibling name) -- so a private/local model is servable WITHOUT being named here.
# match is the DISTINCTIVE filename stem (incl. the quant) so it binds to exactly one gguf -- a bare
# 'Qwen3.8-27B' would also grab every other qwen38 quant on disk.
$known = @(
    @{ match = 'Qwen3.8-27B-UD-Q4_K_XL';            label = 'qwen38';            spec = @('spec-type = draft-mtp','spec-draft-n-max = 3'); mmproj = 'mmproj-F16.gguf' }                          # coding+vision; KL-best quant (Round 5)
    @{ match = 'ornith-1.0-35b-Q5_K_M';             label = 'ornith';            spec = @('spec-type = ngram-mod');                        mmproj = 'mmproj-deepreinforce-ai_Ornith-1.0-35B-f16.gguf' }  # big-text+vision; MoE A3B
    @{ match = 'Qwen38-uncensored-UD-Q4_K_XL';      label = 'qwen38-uncensored'; spec = @('spec-type = draft-mtp','spec-draft-n-max = 3'); mmproj = 'mmproj-Qwen38-uncensored-bf16.gguf' }         # abliterated qwen38; same dense arch -> inherits qwen38's MEASURED tuning
    @{ match = 'CyberStrike-OffSec-35B-abliterated'; label = 'cyberstrike';       spec = @('spec-type = ngram-mod');                        mmproj = 'mmproj-CyberStrike-OffSec-35B-bf16.gguf' }          # abliterated pentest MoE (qwen35moe); ngram-mod per Ornith. draft-mtp loads but is UNMEASURED -- A/B first
)
# shared tuned flags -- the measured optima for gfx1151 (see docs/BENCHMARKS.md, docs/OPTIMIZATION.md)
$common = @(
    "ctx-size = $Ctx",
    'load-mode = none',            # VRAM residency; NOT mmap (two host mirrors would blow ~32 GB sys RAM)
    'flash-attn = on',
    'cache-type-k = q8_0','cache-type-v = q8_0',
    'batch-size = 2048','ubatch-size = 256',
    'temp = 0.6','top-p = 0.95','top-k = 20','min-p = 0'
)

function Get-Slug([string]$name) {
    $s = [IO.Path]::GetFileNameWithoutExtension($name)
    $s = $s -replace '(?i)-(UD-)?(I?Q\d[_A-Za-z0-9]*|BF16|F16|MXFP4).*$',''  # drop the quant tail
    $s = $s -replace '(?i)-abliterated',''
    ($s -replace '[^A-Za-z0-9]+','-').Trim('-').ToLower()
}
function Get-DetectedSpec([string]$path) {
    # draft-mtp needs a native MTP head; its presence shows as 'nextn_predict_layers' in the GGUF
    # metadata. Scan the header (first 3 MB) so an unknown model auto-gets speculation when it can.
    try {
        # FileShare.ReadWrite so a still-downloading file (curl holds a write handle) can be read too
        $fs = [IO.File]::Open($path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
        $buf = New-Object byte[] 3145728
        $n = $fs.Read($buf, 0, $buf.Length); $fs.Close()
        if ([Text.Encoding]::ASCII.GetString($buf, 0, $n) -match 'nextn_predict_layers') {
            return @('spec-type = draft-mtp','spec-draft-n-max = 3')
        }
    } catch {}
    return @()   # no MTP head -> no speculation (safe default; a wrong spec-type aborts the load)
}
function Find-Sibling-Mmproj([string]$file, [string]$dir) {
    $tok = (([IO.Path]::GetFileNameWithoutExtension($file)) -split '-')[0]
    if (-not $tok) { return $null }
    $m = Get-ChildItem $dir -Filter 'mmproj*.gguf' -EA SilentlyContinue |
         Where-Object { $_.Name -match [regex]::Escape($tok) } | Select-Object -First 1
    if ($m) { return $m.Name } else { return $null }
}

# ---- discover every servable gguf in MODELS_DIR (known -> tuned, else auto-tuned) ---------------
$catalog = [ordered]@{}   # label -> @{ file; spec; mmproj }
$ggufs = @(Get-ChildItem $modelsDir -Filter '*.gguf' -EA SilentlyContinue |
           Where-Object { $_.Name -notlike 'mmproj*' } |                      # projectors attach to a model, not served alone
           Where-Object { $_.Name -notmatch '(?i)dflash|[-_]draft' } |        # speculative DRAFT models, not serving targets
           Where-Object { $_.Name -notmatch '-of-\d+\.gguf$' -or $_.Name -match '-0*1-of-\d+\.gguf$' } |  # multi-shard: keep shard 1 only
           Sort-Object Name)
foreach ($g in $ggufs) {
    $k = $known | Where-Object { $g.Name -like "*$($_.match)*" } | Select-Object -First 1
    if ($k) {
        $catalog[$k.label] = @{ file = $g.Name; spec = $k.spec; mmproj = $k.mmproj }
    } else {
        $lbl = Get-Slug $g.Name
        if ($lbl -and -not $catalog.Contains($lbl)) {
            $catalog[$lbl] = @{ file = $g.Name; spec = (Get-DetectedSpec $g.FullName); mmproj = (Find-Sibling-Mmproj $g.Name $modelsDir) }
        }
    }
}
if ($catalog.Count -eq 0) { Write-Error "no .gguf models found in $modelsDir"; exit 1 }

# ---- choose which to serve: -Models, else ASK on start, else the tuned default -------------------
$defaultSel = @($known | ForEach-Object { $_.label } | Where-Object { $catalog.Contains($_) })
if (-not $defaultSel) { $defaultSel = @($catalog.Keys | Select-Object -First 2) }
$keys = @($catalog.Keys)

if ($Models.Count -gt 0) {
    $sel = @()
    foreach ($t in ($Models | ForEach-Object { $_ -split ',' })) {
        $t = "$t".Trim(); if (-not $t) { continue }
        if ($t -match '^\d+$' -and [int]$t -ge 1 -and [int]$t -le $keys.Count) { $sel += $keys[[int]$t - 1] }
        elseif ($catalog.Contains($t)) { $sel += $t }
        else { Write-Warning "unknown model '$t'. Available: $($keys -join ', ')" }
    }
} elseif (-not $DryRun -and [Environment]::UserInteractive -and -not [Console]::IsInputRedirected) {
    Write-Host "`nModels available in $modelsDir :" -ForegroundColor Cyan
    for ($i = 0; $i -lt $keys.Count; $i++) {
        $c = $catalog[$keys[$i]]
        $sp = if ($c.spec) { ($c.spec[0] -replace 'spec-type = ','') } else { 'none' }
        $v  = if ($c.mmproj) { ' +vision' } else { '' }
        Write-Host ("  [{0}] {1,-24} spec={2}{3}" -f ($i + 1), $keys[$i], $sp, $v)
    }
    $ans = Read-Host ("Which to serve? comma-separated numbers/names [Enter = {0}]" -f ($defaultSel -join ','))
    if (-not "$ans".Trim()) { $sel = $defaultSel }
    else {
        $sel = @()
        foreach ($t in ("$ans" -split ',')) {
            $t = $t.Trim(); if (-not $t) { continue }
            if ($t -match '^\d+$' -and [int]$t -ge 1 -and [int]$t -le $keys.Count) { $sel += $keys[[int]$t - 1] }
            elseif ($catalog.Contains($t)) { $sel += $t }
            else { Write-Warning "skip unknown: $t" }
        }
    }
} else {
    $sel = $defaultSel
}
$sel = @($sel | Select-Object -Unique)
if (-not $sel) { Write-Error "no models selected"; exit 1 }
if (-not $PSBoundParameters.ContainsKey('ModelsMax') -and $ModelsMax -lt $sel.Count) { $ModelsMax = $sel.Count }
if (-not $PSBoundParameters.ContainsKey('Preload') -or $Preload.Count -eq 0) { $Preload = $sel }

# ---- build the preset INI -----------------------------------------------------------------------
$iniPath = "$repoRoot\scripts\windows\router-models.generated.ini"
$lines = New-Object System.Collections.Generic.List[string]
foreach ($name in $sel) {
    $c = $catalog[$name]
    $file = Join-Path $modelsDir $c.file
    if (-not (Test-Path $file)) { Write-Warning "model file missing, skipping [$name]: $file"; continue }
    $lines.Add("[$name]")
    $lines.Add("model = $file")
    foreach ($x in $common) { $lines.Add($x) }
    foreach ($s in $c.spec) { $lines.Add($s) }
    if ($c.mmproj) {
        $mmPath = Join-Path $modelsDir $c.mmproj
        if (Test-Path $mmPath) { $lines.Add("mmproj = $mmPath") }
        else { Write-Warning "mmproj missing for [$name], serving text-only: $mmPath" }
    }
    $lines.Add('')
}
Set-Content -Path $iniPath -Value $lines -Encoding ASCII

$routerArgs = @(
    '--models-preset', $iniPath,
    '--models-max', $ModelsMax,
    '--models-autoload',
    '-ngl', 999,
    '--jinja',
    '--host', '0.0.0.0',
    '--port', $Port
)

Write-Host ""
Write-Host "llama-server ROUTER -> http://0.0.0.0:$Port  (route by OpenAI `"model`" field)" -ForegroundColor Cyan
Write-Host ("  models   : {0}" -f ($sel -join ', '))
Write-Host ("  each     : ctx=$Ctx  fa=on  kv=q8_0  batch=2048/256  load-mode=none  + per-model spec/vision")
Write-Host ("  max resident: $ModelsMax   pre-load: {0}" -f ($Preload -join ', '))
Write-Host ("  preset   : $iniPath")
if ($DryRun) {
    Write-Host "`n[DryRun] would run:`n  $bin $($routerArgs -join ' ')" -ForegroundColor DarkGray
    Write-Host "`n--- generated preset ---" -ForegroundColor DarkGray
    Get-Content $iniPath | ForEach-Object { Write-Host "  $_" -ForegroundColor DarkGray }
    exit 0
}

# ---- stop existing llama-servers, drain the GPU -------------------------------------------------
$others = @(Get-Process llama-server -EA SilentlyContinue)
foreach ($o in $others) {
    if (-not $Force) {
        $busy = 0
        foreach ($prt in 8080..8099) {
            $owner = (Get-NetTCPConnection -LocalPort $prt -State Listen -EA SilentlyContinue).OwningProcess
            if ($owner -eq $o.Id) {
                try { $busy = @((Invoke-RestMethod "http://127.0.0.1:$prt/slots" -TimeoutSec 3) | Where-Object { $_.is_processing }).Count } catch {}
            }
        }
        if ($busy -gt 0) { Write-Error "llama-server PID $($o.Id) has $busy active request(s). Wait, or use -Force."; exit 1 }
    }
    Write-Host "  stopping llama-server PID $($o.Id)" -ForegroundColor Yellow
    try { Stop-Process -Id $o.Id -Force -EA Stop }
    catch { Write-Error "Cannot stop PID $($o.Id): $($_.Exception.Message). Probably elevated -- run as Administrator."; exit 1 }
}
Start-Sleep -Seconds 3

# ---- launch router ------------------------------------------------------------------------------
$env:GGML_VK_ENABLE_MEMORY_PRIORITY = '1'
Write-Host "  launching router..." -ForegroundColor DarkGray
$proc = Start-Process -FilePath $bin -ArgumentList $routerArgs -PassThru -WindowStyle Hidden
Write-Host "  router PID $($proc.Id)"

# wait for the router to answer
$up = $false
for ($i = 0; $i -lt 30; $i++) {
    try { Invoke-RestMethod "http://127.0.0.1:$Port/models" -TimeoutSec 3 | Out-Null; $up = $true; break } catch { Start-Sleep -Seconds 1 }
}
if (-not $up) { Write-Error "router did not come up on :$Port"; exit 1 }

# ---- pre-load requested models (avoids the first-request 400) -----------------------------------
foreach ($name in $Preload) {
    Write-Host "  pre-loading $name ..." -ForegroundColor DarkGray
    try {
        Invoke-RestMethod "http://127.0.0.1:$Port/models/load" -Method Post -Body (@{ model = $name } | ConvertTo-Json) -ContentType 'application/json' -TimeoutSec 300 | Out-Null
    } catch { Write-Warning "pre-load $name failed: $($_.Exception.Message)" }
}

# ---- report -------------------------------------------------------------------------------------
Start-Sleep -Seconds 2
Write-Host "`nrouter ready:" -ForegroundColor Green
try {
    (Invoke-RestMethod "http://127.0.0.1:$Port/models" -TimeoutSec 5).data |
        ForEach-Object { Write-Host ("  {0,-8} {1}" -f $_.id, $_.status.value) }
} catch {}
$c = ((Get-Counter '\GPU Process Memory(*)\Total Committed' -EA SilentlyContinue).CounterSamples | Measure-Object CookedValue -Sum).Sum / 1GB
Write-Host ("  GPU committed total: {0:N1} GB of ~109" -f $c)
Write-Host "`n  route by the OpenAI `"model`" field, e.g.:"
foreach ($name in $sel) {
    Write-Host ("    curl :$Port/v1/chat/completions -d '{{`"model`":`"{0}`",...}}'" -f $name)
}
