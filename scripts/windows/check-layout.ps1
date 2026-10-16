<#
.SYNOPSIS
  Check the serving system's layout and write its index: every engine, model and launcher path that the
  scripts, the registries and the Startup launcher refer to must exist where paths.ps1 says it lives.

.DESCRIPTION
  ERROR  a referenced file/engine is missing (a launcher would fail)  -> exit code 1
  WARN   something sits in an OLD location (bin-*, a flat models\ file, loose logs) or is unreferenced
  info   what is present, with sizes

  Writes models\INDEX.md (gitignored, local): every weight file with its size, kind and what uses it
  (run-router label, image registry id, fetch-models label), plus the engines and their versions.
  Run it after adding or removing anything (docs\LAYOUT.md says how to add each kind of part).

.EXAMPLE
  .\scripts\windows\check-layout.ps1            # check + write models\INDEX.md
  .\scripts\windows\check-layout.ps1 -NoIndex   # check only
#>
[CmdletBinding()]
param([switch] $NoIndex)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'paths.ps1')
$R = $StrixRoot
$errors = 0; $warns = 0
function Err($m) { Write-Host "  ERROR  $m" -ForegroundColor Red; $script:errors++ }
function Warn($m) { Write-Host "  WARN   $m" -ForegroundColor Yellow; $script:warns++ }
function Ok($m) { Write-Host "  ok     $m" -ForegroundColor DarkGreen }
function GB($bytes) { '{0:N1} GB' -f ($bytes / 1e9) }
$used = @{}   # file name -> list of users
function Use($file, $who) { $n = Split-Path $file -Leaf; if (-not $used[$n]) { $used[$n] = New-Object System.Collections.ArrayList }; [void]$used[$n].Add($who) }

Write-Host "Layout of $R" -ForegroundColor Cyan

# ---- 1. nothing left in the old places -----------------------------------------------------------
Write-Host "`n[old locations]" -ForegroundColor Cyan
$old = @(Get-ChildItem $R -Directory | Where-Object { $_.Name -match '^bin(-|$)' })
foreach ($d in $old) { Warn "engine folder in the old place: $($d.Name) -> move to engines\ (see docs\LAYOUT.md)" }
$flat = @(Get-ChildItem (Join-Path $R 'models') -File -EA SilentlyContinue | Where-Object { $_.Name -ne 'INDEX.md' })
foreach ($f in $flat) { Warn "loose file in models\: $($f.Name) -> models\llm or models\image" }
$looseLogs = @(Get-ChildItem (Join-Path $R 'logs') -File -EA SilentlyContinue | Where-Object { $_.Name -notlike 'layout-migration-*' })
if ($looseLogs.Count) { Warn "$($looseLogs.Count) loose file(s) in logs\ (scripts now write to logs\llm, images, bench, downloads)" }
if (Test-Path (Join-Path $R 'longctx')) { Warn 'longctx\ (bench output) -> logs\bench\longctx' }
# the checkout root holds only tracked files: bench/server output belongs in logs\
$rootJunk = @()
if (Get-Command git -EA SilentlyContinue) {
    $tracked = @(git -C $R ls-files 2>$null)
    $rootJunk = @(Get-ChildItem $R -File | Where-Object { $tracked -notcontains $_.Name })
    foreach ($f in $rootJunk) { Warn "untracked file in the checkout root: $($f.Name) -> logs\bench\ (or logs\llm\)" }
}
if (-not ($old.Count + $flat.Count + $looseLogs.Count + $rootJunk.Count)) { Ok 'no engines, models, logs or outputs left in the old places' }

# ---- 2. engines --------------------------------------------------------------------------------------
Write-Host "`n[engines]" -ForegroundColor Cyan
$engineRows = @()
foreach ($kind in 'llama.cpp', 'stable-diffusion.cpp') {
    $exeName = if ($kind -eq 'llama.cpp') { 'llama-server.exe' } else { 'sd-server.exe' }
    foreach ($d in @(Get-ChildItem (Join-Path $R "engines\$kind") -Directory -EA SilentlyContinue)) {
        if (Test-Path (Join-Path $d.FullName $exeName)) { Ok "$kind\$($d.Name)"; $engineRows += "| $kind | $($d.Name) | $exeName |" }
        else { Err "$kind\$($d.Name) has no $exeName" }
    }
}
if (Test-Path (Join-Path $R 'engines\poolside\llama-server.exe')) { Ok 'poolside'; $engineRows += '| poolside | (fork) | llama-server.exe |' }
foreach ($a in @(Get-ChildItem (Join-Path $R 'engines\_attic') -Directory -EA SilentlyContinue)) { Warn "engines\_attic\$($a.Name) -- parked, safe to delete once you agree" }
try { $null = Get-StrixEngine ''; Ok "default llama.cpp build $StrixDefaultLlamaBuild present" } catch { Err $_.Exception.Message }

# ---- 3. LLM models the launchers know ----------------------------------------------------------------
Write-Host "`n[LLM models: run-router presets]" -ForegroundColor Cyan
$llmDir = Get-StrixModelsDir llm
$rr = Get-Content (Join-Path $PSScriptRoot 'run-router.ps1') -Raw
foreach ($m in [regex]::Matches($rr, "match\s*=\s*'([^']+)';\s*label\s*=\s*'([^']+)'(.*?)\}\s*#", 'Singleline')) {
    $pat, $label, $rest = $m.Groups[1].Value, $m.Groups[2].Value, $m.Groups[3].Value
    $hit = @(Get-ChildItem $llmDir -Filter "$pat*.gguf" -EA SilentlyContinue | Sort-Object Name)
    if ($hit.Count) {
        Use $hit[0].Name "run-router:$label"; foreach ($h in $hit) { Use $h.Name "run-router:$label" }
        $extra = @()
        foreach ($d in [regex]::Matches($rest, "spec-draft-model = @MODELS@\\([^']+)'")) { $extra += $d.Groups[1].Value }
        foreach ($d in [regex]::Matches($rest, "mmproj = '([^']+)'")) { $extra += $d.Groups[1].Value }
        $miss = @($extra | Where-Object { -not (Test-Path (Join-Path $llmDir $_)) })
        foreach ($x in $extra) { Use $x "run-router:$label" }
        if ($miss.Count) { Err "$label : companion missing: $($miss -join ', ')" } else { Ok ("{0,-14} {1}" -f $label, $hit[0].Name) }
    } else { Write-Host ("  -      {0,-14} not on disk ({1}*)" -f $label, $pat) -ForegroundColor DarkGray }
}

# ---- 4. image / video models (registry + local registry) --------------------------------------------
Write-Host "`n[image / video models]" -ForegroundColor Cyan
$imgDir = Get-StrixModelsDir image
$regs = @((Join-Path $PSScriptRoot 'image-models.json'), (Join-Path $imgDir 'image-models.local.json'))
foreach ($rf in $regs) {
    if (-not (Test-Path $rf)) { continue }
    $reg = Get-Content $rf -Raw | ConvertFrom-Json
    foreach ($m in $reg.models) {
        $miss = @()
        foreach ($p in $m.files.PSObject.Properties) { Use $p.Value "image:$($m.id)"; if (-not (Test-Path (Join-Path $imgDir $p.Value))) { $miss += $p.Value } }
        foreach ($l in @($m.default_lora)) { if ($l) { Use $l.path "image:$($m.id)"; if (-not (Test-Path (Join-Path $imgDir "loras\$($l.path)"))) { $miss += "loras\$($l.path)" } } }
        if ($m.engine -and -not (Test-Path (Join-Path $R $m.engine))) { $miss += "engine $($m.engine)" }
        if ($miss.Count) { Err "$($m.id): missing $($miss -join ', ')" } else { Ok $m.id }
    }
}
foreach ($sub in 'loras', 'upscalers', 'detectors', 'embeddings') {
    foreach ($f in @(Get-ChildItem (Join-Path $imgDir $sub) -File -EA SilentlyContinue)) { Use $f.Name "image:$sub" }
}

# ---- 5. fetch-models labels (what can be re-downloaded) -----------------------------------------------
$fm = Get-Content (Join-Path $PSScriptRoot 'fetch-models.ps1') -Raw
foreach ($m in [regex]::Matches($fm, "(?m)^    '([a-z0-9.-]+)' = @\{(.*?)^    \}", 'Singleline')) {
    foreach ($f in [regex]::Matches($m.Groups[2].Value, "p='([^']+)'(?:;[^}]*?as='([^']+)')?")) {
        $n = if ($f.Groups[2].Success) { $f.Groups[2].Value } else { $f.Groups[1].Value }
        Use $n "fetch:$($m.Groups[1].Value)"
    }
}

# ---- 6. what the Startup launcher starts -------------------------------------------------------------
Write-Host "`n[Startup launcher]" -ForegroundColor Cyan
$cmd = Join-Path ([Environment]::GetFolderPath('Startup')) 'StrixHalo-Router.cmd'
if (Test-Path $cmd) {
    foreach ($ln in Get-Content $cmd | Where-Object { $_ -match '^\s*start\s' }) {
        $script = [regex]::Match($ln, '-File\s+"([^"]+)"').Groups[1].Value
        if (-not (Test-Path $script)) { Err "launcher starts a missing script: $script" } else { Ok ("starts {0}" -f $script.Replace($R, '.')) }
        $b = [regex]::Match($ln, '-Bin\s+"?([^"\s]+)"?').Groups[1].Value
        if ($b) { try { $null = Get-StrixEngine $b; Ok "  engine $b" } catch { Err "  engine $b : $($_.Exception.Message)" } }
    }
} else { Warn "no Startup launcher at $cmd" }

# ---- 7. unreferenced weights ---------------------------------------------------------------------------
Write-Host "`n[unreferenced weights]" -ForegroundColor Cyan
$all = @()
foreach ($k in 'llm', 'image') {
    foreach ($f in @(Get-ChildItem (Get-StrixModelsDir $k) -File -Recurse -EA SilentlyContinue | Where-Object { $_.Extension -in '.gguf', '.safetensors' })) {
        $all += [pscustomobject]@{ Kind = $k; Name = $f.Name; Rel = $f.FullName.Substring($R.Length + 1); Bytes = $f.Length; Users = @($used[$f.Name]) }
    }
}
$orphans = @($all | Where-Object { -not $_.Users.Count })
foreach ($o in $orphans) { Warn ("{0} ({1}) is used by no launcher preset, registry or fetch label" -f $o.Rel, (GB $o.Bytes)) }
if (-not $orphans.Count) { Ok 'every weight file is referenced' }

# ---- index ---------------------------------------------------------------------------------------------
if (-not $NoIndex) {
    $idx = Join-Path $R 'models\INDEX.md'
    $lines = @('# Serving-system index (generated by scripts\windows\check-layout.ps1 -- do not edit)', '',
               "Generated $(Get-Date -Format 'yyyy-MM-dd HH:mm'). Layout and how to add parts: docs\LAYOUT.md.", '',
               '## Engines', '', '| kind | build | server |', '|---|---|---|') + $engineRows + @('', '## Models', '',
               '| kind | file | size | used by |', '|---|---|---|---|')
    foreach ($a in $all | Sort-Object Kind, Rel) { $lines += "| $($a.Kind) | $($a.Rel.Replace('\', '/')) | $(GB $a.Bytes) | $((@($a.Users | Select-Object -Unique)) -join ', ') |" }
    $tot = ($all | Measure-Object Bytes -Sum).Sum
    $lines += @('', "$($all.Count) weight files, $(GB $tot) in total.")
    Set-Content -Path $idx -Value $lines -Encoding UTF8
    Write-Host "`nindex written: $idx" -ForegroundColor Cyan
}
Write-Host ("`n{0} error(s), {1} warning(s)" -f $errors, $warns) -ForegroundColor $(if ($errors) { 'Red' } elseif ($warns) { 'Yellow' } else { 'Green' })
if ($errors) { exit 1 }
