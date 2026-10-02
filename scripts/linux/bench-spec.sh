#!/usr/bin/env bash
# =============================================================================
#  ⚠️  DRAFT — NOT YET RUN ON LINUX. See scripts/linux/README.md.
#
#  Port of scripts/windows/bench-spec.ps1: A/B a model with and without
#  speculative decoding, sweeping the draft depth against ONE shared baseline.
#
#  Why it needs measuring per model rather than assuming (MEASURED on Windows):
#    - the gain is strongly model-dependent: draft-mtp n=3 gave 1.79x on one
#      model and 1.11x on another, on the same box
#    - depth is NOT monotonic: n=3 peaked while n=5 fell BELOW no speculation.
#      Always sweep, and sweep downward, never upward
#    - generic ngram-mod was neutral-to-negative
#  So: measure, do not assume. Speculative decoding verifies every draft token
#  against the target, so this is a SPEED test only.
#
#  Harness lessons baked in (each one produced a believable wrong number on Windows):
#    - one DISCARDED warm-up run first: a cold Vulkan session compiles shaders
#      lazily, which would land on the baseline and inflate every speedup
#    - a run with no timing line is a FAILURE (exit 1), never "0 t/s" -- a
#      rejected CLI flag (llama-cli dropped -no-cnv) once yielded a complete,
#      plausible "0 t/s => 0x" sweep with a confident "best:" line
#    - the old-format fallback reads the GENERATION `eval time` line only, never
#      `prompt eval time` (that would record prefill speed as generation speed)
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

BIN="${LLAMA_CLI:-${REPO_ROOT}/bin/llama-cli}"
MODEL=""
SPEC="draft-mtp"
NMAX_LIST="3"
NPREDICT=256
DRAFT_MODEL=""
TEMP=""            # empty = llama-cli's own default sampler, as the Windows script (NOT greedy)
SEED=42
PROMPT="Write a complete, well-documented Python implementation of an LRU cache class with get, put, and eviction. Then write 8 unit tests for it."

usage() {
  cat <<'EOF'
bench-spec.sh — A/B baseline vs speculative decoding (DRAFT, unverified on Linux)

  -m, --model PATH        model to test (required)
      --spec TYPE         --spec-type to test (default: draft-mtp)
      --nmax LIST         draft depth(s), comma-separated, e.g. 1,2,3 (default: 3)
      --draft-model PATH  separate draft model (draft-dflash / draft-eagle3)
      --n-predict N       tokens to generate per run (default: 256)
      --temp T            sampling temperature (default: none passed = llama-cli default
                          sampler; pass 0 for greedy, but do not mix the two in one table)
      --prompt TEXT       prompt to use
      --bin DIR           engine dir holding llama-cli (relative = against the repo root)
  -h, --help

Runs one discarded warm-up, one baseline, then one run per depth, and reports each
depth's generation rate against the shared baseline. Env LLAMA_CLI=/path overrides the
binary when --bin is not given.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -m|--model)    MODEL="$2"; shift 2 ;;
    --spec)        SPEC="$2"; shift 2 ;;
    --nmax)        NMAX_LIST="$2"; shift 2 ;;
    --draft-model) DRAFT_MODEL="$2"; shift 2 ;;
    --n-predict)   NPREDICT="$2"; shift 2 ;;
    --temp)        TEMP="$2"; shift 2 ;;
    --prompt)      PROMPT="$2"; shift 2 ;;
    --bin)         case "$2" in /*) BIN="$2/llama-cli" ;; *) BIN="${REPO_ROOT}/$2/llama-cli" ;; esac; shift 2 ;;
    -h|--help)     usage; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

[[ -n "$MODEL" ]]  || { echo "--model is required" >&2; usage; exit 2; }
[[ -f "$MODEL" ]]  || { echo "model not found: $MODEL" >&2; exit 1; }
[[ -x "$BIN" ]]    || { echo "llama-cli not found: $BIN (set LLAMA_CLI= or --bin)" >&2; exit 1; }
[[ -z "$DRAFT_MODEL" || -f "$DRAFT_MODEL" ]] || { echo "draft model not found: $DRAFT_MODEL" >&2; exit 1; }
IFS=',' read -r -a NMAX <<<"$NMAX_LIST"
for n in "${NMAX[@]}"; do [[ "$n" =~ ^[0-9]+$ ]] || { echo "bad --nmax value: '$n'" >&2; exit 2; }; done

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
printf '%s' "$PROMPT" > "${WORK}/prompt.txt"

# run_one <label> [extra llama-cli args...]  -> sets TPS and ACCEPT, or exits 1 on a dead run.
# Deliberately NOT called inside $(...): an `exit 1` in a command substitution only leaves the
# subshell, which is how a failed run could quietly become an empty value.
TPS=""; ACCEPT=""
run_one() {
  local label="$1"; shift
  local out="${WORK}/${label}.out" err="${WORK}/${label}.err"
  local -a a=(-m "$MODEL" -ngl 999 -fa on -n "$NPREDICT" -f "${WORK}/prompt.txt"
              --no-warmup --simple-io -st --seed "$SEED")
  # NO -no-cnv: llama-cli removed it and rejects it outright. -st (single-turn) gives the
  # non-conversation behaviour it was there for.
  [[ -n "$TEMP" ]] && a+=(--temp "$TEMP")
  "$BIN" "${a[@]}" "$@" >"$out" 2>"$err" || true
  # --simple-io prints "[ Prompt: X t/s | Generation: Y t/s ]" to stdout
  TPS="$(grep -hoE 'Generation:[[:space:]]*[0-9.]+[[:space:]]*t/s' "$out" "$err" 2>/dev/null \
         | tail -1 | grep -oE '[0-9]+(\.[0-9]+)?' | head -1 || true)"
  if [[ -z "$TPS" ]]; then
    # old format: "eval time = ... ( 58.12 tokens per second)" -- the GENERATION line only
    TPS="$(cat "$out" "$err" 2>/dev/null | grep -E '(^|[^a-z_])eval time' | grep -v 'prompt eval' \
           | grep -oE '[0-9]+(\.[0-9]+)?[[:space:]]*tokens per second' | tail -1 \
           | grep -oE '^[0-9]+(\.[0-9]+)?' || true)"
  fi
  ACCEPT="$(grep -E 'accept|n_drafted' "$err" 2>/dev/null | tail -2 | tr -s ' \n' ' ' || true)"
  if [[ -z "$TPS" ]] || ! awk -v t="$TPS" 'BEGIN{exit !(t > 0)}'; then
    local why
    why="$(cat "$err" "$out" 2>/dev/null | grep -iE 'error|invalid|failed' | head -1 || true)"
    echo "[$label] produced NO timing line -- a harness/CLI failure, not a 0 t/s result." >&2
    echo "  first error from llama-cli: ${why:-(none captured)}" >&2
    exit 1
  fi
  return 0
}

echo "A/B speculative decoding — $(basename "$MODEL")"
echo "  spec=${SPEC} depths=${NMAX_LIST} n-predict=${NPREDICT} seed=${SEED} sampler=$([[ -n "$TEMP" ]] && echo "temp ${TEMP}" || echo 'llama-cli default (NOT greedy)')"
echo "  ⚠️  DRAFT: output parsing is version-sensitive; confirm against a manual run."
echo

echo "  warming up (1 discarded run -- cold Vulkan pays shader compilation)..."
run_one warmup

run_one baseline
BASE="$TPS"
printf '  %-26s %8.2f t/s\n' "baseline" "$BASE"

ROWS=()
for n in "${NMAX[@]}"; do
  extra=(--spec-type "$SPEC" --spec-draft-n-max "$n")
  [[ -n "$DRAFT_MODEL" ]] && extra+=(--spec-draft-model "$DRAFT_MODEL")
  run_one "spec_n${n}" "${extra[@]}"
  mult="$(awk -v b="$BASE" -v s="$TPS" 'BEGIN{printf "%.2f", s/b}')"
  printf '  %-26s %8.2f t/s   => %sx\n' "${SPEC} n=${n}" "$TPS" "$mult"
  [[ -n "$ACCEPT" ]] && echo "      draft/accept: $ACCEPT"
  ROWS+=("${n} ${TPS} ${mult}")
done

echo
printf '%s\n' "${ROWS[@]}" | awk -v b="$BASE" -v spec="$SPEC" '
  { if ($2 > best) { best = $2; bn = $1; bm = $3 } if ($3 < 1.0) slow = 1 }
  END {
    if (best > b) printf "  best: %s n=%s at %.2f t/s (%sx)\n", spec, bn, best, bm
    else          printf "  best: baseline at %.2f t/s -- no depth beat it; leave speculation off\n", b
    if (slow) print "  NOTE: at least one depth is SLOWER than no speculation -- depth is not monotonic; do not extrapolate upward."
  }'
