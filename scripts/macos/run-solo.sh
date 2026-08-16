#!/usr/bin/env bash
# =============================================================================
#  Serve ONE model on Apple silicon (Metal), with the whole memory budget.
#
#  ⚠️  DRAFT — written on a Windows box, never run on macOS. The llama.cpp flags
#  are ported from the measured-optimal Windows config; the ones that are
#  ARCHITECTURE-specific are marked below and should be re-measured here.
#
#  WHAT ALMOST CERTAINLY DOES NOT TRANSFER: -ub 256. On gfx1151 the small ubatch
#  wins because a 256-row tile fits in 32 KB of shared memory; Apple's GPU has a
#  different threadgroup memory budget, so the sweet spot is a different number.
#  Sweep it before believing any of it — see scripts/macos/README.md.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

MODEL=""                                    # empty => pick interactively from MODELS_DIR
MODELS_DIR="${MODELS_DIR:-${REPO_ROOT}/models}"   # same env override as fetch-models.sh
CTX=131072
PORT=8080
BATCH=2048
UBATCH=512          # NOT the Windows 256 -- unmeasured here. See the header.
PARALLEL=1
SPEC=""
SPEC_NMAX=3
KV_QUANT=1
HOST="127.0.0.1"
DRY_RUN=0

usage() {
  cat <<'EOF'
run-solo.sh (macOS/Metal) — serve ONE model with the whole memory budget (DRAFT)

  -m, --model PATH       GGUF to serve         (default: pick one from models/)
  -c, --ctx N            context size          (default: 131072)
  -p, --port N           listen port           (default: 8080)
      --host ADDR        bind address          (default: 127.0.0.1)
      --ubatch N         --ubatch-size         (default: 512 — UNMEASURED on Metal)
      --spec TYPE        --spec-type (draft-mtp | ngram-mod | ...)
      --no-kv-quant      disable q8_0 KV cache
      --dry-run          print the command line and exit
  -h, --help

HOW MUCH MEMORY THE GPU MAY HAVE
macOS caps GPU-"wired" memory well below installed RAM. This is the Apple
equivalent of the BIOS carve-out this repo spends so much time on, and it is the
first thing to check when a model that should fit refuses to load:

  sysctl iogpu.wired_limit_mb                    # 0 = system default (~65-75%)
  sudo sysctl iogpu.wired_limit_mb=<MB>          # raise it; resets on reboot

Leave several GB for the OS. Setting it to your full RAM will hang the machine,
not speed anything up.

With no -m/--model this lists the GGUFs in models/ and asks which to serve. Set MODELS_DIR
to look somewhere else. There is no built-in default model on purpose: the previous one was a
path that only existed on the machine this repo was written on.
EOF
}

# Interactive picker. Only reached when no -m/--model was given.
# NOTE: no `((i++))` anywhere below -- it evaluates to the PRE-increment value, so the first
# call returns 0, which is a non-zero exit status, which `set -e` turns into a silent abort.
pick_model() {
  local dir="$1" f choice
  local -a found=()
  for f in "${dir}"/*.gguf; do
    [[ -f "$f" ]] && found+=("$f")     # unquoted glob stays literal when nothing matches
  done

  if [[ ${#found[@]} -eq 0 ]]; then
    echo "no .gguf files in ${dir}" >&2
    echo "  fetch one with ${REPO_ROOT}/scripts/linux/fetch-models.sh --list, pass -m/--model, or set MODELS_DIR" >&2
    exit 1
  fi
  if [[ ${#found[@]} -eq 1 ]]; then
    MODEL="${found[0]}"
    echo "only one model in ${dir}, using $(basename "$MODEL")" >&2
    return
  fi
  # Refuse to block forever when there is nobody to answer -- read on a closed stdin returns
  # instantly and would otherwise spin this loop at full tilt under launchd or CI.
  if [[ ! -t 0 ]]; then
    echo "${#found[@]} models in ${dir} and no terminal to choose with." >&2
    echo "  pass -m/--model explicitly." >&2
    exit 1
  fi

  echo "select a model to serve:" >&2
  local i=1
  for f in "${found[@]}"; do
    printf '  %2d) %s\n' "$i" "$(basename "$f")" >&2
    i=$((i + 1))
  done
  while true; do
    read -rp "model [1-${#found[@]}]: " choice || { echo >&2; exit 1; }
    if [[ "$choice" =~ ^[0-9]+$ ]] && ((choice >= 1 && choice <= ${#found[@]})); then
      MODEL="${found[choice - 1]}"
      return
    fi
    echo "  enter a number between 1 and ${#found[@]}" >&2
  done
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -m|--model)    MODEL="$2"; shift 2 ;;
    -c|--ctx)      CTX="$2"; shift 2 ;;
    -p|--port)     PORT="$2"; shift 2 ;;
    --host)        HOST="$2"; shift 2 ;;
    --ubatch)      UBATCH="$2"; shift 2 ;;
    --spec)        SPEC="$2"; shift 2 ;;
    --spec-nmax)   SPEC_NMAX="$2"; shift 2 ;;
    --no-kv-quant) KV_QUANT=0; shift ;;
    --dry-run)     DRY_RUN=1; shift ;;
    -h|--help)     usage; exit 0 ;;
    *) echo "unknown option: $1" >&2; usage; exit 2 ;;
  esac
done

BIN="${LLAMA_BIN:-${REPO_ROOT}/bin/llama-server}"
if [[ ! -x "$BIN" ]]; then
  if command -v llama-server >/dev/null 2>&1; then
    BIN="$(command -v llama-server)"     # Homebrew install
  else
    echo "llama-server not found: $BIN" >&2
    echo "  run ${SCRIPT_DIR}/fetch-llamacpp.sh, or set LLAMA_BIN=/path/to/llama-server" >&2
    exit 1
  fi
fi

# Picked AFTER the binary check: there is no point asking which model to serve when there is
# nothing to serve it with.
[[ -n "$MODEL" ]] || pick_model "$MODELS_DIR"
[[ -f "$MODEL" ]] || { echo "model not found: $MODEL" >&2
                       echo "  get one with scripts/linux/fetch-models.sh --list" >&2; exit 1; }

# One model at a time. Two resident models share one memory pool; a contended measurement is
# not slightly wrong, it is meaningless -- and on a unified-memory machine the second one may
# simply fail to allocate rather than evicting the first.
if pgrep -x llama-server >/dev/null 2>&1; then
  echo "another llama-server is running:"
  pgrep -lx llama-server | sed 's/^/  /'
  echo "stop it first (pkill -x llama-server)." >&2
  exit 1
fi

ARGS=(
  -m "$MODEL"
  -ngl 999                    # offload everything; on Metal this is the normal case
  --ctx-size "$CTX"
  --batch-size "$BATCH"
  --ubatch-size "$UBATCH"
  -fa on                      # required for q8_0 KV
  --jinja                     # use the model's own chat template
  --parallel "$PARALLEL"
  --host "$HOST"
  --port "$PORT"
  --no-warmup
)
[[ $KV_QUANT -eq 1 ]] && ARGS+=(--cache-type-k q8_0 --cache-type-v q8_0)
[[ -n "$SPEC" ]]      && ARGS+=(--spec-type "$SPEC" --spec-draft-n-max "$SPEC_NMAX")

# NO --mlock. On macOS the weights are already in the unified pool that the GPU reads; wiring
# them down only removes the OS's freedom to manage the rest of the machine.

echo "llama-server (SOLO, macOS/Metal DRAFT) -> http://${HOST}:${PORT}"
echo "  model : $(basename "$MODEL")"
echo "  ctx=${CTX} batch=${BATCH}/${UBATCH} fa=on kv=$([[ $KV_QUANT -eq 1 ]] && echo q8_0 || echo f16)"
echo "  wired limit: $(sysctl -n iogpu.wired_limit_mb 2>/dev/null || echo '?') MB (0 = system default)"
echo "  ⚠️  DRAFT: no number in this repo was measured on Apple silicon."

if [[ $DRY_RUN -eq 1 ]]; then
  printf '\n[dry-run] would exec:\n  %s' "$BIN"
  printf ' %q' "${ARGS[@]}"
  printf '\n'
  exit 0
fi

exec "$BIN" "${ARGS[@]}"
