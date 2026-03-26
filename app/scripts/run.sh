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
APP_BUNDLE_PATH="/Applications/CantoFlow.app"
APP_BUNDLE_BINARY="/Applications/CantoFlow.app/Contents/MacOS/cantoflow"
LAUNCH_AGENT_LABEL="com.cantoflow.launchagent"
LAUNCH_AGENT_PLIST="${HOME}/Library/LaunchAgents/${LAUNCH_AGENT_LABEL}.plist"

has_pid() {
  local needle="$1"
  local pid
  for pid in "$@"; do
    [[ "${pid}" == "${needle}" ]] && return 0
  done
  return 1
}

terminate_existing_instances() {
  local current_pid="$$"
  local pids=()
  local patterns=(
    "${BINARY_PATH}"
    "${APP_BUNDLE_BINARY}"
  )

  for pattern in "${patterns[@]}"; do
    while IFS= read -r pid; do
      [[ -n "${pid}" ]] || continue
      [[ "${pid}" == "${current_pid}" ]] && continue

      if ! has_pid "${pid}" "${pids[@]-}"; then
        pids+=("${pid}")
      fi
    done < <(pgrep -f "${pattern}" || true)
  done

  if [[ "${#pids[@]}" -eq 0 ]]; then
    return
  fi

  echo "Stopping existing CantoFlow instance(s): ${pids[*]}"
  kill "${pids[@]}" 2>/dev/null || true

  local deadline=$((SECONDS + 5))
  while (( SECONDS < deadline )); do
    local alive=0
    for pid in "${pids[@]}"; do
      if kill -0 "${pid}" 2>/dev/null; then
        alive=1
        break
      fi
    done

    (( alive == 0 )) && return
    sleep 0.2
  done

  echo "Force-stopping remaining CantoFlow instance(s): ${pids[*]}"
  kill -9 "${pids[@]}" 2>/dev/null || true
}

safe_quit_existing_instances() {
  if pgrep -f "${APP_BUNDLE_BINARY}" >/dev/null 2>&1; then
    echo "Requesting CantoFlow to quit cleanly..."
    osascript -e 'tell application "CantoFlow" to quit' >/dev/null 2>&1 || true

    local deadline=$((SECONDS + 5))
    while (( SECONDS < deadline )); do
      if ! pgrep -f "${APP_BUNDLE_BINARY}" >/dev/null 2>&1; then
        break
      fi
      sleep 0.2
    done
  fi

  terminate_existing_instances
}

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

if [[ "${#ARGS[@]}" -gt 0 ]] && [[ " ${ARGS[*]} " == *" --help "* || " ${ARGS[*]} " == *" -h "* ]]; then
  exec "${BINARY_PATH}" "${ARGS[@]}"
fi

safe_quit_existing_instances

if [[ ! -x "${APP_BUNDLE_BINARY}" ]]; then
  echo "Installed app not found at ${APP_BUNDLE_BINARY}" >&2
  echo "Install /Applications/CantoFlow.app first." >&2
  exit 1
fi

if [[ "${#ARGS[@]}" -eq 0 ]] && [[ -f "${LAUNCH_AGENT_PLIST}" ]]; then
  echo "Starting CantoFlow via launchd supervision..."
  launchctl kickstart -k "gui/$(id -u)/${LAUNCH_AGENT_LABEL}"
  exit 0
fi

echo "Starting CantoFlow.app..."
open -n "${APP_BUNDLE_PATH}" --args \
  --project-root "${REPO_ROOT}" \
  --stt-profile fast \
  --auto-replace \
  "${ARGS[@]+"${ARGS[@]}"}"
