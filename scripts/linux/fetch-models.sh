#!/usr/bin/env bash
# =============================================================================
#  ⚠️  DRAFT — NOT YET RUN ON LINUX. See scripts/linux/README.md.
#
#  Port of scripts/windows/fetch-models.ps1. This one should be the most
#  portable of the set — it is curl and arithmetic, with no OS-specific
#  behaviour — but it is still unverified end to end.
#
#  The registry deliberately contains 2026-era models only. gpt-oss and other
#  2025 entries were dropped on purpose; do not re-add them without a reason.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
DEST="${MODELS_DIR:-${REPO_ROOT}/models}"
HF_BASE="${HF_ENDPOINT:-https://huggingface.co}"

# key|repo|path|expected_bytes[|save_as]   (save_as: see entry_fields note below)
REGISTRY=(
  "ornith-q5|deepreinforce-ai/Ornith-1.0-35B-GGUF|ornith-1.0-35b-Q5_K_M.gguf|24729130848"
  "qwen38|unsloth/Qwen3.8-27B-GGUF|Qwen3.8-27B-UD-Q4_K_XL.gguf|17923394624"
  "qwen38-mmproj|unsloth/Qwen3.8-27B-GGUF|mmproj-F16.gguf|927607488"
  # abliterated (uncensored) options. save_as gives distinct on-disk names the launchers match.
  "qwen38-uncensored|huihui-ai/Huihui-Qwen3.8-27B-abliterated-GGUF|Huihui-Qwen3.8-27B-abliterated-UD-Q4_K_XL.gguf|17378626464|Qwen38-uncensored-UD-Q4_K_XL.gguf"
  "qwen38-uncensored-mmproj|huihui-ai/Huihui-Qwen3.8-27B-abliterated-GGUF|mmproj-model-bf16.gguf|931145888|mmproj-Qwen38-uncensored-bf16.gguf"
  "cyberstrike|huihui-ai/Huihui-CyberStrike-OffSec-35B-abliterated-GGUF|Huihui-CyberStrike-OffSec-35B-abliterated-Q5_K.gguf|25347531968|CyberStrike-OffSec-35B-abliterated-Q5_K.gguf"
  "cyberstrike-mmproj|huihui-ai/Huihui-CyberStrike-OffSec-35B-abliterated-GGUF|mmproj-model-bf16.gguf|902822080|mmproj-CyberStrike-OffSec-35B-bf16.gguf"
  "qwen122b-1|unsloth/Qwen3.5-122B-A10B-MTP-GGUF|UD-Q4_K_XL/Qwen3.5-122B-A10B-UD-Q4_K_XL-00001-of-00003.gguf|10943808"
  "qwen122b-2|unsloth/Qwen3.5-122B-A10B-MTP-GGUF|UD-Q4_K_XL/Qwen3.5-122B-A10B-UD-Q4_K_XL-00002-of-00003.gguf|49667346080"
  "qwen122b-3|unsloth/Qwen3.5-122B-A10B-MTP-GGUF|UD-Q4_K_XL/Qwen3.5-122B-A10B-UD-Q4_K_XL-00003-of-00003.gguf|28968190016"
)
# Every byte count here is VERIFIED — the original four against files on disk (2026-08-04), the
# two qwen38 rows against the HF API and the Windows registry they mirror (2026-08-16). Worth
# stating because the first draft of this table had ornith-q5 off by ~9 MB from a guessed value —
# a size that looks right and produces a GGUF that fails at load with a confusing error rather
# than an obvious one. Never guess these; read them from the HF API or a known-good file.
# Shard 1 of Qwen122b being only ~10 MB is CORRECT — it holds the MTP head, not weights.
#
# qwen38 was MISSING here until 2026-08-16 while README.md, docs/INSTALL.md and
# scripts/linux/README.md all told Linux users to run `--only qwen38` as step two of the quick
# start. It is the documented default model on the Windows side and carries its MTP head in the
# main GGUF (--spec-type draft-mtp, n-max 3 — 1.79x). The mmproj row is its vision projector and
# is a SEPARATE key on purpose: it is only needed for image input, and pulling 0.9 GB nobody
# asked for is the kind of thing that makes people stop trusting a downloader.

usage() {
  cat <<'EOF'
fetch-models.sh — resume-capable model downloader (DRAFT, unverified on Linux)

  --list              show the registry and what is already present
  --only KEY[,KEY]    fetch specific entries
  --all               fetch everything
  --dest DIR          destination (default: <repo>/models)
  --verify            re-check byte counts of existing files, download nothing
  -h, --help

Resumes with `curl -C -`, then verifies the final byte count. A file whose size does not
match is reported, never silently accepted — a truncated GGUF fails at load time with a
confusing error, which is much worse than failing here.
EOF
}

MODE=""; ONLY=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --list)   MODE=list; shift ;;
    --all)    MODE=all; shift ;;
    --only)   MODE=only; ONLY="$2"; shift 2 ;;
    --dest)   DEST="$2"; shift 2 ;;
    --verify) MODE=verify; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown option: $1" >&2; usage; exit 2 ;;
  esac
done
[[ -z "$MODE" ]] && { usage; exit 0; }

command -v curl >/dev/null || { echo "curl is required" >&2; exit 1; }
mkdir -p "$DEST"

human() { numfmt --to=iec --suffix=B "$1" 2>/dev/null || echo "${1}B"; }

# key|repo|path|expected_bytes[|save_as]   -- save_as (optional) overrides the on-disk name, needed
# when two repos ship an identically-named file (both huihui GGUFs have mmproj-model-bf16.gguf).
entry_fields() { IFS='|' read -r KEY REPO RPATH WANT AS <<<"$1"; FNAME="${AS:-$(basename "$RPATH")}"; }

if [[ "$MODE" == "list" || "$MODE" == "verify" ]]; then
  printf '%-14s %-14s %-14s %s\n' KEY EXPECTED ONDISK STATUS
  for e in "${REGISTRY[@]}"; do
    entry_fields "$e"
    local_path="${DEST}/${FNAME}"
    if [[ -f "$local_path" ]]; then
      have=$(stat -c%s "$local_path")
      if [[ "$have" == "$WANT" ]]; then status="OK"; else status="SIZE MISMATCH — re-fetch"; fi
    else
      have=0; status="missing"
    fi
    printf '%-14s %-14s %-14s %s\n' "$KEY" "$(human "$WANT")" "$(human "$have")" "$status"
  done
  exit 0
fi

for e in "${REGISTRY[@]}"; do
  entry_fields "$e"
  if [[ "$MODE" == "only" && ",${ONLY}," != *",${KEY},"* ]]; then continue; fi
  local_path="${DEST}/${FNAME}"
  url="${HF_BASE}/${REPO}/resolve/main/${RPATH}"

  if [[ -f "$local_path" ]] && [[ "$(stat -c%s "$local_path")" == "$WANT" ]]; then
    echo "[skip] ${KEY} already complete ($(human "$WANT"))"
    continue
  fi

  echo "[get ] ${KEY} -> ${local_path}"
  # -C - resumes; --retry survives the flaky-link case this was written for.
  curl -L -C - --retry 8 --retry-delay 5 --retry-all-errors \
       --progress-bar -o "$local_path" "$url"

  have=$(stat -c%s "$local_path")
  if [[ "$have" != "$WANT" ]]; then
    echo "[FAIL] ${KEY}: got $(human "$have"), expected $(human "$WANT") — NOT usable, re-run to resume" >&2
    exit 1
  fi
  echo "[ok  ] ${KEY} verified $(human "$have")"
done
