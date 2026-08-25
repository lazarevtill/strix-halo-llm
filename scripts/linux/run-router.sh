#!/usr/bin/env bash
# run-router.sh -- DRAFT. Syntax-checked (bash -n) only; NEVER run on this platform. Linux port of
# scripts/windows/run-router.ps1: serve MULTIPLE models from ONE endpoint via llama.cpp router mode
# (start llama-server with NO -m). Route each request by the OpenAI `model` field.
#
# Mirrors the Windows launcher: KNOWN models carry exact tuning; ANY other gguf in MODELS_DIR is
# discovered and auto-tuned -- spec read from the gguf's own header (draft-mtp when it has an MTP
# head / nextn_predict_layers), vision projector matched by sibling filename. ASKS ON START which to
# serve when run interactively with no --models.
#
# gfx1151 note: ubatch-size 256 is the MEASURED knee on THIS APU (see run-solo.sh). SWEEP IT on other
# hardware -- do not treat it as portable. load-mode=none keeps weights in VRAM (mmap pins a host
# mirror per model; two would exhaust a small system-RAM partition).
#
# Usage:
#   ./run-router.sh                              # ask on start; default = first two known present
#   ./run-router.sh --models qwen38-uncensored,ornith
#   ./run-router.sh --models cyberstrike --models-max 1
#   ./run-router.sh --dry-run
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
BIN="${REPO_ROOT}/bin/llama-server"
MODELS_DIR="${MODELS_DIR:-${REPO_ROOT}/models}"

PORT=8080
CTX=131072
MODELS_MAX=0        # 0 => set to the number of models selected (all co-resident)
HOST="0.0.0.0"      # LAN/overlay-reachable, matching the Windows launcher
DRYRUN=0
SEL_ARG=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    -m|--models)   SEL_ARG="$2"; shift 2 ;;
    -p|--port)     PORT="$2"; shift 2 ;;
    -c|--ctx)      CTX="$2"; shift 2 ;;
    --models-max)  MODELS_MAX="$2"; shift 2 ;;
    --host)        HOST="$2"; shift 2 ;;
    --dry-run)     DRYRUN=1; shift ;;
    -h|--help)     grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

[[ -x "$BIN" ]] || { echo "llama-server not found (or not executable): $BIN" >&2; exit 1; }
[[ -d "$MODELS_DIR" ]] || { echo "models dir not found: $MODELS_DIR" >&2; exit 1; }

# KNOWN tuning: match_substring | label | spec_type (draft-mtp|ngram-mod|empty) | mmproj_filename
# match binds to a distinctive stem incl. the quant, so one entry maps to exactly one gguf.
KNOWN=(
  "Qwen3.8-27B-UD-Q4_K_XL|qwen38|draft-mtp|mmproj-F16.gguf"                                         # coding+vision; KL-best quant
  "ornith-1.0-35b-Q5_K_M|ornith|ngram-mod|mmproj-deepreinforce-ai_Ornith-1.0-35B-f16.gguf"          # big-text+vision; MoE A3B
  "Qwen38-uncensored-UD-Q4_K_XL|qwen38-uncensored|draft-mtp|mmproj-Qwen38-uncensored-bf16.gguf"     # abliterated qwen38; inherits qwen38's measured tuning
  "CyberStrike-OffSec-35B-abliterated|cyberstrike|ngram-mod|mmproj-CyberStrike-OffSec-35B-bf16.gguf" # abliterated pentest MoE; ngram-mod per Ornith (draft-mtp loads but UNMEASURED)
)

# shared tuned flags, as preset INI lines
COMMON_INI="load-mode = none
flash-attn = on
cache-type-k = q8_0
cache-type-v = q8_0
batch-size = 2048
ubatch-size = 256
temp = 0.6
top-p = 0.95
top-k = 20
min-p = 0"

slug() {
  local x="${1%.gguf}"
  x="$(printf '%s' "$x" | sed -E 's/-(UD-)?(I?Q[0-9][_A-Za-z0-9]*|BF16|F16|MXFP4).*$//I; s/-abliterated//I')"
  printf '%s' "$x" | sed -E 's/[^A-Za-z0-9]+/-/g; s/^-+//; s/-+$//' | tr 'A-Z' 'a-z'
}
detect_spec() {  # echo draft-mtp if the gguf header carries an MTP head, else nothing
  if head -c 3000000 "$1" 2>/dev/null | grep -aqm1 'nextn_predict_layers'; then echo "draft-mtp"; fi
}
find_mmproj() {  # sibling projector sharing the model's first filename token
  local tok; tok="$(printf '%s' "${1%.gguf}" | cut -d- -f1)"
  [[ -z "$tok" ]] && return 0
  ls "$MODELS_DIR"/mmproj*.gguf 2>/dev/null | grep -F "$tok" | head -1 || true
}
emit_spec() { local s="$1"; [[ -z "$s" ]] && return 0; echo "spec-type = $s"; [[ "$s" == "draft-mtp" ]] && echo "spec-draft-n-max = 3"; }

# ---- build the catalog: known (tuned) first, then discovered (auto-tuned) -----------------------
declare -A CAT_FILE CAT_SPEC CAT_MM
CAT_ORDER=()
add_cat() { [[ -n "${CAT_FILE[$1]:-}" ]] && return 0; CAT_FILE[$1]="$2"; CAT_SPEC[$1]="$3"; CAT_MM[$1]="$4"; CAT_ORDER+=("$1"); }

shopt -s nullglob
for g in "$MODELS_DIR"/*.gguf; do
  base="$(basename "$g")"
  case "$base" in mmproj*|*dflash*|*draft*) continue ;; esac
  if [[ "$base" == *-of-*.gguf && "$base" != *-00001-of-*.gguf && "$base" != *-1-of-*.gguf ]]; then continue; fi
  matched=0
  for k in "${KNOWN[@]}"; do
    IFS='|' read -r msub mlbl mspec mmm <<<"$k"
    if [[ "$base" == *"$msub"* ]]; then
      mmpath=""; [[ -n "$mmm" && -f "$MODELS_DIR/$mmm" ]] && mmpath="$MODELS_DIR/$mmm"
      add_cat "$mlbl" "$g" "$mspec" "$mmpath"; matched=1; break
    fi
  done
  [[ $matched -eq 1 ]] && continue
  lbl="$(slug "$base")"; [[ -z "$lbl" ]] && continue
  add_cat "$lbl" "$g" "$(detect_spec "$g")" "$(find_mmproj "$base")"
done
shopt -u nullglob
[[ ${#CAT_ORDER[@]} -gt 0 ]] || { echo "no .gguf models found in $MODELS_DIR" >&2; exit 1; }

# default selection = first two KNOWN labels that are present
default_sel() {
  local out=() k lbl n=0
  for k in "${KNOWN[@]}"; do
    IFS='|' read -r _ lbl _ _ <<<"$k"
    if [[ -n "${CAT_FILE[$lbl]:-}" ]]; then out+=("$lbl"); n=$((n+1)); [[ $n -ge 2 ]] && break; fi
  done
  [[ ${#out[@]} -eq 0 ]] && out=("${CAT_ORDER[0]}")
  printf '%s\n' "${out[@]}"
}

# ---- choose which to serve: --models, else ASK on start, else default --------------------------
SEL=()
if [[ -n "$SEL_ARG" ]]; then
  IFS=',' read -r -a req <<<"$SEL_ARG"
  for t in "${req[@]}"; do t="${t// /}"; [[ -z "$t" ]] && continue
    if [[ -n "${CAT_FILE[$t]:-}" ]]; then SEL+=("$t"); else echo "unknown model '$t'. Available: ${CAT_ORDER[*]}" >&2; fi
  done
elif [[ $DRYRUN -eq 0 && -t 0 ]]; then
  echo "Models available in $MODELS_DIR :"
  i=1; for lbl in "${CAT_ORDER[@]}"; do
    v=""; [[ -n "${CAT_MM[$lbl]}" ]] && v=" +vision"
    sp="${CAT_SPEC[$lbl]:-none}"; [[ -z "$sp" ]] && sp="none"
    printf '  [%d] %-24s spec=%s%s\n' "$i" "$lbl" "$sp" "$v"; i=$((i+1))
  done
  mapfile -t defs < <(default_sel)
  read -r -p "Which to serve? comma numbers/names [Enter = ${defs[*]}]: " ans
  if [[ -z "${ans// /}" ]]; then SEL=("${defs[@]}"); else
    IFS=',' read -r -a picks <<<"$ans"
    for t in "${picks[@]}"; do t="${t// /}"; [[ -z "$t" ]] && continue
      if [[ "$t" =~ ^[0-9]+$ ]] && (( t>=1 && t<=${#CAT_ORDER[@]} )); then SEL+=("${CAT_ORDER[$((t-1))]}")
      elif [[ -n "${CAT_FILE[$t]:-}" ]]; then SEL+=("$t"); else echo "skip unknown: $t" >&2; fi
    done
  fi
else
  mapfile -t SEL < <(default_sel)
fi
[[ ${#SEL[@]} -gt 0 ]] || { echo "no models selected" >&2; exit 1; }
[[ "$MODELS_MAX" -eq 0 ]] && MODELS_MAX=${#SEL[@]}

# ---- generate the preset INI -------------------------------------------------------------------
INI="${SCRIPT_DIR}/router-models.generated.ini"
: > "$INI"
for lbl in "${SEL[@]}"; do
  {
    echo "[$lbl]"
    echo "model = ${CAT_FILE[$lbl]}"
    echo "ctx-size = $CTX"
    printf '%s\n' "$COMMON_INI"
    emit_spec "${CAT_SPEC[$lbl]}"
    [[ -n "${CAT_MM[$lbl]}" ]] && echo "mmproj = ${CAT_MM[$lbl]}"
    echo
  } >> "$INI"
done

ARGS=(--models-preset "$INI" --models-max "$MODELS_MAX" --models-autoload -ngl 999 --jinja --host "$HOST" --port "$PORT")

echo ""
echo "llama-server ROUTER -> http://${HOST}:${PORT}  (route by the OpenAI \"model\" field)"
echo "  models      : ${SEL[*]}"
echo "  each        : ctx=$CTX fa=on kv=q8_0 batch=2048/256 load-mode=none + per-model spec/vision"
echo "  max resident: $MODELS_MAX"
if [[ $DRYRUN -eq 1 ]]; then
  echo ""; echo "[dry-run] $BIN ${ARGS[*]}"; echo "--- generated preset ---"; sed 's/^/  /' "$INI"; exit 0
fi

# stop any existing llama-server (Linux has no WDDM occupancy guard; a busy peer OOMs the newcomer)
pkill -f 'llama-server' 2>/dev/null || true
sleep 3

export GGML_VK_ENABLE_MEMORY_PRIORITY=1
echo "  launching router..."
"$BIN" "${ARGS[@]}" >/tmp/llama-router.log 2>&1 &
up=0
for _ in $(seq 1 30); do curl -sf "http://127.0.0.1:${PORT}/models" >/dev/null 2>&1 && { up=1; break; }; sleep 1; done
[[ $up -eq 1 ]] || { echo "router did not come up on :$PORT (see /tmp/llama-router.log)" >&2; exit 1; }

for lbl in "${SEL[@]}"; do   # pre-load: autoload does not fire on the first /v1/chat/completions
  echo "  pre-loading $lbl ..."
  curl -s -X POST "http://127.0.0.1:${PORT}/models/load" -H 'content-type: application/json' \
       -d "{\"model\":\"$lbl\"}" >/dev/null 2>&1 || echo "  pre-load $lbl failed (will autoload on request)" >&2
done

echo ""
echo "router ready. Route by the \"model\" field, e.g.:"
for lbl in "${SEL[@]}"; do echo "  curl :$PORT/v1/chat/completions -d '{\"model\":\"$lbl\",...}'"; done
