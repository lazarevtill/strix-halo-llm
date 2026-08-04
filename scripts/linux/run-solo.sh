#!/usr/bin/env bash
# =============================================================================
#  ⚠️  DRAFT — NOT YET RUN ON LINUX. See scripts/linux/README.md.
#
#  Written by porting scripts/windows/run-solo.ps1 flag-for-flag. The llama.cpp
#  arguments are the measured-optimal ones from docs/OPTIMIZATION.md and should
#  carry over unchanged. What is NOT verified here is everything touching the
#  OS: GPU memory accounting, the memory ceiling, and whether --mlock helps or
#  hurts. Those are Windows/WDDM findings and must be re-measured.
#
#  Every number this prints as a "ceiling" is a Windows number until someone
#  measures it on Linux. Treat them as placeholders, not facts.
# =============================================================================
set -euo pipefail

# Repo root: this lives in scripts/linux/, so climb out two levels.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

MODEL="${REPO_ROOT}/models/ornith-1.0-35b-Q5_K_M.gguf"
CTX=262144
PORT=8080
BATCH=2048          # MEASURED on gfx1151: pp sweet spot. Should be arch-, not OS-, dependent.
UBATCH=1024
PARALLEL=1          # one interactive agent gets the whole context; -c is SPLIT across slots
SPEC=""
SPEC_NMAX=3
REASONING="auto"
KV_QUANT=1
HOST="0.0.0.0"      # LAN/overlay-reachable by default, matching the Windows launcher
DRY_RUN=0
FORCE=0

usage() {
  cat <<'EOF'
run-solo.sh — serve ONE model with the whole memory budget (DRAFT, unverified on Linux)

  -m, --model PATH       GGUF to serve            (default: Ornith-1.0-35B Q5_K_M)
  -c, --ctx N            context size             (default: 262144)
  -p, --port N           listen port              (default: 8080)
      --host ADDR        bind address             (default: 127.0.0.1)
      --spec TYPE        --spec-type (draft-mtp | ngram-mod | ...)
      --spec-nmax N      --spec-draft-n-max       (default: 3)
      --reasoning MODE   off | on | auto          (default: auto)
      --no-kv-quant      disable q8_0 KV cache (default is q8_0: half size, equal quality)
      --force            stop other llama-servers without asking
      --dry-run          print the command line and exit
  -h, --help

Why Ornith-1.0-35B Q5_K_M is the default: measured 2026-08-04 it TIES Laguna-S-2.1 and
Qwen3.5-122B-A10B on two private eval suites, at a quarter the size and ~4x the speed.
Do NOT "upgrade" to bf16 — measured 5.6x SLOWER on Windows/Vulkan. See docs/BENCHMARKS.md.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -m|--model)      MODEL="$2"; shift 2 ;;
    -c|--ctx)        CTX="$2"; shift 2 ;;
    -p|--port)       PORT="$2"; shift 2 ;;
    --host)          HOST="$2"; shift 2 ;;
    --spec)          SPEC="$2"; shift 2 ;;
    --spec-nmax)     SPEC_NMAX="$2"; shift 2 ;;
    --reasoning)     REASONING="$2"; shift 2 ;;
    --no-kv-quant)   KV_QUANT=0; shift ;;
    --force)         FORCE=1; shift ;;
    --dry-run)       DRY_RUN=1; shift ;;
    -h|--help)       usage; exit 0 ;;
    *) echo "unknown option: $1" >&2; usage; exit 2 ;;
  esac
done

BIN="${LLAMA_BIN:-${REPO_ROOT}/bin/llama-server}"
[[ -x "$BIN" ]]   || { echo "llama-server not found or not executable: $BIN" >&2
                       echo "  set LLAMA_BIN=/path/to/llama-server, or build into ${REPO_ROOT}/bin/" >&2; exit 1; }
[[ -f "$MODEL" ]] || { echo "model not found: $MODEL" >&2; exit 1; }

# ---- solo occupancy ---------------------------------------------------------
# MEASURED ON WINDOWS: two big models cannot co-reside, and the OS does NOT evict
# the incumbent to make room -- the newcomer just fails to allocate. Whether Linux
# behaves the same is UNVERIFIED; amdgpu may evict rather than fail. Re-measure
# before trusting this.
mapfile -t OTHERS < <(pgrep -x llama-server 2>/dev/null || true)
if [[ ${#OTHERS[@]} -gt 0 ]]; then
  echo "other llama-server process(es) running: ${OTHERS[*]}"
  if [[ $FORCE -eq 0 && $DRY_RUN -eq 0 ]]; then
    read -rp "stop them? [y/N] " ans
    [[ "$ans" =~ ^[Yy]$ ]] || { echo "aborted — two big models will not co-reside." >&2; exit 1; }
  fi
  if [[ $DRY_RUN -eq 0 ]]; then
    kill "${OTHERS[@]}" 2>/dev/null || true
    sleep 3
    pgrep -x llama-server >/dev/null 2>&1 && kill -9 "$(pgrep -x llama-server)" 2>/dev/null || true
  fi
fi

# ---- GPU memory report ------------------------------------------------------
# TODO(linux): the Windows version reads '\GPU Process Memory(*)\Total Committed',
# because WDDM trims an idle model's *dedicated* bytes to ~0 while it still holds
# the reservation -- reading the wrong counter under-reported two resident servers
# by 42.5 GB. The equivalent distinction on amdgpu is NOT established. sysfs below
# is a starting point; verify against rocm-smi / amdgpu_top before relying on it.
report_vram() {
  local d used_vram used_gtt
  for d in /sys/class/drm/card*/device; do
    [[ -r "${d}/mem_info_vram_used" ]] || continue
    used_vram=$(cat "${d}/mem_info_vram_used" 2>/dev/null || echo 0)
    used_gtt=$(cat "${d}/mem_info_gtt_used"  2>/dev/null || echo 0)
    printf '  %s: VRAM %.2f GiB, GTT %.2f GiB\n' \
      "$(basename "$(dirname "$d")")" \
      "$(echo "scale=2; ${used_vram}/1073741824" | bc 2>/dev/null || echo 0)" \
      "$(echo "scale=2; ${used_gtt}/1073741824"  | bc 2>/dev/null || echo 0)"
  done
}

# ---- launch -----------------------------------------------------------------
ARGS=(
  -m "$MODEL"
  -ngl 999
  --ctx-size "$CTX"
  --batch-size "$BATCH"
  --ubatch-size "$UBATCH"
  -fa on                      # required for q8_0 KV
  --jinja                     # use the model's own chat template
  --parallel "$PARALLEL"
  --host "$HOST"
  --port "$PORT"
  --no-warmup
  --reasoning "$REASONING"
  --reasoning-preserve        # only does anything if the CLIENT echoes reasoning_content back
)
# --no-mmap is DEPRECATED upstream; --load-mode none is the replacement and defaults to mmap.
ARGS+=(-lm none)
[[ $KV_QUANT -eq 1 ]] && ARGS+=(--cache-type-k q8_0 --cache-type-v q8_0)
[[ -n "$SPEC" ]]      && ARGS+=(--spec-type "$SPEC" --spec-draft-n-max "$SPEC_NMAX")

# NEVER add --mlock on the Windows/WDDM path: it pins weights in system RAM and blocks
# the Vulkan upload. On Linux it may be harmless or even correct -- UNVERIFIED, so it is
# left off here to match the measured-good config.

echo "llama-server (SOLO, Linux DRAFT) -> http://${HOST}:${PORT}"
echo "  model : $(basename "$MODEL")"
echo "  ctx=${CTX} batch=${BATCH}/${UBATCH} fa=on kv=$([[ $KV_QUANT -eq 1 ]] && echo q8_0 || echo f16) parallel=${PARALLEL}"
[[ -n "$SPEC" ]] && echo "  spec  : ${SPEC} (n-max ${SPEC_NMAX})"
echo "  ⚠️  DRAFT: memory ceiling and occupancy behaviour are UNVERIFIED on Linux."
echo "  GPU before launch:"; report_vram

if [[ $DRY_RUN -eq 1 ]]; then
  printf '\n[dry-run] would exec:\n  %s' "$BIN"
  printf ' %q' "${ARGS[@]}"
  printf '\n'
  exit 0
fi

# GGML_VK_ENABLE_MEMORY_PRIORITY requests max priority via VK_EXT_memory_priority /
# VK_EXT_pageable_device_local_memory. Harmless if the extension is absent.
export GGML_VK_ENABLE_MEMORY_PRIORITY="${GGML_VK_ENABLE_MEMORY_PRIORITY:-1}"
exec "$BIN" "${ARGS[@]}"
