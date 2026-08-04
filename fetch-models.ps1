<#
.SYNOPSIS
  Download the July-2026 "biggest that fits" model set for this box, with resume + size verification.

.DESCRIPTION
  Replaces download-model.ps1 for large multi-shard models. Differences that matter at this scale:
    * uses curl.exe (ships with Windows) with `-C -` so an interrupted 90 GB download RESUMES
      instead of restarting; Invoke-WebRequest has no resume and buffers badly
    * verifies each file against its EXPECTED byte count (from the HF API) and re-fetches on mismatch
    * skips files already complete, so re-running is cheap and idempotent
    * registry of vetted models: every size here was byte-summed from the HF API, not estimated

  MEASURED CEILING on this box is ~109 GiB total (96 GiB carve-out + ~13.4 GiB WDDM shared).
  Sizes below are GiB of weights; leave room for KV + compute buffers. See OPTIMIZATION.md.

.EXAMPLE
  .\fetch-models.ps1 -List                       # show the registry, sizes, what's already present
  .\fetch-models.ps1 -Only ornith-bf16           # one model
  .\fetch-models.ps1 -Only ornith-bf16,qwen122b  # several
  .\fetch-models.ps1 -All                        # the whole bench set (~314 GiB)
  .\fetch-models.ps1 -All -WhatIf                # plan only
#>
[CmdletBinding()]
param(
    [string[]] $Only,
    [switch]   $All,
    [switch]   $List,
    [switch]   $WhatIf,
    [string]   $Dest = 'D:\llamacpp-vulkan\models'
)
$ErrorActionPreference = 'Continue'

# label -> repo, files (path within repo), expected bytes per file, notes
# Every byte count verified against https://huggingface.co/api/models/<repo>/tree/... on 2026-07-30.
$REG = [ordered]@{
    'ornith-bf16' = @{
        repo  = 'deepreinforce-ai/Ornith-1.0-35B-GGUF'
        files = @(@{ p='ornith-1.0-35b-bf16.gguf'; b=69376636800 })
        note  = '35B/A3B FULL PRECISION. Fastest of the set (~63 t/s at Q5). 262K ctx, MIT.'
    }
    'ornith-q8' = @{
        repo  = 'deepreinforce-ai/Ornith-1.0-35B-GGUF'
        files = @(@{ p='ornith-1.0-35b-Q8_0.gguf'; b=36903138880 })
        note  = '35B/A3B near-lossless, half the size of bf16.'
    }
    'qwen122b' = @{
        repo  = 'unsloth/Qwen3.5-122B-A10B-MTP-GGUF'
        files = @(
            @{ p='UD-Q4_K_XL/Qwen3.5-122B-A10B-UD-Q4_K_XL-00001-of-00003.gguf'; b=10943808 },
            @{ p='UD-Q4_K_XL/Qwen3.5-122B-A10B-UD-Q4_K_XL-00002-of-00003.gguf'; b=49667346080 },
            @{ p='UD-Q4_K_XL/Qwen3.5-122B-A10B-UD-Q4_K_XL-00003-of-00003.gguf'; b=28968190016 }
        )
        note  = '125B/A10B, honest 4-bit, 262K ctx, Apache-2.0. MTP head -> --spec-type draft-mtp.'
    }
    'laguna' = @{
        repo  = 'poolside/Laguna-S-2.1-GGUF'
        files = @(
            @{ p='laguna-s-2.1-Q4_K_M.gguf';     b=96031829760 },
            @{ p='laguna-s-2.1-DFlash-BF16.gguf'; b=2233764224 },
            @{ p='chat_template.jinja';           b=4028 }
        )
        note  = '118B/A8B, 1M ctx, OpenMDW-1.1. Best agentic-coding scores (TB2.1 70.2%). DFlash draft incl.'
    }
    'deepseek-v4-flash' = @{
        repo  = 'unsloth/DeepSeek-V4-Flash-GGUF'
        files = @(
            @{ p='UD-IQ2_M/DeepSeek-V4-Flash-UD-IQ2_M-00001-of-00003.gguf'; b=5256864 },
            @{ p='UD-IQ2_M/DeepSeek-V4-Flash-UD-IQ2_M-00002-of-00003.gguf'; b=49956780160 },
            @{ p='UD-IQ2_M/DeepSeek-V4-Flash-UD-IQ2_M-00003-of-00003.gguf'; b=40964890464 }
        )
        note  = '284B/A13B, 1M ctx, MIT. BUT ~2-bit quant and the slowest tg here (highest active params).'
    }
}
# DELIBERATELY NOT IN THE REGISTRY (2026-07-30, user's call): gpt-oss-120b and any other 2025-era
# model. The bar is "Ornith-1.0-35B-tier agentic/coding quality or better, 2026 releases only" --
# gpt-oss-120b is the oldest thing in its size class and does not clear it. Don't re-add it.

function Show-Reg {
    Write-Host "`nRegistry (label -> weights GiB, status):" -ForegroundColor Cyan
    foreach ($k in $REG.Keys) {
        # NB: PS 5.1 Measure-Object cannot read hashtable keys as properties -- sum by hand.
        $tot = 0; foreach ($f in $REG[$k].files) { if ($f.b -gt 0) { $tot += $f.b } }
        $have = 0
        foreach ($f in $REG[$k].files) {
            $lp = Join-Path $Dest ([IO.Path]::GetFileName($f.p))
            if (Test-Path $lp) { $have += (Get-Item $lp).Length }
        }
        $pct = if ($tot -gt 0) { [math]::Round(100*$have/$tot) } else { 0 }
        $st  = if ($tot -gt 0 -and $have -ge $tot) { 'COMPLETE' } elseif ($have -gt 0) { "$pct%" } else { '-' }
        "{0,-18} {1,8:N2} GiB  {2,-9}  {3}" -f $k, ($tot/1GB), $st, $REG[$k].note
    }
    $d = Get-PSDrive ($Dest.Substring(0,1)) -EA SilentlyContinue
    if ($d) { Write-Host ("`n{0}: {1:N1} GiB free" -f $d.Name, ($d.Free/1GB)) -ForegroundColor DarkGray }
    Write-Host ""
}
if ($List) { Show-Reg; return }

if (-not (Test-Path $Dest)) { New-Item -ItemType Directory -Force $Dest | Out-Null }
$curl = (Get-Command curl.exe -EA SilentlyContinue).Source
if (-not $curl) { Write-Error "curl.exe not found (expected in C:\Windows\System32). Cannot resume large downloads."; exit 1 }

$sel = if ($All) { @($REG.Keys) } elseif ($Only) { $Only } else { Write-Error "Specify -Only <label,...> / -All / -List"; exit 1 }
foreach ($s in $sel) { if (-not $REG.Contains($s)) { Write-Error "unknown label '$s'. Known: $($REG.Keys -join ', ')"; exit 1 } }

$plannedBytes = 0
foreach ($s in $sel) { foreach ($f in $REG[$s].files) { if ($f.b -gt 0) { $plannedBytes += $f.b } } }
$drv = Get-PSDrive ($Dest.Substring(0,1))
Write-Host ("`nPlan: {0} model(s), ~{1:N1} GiB into {2}" -f $sel.Count, ($plannedBytes/1GB), $Dest) -ForegroundColor Cyan
Write-Host ("{0}: {1:N1} GiB free -> ~{2:N1} GiB after" -f $drv.Name, ($drv.Free/1GB), (($drv.Free-$plannedBytes)/1GB)) -ForegroundColor DarkGray
if ($plannedBytes -gt $drv.Free) { Write-Error "Not enough free space on $($drv.Name):"; exit 1 }
if ($WhatIf) { Write-Host "[WhatIf] nothing downloaded." -ForegroundColor Yellow; return }

$grand = [Diagnostics.Stopwatch]::StartNew()
$doneBytes = 0
foreach ($s in $sel) {
    $m = $REG[$s]
    Write-Host "`n=============== $s ===============" -ForegroundColor Cyan
    Write-Host "  $($m.note)" -ForegroundColor DarkGray
    foreach ($f in $m.files) {
        $name = [IO.Path]::GetFileName($f.p)
        $out  = Join-Path $Dest $name
        $url  = "https://huggingface.co/$($m.repo)/resolve/main/$($f.p)"

        if ((Test-Path $out) -and $f.b -gt 0 -and (Get-Item $out).Length -eq $f.b) {
            Write-Host ("  [have] {0} ({1:N2} GiB)" -f $name, ($f.b/1GB)) -ForegroundColor DarkGreen
            $doneBytes += $f.b; continue
        }
        if ((Test-Path $out) -and $f.b -gt 0 -and (Get-Item $out).Length -gt $f.b) {
            Write-Host ("  [bad size, refetching] $name") -ForegroundColor Yellow
            Remove-Item $out -Force
        }
        $existing = if (Test-Path $out) { (Get-Item $out).Length } else { 0 }
        if ($existing -gt 0) { Write-Host ("  [resume @ {0:N2} GiB] {1}" -f ($existing/1GB), $name) -ForegroundColor Yellow }
        else                 { Write-Host ("  [get] {0}" -f $name) -ForegroundColor Green }

        $sw = [Diagnostics.Stopwatch]::StartNew()
        # -L follow redirects (HF -> CDN), -C - resume, --retry survive transient CDN faults
        & $curl -L -C - --retry 8 --retry-delay 5 --retry-all-errors `
                --connect-timeout 30 -o $out $url
        $sw.Stop()

        if (-not (Test-Path $out)) { Write-Host "  FAILED (no file): $name" -ForegroundColor Red; continue }
        $got = (Get-Item $out).Length
        if ($f.b -gt 0 -and $got -ne $f.b) {
            Write-Host ("  SIZE MISMATCH {0}: got {1} expected {2} -- re-run to resume" -f $name, $got, $f.b) -ForegroundColor Red
        } else {
            $mbps = if ($sw.Elapsed.TotalSeconds -gt 0) { [math]::Round((($got-$existing)/1MB)/$sw.Elapsed.TotalSeconds,1) } else { 0 }
            Write-Host ("  OK {0:N2} GiB in {1:N1} min ({2} MB/s)" -f ($got/1GB), $sw.Elapsed.TotalMinutes, $mbps) -ForegroundColor Cyan
        }
        $doneBytes += $got
    }
}
$grand.Stop()
Write-Host ("`nTotal: {0:N1} GiB in {1:N1} min" -f ($doneBytes/1GB), $grand.Elapsed.TotalMinutes) -ForegroundColor Green
Show-Reg
