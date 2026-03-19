#!/usr/bin/env bash
set -euo pipefail

# Resolve symlink to find the real script location
SCRIPT_PATH="${BASH_SOURCE[0]}"
while [ -L "$SCRIPT_PATH" ]; do
  SCRIPT_PATH="$(readlink "$SCRIPT_PATH")"
done
SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_PATH")" && pwd)"
PROJECT_DIR="$(dirname "${SCRIPT_DIR}")"
REPO_ROOT="$(dirname "${PROJECT_DIR}")"
BINARY_PATH="${PROJECT_DIR}/.build/release/cantoflow"
WHISPER_DIR="${REPO_ROOT}/third_party/whisper.cpp"
WHISPER_BIN="${WHISPER_DIR}/build/bin/whisper-cli"

build_release() {
  (
    cd "${PROJECT_DIR}"
    swift build -c release
  )
}

ensure_release_binary() {
  if [[ -x "${BINARY_PATH}" ]]; then
    return
  fi

  echo "Release binary not found. Building CantoFlow..."
  build_release
}

recover_if_module_cache_moved() {
  local output="$1"

  if [[ "${output}" == *"PCH was compiled with module cache path"* ]] || [[ "${output}" == *"missing required module 'SwiftShims'"* ]]; then
    echo "Detected stale Swift module cache after repo path change. Cleaning and rebuilding..."
    (
      cd "${PROJECT_DIR}"
      swift package clean
      rm -rf .build
      swift build -c release
    )
    return 0
  fi

  return 1
}

build_whisper() {
  echo "Building whisper.cpp for current repo path..."
  (
    cd "${REPO_ROOT}"
    cmake -B "${WHISPER_DIR}/build" -S "${WHISPER_DIR}"
    cmake --build "${WHISPER_DIR}/build" -j 8
  )
}

ensure_whisper_binary() {
  if [[ ! -x "${WHISPER_BIN}" ]]; then
    echo "whisper-cli not found. Building whisper.cpp..."
    build_whisper
    return
  fi

  local output
  if ! output="$("${WHISPER_BIN}" --help 2>&1 >/dev/null)"; then
    if [[ "${output}" == *"Library not loaded:"* ]] || [[ "${output}" == *"image not found"* ]]; then
      echo "Detected broken whisper-cli runtime linkage after repo path change. Rebuilding..."
      rm -rf "${WHISPER_DIR}/build"
      build_whisper
      return
    fi

    echo "${output}" >&2
    exit 1
  fi
}

# Load user API keys if present
if [[ -f "${HOME}/.cantoflow.env" ]]; then
  set -o allexport
  source "${HOME}/.cantoflow.env"
  set +o allexport
fi

# Shortcut: --funasr expands to --stt-backend funasr
ARGS=()
for arg in "$@"; do
  if [[ "$arg" == "--funasr" ]]; then
    ARGS+=(--stt-backend funasr)
  else
    ARGS+=("$arg")
  fi
done

ensure_whisper_binary
ensure_release_binary

if ! BUILD_OUTPUT="$("${BINARY_PATH}" --help 2>&1 >/dev/null)"; then
  if ! recover_if_module_cache_moved "${BUILD_OUTPUT}"; then
    echo "${BUILD_OUTPUT}" >&2
    exit 1
  fi
fi

exec "${BINARY_PATH}" \
  --project-root "${REPO_ROOT}" \
  --stt-profile fast \
  --auto-replace \
  "${ARGS[@]+"${ARGS[@]}"}"
