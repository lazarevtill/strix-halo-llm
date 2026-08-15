#!/usr/bin/env bash
# =============================================================================
#  Download a prebuilt llama.cpp binary release into bin/.
#
#  Step zero: everything else here calls bin/llama-server, and nothing else in
#  the repo puts it there.
#
#  ⚠️  DRAFT — written on Windows, never run on Linux. The download and unpack
#  are ordinary shell and should work; what is NOT verified is whether the
#  Vulkan release runs on your driver stack, or whether ROCm beats Vulkan here
#  (on Linux it might — the 1.79x Vulkan win in this repo is a Windows result
#  against Ollama's ROCm, which is not the same comparison).
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

BUILD="latest"
DEST="${REPO_ROOT}/bin"
BACKEND="vulkan"
FORCE=0

usage() {
  cat <<'EOF'
fetch-llamacpp.sh — download a prebuilt llama.cpp release into bin/ (DRAFT)

  -b, --build TAG     build tag, e.g. b10431   (default: latest)
      --backend NAME  vulkan | cpu             (default: vulkan)
  -d, --dest DIR      unpack target            (default: <repo>/bin)
      --force         replace an existing install
  -h, --help

Pin the build when reproducing numbers: every result in this repo names the
build it came from, currently b10431. Benchmarks move between builds.

Vulkan needs a working Vulkan loader and an AMD/Intel/NVIDIA ICD:
  Debian/Ubuntu:  sudo apt install libvulkan1 mesa-vulkan-drivers vulkan-tools
  Fedora:         sudo dnf install vulkan-loader mesa-vulkan-drivers vulkan-tools
  Arch:           sudo pacman -S vulkan-icd-loader vulkan-radeon vulkan-tools
Then confirm the GPU is visible before blaming llama.cpp:  vulkaninfo --summary
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -b|--build)   BUILD="$2"; shift 2 ;;
    --backend)    BACKEND="$2"; shift 2 ;;
    -d|--dest)    DEST="$2"; shift 2 ;;
    --force)      FORCE=1; shift ;;
    -h|--help)    usage; exit 0 ;;
    *) echo "unknown option: $1" >&2; usage; exit 2 ;;
  esac
done

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

# Match on the asset name rather than a hardcoded filename -- the naming has changed more than
# once, and a hardcoded string turns an upstream rename into a 404. jq is not assumed present.
URL="$(printf '%s' "$JSON" \
  | grep -o '"browser_download_url": *"[^"]*"' \
  | cut -d'"' -f4 \
  | grep -Ei "(ubuntu|linux).*${BACKEND}.*x64.*\.zip$" \
  | head -n1 || true)"

if [[ -z "$URL" ]]; then
  echo "no Linux ${BACKEND} x64 asset in that release. Assets present:" >&2
  printf '%s' "$JSON" | grep -o '"browser_download_url": *"[^"]*"' | cut -d'"' -f4 | sed 's#.*/#  #' >&2
  echo "Try --backend cpu, or build from source: https://github.com/ggml-org/llama.cpp" >&2
  exit 1
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
echo "downloading $(basename "$URL")"
curl -fL --progress-bar -o "${TMP}/llama.zip" "$URL"

mkdir -p "$DEST"
unzip -q -o "${TMP}/llama.zip" -d "$DEST"

# Some releases nest everything under build/bin/; flatten so bin/llama-server is correct.
if [[ ! -x "${DEST}/llama-server" ]]; then
  FOUND="$(find "$DEST" -type f -name llama-server -print -quit 2>/dev/null || true)"
  if [[ -n "$FOUND" ]]; then
    echo "flattening $(dirname "$FOUND")"
    find "$(dirname "$FOUND")" -maxdepth 1 -type f -exec mv -f {} "$DEST"/ \;
  fi
fi

[[ -f "${DEST}/llama-server" ]] || { echo "unpacked, but no llama-server under ${DEST}" >&2; exit 1; }
chmod +x "${DEST}"/llama-* 2>/dev/null || true

echo
echo "checking it runs..."
"${DEST}/llama-server" --version 2>&1 | head -n 6 | sed 's/^/  /' || true

cat <<EOF

llama.cpp is in ${DEST}
next:  ${SCRIPT_DIR}/fetch-models.sh --only qwen38    then    ${SCRIPT_DIR}/run-solo.sh

If the banner above listed no Vulkan device, the driver stack is the problem, not
llama.cpp. Check 'vulkaninfo --summary' first.
EOF
