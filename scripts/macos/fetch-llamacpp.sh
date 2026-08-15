#!/usr/bin/env bash
# =============================================================================
#  Get llama.cpp onto an Apple Silicon Mac (Metal backend).
#
#  ⚠️  DRAFT — written on a Windows box, never run on macOS.
#
#  Why a Mac script lives in a Strix Halo repo: an M-series Mac is the other
#  mainstream unified-memory machine. The GPU and the CPU share one pool of
#  LPDDR, so the questions this repo exists to answer -- how much of it can the
#  GPU actually have, does a bigger model beat a faster one, where does prefill
#  time go -- are the same questions with different numbers. The METHOD carries
#  over. The numbers do not: nothing here was measured on Apple silicon.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

METHOD="brew"
DEST="${REPO_ROOT}/bin"
BUILD="latest"
FORCE=0

usage() {
  cat <<'EOF'
fetch-llamacpp.sh (macOS) — install llama.cpp with Metal support (DRAFT)

      --method brew|release   how to install       (default: brew)
  -b, --build TAG             build tag for --method release (default: latest)
  -d, --dest DIR              unpack target for --method release (default: <repo>/bin)
      --force                 replace an existing install
  -h, --help

  brew     Homebrew formula. Metal is enabled by default; binaries land on PATH
           as llama-server / llama-bench. Simplest, and the one most likely to
           just work.
  release  Download the prebuilt macos-arm64 zip into bin/, matching how the
           Windows and Linux scripts lay things out. Pin --build when you are
           reproducing a number.

Intel Macs: there is no useful GPU path. llama.cpp will run on CPU and will be
slow. Neither method is wrong, but do not expect the numbers in this repo.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --method)   METHOD="$2"; shift 2 ;;
    -b|--build) BUILD="$2"; shift 2 ;;
    -d|--dest)  DEST="$2"; shift 2 ;;
    --force)    FORCE=1; shift ;;
    -h|--help)  usage; exit 0 ;;
    *) echo "unknown option: $1" >&2; usage; exit 2 ;;
  esac
done

ARCH="$(uname -m)"
if [[ "$ARCH" != "arm64" ]]; then
  echo "⚠️  This is a ${ARCH} Mac, not Apple silicon — there is no Metal GPU path."
  echo "    llama.cpp will run on CPU only. Continuing anyway."
fi

if [[ "$METHOD" == "brew" ]]; then
  command -v brew >/dev/null 2>&1 || {
    echo "Homebrew not found. Install it from https://brew.sh, or use --method release" >&2
    exit 1; }
  echo "installing llama.cpp via Homebrew (Metal is on by default)"
  brew install llama.cpp
  echo
  llama-server --version 2>&1 | head -n 6 | sed 's/^/  /' || true
  cat <<EOF

llama-server is on your PATH.

The other scripts in this repo look for bin/llama-server. Point them at the brew
copy instead of copying the binary around:

  export LLAMA_BIN="\$(command -v llama-server)"

next:  ${SCRIPT_DIR}/run-solo.sh --dry-run
EOF
  exit 0
fi

# ---- release download -------------------------------------------------------
for tool in curl unzip; do
  command -v "$tool" >/dev/null 2>&1 || { echo "need $tool on PATH" >&2; exit 1; }
done

if [[ -x "${DEST}/llama-server" && $FORCE -eq 0 ]]; then
  echo "${DEST}/llama-server already exists — re-run with --force to replace it."
  exit 0
fi

if [[ "$BUILD" == "latest" ]]; then
  API="https://api.github.com/repos/ggml-org/llama.cpp/releases/latest"
else
  API="https://api.github.com/repos/ggml-org/llama.cpp/releases/tags/${BUILD}"
fi

echo "querying ${API}"
JSON="$(curl -fsSL -H 'User-Agent: strix-halo-llm' "$API")" \
  || { echo "could not reach the GitHub releases API" >&2; exit 1; }

URL="$(printf '%s' "$JSON" \
  | grep -o '"browser_download_url": *"[^"]*"' \
  | cut -d'"' -f4 \
  | grep -Ei 'macos.*(arm64|aarch64).*\.zip$' \
  | head -n1 || true)"

if [[ -z "$URL" ]]; then
  echo "no macOS arm64 asset in that release. Assets present:" >&2
  printf '%s' "$JSON" | grep -o '"browser_download_url": *"[^"]*"' | cut -d'"' -f4 | sed 's#.*/#  #' >&2
  echo "Use --method brew instead." >&2
  exit 1
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
echo "downloading $(basename "$URL")"
curl -fL --progress-bar -o "${TMP}/llama.zip" "$URL"

mkdir -p "$DEST"
unzip -q -o "${TMP}/llama.zip" -d "$DEST"

if [[ ! -x "${DEST}/llama-server" ]]; then
  FOUND="$(find "$DEST" -type f -name llama-server -print -quit 2>/dev/null || true)"
  if [[ -n "$FOUND" ]]; then
    echo "flattening $(dirname "$FOUND")"
    find "$(dirname "$FOUND")" -maxdepth 1 -type f -exec mv -f {} "$DEST"/ \;
  fi
fi

[[ -f "${DEST}/llama-server" ]] || { echo "unpacked, but no llama-server under ${DEST}" >&2; exit 1; }
chmod +x "${DEST}"/llama-* 2>/dev/null || true

# Gatekeeper quarantines anything downloaded by curl. Without this the first launch dies with
# "cannot be opened because the developer cannot be verified", which reads like a broken binary.
xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true

echo
"${DEST}/llama-server" --version 2>&1 | head -n 6 | sed 's/^/  /' || true
echo
echo "llama.cpp is in ${DEST}"
echo "next:  ${SCRIPT_DIR}/run-solo.sh --dry-run"
