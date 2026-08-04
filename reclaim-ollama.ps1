<#
.SYNOPSIS
  Reclaim the ~1.3 TB held by the Ollama model store in D:\llama, which stock llama.cpp CANNOT read.

.DESCRIPTION
  WHY THIS EXISTS
  Ollama's AMD-bundle stores models as content-addressed blobs under D:\llama\blobs and declares
  Ollama-specific architecture names (gptoss, gemma4, qwen3.6). Upstream llama.cpp cannot load them
  (verified: "unknown model architecture" / "wrong number of tensors"). Ollama also measured 1.79x
  SLOWER than the Vulkan stack on identical weights (gpt-oss-20b: 40.2 vs 71.7 t/s). So this store
  is ~1.3 TB of disk that the production engine cannot use and would not want to.

  Reclaiming it is what makes "run the biggest possible models" possible: a Q3-class 235B is
  ~104 GB and D: currently has only ~123 GB free.

  SAFETY
  DRY RUN BY DEFAULT. Nothing is deleted unless you pass -Execute. Run it with no arguments first,
  read the report, then decide. -KeepManifest lets you preserve specific models' blobs if you want
  to re-export them via `ollama show --modelfile` before dropping the store.

.EXAMPLE
  .\reclaim-ollama.ps1                      # report only -- what would be freed, nothing touched
  .\reclaim-ollama.ps1 -ListModels          # report + per-model disk usage table
  .\reclaim-ollama.ps1 -Execute             # actually delete (prompts once for confirmation)
  .\reclaim-ollama.ps1 -Execute -Force      # no prompt (scripted use)
#>
[CmdletBinding()]
param(
    [string]   $Root        = 'D:\llama',
    [switch]   $Execute,                    # without this, the script only reports
    [switch]   $Force,                      # skip the interactive confirmation
    [switch]   $ListModels,                 # print per-model sizes resolved via manifests
    [string[]] $KeepManifest = @(),         # manifest paths whose blobs to PRESERVE, e.g. 'library\gpt-oss\120b'
    [switch]   $RemoveAutostart,            # also remove the Ollama Startup shortcut
    [switch]   $StopProcesses               # also stop running ollama processes
)
$ErrorActionPreference = 'Stop'

if (-not (Test-Path $Root)) { Write-Error "Ollama root not found: $Root"; exit 1 }
$blobDir = Join-Path $Root 'blobs'
$manDir  = Join-Path $Root 'manifests'

Write-Host "`n=== Ollama store audit: $Root ===" -ForegroundColor Cyan

# ---- 1) inventory -------------------------------------------------------------------------------
$blobs = @(Get-ChildItem $blobDir -File -EA SilentlyContinue)
$blobTotal = ($blobs | Measure-Object Length -Sum).Sum
$blobMap = @{}
foreach ($b in $blobs) { $blobMap[$b.Name] = $b.Length }
Write-Host ("blobs     : {0} files, {1:N1} GB" -f $blobs.Count, ($blobTotal/1GB))

$manifests = @(Get-ChildItem $manDir -Recurse -File -EA SilentlyContinue)
Write-Host ("manifests : {0}" -f $manifests.Count)

# ---- 2) map manifests -> blobs (a blob can be shared by several manifests) ----------------------
$refs = @{}     # blobName -> list of manifest labels
$modelSize = @{}
foreach ($m in $manifests) {
    $label = $m.FullName.Substring($manDir.Length).TrimStart('\')
    $size = 0
    try {
        $j = Get-Content $m.FullName -Raw | ConvertFrom-Json
        $digests = @()
        if ($j.layers)  { $digests += $j.layers.digest }
        if ($j.config)  { $digests += $j.config.digest }
        foreach ($d in ($digests | Where-Object { $_ })) {
            $name = $d -replace ':', '-'
            if (-not $refs.ContainsKey($name)) { $refs[$name] = @() }
            $refs[$name] += $label
            if ($blobMap.ContainsKey($name)) { $size += $blobMap[$name] }
        }
    } catch { Write-Warning "unparsable manifest: $label" }
    $modelSize[$label] = $size
}

$referenced   = @($refs.Keys | Where-Object { $blobMap.ContainsKey($_) })
$orphaned     = @($blobMap.Keys | Where-Object { -not $refs.ContainsKey($_) })
$orphanBytes  = ($orphaned | ForEach-Object { $blobMap[$_] } | Measure-Object -Sum).Sum
Write-Host ("referenced blobs : {0}" -f $referenced.Count)
Write-Host ("ORPHANED blobs   : {0} files, {1:N1} GB  (no manifest points at these -- pure waste)" -f $orphaned.Count, ($orphanBytes/1GB)) -ForegroundColor Yellow

if ($ListModels) {
    Write-Host "`n--- per-model disk usage (largest first) ---" -ForegroundColor Cyan
    $modelSize.GetEnumerator() | Sort-Object Value -Descending |
        Select-Object @{n='GB';e={[math]::Round($_.Value/1GB,2)}}, @{n='model';e={$_.Key}} |
        Format-Table -AutoSize | Out-String -Width 140 | Write-Host
}

# ---- 3) decide the delete set ------------------------------------------------------------------
$keepBlobs = @{}
foreach ($k in $KeepManifest) {
    $hit = $refs.Keys | Where-Object { $refs[$_] -contains $k }
    if (-not $hit) { Write-Warning "-KeepManifest '$k' matched no manifest; check the label spelling." }
    foreach ($h in $hit) { $keepBlobs[$h] = $true }
}
if ($KeepManifest.Count) {
    $keptBytes = ($keepBlobs.Keys | ForEach-Object { $blobMap[$_] } | Measure-Object -Sum).Sum
    Write-Host ("PRESERVING {0} blobs ({1:N1} GB) for: {2}" -f $keepBlobs.Count, ($keptBytes/1GB), ($KeepManifest -join ', ')) -ForegroundColor Green
}

$toDelete = @($blobMap.Keys | Where-Object { -not $keepBlobs.ContainsKey($_) })
$freeBytes = ($toDelete | ForEach-Object { $blobMap[$_] } | Measure-Object -Sum).Sum

$drive = (Get-PSDrive ($Root.Substring(0,1)) -EA SilentlyContinue)
Write-Host "`n=== VERDICT ===" -ForegroundColor Cyan
Write-Host ("would delete : {0} blobs, {1:N1} GB" -f $toDelete.Count, ($freeBytes/1GB)) -ForegroundColor Yellow
if ($drive) {
    Write-Host ("{0}: free now  : {1:N1} GB" -f $drive.Name, ($drive.Free/1GB))
    Write-Host ("{0}: free after: {1:N1} GB" -f $drive.Name, (($drive.Free + $freeBytes)/1GB)) -ForegroundColor Green
}

if (-not $Execute) {
    Write-Host "`nDRY RUN -- nothing was deleted." -ForegroundColor Green
    Write-Host "Re-run with -Execute to delete. Add -ListModels to see what each model costs first." -ForegroundColor DarkGray
    Write-Host "To keep specific models: -KeepManifest 'registry.ollama.ai\library\gpt-oss\120b'" -ForegroundColor DarkGray
    return
}

# ---- 4) execute --------------------------------------------------------------------------------
if (-not $Force) {
    Write-Host ("`nAbout to permanently delete {0:N1} GB from {1}." -f ($freeBytes/1GB), $blobDir) -ForegroundColor Red
    $ans = Read-Host "Type DELETE to proceed"
    if ($ans -ne 'DELETE') { Write-Host "Aborted." -ForegroundColor Yellow; return }
}

if ($StopProcesses) {
    Write-Host "Stopping ollama processes..." -ForegroundColor Yellow
    Get-Process ollama, 'ollama app' -EA SilentlyContinue | Stop-Process -Force -EA SilentlyContinue
    Start-Sleep 2
}

$done = 0; $freed = 0
foreach ($name in $toDelete) {
    $p = Join-Path $blobDir $name
    try { $sz = $blobMap[$name]; Remove-Item $p -Force -EA Stop; $freed += $sz; $done++ }
    catch { Write-Warning "could not delete ${name}: $($_.Exception.Message)" }
    if ($done % 25 -eq 0) { Write-Host ("  deleted {0}/{1} ({2:N1} GB)" -f $done, $toDelete.Count, ($freed/1GB)) -ForegroundColor DarkGray }
}
Write-Host ("`nDeleted {0} blobs, freed {1:N1} GB" -f $done, ($freed/1GB)) -ForegroundColor Green

# manifests are tiny but meaningless without their blobs -- drop the ones we fully de-blobbed
if (-not $KeepManifest.Count) {
    Remove-Item $manDir -Recurse -Force -EA SilentlyContinue
    Write-Host "Removed manifests." -ForegroundColor Green
}

if ($RemoveAutostart) {
    $lnk = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Startup\Ollama.lnk'
    if (Test-Path $lnk) { Remove-Item $lnk -Force; Write-Host "Removed Ollama autostart shortcut." -ForegroundColor Green }
    foreach ($v in 'OLLAMA_KEEP_ALIVE','OLLAMA_MODELS','OLLAMA_FLASH_ATTENTION','OLLAMA_KV_CACHE_TYPE') {
        [Environment]::SetEnvironmentVariable($v, $null, 'User')
    }
    Write-Host "Cleared OLLAMA_* user environment variables." -ForegroundColor Green
}

$drive = (Get-PSDrive ($Root.Substring(0,1)) -EA SilentlyContinue)
if ($drive) { Write-Host ("`n{0}: {1:N1} GB free" -f $drive.Name, ($drive.Free/1GB)) -ForegroundColor Cyan }
Write-Host "NOTE: the Ollama binary itself is still at C:\Users\<you>\AppData\Local\AMD\AI_Bundle\Ollama." -ForegroundColor DarkGray
Write-Host "      Uninstall the AMD AI Bundle separately if you want it gone entirely." -ForegroundColor DarkGray
