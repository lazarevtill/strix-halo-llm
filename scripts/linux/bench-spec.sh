#!/usr/bin/env bash
# =============================================================================
#  ⚠️  DRAFT — NOT YET RUN ON LINUX. See scripts/linux/README.md.
#
#  Port of scripts/windows/bench-spec.ps1: A/B a model with and without
#  speculative decoding.
#
#  Why it needs measuring per model rather than assuming (MEASURED on Windows):
#    - native MTP head (--spec-type draft-mtp) was a BIG win: +35% on Qwen3.6-35B-A3B
#    - generic ngram-mod was NEUTRAL on code (14.34/14.07 vs 14.17 baseline = noise)
#    - community data has generic drafts NET-NEGATIVE (-3..-12%) on general MoE text
#  So: measure, do not assume. Speculative decoding is lossless at temp 0 (drafts are
#  verified against the target), so this is a SPEED test only — quality is unchanged.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

BIN="${LLAMA_CLI:-${REPO_ROOT}/bin/llama-cli}"
MODEL=""
SPEC="draft-mtp"
NMAX=3
NPREDICT=256
PROMPT="Write a Python function that merges overlapping intervals, with a short docstring."

usage() {
  cat <<'EOF'
bench-spec.sh — A/B baseline vs speculative decoding (DRAFT, unverified on Linux)

  -m, --model PATH     model to test (required)
      --spec TYPE      --spec-type to test (default: draft-mtp)
      --nmax N         --spec-draft-n-max (default: 3)
      --n-predict N    tokens to generate per run (default: 256)
      --prompt TEXT    prompt to use
  -h, --help

Runs the SAME prompt twice — once plain, once with --spec-type — and reports both
token-generation rates plus the ratio.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -m|--model)   MODEL="$2"; shift 2 ;;
    --spec)       SPEC="$2"; shift 2 ;;
    --nmax)       NMAX="$2"; shift 2 ;;
    --n-predict)  NPREDICT="$2"; shift 2 ;;
    --prompt)     PROMPT="$2"; shift 2 ;;
    -h|--help)    usage; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

[[ -n "$MODEL" ]]  || { echo "--model is required" >&2; usage; exit 2; }
[[ -f "$MODEL" ]]  || { echo "model not found: $MODEL" >&2; exit 1; }
[[ -x "$BIN" ]]    || { echo "llama-cli not found: $BIN (set LLAMA_CLI=)" >&2; exit 1; }

run_one() {
  local label="$1"; shift
  local log; log="$(mktemp)"
  "$BIN" -m "$MODEL" -ngl 999 -fa on -c 8192 -n "$NPREDICT" \
         --temp 0 -p "$PROMPT" "$@" >"$log" 2>&1 || true
  # llama.cpp prints e.g. "eval time = ... ( 58.12 tokens per second)"
  local tg
  tg="$(grep -oE 'eval time.*\(\s*[0-9.]+ tokens per second' "$log" | tail -1 | grep -oE '[0-9.]+ tokens' | grep -oE '[0-9.]+' || echo "")"
  if [[ -z "$tg" ]]; then
    echo "  ${label}: could not parse tg from output — see $log" >&2
    echo ""
  else
    printf '  %-22s %8.2f t/s\n' "$label" "$tg"
    echo "$tg"
  fi
}

echo "A/B speculative decoding — $(basename "$MODEL")"
echo "  spec=${SPEC} n-max=${NMAX} n-predict=${NPREDICT} temp=0"
echo "  ⚠️  DRAFT: output parsing is version-sensitive; confirm against a manual run."
echo

BASE="$(run_one 'baseline' | tail -1)"
SPECV="$(run_one "spec ${SPEC}" --spec-type "$SPEC" --spec-draft-n-max "$NMAX" | tail -1)"

if [[ -n "$BASE" && -n "$SPECV" ]]; then
  awk -v b="$BASE" -v s="$SPECV" 'BEGIN{
    r=s/b
    printf "\n  ratio: %.2fx", r
    if (r < 1.05 && r > 0.95) print "  -> NEUTRAL (within noise; do not enable on this basis)"
    else if (r >= 1.05)       print "  -> WIN"
    else                      print "  -> NET NEGATIVE (leave it off)"
  }'
fi
