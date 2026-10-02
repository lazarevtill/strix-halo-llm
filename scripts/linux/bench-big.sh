#!/usr/bin/env bash
# =============================================================================
#  ⚠️  DRAFT — NOT YET RUN ON LINUX. See scripts/linux/README.md.
#
#  Port of scripts/windows/bench-big.ps1: benchmark at REAL context depths, not
#  the depth-0 default, optionally sweeping -ub.
#
#  Why depth matters: `llama-bench` with no -d measures against an EMPTY KV
#  cache. For agentic work that number is a fiction — tg degrades as the cache
#  fills, and depth 0 is the one depth you never actually run at.
#
#  Why -ub is swept: it is the most architecture-specific flag in this repo. On
#  gfx1151 dense models peaked at 256 and two unrelated MoEs at 1024 (with 2048
#  regressing). Neither number is portable — sweep it here.
#
#  Output: one CSV whose columns are label,ub,status followed by llama-bench's OWN
#  CSV header (build, backend, model, n_ubatch, n_depth, avg_ts, ...), so every row
#  carries its build and ub. A model/ub that fails is recorded as an OOM or FAIL
#  row and the sweep continues — a failure is a result, not a reason to stop.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

BENCH="${LLAMA_BENCH:-${REPO_ROOT}/bin/llama-bench}"
MODELS_DIR="${MODELS_DIR:-${REPO_ROOT}/models}"
DEPTHS="0,4096,16384,32768"
UBATCH="256"
BATCH=2048
PROMPT_LENS="512,4096"
GEN_LEN=128
REPS=2
OUT="${REPO_ROOT}/bench-big-linux.csv"
MODEL=""

usage() {
  cat <<'EOF'
bench-big.sh — depth-aware benchmark (DRAFT, unverified on Linux)

  -m, --model PATH      single model (default: every servable .gguf in models/, first shard only)
  -d, --depths LIST     comma-separated -d values (default: 0,4096,16384,32768)
      --ubatch LIST     comma-separated -ub values, one llama-bench run each (default: 256)
      --batch N         -b (default: 2048)
  -p, --prompt LIST     -p prompt lengths (default: 512,4096)
  -n, --gen N           -n generation length (default: 128)
  -r, --reps N          -r repetitions (default: 2)
  -o, --out FILE        CSV output (default: <repo>/bench-big-linux.csv)
  -h, --help

Reports pp and tg SEPARATELY. One combined "tok/s" is not a result.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -m|--model)  MODEL="$2"; shift 2 ;;
    -d|--depths) DEPTHS="$2"; shift 2 ;;
    --ubatch)    UBATCH="$2"; shift 2 ;;
    --batch)     BATCH="$2"; shift 2 ;;
    -p|--prompt) PROMPT_LENS="$2"; shift 2 ;;
    -n|--gen)    GEN_LEN="$2"; shift 2 ;;
    -r|--reps)   REPS="$2"; shift 2 ;;
    -o|--out)    OUT="$2"; shift 2 ;;
    -h|--help)   usage; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

[[ -x "$BENCH" ]] || { echo "llama-bench not found: $BENCH (set LLAMA_BENCH=)" >&2; exit 1; }
IFS=',' read -r -a UBS <<<"$UBATCH"
for u in "${UBS[@]}"; do [[ "$u" =~ ^[0-9]+$ ]] || { echo "bad --ubatch value: '$u'" >&2; exit 2; }; done

# TODO(linux): the Windows version refuses to start when another process holds GPU memory,
# because a dirty baseline produced THREE false OOM "failures" that all passed on a clean
# box. The amdgpu equivalent is not established -- check sysfs/rocm-smi and add the guard.
if pgrep -x llama-server >/dev/null 2>&1; then
  echo "⚠️  a llama-server is running — it will contend for GPU memory and may invalidate this run." >&2
  echo "    (the Windows version blocks here; this DRAFT only warns)" >&2
fi

MODELS=()
if [[ -n "$MODEL" ]]; then
  MODELS=("$MODEL")
else
  shopt -s nullglob
  for g in "$MODELS_DIR"/*.gguf; do
    lc="$(basename "$g" | tr '[:upper:]' '[:lower:]')"
    case "$lc" in mmproj*|*dflash*|*[-_]draft*) continue ;; esac                    # not benchable alone
    if [[ "$lc" == *-of-*.gguf && ! "$lc" =~ -0*1-of-[0-9]+\.gguf$ ]]; then continue; fi  # shard 1 only
    MODELS+=("$g")
  done
  shopt -u nullglob
fi
[[ ${#MODELS[@]} -gt 0 ]] || { echo "no models found in $MODELS_DIR" >&2; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
BODY="${WORK}/body.csv"; : > "$BODY"
HEADER=""

echo "build: $("$BENCH" --version 2>&1 | head -1 || true)"
echo "depths: ${DEPTHS}   ubatch: ${UBATCH}   batch: ${BATCH}   -p ${PROMPT_LENS} -n ${GEN_LEN} -r ${REPS}"
echo

csvq() { local s="${1//\"/\"\"}"; printf '"%s"' "$s"; }

for m in "${MODELS[@]}"; do
  label="$(basename "$m" .gguf)"
  echo "=== ${label} ==="
  for ub in "${UBS[@]}"; do
    out="${WORK}/run.csv"; err="${WORK}/run.err"
    # -fa 1 and q8_0 KV mirror the serving config; benchmarking a config you do not serve tells
    # you nothing useful. -lm none = no mmap: --load-mode replaced -mmp 0 and DEFAULTS TO mmap,
    # which changes the memory picture entirely. ONE invocation per (model, ub): the readable
    # summary below is printed from this same CSV, not from a second full run.
    rc=0
    "$BENCH" -m "$m" -ngl 999 -fa 1 -ctk q8_0 -ctv q8_0 -lm none \
             -b "$BATCH" -ub "$ub" -p "$PROMPT_LENS" -n "$GEN_LEN" -d "$DEPTHS" -r "$REPS" \
             -o csv >"$out" 2>"$err" || rc=$?
    nrows=0
    if [[ -s "$out" ]]; then nrows=$(( $(wc -l <"$out") - 1 )); fi
    if [[ $rc -ne 0 || $nrows -le 0 ]]; then
      status=FAIL
      grep -qiE 'ErrorOutOfDeviceMemory|failed to allocate|unable to allocate|out of memory' "$err" 2>/dev/null && status=OOM
      echo "  ub=${ub}: ${status} (exit ${rc})" >&2
      tail -n 6 "$err" 2>/dev/null | sed 's/^/    /' >&2 || true
      printf '%s,%s,%s\n' "$(csvq "$label")" "$ub" "$status" >> "$BODY"
      continue
    fi
    [[ -z "$HEADER" ]] && HEADER="$(head -1 "$out")"
    tail -n +2 "$out" | while IFS= read -r line; do
      printf '%s,%s,OK,%s\n' "$(csvq "$label")" "$ub" "$line"
    done >> "$BODY"
    # readable summary from llama-bench's own column names
    # (quote-aware split: cpu_info/gpu_info are quoted strings that may contain commas)
    awk -v ub="$ub" '
      function split_csv(s, f,   n, i, ch, q, cur) {
        n = 0; q = 0; cur = ""
        for (i = 1; i <= length(s); i++) {
          ch = substr(s, i, 1)
          if (ch == "\"") { if (q && substr(s, i + 1, 1) == "\"") { cur = cur ch; i++ } else q = !q }
          else if (ch == "," && !q) { f[++n] = cur; cur = "" }
          else cur = cur ch
        }
        f[++n] = cur
        return n
      }
      NR == 1 { n = split_csv($0, h); for (i = 1; i <= n; i++) c[h[i]] = i; next }
      { split_csv($0, f)
        printf "  ub=%-5s pp%-6s tg%-5s @d%-7s %10s t/s  (+/- %s)\n", ub,
               f[c["n_prompt"]], f[c["n_gen"]], f[c["n_depth"]], f[c["avg_ts"]], f[c["stddev_ts"]] }' "$out"
  done
  echo
done

if [[ -n "$HEADER" ]]; then echo "label,ub,status,${HEADER}" > "$OUT"; else echo "label,ub,status" > "$OUT"; fi
cat "$BODY" >> "$OUT"

echo "wrote $OUT"
echo "⚠️  DRAFT: numbers from this script have not been cross-checked against the Windows"
echo "    results. Record build + driver alongside them — they move between versions."
