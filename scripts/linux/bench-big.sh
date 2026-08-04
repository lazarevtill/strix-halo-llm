#!/usr/bin/env bash
# =============================================================================
#  ⚠️  DRAFT — NOT YET RUN ON LINUX. See scripts/linux/README.md.
#
#  Port of scripts/windows/bench-big.ps1: benchmark at REAL context depths, not
#  the depth-0 default.
#
#  Why depth matters: `llama-bench` with no -d measures against an EMPTY KV
#  cache. For agentic work that number is a fiction — tg degrades as the cache
#  fills, and depth 0 is the one depth you never actually run at.
#
#  A result without context depth, quant, backend and build attached cannot be
#  compared to anything. This prints all four.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

BENCH="${LLAMA_BENCH:-${REPO_ROOT}/bin/llama-bench}"
MODELS_DIR="${MODELS_DIR:-${REPO_ROOT}/models}"
DEPTHS="0,4096,16384,32768"
OUT="${REPO_ROOT}/bench-big-linux.csv"
MODEL=""

usage() {
  cat <<'EOF'
bench-big.sh — depth-aware benchmark (DRAFT, unverified on Linux)

  -m, --model PATH    single model (default: every .gguf in models/, first shard only)
  -d, --depths LIST   comma-separated -d values (default: 0,4096,16384,32768)
  -o, --out FILE      CSV output (default: <repo>/bench-big-linux.csv)
  -h, --help

Reports pp and tg SEPARATELY. One combined "tok/s" is not a result.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -m|--model)  MODEL="$2"; shift 2 ;;
    -d|--depths) DEPTHS="$2"; shift 2 ;;
    -o|--out)    OUT="$2"; shift 2 ;;
    -h|--help)   usage; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

[[ -x "$BENCH" ]] || { echo "llama-bench not found: $BENCH (set LLAMA_BENCH=)" >&2; exit 1; }

# TODO(linux): the Windows version refuses to start when another process holds GPU memory,
# because a dirty baseline produced THREE false OOM "failures" that all passed on a clean
# box. The amdgpu equivalent is not established -- check sysfs/rocm-smi and add the guard.
if pgrep -x llama-server >/dev/null 2>&1; then
  echo "⚠️  a llama-server is running — it will contend for GPU memory and may invalidate this run." >&2
  echo "    (the Windows version blocks here; this DRAFT only warns)" >&2
fi

if [[ -n "$MODEL" ]]; then
  MODELS=("$MODEL")
else
  mapfile -t MODELS < <(find "$MODELS_DIR" -maxdepth 1 -name '*.gguf' \
                        ! -name '*-0000[2-9]-of-*' ! -name '*mmproj*' | sort)
fi
[[ ${#MODELS[@]} -gt 0 ]] || { echo "no models found in $MODELS_DIR" >&2; exit 1; }

echo "model,depth,test,t_per_sec,stddev" > "$OUT"
echo "build: $("$BENCH" --version 2>&1 | head -1)"
echo "depths: ${DEPTHS}"
echo

for m in "${MODELS[@]}"; do
  echo "=== $(basename "$m") ==="
  # -fa 1 and q8_0 KV mirror the serving config; benchmarking a config you do not serve
  # tells you nothing useful.
  "$BENCH" -m "$m" -ngl 999 -fa 1 -ctk q8_0 -ctv q8_0 \
           -b 2048 -ub 1024 -d "$DEPTHS" -o csv 2>/dev/null \
    | tail -n +2 | while IFS= read -r line; do
        echo "$line" >> "$OUT"
      done
  "$BENCH" -m "$m" -ngl 999 -fa 1 -ctk q8_0 -ctv q8_0 -b 2048 -ub 1024 -d "$DEPTHS" 2>/dev/null \
    | grep -E '\|\s*(pp|tg)' || true
  echo
done

echo "wrote $OUT"
echo "⚠️  DRAFT: numbers from this script have not been cross-checked against the Windows"
echo "    results. Record build + driver alongside them — they move between versions."
