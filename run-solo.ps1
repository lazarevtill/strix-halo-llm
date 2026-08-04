<#
.SYNOPSIS
  Serve ONE model at a time, using the full measured memory ceiling of this box (~109 GB).

.DESCRIPTION
  Single-model launcher. Differs from run-server.ps1 / serve-model.ps1 (which were written for the
  multi-model stack) in three ways that matter:

    1. It ENFORCES solo occupancy -- stops any other llama-server first. Two big models cannot
       co-reside: measured, Ornith Q5 (24 GB) + 235B (83 GB) = 107 GB of weights alone OOMs, because
       WDDM does NOT trim a resident model to make room; the newcomer just fails.
    2. Context defaults to the model's maximum rather than a conservative 32K. With the whole
       109 GB budget for one model there is no reason to leave context on the table -- e.g. Ornith
       Q5_K_M runs its FULL 262144 ctx in 29.93 GB at ~58-62 t/s (measured 2026-07-30).
    3. It sets GGML_VK_ENABLE_MEMORY_PRIORITY=1 (present in b9771; requests max priority via
       VK_EXT_memory_priority / VK_EXT_pageable_device_local_memory).

  MEASURED CEILING (see OPTIMIZATION.md): 96 GB dedicated + ~13.4 GB usable WDDM shared = ~109 GB.
  tg is FLAT from 89 GB to 109 GB -- spilling past the carve-out costs nothing on this UMA APU.
  Do NOT use --fit / llama-fit-params here: -ngl 999 aborts the fit, and llama.cpp's reported free
  VRAM is a constant, not a measurement. Size context from the table instead.

  WHY ORNITH Q5_K_M IS THE DEFAULT (measured 2026-08-04, not assumed): scored against
  Laguna-S-2.1 Q4_K_M and Qwen3.5-122B-A10B Q4_K_XL on two private uncontaminated suites, it TIES
  both -- tool calling 28/29 vs 28/29 vs 27/29 (all CIs overlap, McNemar p=1.0), agentic coding
  70/70 for all three -- at 23 GB instead of 78/89 GB and ~58 t/s instead of ~34/~14. Pick a bigger
  model only for a capability you actually need (draft-mtp on Qwen, >262K ctx on Laguna), not for
  expected quality. See BENCHMARKS.md.

  Do NOT "upgrade" to bf16: measured 11.17 t/s, 5.6x slower than Q5_K_M, and pp collapses too.

.EXAMPLE
  .\run-solo.ps1                                    # Ornith-1.0-35B Q5_K_M at full 262144 ctx
  .\run-solo.ps1 -Model .\models\<big>.gguf -Ctx 131072
  .\run-solo.ps1 -Spec draft-mtp                    # if the GGUF carries an MTP head (+35%)
  .\run-solo.ps1 -Reasoning off                     # fast direct answers (router/tool-call use)
  .\run-solo.ps1 -DryRun                            # print the command line, launch nothing
#>
[CmdletBinding()]
param(
    [string] $Model  = 'C:\llm-router\models\ornith-1.0-35b-Q5_K_M.gguf',
    [int]    $Ctx    = 262144,      # measured OK for Ornith Q5_K_M (29.93 GB total). Lower for bigger weights.
    [int]    $Port   = 8080,
    [int]    $Batch  = 2048,        # measured pp sweet spot on gfx1151
    [int]    $Ubatch = 1024,
    # none | draft-dflash | draft-mtp | draft-eagle3 | ngram-mod | ... (see --spec-type in --help)
    [string] $Spec   = 'none',
    [string] $SpecDraftModel = '',  # separate draft GGUF, e.g. laguna-s-2.1-DFlash-BF16.gguf
    [int]    $SpecNMax = 3,
    [string] $Mmproj = '',          # vision projector for VL models
    [ValidateSet('off','on','auto')] [string] $Reasoning = 'auto',
    [int]    $ReasoningBudget = -1,
    [switch] $ReasoningPreserve,    # keep prior turns' reasoning in history (poolside rec. for Laguna)
    # Server slots. 1 = one interactive agent gets the whole context (the default here).
    # >1 enables concurrent requests + continuous batching: raises AGGREGATE throughput, NOT
    # per-request speed. NOTE: -c is the TOTAL context and is SPLIT across slots, so
    # -Parallel 4 -Ctx 131072 gives four 32768-token slots. Raise -Ctx to compensate; KV scales with
    # it. -KvUnified uses one shared KV buffer instead of per-slot partitions.
    [int]    $Parallel = 1,
    [switch] $KvUnified,
    [switch] $NoKvQuant,            # default KV is q8_0 (half size, equal quality, needs -fa on)
    [switch] $NoMemPriority,        # skip GGML_VK_ENABLE_MEMORY_PRIORITY
    [switch] $DryRun,
    [switch] $Force                 # stop other servers even if they have a request in flight
)
$ErrorActionPreference = 'Stop'
$bin = "$PSScriptRoot\bin\llama-server.exe"
$gpu = 'luid_0x00000000_0x01c3ed4a_phys_0'
if (-not (Test-Path $bin))   { Write-Error "llama-server.exe not found: $bin"; exit 1 }
if (-not (Test-Path $Model)) { Write-Error "Model not found: $Model"; exit 1 }
$Model = (Resolve-Path $Model).Path

function Get-GpuDedGB {
    try { return [math]::Round((Get-Counter "\GPU Adapter Memory($gpu)\dedicated usage" -EA Stop).CounterSamples[0].CookedValue/1GB, 2) } catch { return -1 }
}

# ---- 1) enforce solo occupancy ------------------------------------------------------------------
$others = @(Get-Process llama-server -EA SilentlyContinue)
if ($others.Count -and -not $DryRun) {
    # Only servers that actually MATTER block us: ones holding real VRAM, or ones squatting on our
    # port. Idle/zombie servers holding nothing are harmless -- and if they were started elevated we
    # cannot kill them anyway, so refusing on their account would deadlock the launcher for nothing.
    # USE 'Total Committed', NOT 'Dedicated Usage'. MEASURED 2026-08-03: two idle llama-servers read
    # ~0 GiB dedicated (WDDM had trimmed them) while committing 24.56 and 17.93 GiB -- 42.5 GiB of
    # real budget invisible to the dedicated counter. Laguna then OOM'd at 1.5 GiB with "109 GiB
    # free" on screen. Committed is what the allocator actually has to respect.
    $procVram = @{}
    try {
        foreach ($s in (Get-Counter '\GPU Process Memory(*)\Total Committed' -EA Stop).CounterSamples) {
            $q = ([regex]::Match($s.InstanceName,'pid_(\d+)')).Groups[1].Value
            if ($q) { $procVram[[int]$q] = [double]$procVram[[int]$q] + $s.CookedValue }
        }
    } catch {}
    $portOwner = (Get-NetTCPConnection -LocalPort $Port -State Listen -EA SilentlyContinue).OwningProcess

    $blocking = @($others | Where-Object {
        ($procVram.ContainsKey($_.Id) -and $procVram[$_.Id] -gt 2GB) -or ($portOwner -contains $_.Id)
    })
    $ignored = @($others | Where-Object { $_.Id -notin $blocking.Id })
    foreach ($g in $ignored) {
        Write-Host ("  note: llama-server PID {0} holds no VRAM and not on :{1} -- ignoring" -f $g.Id, $Port) -ForegroundColor DarkGray
    }

    foreach ($o in $blocking) {
        if (-not $Force) {
            # refuse to kill a server that is mid-request (unless -Force)
            $busy = 0
            foreach ($prt in 8080..8099) {
                $owner = (Get-NetTCPConnection -LocalPort $prt -State Listen -EA SilentlyContinue).OwningProcess
                if ($owner -eq $o.Id) {
                    try { $busy = @((Invoke-RestMethod "http://127.0.0.1:$prt/slots" -TimeoutSec 3) | Where-Object { $_.is_processing }).Count } catch {}
                }
            }
            if ($busy -gt 0) { Write-Error "llama-server PID $($o.Id) has $busy active request(s). Wait, or use -Force."; exit 1 }
        }
        Write-Host "  stopping other llama-server PID $($o.Id) (solo mode)" -ForegroundColor Yellow
        try { Stop-Process -Id $o.Id -Force -EA Stop }
        catch { Write-Error "Cannot stop PID $($o.Id): $($_.Exception.Message)`nIt is probably ELEVATED. Re-run this script as Administrator, or kill it from an elevated shell."; exit 1 }
    }
}

# ---- 2) wait for the GPU to actually drain ------------------------------------------------------
# A stale allocation causes a bogus ErrorOutOfDeviceMemory that looks like "model too big".
if (-not $DryRun) {
    for ($i = 0; $i -lt 40; $i++) {
        $d = Get-GpuDedGB
        if ($d -lt 0 -or $d -le 3.0) { break }
        Write-Host ("  waiting for GPU to drain... dedicated {0} GB" -f $d) -ForegroundColor DarkYellow
        Start-Sleep -Seconds 5
    }
    $d = Get-GpuDedGB
    if ($d -gt 3.0) { Write-Warning "GPU still holds ${d} GB. An OOM here means a stale allocation, not an oversized model." }
}

# ---- 3) build the command line -----------------------------------------------------------------
$a = @(
    '-m', $Model,
    '-ngl', 999,
    '--ctx-size', $Ctx,
    '--batch-size', $Batch,
    '--ubatch-size', $Ubatch,
    '-fa', 'on',
    # -lm none == the old --no-mmap. b10182 DEPRECATED --no-mmap/--mlock in favour of --load-mode,
    # and --load-mode DEFAULTS TO mmap -- so relying on the deprecated flag is a trap waiting to
    # spring. mmap here pins a ~21 GB host file-cache mirror in physical RAM (measured 2026-06-26,
    # "RAM 100%"); 'none' keeps weights in the VRAM carve-out with the host copy paged out.
    '-lm', 'none',
    '--jinja',
    '--parallel', $Parallel,     # 1 = one slot gets the whole context, no KV split
    # NO --cache-reuse. VERIFIED 2026-07-30 on the production 35B: the server logs
    #   "srv load_model: cache_reuse is not supported by this context, it will be disabled"
    # It needs KV shifting (llama_memory_can_shift), which is false for this MoE context. Not caused
    # by q8_0 KV or kv_unified (both were tested). It was a silent no-op -- misleading, so it's gone.
    # You don't need it: plain PREFIX CACHING already avoids re-prefill on append-only conversations.
    # MEASURED 4-step agentic loop: step1 prompt_n=2185 cache_n=0; steps 2-4 prompt_n=344 with
    # cache_n growing 2181->2521->2861. Only genuinely new tokens are prefilled. (cache_prompt is on
    # by default.) --cache-reuse only helps when a prefix diverges in the MIDDLE.
    '--host', '0.0.0.0',
    '--port', $Port,
    '--no-warmup'
)
if (-not $NoKvQuant)          { $a += @('--cache-type-k','q8_0','--cache-type-v','q8_0') }
if ($KvUnified)               { $a += '--kv-unified' }
if ($Reasoning -ne 'auto')    { $a += @('--reasoning', $Reasoning) }
if ($ReasoningBudget -ge 0)   { $a += @('--reasoning-budget', $ReasoningBudget) }
# poolside on Laguna: "For agentic coding use cases we recommend enabling thinking and PRESERVING
# reasoning in the message history." --reasoning-preserve keeps prior turns' reasoning_content in
# the re-rendered prompt instead of stripping it, which is what their template's preserve_thinking
# branch expects. Harmless on models that emit no thinking.
if ($ReasoningPreserve)       { $a += '--reasoning-preserve' }
if ($Spec -ne 'none') {
    $a += @('--spec-type', $Spec, '--spec-draft-n-max', $SpecNMax)
    if ($SpecDraftModel) {
        if (-not (Test-Path $SpecDraftModel)) { Write-Error "draft model not found: $SpecDraftModel"; exit 1 }
        $a += @('--spec-draft-model', (Resolve-Path $SpecDraftModel).Path)
    }
}
if ($Mmproj) {
    if (-not (Test-Path $Mmproj)) { Write-Error "mmproj not found: $Mmproj"; exit 1 }
    $a += @('--mmproj', (Resolve-Path $Mmproj).Path)
}
# NEVER --mlock here: it pins weights in the 32 GB system-RAM partition and blocks the Vulkan
# upload to the carve-out (measured 2026-06-26). --no-mmap alone gives permanent VRAM residency.

if (-not $NoMemPriority) { $env:GGML_VK_ENABLE_MEMORY_PRIORITY = '1' }

Write-Host "`nllama-server (Vulkan, SOLO) -> http://127.0.0.1:$Port" -ForegroundColor Green
Write-Host ("  model     : {0}" -f (Split-Path $Model -Leaf)) -ForegroundColor DarkGray
Write-Host ("  weights   : {0:N2} GB on disk" -f ((Get-Item $Model).Length/1GB)) -ForegroundColor DarkGray
$perSlot = if ($Parallel -gt 1 -and -not $KvUnified) { [int]($Ctx / $Parallel) } else { $Ctx }
Write-Host ("  ctx={0}  batch={1}/{2}  fa=on  kv={3}  parallel={4}{5}" -f $Ctx, $Batch, $Ubatch, $(if($NoKvQuant){'f16'}else{'q8_0'}), $Parallel, $(if($KvUnified){' (kv-unified)'}else{''})) -ForegroundColor DarkGray
if ($Parallel -gt 1 -and -not $KvUnified) { Write-Host ("  -> {0} slots x {1} tokens each (ctx is SPLIT across slots)" -f $Parallel, $perSlot) -ForegroundColor DarkYellow }
Write-Host ("  mem-priority: {0}" -f $(if($NoMemPriority){'off'}else{'ON'})) -ForegroundColor DarkGray
if ($Spec -ne 'none') { Write-Host ("  spec      : {0} (n-max {1})" -f $Spec, $SpecNMax) -ForegroundColor Magenta }
Write-Host "  ceiling   : ~109 GB total (96 dedicated + ~13.4 shared). tg is flat up to it." -ForegroundColor DarkGray
Write-Host ("  OpenAI API: http://127.0.0.1:{0}/v1   |   Web UI: http://127.0.0.1:{0}" -f $Port) -ForegroundColor Cyan

if ($DryRun) { Write-Host "`n[DryRun] would run:`n  $bin $($a -join ' ')" -ForegroundColor Yellow; return }
& $bin @a
