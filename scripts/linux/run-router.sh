#!/usr/bin/env bash
# run-router.sh -- DRAFT. Syntax-checked (bash -n), shellchecked, and its --dry-run argv/preset are
# asserted in CI (launcher-contract); NEVER run against a GPU on this platform. Linux port of
# scripts/windows/run-router.ps1: serve one or more models from ONE endpoint via llama.cpp router
# mode (start llama-server with NO -m). Route each request by the OpenAI `model` field.
#
# Mirrors the Windows launcher: KNOWN models carry exact tuning (per-model preset lines that
# OVERRIDE the common defaults for the same key); ANY other gguf in MODELS_DIR is discovered and
# auto-tuned -- spec read from the gguf's own header (draft-mtp when it has an MTP head /
# nextn_predict_layers), vision projector matched by sibling filename. ASKS ON START which to serve
# when run interactively with no --models.
#
# gfx1151 note: ubatch-size 256 is the common default (the MEASURED knee for DENSE models on THIS
# APU); the MoE entries override it to 1024, also measured. SWEEP IT on other hardware -- neither
# number is portable. load-mode=none keeps weights in VRAM (mmap pins a host mirror per model).
#
# Multi-slot: llama.cpp SPLITS --ctx-size across slots, so use --per-slot-ctx to ask for "each slot
# gets N tokens" (ctx-size := per-slot x parallel). Speculation and batching compete for the same
# batch dimension: under real concurrency, --no-spec measured faster on the Windows box.
#
# Usage:
#   ./run-router.sh                              # ask on start; Enter = --default-models (ornith15)
#   ./run-router.sh --models ornith15 --parallel 2 --per-slot-ctx 262144
#   ./run-router.sh --models ornith15 --parallel 4 --per-slot-ctx 262144 --no-spec
#   ./run-router.sh --models qwen38,ornith --bin bin-b11330
#   ./run-router.sh --dry-run                    # print argv + preset (temp file), launch nothing
#
# Options:
#   -m, --models A,B        which models to serve (labels; duplicates are ignored)
#       --default-models A  what Enter / no --models means (default: ornith15; else first found)
#   -p, --port N            listen port (default 8080)
#   -c, --ctx N             TOTAL ctx-size per model (default 131072); see --per-slot-ctx
#       --parallel N        server slots per model (default 1)
#       --per-slot-ctx N    sets ctx-size = N x parallel (0 = off, use --ctx verbatim)
#       --no-spec           drop every speculative-decoding line, incl. auto-detected draft-mtp
#       --models-max N      max resident models (default: number selected)
#       --bin DIR           engine dir holding llama-server (relative = against the repo root);
#                           wins over LLAMA_BIN, which wins over <repo>/bin
#       --host ADDR         bind address (default 0.0.0.0)
#       --dry-run           print the command line and the generated preset, launch nothing
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
MODELS_DIR="${MODELS_DIR:-${REPO_ROOT}/models}"

PORT=8080
CTX=131072
PARALLEL=1
PER_SLOT_CTX=0
NO_SPEC=0
MODELS_MAX=0        # 0 => set to the number of models selected (all co-resident)
HOST="0.0.0.0"      # LAN/overlay-reachable, matching the Windows launcher
DRYRUN=0
SEL_ARG=""
DEFAULT_MODELS="ornith15"
BIN_DIR_ARG=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    -m|--models)      SEL_ARG="$2"; shift 2 ;;
    --default-models) DEFAULT_MODELS="$2"; shift 2 ;;
    -p|--port)        PORT="$2"; shift 2 ;;
    -c|--ctx)         CTX="$2"; shift 2 ;;
    --parallel)       PARALLEL="$2"; shift 2 ;;
    --per-slot-ctx)   PER_SLOT_CTX="$2"; shift 2 ;;
    --no-spec)        NO_SPEC=1; shift ;;
    --models-max)     MODELS_MAX="$2"; shift 2 ;;
    --bin)            BIN_DIR_ARG="$2"; shift 2 ;;
    --host)           HOST="$2"; shift 2 ;;
    --dry-run)        DRYRUN=1; shift ;;
    -h|--help)        grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

for n in "$PORT" "$CTX" "$PARALLEL" "$PER_SLOT_CTX" "$MODELS_MAX"; do
  [[ "$n" =~ ^[0-9]+$ ]] || { echo "expected a non-negative integer, got '$n'" >&2; exit 2; }
done
[[ "$PARALLEL" -ge 1 ]] || { echo "--parallel must be >= 1" >&2; exit 2; }

# Engine: --bin DIR (explicit) > LLAMA_BIN (env, a full path to the binary) > <repo>/bin.
if [[ -n "$BIN_DIR_ARG" ]]; then
  case "$BIN_DIR_ARG" in /*) BIN_DIR="$BIN_DIR_ARG" ;; *) BIN_DIR="${REPO_ROOT}/${BIN_DIR_ARG}" ;; esac
  BIN="${BIN_DIR}/llama-server"
else
  BIN="${LLAMA_BIN:-${REPO_ROOT}/bin/llama-server}"
fi

[[ -x "$BIN" ]] || { echo "llama-server not found (or not executable): $BIN" >&2; exit 1; }
[[ -d "$MODELS_DIR" ]] || { echo "models dir not found: $MODELS_DIR" >&2; exit 1; }

# per-slot ctx -> total ctx-size, because llama.cpp divides --ctx-size among the slots
if [[ "$PER_SLOT_CTX" -gt 0 ]]; then
  CTX=$((PER_SLOT_CTX * PARALLEL))
  echo "  per-slot ctx ${PER_SLOT_CTX} x ${PARALLEL} slots -> total ctx-size ${CTX}" >&2
fi

# KNOWN tuning: match_substring | label | mmproj_filename | per-model preset lines (';'-separated)
# match binds to a distinctive stem incl. the quant, so one entry maps to exactly one gguf.
# A per-model line OVERRIDES the common line with the same key (the common one is not emitted).
# @MODELS@ is replaced by MODELS_DIR. The tuning numbers are MEASURED ON THE WINDOWS gfx1151 BOX
# (see scripts/windows/run-router.ps1 for each measurement) -- re-measure before trusting here.
KNOWN=(
  "Qwen3.8-27B-UD-Q4_K_XL|qwen38|mmproj-F16.gguf|spec-type = draft-mtp;spec-draft-n-max = 3"                                         # coding+vision; KL-best quant
  "ornith-1.0-35b-Q5_K_M|ornith|mmproj-deepreinforce-ai_Ornith-1.0-35B-f16.gguf|spec-type = ngram-mod"                               # big-text+vision; MoE A3B
  "Qwen38-uncensored-UD-Q4_K_XL|qwen38-uncensored|mmproj-Qwen38-uncensored-bf16.gguf|spec-type = draft-mtp;spec-draft-n-max = 3"    # abliterated qwen38; inherits qwen38's measured tuning
  "CyberStrike-OffSec-35B-abliterated|cyberstrike|mmproj-CyberStrike-OffSec-35B-bf16.gguf|spec-type = ngram-mod"                     # abliterated pentest MoE; draft-mtp loads but UNMEASURED
  "creative-writer-plus-35b|writer||"                                                                                                # Command-R prose finetune; text-only, no MTP head
  "Qwen3-Coder-Next-UD-Q4_K_XL|coder||ubatch-size = 1024"                                                                            # qwen3next MoE, text-only, no MTP head; needs a recent build (--bin)
  "Ornith-1.5-35B-Q6_K|ornith15|mmproj-Ornith-1.5-35B-BF16.gguf|ubatch-size = 1024;spec-type = draft-dflash;spec-draft-n-max = 3;spec-draft-model = @MODELS@/Ornith-1.5-35B-A3B-DFlash-Q8_0.gguf"  # qwen35moe+vision, thinking; Q8_0 DFlash draft beat BF16 and draft-mtp
  "gemma4-26B-A4B-abliterated-Q6_K|gemma|mmproj-gemma-4-26B-A4B-f16.gguf|"                                                           # abliterated Gemma-4 MoE + vision; thinking model
)

# shared tuned flags, as preset INI lines (ctx-size/parallel are added per run below)
COMMON_INI="metrics = 1
load-mode = none
flash-attn = on
cache-type-k = q8_0
cache-type-v = q8_0
batch-size = 2048
ubatch-size = 256
temp = 0.6
top-p = 0.95
top-k = 20
min-p = 0"
# metrics = 1: Prometheus /metrics on every child (upstream default is off). Children listen on
# RANDOM ports, so scrape through a fixed-port relabelling exporter, not a child directly.

slug() {
  local x="${1%.gguf}"
  x="$(printf '%s' "$x" | sed -E 's/-(UD-)?(I?Q[0-9][_A-Za-z0-9]*|BF16|F16|MXFP4).*$//I; s/-abliterated//I')"
  printf '%s' "$x" | sed -E 's/[^A-Za-z0-9]+/-/g; s/^-+//; s/-+$//' | tr '[:upper:]' '[:lower:]'
}
# Echo the draft-mtp preset lines if the gguf header carries an MTP head, else nothing.
# Process substitution, NOT `head | grep -q`: under pipefail, grep -q exiting on the first match
# SIGPIPEs head (status 141) and the pipeline reads as "no match" -- a found MTP head was dropped.
detect_spec() {
  if grep -aqm1 'nextn_predict_layers' < <(head -c 3000000 "$1" 2>/dev/null); then
    printf '%s\n' "spec-type = draft-mtp" "spec-draft-n-max = 3"
  fi
  return 0
}
find_mmproj() {  # sibling projector sharing the model's first filename token
  local tok f; tok="$(printf '%s' "${1%.gguf}" | cut -d- -f1)"
  [[ -z "$tok" ]] && return 0
  for f in "$MODELS_DIR"/mmproj*.gguf; do
    [[ -e "$f" ]] || continue          # glob matched nothing -> skip the literal pattern
    case "$f" in *"$tok"*) printf '%s\n' "$f"; return 0 ;; esac
  done
  return 0
}
ini_key() { local k="${1%%=*}"; k="${k#"${k%%[![:space:]]*}"}"; printf '%s' "${k%"${k##*[![:space:]]}"}"; }
ini_val() { local v="${1#*=}"; v="${v#"${v%%[![:space:]]*}"}"; printf '%s' "${v%"${v##*[![:space:]]}"}"; }
# NB: every helper ends in an explicit `return 0`. A function whose last command is a false
# `[[ ]] &&` returns 1, and called bare under `set -e` that aborts the whole launch AFTER a partial
# preset is written (caught by the Docker harness 2026-08-28).

# ---- build the catalog: known (tuned) first, then discovered (auto-tuned) -----------------------
declare -A CAT_FILE CAT_LINES CAT_MM
CAT_ORDER=()
add_cat() {
  [[ -n "${CAT_FILE[$1]:-}" ]] && return 0
  CAT_FILE[$1]="$2"; CAT_LINES[$1]="$3"; CAT_MM[$1]="$4"; CAT_ORDER+=("$1")
  return 0
}

shopt -s nullglob
for g in "$MODELS_DIR"/*.gguf; do
  base="$(basename "$g")"
  lc="${base,,}"
  # projectors attach to a model; speculative DRAFT models (DFlash, *-draft) are not serving
  # targets. Case-insensitive: the real file is Ornith-1.5-35B-A3B-DFlash-Q8_0.gguf.
  case "$lc" in mmproj*|*dflash*|*[-_]draft*) continue ;; esac
  if [[ "$lc" == *-of-*.gguf && ! "$lc" =~ -0*1-of-[0-9]+\.gguf$ ]]; then continue; fi  # shard 1 only
  matched=0
  for k in "${KNOWN[@]}"; do
    IFS='|' read -r msub mlbl mmm mlines <<<"$k"
    if [[ "$base" == *"$msub"* ]]; then
      mmpath=""
      if [[ -n "$mmm" ]]; then
        if [[ -f "$MODELS_DIR/$mmm" ]]; then mmpath="$MODELS_DIR/$mmm"
        else echo "  warning: mmproj missing for [$mlbl], serving text-only: $MODELS_DIR/$mmm" >&2; fi
      fi
      mlines="${mlines//@MODELS@/$MODELS_DIR}"
      add_cat "$mlbl" "$g" "${mlines//;/$'\n'}" "$mmpath"; matched=1; break
    fi
  done
  [[ $matched -eq 1 ]] && continue
  lbl="$(slug "$base")"; [[ -z "$lbl" ]] && continue
  add_cat "$lbl" "$g" "$(detect_spec "$g")" "$(find_mmproj "$base")"
done
shopt -u nullglob
[[ ${#CAT_ORDER[@]} -gt 0 ]] || { echo "no servable .gguf models found in $MODELS_DIR" >&2; exit 1; }

spec_name() {  # the spec-type a catalog entry would use, or "none"
  local l s="none"
  while IFS= read -r l; do [[ "$(ini_key "$l")" == "spec-type" ]] && s="$(ini_val "$l")"; done <<<"${CAT_LINES[$1]}"
  printf '%s' "$s"
  return 0
}

# default selection = --default-models labels that are present, else the first catalog entry
default_sel() {
  local out=() t
  local -a want
  IFS=',' read -r -a want <<<"$DEFAULT_MODELS"
  for t in "${want[@]}"; do t="${t// /}"; [[ -n "$t" && -n "${CAT_FILE[$t]:-}" ]] && out+=("$t"); done
  [[ ${#out[@]} -eq 0 ]] && out=("${CAT_ORDER[0]}")
  printf '%s\n' "${out[@]}"
  return 0
}

# resolve one token (label or 1-based menu number) into SEL, warning on unknowns
pick_token() {
  local t="${1// /}"
  [[ -z "$t" ]] && return 0
  if [[ "$t" =~ ^[0-9]+$ ]] && (( t >= 1 && t <= ${#CAT_ORDER[@]} )); then SEL+=("${CAT_ORDER[$((t-1))]}")
  elif [[ -n "${CAT_FILE[$t]:-}" ]]; then SEL+=("$t")
  else echo "unknown model '$t'. Available: ${CAT_ORDER[*]}" >&2; fi
  return 0
}

# ---- choose which to serve: --models, else ASK on start, else default --------------------------
SEL=()
if [[ -n "$SEL_ARG" ]]; then
  IFS=',' read -r -a req <<<"$SEL_ARG"
  for t in "${req[@]}"; do pick_token "$t"; done
elif [[ $DRYRUN -eq 0 && -t 0 ]]; then
  echo "Models available in $MODELS_DIR :"
  i=1; for lbl in "${CAT_ORDER[@]}"; do
    v=""; [[ -n "${CAT_MM[$lbl]}" ]] && v=" +vision"
    printf '  [%d] %-24s spec=%s%s\n' "$i" "$lbl" "$(spec_name "$lbl")" "$v"; i=$((i+1))
  done
  mapfile -t defs < <(default_sel)
  read -r -p "Which to serve? comma numbers/names [Enter = ${defs[*]}]: " ans
  if [[ -z "${ans// /}" ]]; then SEL=("${defs[@]}"); else
    IFS=',' read -r -a picks <<<"$ans"
    for t in "${picks[@]}"; do pick_token "$t"; done
  fi
else
  mapfile -t SEL < <(default_sel)
fi
# de-duplicate, keeping first-seen order (`--models a,a` must not emit two [a] sections)
declare -A SEEN=()
UNIQ=()
for lbl in "${SEL[@]}"; do [[ -n "${SEEN[$lbl]:-}" ]] && continue; SEEN[$lbl]=1; UNIQ+=("$lbl"); done
SEL=("${UNIQ[@]}")
[[ ${#SEL[@]} -gt 0 ]] || { echo "no models selected" >&2; exit 1; }
[[ "$MODELS_MAX" -eq 0 ]] && MODELS_MAX=${#SEL[@]}

# ---- generate the preset INI -------------------------------------------------------------------
# --dry-run writes to a temp file: the live preset is re-read whenever the router (re)spawns a
# child, so a "launch nothing" dry run must never overwrite it.
if [[ $DRYRUN -eq 1 ]]; then
  INI="$(mktemp "${TMPDIR:-/tmp}/router-models.dryrun.XXXXXX")"
  trap 'rm -f "$INI"' EXIT
else
  INI="${SCRIPT_DIR}/router-models.generated.ini"   # gitignored: holds absolute machine paths
fi

emit_section() {  # emit_section <label>
  local lbl="$1" l key drop=$NO_SPEC
  local -a own=() keys=()
  while IFS= read -r l; do [[ -n "$l" ]] && own+=("$l"); done <<<"${CAT_LINES[$lbl]}"
  for l in "${own[@]}"; do
    key="$(ini_key "$l")"
    if [[ "$key" == "spec-draft-model" && ! -f "$(ini_val "$l")" ]]; then
      echo "  warning: draft model missing for [$lbl], serving WITHOUT speculation: $(ini_val "$l")" >&2
      drop=1
    fi
  done
  echo "[$lbl]"
  echo "model = ${CAT_FILE[$lbl]}"
  for l in "${own[@]}"; do keys+=("$(ini_key "$l")"); done
  while IFS= read -r l; do
    key="$(ini_key "$l")"
    # a per-model line OVERRIDES the common default for the same key: emit only one of them, do
    # not append both and trust last-wins (unverified in llama.cpp's preset parser)
    case " ${keys[*]} " in *" $key "*) continue ;; esac
    echo "$l"
  done <<<"ctx-size = $CTX
parallel = $PARALLEL
$COMMON_INI"
  for l in "${own[@]}"; do
    key="$(ini_key "$l")"
    [[ $drop -eq 1 && "$key" == spec-* ]] && continue
    echo "$l"
  done
  if [[ -n "${CAT_MM[$lbl]}" ]]; then echo "mmproj = ${CAT_MM[$lbl]}"; fi
  echo
  return 0
}

: > "$INI"
for lbl in "${SEL[@]}"; do emit_section "$lbl" >> "$INI"; done

ARGS=(--models-preset "$INI" --models-max "$MODELS_MAX" --models-autoload -ngl 999 --jinja --host "$HOST" --port "$PORT")

echo ""
echo "llama-server ROUTER -> http://${HOST}:${PORT}  (route by the OpenAI \"model\" field)"
echo "  models      : ${SEL[*]}"
echo "  each        : ctx=$CTX fa=on kv=q8_0 batch=2048/256(default) load-mode=none + per-model tuning"
echo "  slots       : $PARALLEL x $((CTX / PARALLEL)) ctx each   speculation: $([[ $NO_SPEC -eq 1 ]] && echo 'OFF (--no-spec)' || echo 'per model')"
echo "  max resident: $MODELS_MAX"
if [[ $DRYRUN -eq 1 ]]; then
  echo ""; echo "[dry-run] $BIN ${ARGS[*]}"
  echo "--- generated preset (temporary; deleted on exit) ---"; sed 's/^/  /' "$INI"; exit 0
fi

# stop any existing llama-server (Linux has no WDDM occupancy guard; a busy peer OOMs the newcomer).
# -x, not -f: -f also matches e.g. `tail -f llama-server.log` or an editor on a file of that name.
pkill -x llama-server 2>/dev/null || true
sleep 3

export GGML_VK_ENABLE_MEMORY_PRIORITY=1
echo "  launching router..."
"$BIN" "${ARGS[@]}" >/tmp/llama-router.log 2>&1 &
up=0
for _ in $(seq 1 30); do curl -sf --max-time 3 "http://127.0.0.1:${PORT}/models" >/dev/null 2>&1 && { up=1; break; }; sleep 1; done
[[ $up -eq 1 ]] || { echo "router did not come up on :$PORT (see /tmp/llama-router.log)" >&2; exit 1; }

for lbl in "${SEL[@]}"; do   # pre-load: autoload does not fire on the first /v1/chat/completions
  echo "  pre-loading $lbl ..."
  # -f so an HTTP error is a failure (plain -s exits 0 on a 4xx/5xx); --max-time because a large
  # model can take minutes to load, but not forever.
  if ! err="$(curl -sS -f --max-time 300 -X POST "http://127.0.0.1:${PORT}/models/load" \
                -H 'content-type: application/json' -d "{\"model\":\"$lbl\"}" 2>&1 >/dev/null)"; then
    echo "  pre-load $lbl FAILED: ${err:-unknown error} (see /tmp/llama-router.log)" >&2
  fi
done

echo ""
echo "router ready. Route by the \"model\" field, e.g.:"
for lbl in "${SEL[@]}"; do echo "  curl :$PORT/v1/chat/completions -d '{\"model\":\"$lbl\",...}'"; done
