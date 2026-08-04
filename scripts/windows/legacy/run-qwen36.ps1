<#
.SYNOPSIS
  One-command launcher for MTP Qwen3.6-35B-A3B on the Radeon 8060S (Vulkan): speculative
  decoding (MTP) + vision (image input) + OpenAI API/web UI on :8080.

  Guarantees the model lives PERMANENTLY in the 96GB VRAM carve-out and is NEVER offloaded to
  system RAM, for the life of the process. Recipe (this box, Strix Halo / UMA):
    -ngl 999          all layers on GPU
    --no-mmap         weights go straight into the Vulkan device buffer (no file mmap to page
                      out / refetch, no 27GB RAM mirror)
    q8_0 KV cache     half-size KV so even 128K context stays in VRAM (set via run-server.ps1)
    NO --mlock        (it pins weights in the ~32GB system-RAM partition and BLOCKS the VRAM
                      upload: measured GPU ~0, RAM ~1GB free. See OPTIMIZATION.md #8.)
    NO --n-cpu-moe / --override-tensor *=CPU / --fit / --no-mmproj-offload  (those offload to RAM)
  After load it ASSERTS the weights are resident in VRAM and warns if they spilled to RAM.

.EXAMPLE
  .\run-qwen36.ps1                 # MTP + vision, pinned in VRAM, on :8080
  .\run-qwen36.ps1 -NoVision       # text only (skip the vision projector)
  .\run-qwen36.ps1 -Force          # restart even if a request is in flight (skip Pi-idle check)
#>
[CmdletBinding()]
param(
    [int]    $Port = 8080,
    [int]    $Ctx  = 131072,
    [switch] $NoVision,             # skip mmproj (text-only)
    [switch] $Force                 # restart even if a slot is busy (otherwise respect Pi-idle rule)
)
$ErrorActionPreference = 'Stop'
$root   = $($PSScriptRoot | Split-Path -Parent | Split-Path -Parent | Split-Path -Parent)
$model  = Join-Path $root 'models\MTP-Qwen3.6-35B-A3B-UD-Q4_K_M.gguf'
$mmproj = Join-Path $root 'models\mmproj-F16.gguf'
$runner = Join-Path $root 'run-server.ps1'
foreach ($f in @($model, $runner)) { if (-not (Test-Path $f)) { Write-Error "missing: $f"; exit 1 } }
$useVision = (-not $NoVision) -and (Test-Path $mmproj)
if ((-not $NoVision) -and (-not (Test-Path $mmproj))) {
    Write-Warning "mmproj not found ($mmproj) - starting text-only. Get it with:"
    Write-Warning "  .\download-model.ps1 -Repo unsloth/Qwen3.6-35B-A3B-MTP-GGUF -File mmproj-F16.gguf"
}

# --- respect the Pi-idle rule: do not kill a server mid-request ----------------------------------
$existing = (Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue).OwningProcess
if ($existing) {
    $busy = 0
    try { $busy = (Invoke-RestMethod "http://127.0.0.1:$Port/slots" -TimeoutSec 5 |
                   Where-Object { $_.is_processing } | Measure-Object).Count } catch {}
    if ($busy -gt 0 -and -not $Force) {
        Write-Error "A server on :$Port has $busy active request(s). Re-run with -Force to restart anyway."
        exit 1
    }
    Write-Host "Stopping existing server on :$Port (PID $existing, idle)..." -ForegroundColor Yellow
    Stop-Process -Id $existing -Force
    Start-Sleep -Seconds 3
}

# --- launch the verified config in its own window (runs until you Ctrl+C / close it) --------------
$visArgs = if ($useVision) { @('-Mmproj', $mmproj) } else { @() }
$scriptArgs = @(
    '-ExecutionPolicy','Bypass','-NoExit','-File', $runner,
    '-Model', $model, '-Ctx', $Ctx, '-Port', $Port, '-Spec','draft-mtp',
    '-Temp','0.6','-TopP','0.95','-TopK','20','-MinP','0'   # Qwen3 thinking-mode quality defaults
) + $visArgs
Write-Host "Launching MTP Qwen3.6 (vision=$useVision) on :$Port ..." -ForegroundColor Green
Start-Process powershell -ArgumentList $scriptArgs | Out-Null

# --- wait for it to come up ----------------------------------------------------------------------
Write-Host "Waiting for the model to load into VRAM..." -ForegroundColor DarkGray
$up = $false
for ($i = 0; $i -lt 60; $i++) {
    try { if ((Invoke-RestMethod "http://127.0.0.1:$Port/health" -TimeoutSec 3).status -eq 'ok') { $up = $true; break } } catch {}
    Start-Sleep -Seconds 3
}
if (-not $up) { Write-Error "Server did not become healthy on :$Port within ~3 min."; exit 1 }

# --- ASSERT the weights are resident in VRAM, not spilled to system RAM ---------------------------
$srvPid = (Get-NetTCPConnection -LocalPort $Port -State Listen).OwningProcess
$vram = 0.0
try {
    $vram = (((Get-Counter '\GPU Process Memory(*)\Dedicated Usage').CounterSamples |
        Where-Object { $_.InstanceName -like "*$srvPid*" } |
        Measure-Object CookedValue -Sum).Sum) / 1GB
} catch {}
$os      = Get-CimInstance Win32_OperatingSystem
$ramFree = $os.FreePhysicalMemory / 1MB
Write-Host ""
Write-Host ("VRAM resident (GPU dedicated) : {0:N1} GB" -f $vram) -ForegroundColor Cyan
Write-Host ("System RAM free              : {0:N1} GB / {1:N1} GB" -f $ramFree, ($os.TotalVisibleMemorySize/1MB)) -ForegroundColor Cyan

# Healthy load = bulk of the model sits in VRAM and RAM did not crater. The mlock-spill failure
# showed GPU dedicated ~0.1GB and RAM ~1GB free; a good load shows ~25GB VRAM and >15GB RAM free.
if ($vram -lt 15 -or $ramFree -lt 4) {
    Write-Host "WARNING: model appears to have spilled to system RAM (NOT fully in VRAM)." -ForegroundColor Red
    Write-Host "         Check for --mlock / --n-cpu-moe / --override-tensor CPU. See OPTIMIZATION.md." -ForegroundColor Red
} else {
    Write-Host "PASS: model is pinned in VRAM and will stay there until you stop the server." -ForegroundColor Green
}
Write-Host ""
Write-Host "  Local    : http://127.0.0.1:$Port    (web UI + OpenAI API /v1)" -ForegroundColor Cyan
# NetBird overlay address. NetBird assigns from the 100.64.0.0/10 CGNAT range, so match the
# second octet properly rather than '100.*' (which would also catch 100.0-63.x public space).
$nb = (Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
       Where-Object { $_.IPAddress -match '^100\.(6[4-9]|[7-9]\d|1[01]\d|12[0-7])\.' } |
       Select-Object -First 1).IPAddress
if ($nb) { Write-Host ("  NetBird: http://{0}:{1}" -f $nb, $Port) -ForegroundColor Cyan }
Write-Host ("  Stop     : close the server window, or  Stop-Process -Id {0}" -f $srvPid) -ForegroundColor DarkGray
