<#
.SYNOPSIS
  Benchmark the "biggest that fits" model set on this box: does it fit, and how fast at DEPTH.

.DESCRIPTION
  Why a new bench rather than bench.ps1: the existing one measures pp512/tg128 at depth 0, which
  flatters small-context use and tells you nothing about the agentic/long-context regime this box is
  actually used for. This one sweeps `llama-bench -d` (context depth), which is where the candidates
  genuinely diverge -- tg decays with depth, and models with sliding-window attention (Laguna) decay
  far less than full-attention ones.

  It also records what the throughput numbers cost in memory: peak GPU dedicated vs shared, sampled
  while the bench runs. On this box that matters because the ceiling is ~109 GiB (96 GiB carve-out +
  ~13.4 GiB WDDM shared) and a model can silently spill into the shared heap -- which is FREE here
  (measured: tg flat 89->109 GiB), but tells you how much context headroom is left.

  Lessons baked in (see OPTIMIZATION.md):
    * hard clean-baseline guard -- a stale allocation produces a bogus ErrorOutOfDeviceMemory that
      looks exactly like "model too big". 3 false negatives were traced to this.
    * a model that does not fit is recorded as FAIL with the allocator error, not a crash.
    * never --mlock; --no-mmap (mmap 0) always.

.EXAMPLE
  .\bench-big.ps1 -List
  .\bench-big.ps1 -Only ornith-bf16
  .\bench-big.ps1 -All                          # full sweep, writes bench-big.csv
  .\bench-big.ps1 -All -Depths 0,8192,32768 -Quick
#>
[CmdletBinding()]
param(
    [string[]] $Only,
    [switch]   $All,
    [switch]   $List,
    [int[]]    $Depths   = @(0, 8192, 32768),
    [int[]]    $PromptLens = @(512, 4096),
    [int]      $GenLen   = 128,
    [int]      $Reps     = 2,
    [switch]   $Quick,                                   # depths 0,8192 and 1 rep
    # models live in two places on this box: the llamacpp-vulkan store and the router store on C:.
    # Search both so the incumbent (ornith Q5_K_M, which lives on C:) resolves without copying 23 GiB.
    [string[]] $ModelDirs = @('D:\llamacpp-vulkan\models','C:\llm-router\models'),
    [string]   $ModelDir = 'D:\llamacpp-vulkan\models',   # where NEW downloads land
    [string]   $Bin      = 'D:\llamacpp-vulkan\bin',
    [string]   $Csv      = 'D:\llamacpp-vulkan\bench-big.csv'
)
$ErrorActionPreference = 'Continue'
$gpu = 'luid_0x00000000_0x01c3ed4a_phys_0'

# label -> primary gguf (shard 1 for splits; llama.cpp auto-joins), plus notes for the report
$REG = [ordered]@{
    'ornith-q5'         = @{ file='ornith-1.0-35b-Q5_K_M.gguf';                              arch='qwen35moe'; act='A3B';  note='incumbent baseline (also at C:\llm-router\models)' }
    'ornith-bf16'       = @{ file='ornith-1.0-35b-bf16.gguf';                                arch='qwen35moe'; act='A3B';  note='full precision, 262K ctx, MIT' }
    'ornith-q8'         = @{ file='ornith-1.0-35b-Q8_0.gguf';                                arch='qwen35moe'; act='A3B';  note='near-lossless' }
    'qwen122b'          = @{ file='Qwen3.5-122B-A10B-UD-Q4_K_XL-00001-of-00003.gguf';        arch='qwen35moe'; act='A10B'; note='125B, honest 4-bit, Apache-2.0, MTP head available' }
    'laguna'            = @{ file='laguna-s-2.1-Q4_K_M.gguf';                                arch='laguna';    act='A8B';  note='118B, 1M ctx, sliding-window -> should decay least with depth' }
    'deepseek-v4-flash' = @{ file='DeepSeek-V4-Flash-UD-IQ2_M-00001-of-00003.gguf';           arch='deepseek4'; act='A13B'; note='284B but ~2-bit; highest active params -> slowest tg' }
}
# Scope (2026-07-30, user's call): 2026 releases only, Ornith-1.0-35B-tier agentic/coding or better.
# gpt-oss-120b and other 2025-era models are deliberately excluded -- do not re-add.

function Get-GpuMem {
    $s = (Get-Counter "\GPU Adapter Memory($gpu)\*" -EA SilentlyContinue).CounterSamples
    $d = ($s | Where-Object { $_.Path -like '*dedicated usage*' }).CookedValue
    $h = ($s | Where-Object { $_.Path -like '*shared usage*'    }).CookedValue
    [pscustomobject]@{ Ded=[double]$d; Shr=[double]$h }
}

# Account for GPU memory held by OTHER processes, and classify each holder by whether we can
# reclaim it. Returns @{ TotalGB; ReclaimableGB; StuckGB; Holders[] }.
#
# HARD-WON (2026-07-31, and I got this wrong once in both directions):
#  * An EXITED-but-unreaped process STILL HOLDS its GPU allocation. Windows keeps the process object
#    (and its \GPU Process Memory counter instance) alive while any handle remains, and WDDM does not
#    reclaim the memory until the object is destroyed. `taskkill` reports "no running instance of the
#    task" and `Stop-Process` silently no-ops, which makes it LOOK like a stale counter. It is not:
#    with ~9.7 GiB held this way, 64.61 GiB of weights still OOM'd. So DO count exited holders.
#  * An ELEVATED process cannot be stopped from a non-elevated shell (Access denied) -- also real,
#    also unreclaimable without UAC.
# Only a reboot (or reaping the handle owner) frees the exited ones.
function Get-GpuHeld {
    $tot = 0.0; $recl = 0.0; $stuck = 0.0; $holders = @()
    try {
        # 'Total Committed', NOT 'Dedicated Usage' -- see the note in run-solo.ps1. A trimmed model
        # reads ~0 dedicated while still committing tens of GiB that the allocator must respect.
        foreach ($s in (Get-Counter '\GPU Process Memory(*)\Total Committed' -EA Stop).CounterSamples) {
            if ($s.CookedValue -le 100MB) { continue }
            $q = ([regex]::Match($s.InstanceName,'pid_(\d+)')).Groups[1].Value
            if (-not $q) { continue }
            $gb = $s.CookedValue
            $pr = Get-Process -Id $q -EA SilentlyContinue
            if (-not $pr) { continue }                       # truly gone; counter instance will age out
            if ($pr.ProcessName -in @('dwm','chrome','msedge','explorer','WindowsTerminal','SamsungMagician')) { continue }  # desktop baseline
            $state = if ($pr.HasExited) { 'EXITED-stuck' } else { 'live' }
            $tot += $gb
            if ($state -eq 'live') { $recl += $gb } else { $stuck += $gb }
            $holders += [pscustomobject]@{ PID=[int]$q; Name=$pr.ProcessName; State=$state; GiB=[math]::Round($gb/1GB,2) }
        }
    } catch { return $null }
    @{ TotalGB=[math]::Round($tot/1GB,2); ReclaimableGB=[math]::Round($recl/1GB,2)
       StuckGB=[math]::Round($stuck/1GB,2); Holders=$holders }
}

# Measured usable ceiling on this box: 96 GiB carve-out + ~13.4 GiB usable WDDM shared. See OPTIMIZATION.md.
$CEILING_GIB = 109.0

# Resolve a gguf across every known model dir; return $null if absent.
function Resolve-Model([string]$file) {
    foreach ($d in $ModelDirs) {
        $p = Join-Path $d $file
        if (Test-Path $p) { return $p }
    }
    return $null
}

# Total weight size in GiB: for a split gguf, sum all sibling shards, not just shard 1 (which is tiny).
function Get-WeightsGiB([string]$path, [string]$file) {
    $stem = $file -replace '-00001-of-\d+\.gguf$',''
    if ($stem -eq $file) { return [math]::Round((Get-Item $path).Length/1GB,2) }
    $dir = Split-Path $path -Parent
    $sum = ((Get-ChildItem $dir -Filter "$stem-*.gguf" -EA SilentlyContinue) | Measure-Object Length -Sum).Sum
    return [math]::Round($sum/1GB,2)
}

function Show-Reg {
    Write-Host "`nBench registry:" -ForegroundColor Cyan
    foreach ($k in $REG.Keys) {
        $p = Resolve-Model $REG[$k].file
        $gib = if ($p) { Get-WeightsGiB $p $REG[$k].file } else { 0 }
        $where = if ($p) { Split-Path $p -Parent } else { 'MISSING' }
        "{0,-18} {1,-9} {2,7:N2} GiB  {3,-8} {4}" -f $k, $REG[$k].act, $gib, $(if($p){'present'}else{'MISSING'}), $REG[$k].note
        if ($p) { "{0,-18} {1}" -f '', $where }
    }
    Write-Host ""
}
if ($List) { Show-Reg; return }

if ($Quick) { $Depths = @(0, 8192); $Reps = 1 }
$sel = if ($All) { @($REG.Keys) } elseif ($Only) { $Only } else { Write-Error "Specify -Only <label,...> / -All / -List"; exit 1 }
foreach ($s in $sel) { if (-not $REG.Contains($s)) { Write-Error "unknown label '$s'. Known: $($REG.Keys -join ', ')"; exit 1 } }

$bench = Join-Path $Bin 'llama-bench.exe'
if (-not (Test-Path $bench)) { Write-Error "llama-bench.exe not found: $bench"; exit 1 }
# version goes to stderr and the match can be absent -- never let this kill the run
$ver = (& $bench --version 2>&1 | Select-String 'version' | Select-Object -First 1)
Write-Host ("build: {0}" -f $(if ($ver) { $ver.ToString().Trim() } else { 'unknown' })) -ForegroundColor DarkGray

$results = @()
foreach ($s in $sel) {
    $m = $REG[$s]
    $model = Resolve-Model $m.file
    Write-Host "`n================= $s =================" -ForegroundColor Cyan
    if (-not $model) {
        Write-Host ("  SKIP - not present in: {0}" -f ($ModelDirs -join ' ; ')) -ForegroundColor Yellow
        $results += [pscustomobject]@{ label=$s; act=$m.act; weightsGiB=''; status='MISSING'; test=''; tps=''; pkDedGiB=''; pkShrGiB=''; pkTotGiB=''; ramFreeGiB='' }
        continue
    }
    $wGiB = Get-WeightsGiB $model $m.file
    Write-Host ("  weights {0:N2} GiB | {1} | {2}" -f $wGiB, $m.act, $m.note) -ForegroundColor DarkGray

    # --- clean-baseline guard (see OPTIMIZATION.md: dirty baseline => bogus OOM) ---
    Get-Process llama-bench,llama-server,llama-cli -EA SilentlyContinue | Stop-Process -Force -EA SilentlyContinue
    Start-Sleep 6
    # BUDGET-AWARE guard. Don't abort just because memory is held -- abort only if what's left is
    # genuinely too small for THIS model. Held memory is real whether the holder is live or exited.
    $held = Get-GpuHeld
    for ($w=0; $w -lt 24 -and $held -and $held.ReclaimableGB -gt 1.0; $w++) {
        Start-Sleep 5; $held = Get-GpuHeld          # give live stragglers time to release
    }
    $b = Get-GpuMem
    # need = weights + KV/compute headroom. ~12% + 4 GiB covers ubatch 1024 compute buffers and the
    # q8_0 KV for the depths this harness benches; deliberately a little pessimistic.
    $needGiB  = [math]::Round($wGiB * 1.12 + 4.0, 2)
    $heldGiB  = if ($held) { $held.TotalGB } else { 0 }
    $availGiB = [math]::Round($CEILING_GIB - $heldGiB, 2)

    if ($held -and $held.Holders.Count) {
        Write-Host ("  GPU held by others: {0:N2} GiB ({1:N2} reclaimable, {2:N2} STUCK)" -f $heldGiB,$held.ReclaimableGB,$held.StuckGB) -ForegroundColor DarkYellow
        foreach ($h in ($held.Holders | Sort-Object GiB -Descending | Select-Object -First 6)) {
            Write-Host ("    PID {0,-6} {1,-14} [{2}] {3:N2} GiB" -f $h.PID,$h.Name,$h.State,$h.GiB) -ForegroundColor DarkGray
        }
    }
    Write-Host ("  budget: need ~{0:N2} GiB, available ~{1:N2} GiB (ceiling {2} - held {3:N2})" -f $needGiB,$availGiB,$CEILING_GIB,$heldGiB) -ForegroundColor DarkGray

    if ($needGiB -gt $availGiB) {
        Write-Host ("  SKIP {0} - will not fit: needs ~{1:N2} GiB, only ~{2:N2} GiB free." -f $s,$needGiB,$availGiB) -ForegroundColor Red
        if ($held.StuckGB -gt 1.0) {
            Write-Host ("  {0:N2} GiB is held by EXITED-but-unreaped processes. Stop-Process/taskkill cannot free this." -f $held.StuckGB) -ForegroundColor Red
            Write-Host  "  -> reboot, or reap the handle owner, to reclaim it." -ForegroundColor Red
        }
        $stuckPids = @($held.Holders | Where-Object { $_.State -ne 'live' } | Select-Object -Expand PID) -join ','
        $results += [pscustomobject]@{ label=$s; act=$m.act; weightsGiB=$wGiB; status='SKIP-NOFIT'; test="need $needGiB / avail $availGiB"; tps=''
                                       pkDedGiB=$heldGiB; pkShrGiB=''; pkTotGiB=''; ramFreeGiB="stuck PIDs: $stuckPids" }
        continue
    }

    $out = Join-Path $env:TEMP "benchbig-$s.out"
    $err = Join-Path $env:TEMP "benchbig-$s.err"
    # -lm none == the old -mmp 0 (no mmap). b10182 DEPRECATED -mmp/--mmap in favour of
    # --load-mode <none|mmap|mlock|mmap+mlock|dio>, and its DEFAULT IS mmap -- so passing the
    # deprecated flag risked silently benching with mmap, which changes the memory picture entirely
    # (mmap pins a host-side file-cache mirror; see OPTIMIZATION.md "never switch to mmap").
    $a = @('-m',$model,'-ngl',999,'-fa',1,'-ctk','q8_0','-ctv','q8_0','-lm','none',
           '-p',($PromptLens -join ','),'-n',$GenLen,'-d',($Depths -join ','),'-r',$Reps,'-o','md')
    Write-Host ("  running: -p {0} -n {1} -d {2} -r {3}" -f ($PromptLens -join ','), $GenLen, ($Depths -join ','), $Reps) -ForegroundColor DarkGray

    $sw = [Diagnostics.Stopwatch]::StartNew()
    $p = Start-Process $bench -ArgumentList $a -PassThru -WindowStyle Minimized -RedirectStandardOutput $out -RedirectStandardError $err
    # sample peak memory while it runs
    $pkD = 0.0; $pkS = 0.0; $minRam = [double]::MaxValue
    while (-not $p.HasExited) {
        $g = Get-GpuMem
        if ($g.Ded -gt $pkD) { $pkD = $g.Ded }
        if ($g.Shr -gt $pkS) { $pkS = $g.Shr }
        $rf = (Get-CimInstance Win32_OperatingSystem).FreePhysicalMemory/1MB
        if ($rf -lt $minRam) { $minRam = $rf }
        Start-Sleep -Milliseconds 1500
    }
    $sw.Stop()

    # llama-bench emits UTF-8 (the +/- sign); PS 5.1 Get-Content would mangle it to mojibake.
    $text  = if (Test-Path $out) { [IO.File]::ReadAllText($out, [Text.Encoding]::UTF8) } else { '' }
    $etext = if (Test-Path $err) { [IO.File]::ReadAllText($err, [Text.Encoding]::UTF8) } else { '' }
    $rows = @()
    if ($text) { $rows = @($text -split "`n" | Where-Object { $_ -match '^\|' -and $_ -match '\d+\.\d+' -and $_ -notmatch '^\|\s*-' }) }

    if (-not $rows.Count) {
        $oom = if ($etext -match 'ErrorOutOfDeviceMemory|failed to allocate|unable to allocate') { 'OOM' } else { 'FAIL' }
        Write-Host ("  $oom after {0:N1} min" -f $sw.Elapsed.TotalMinutes) -ForegroundColor Red
        if ($etext) { ($etext -split "`n" | Select-Object -Last 6) | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray } }
        $results += [pscustomobject]@{ label=$s; act=$m.act; weightsGiB=$wGiB; status=$oom; test=''; tps=''
                                       pkDedGiB=[math]::Round($pkD/1GB,2); pkShrGiB=[math]::Round($pkS/1GB,2)
                                       pkTotGiB=[math]::Round(($pkD+$pkS)/1GB,2); ramFreeGiB='' }
        continue
    }

    Write-Host ("  OK in {0:N1} min | peak GPU ded {1:N2} / shr {2:N2} / tot {3:N2} GiB | RAM low {4:N1} GiB" -f `
        $sw.Elapsed.TotalMinutes, ($pkD/1GB), ($pkS/1GB), (($pkD+$pkS)/1GB), $minRam) -ForegroundColor Green
    foreach ($r in $rows) {
        $cells = @($r -split '\|' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
        $test = $cells[$cells.Count-2]; $tps = $cells[$cells.Count-1]
        Write-Host ("    {0,-22} {1}" -f $test, $tps) -ForegroundColor Gray
        $results += [pscustomobject]@{ label=$s; act=$m.act; weightsGiB=$wGiB; status='OK'; test=$test; tps=$tps
                                       pkDedGiB=[math]::Round($pkD/1GB,2); pkShrGiB=[math]::Round($pkS/1GB,2)
                                       pkTotGiB=[math]::Round(($pkD+$pkS)/1GB,2); ramFreeGiB=[math]::Round($minRam,1) }
    }
    Start-Sleep 5
}

$results | Export-Csv $Csv -NoTypeInformation
Write-Host "`n================ SUMMARY ================" -ForegroundColor Green
$results | Format-Table -AutoSize | Out-String -Width 190 | Write-Host
Write-Host "csv -> $Csv" -ForegroundColor DarkGray
Write-Host "Ceiling reminder: ~109 GiB total (96 dedicated + ~13.4 shared). Shared spill is FREE here." -ForegroundColor DarkGray
