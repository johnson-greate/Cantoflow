#!/usr/bin/env bash
set -euo pipefail

# Resolve symlink to find the real script location
SCRIPT_PATH="${BASH_SOURCE[0]}"
while [ -L "$SCRIPT_PATH" ]; do
  SCRIPT_PATH="$(readlink "$SCRIPT_PATH")"
done
SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_PATH")" && pwd)"
PROJECT_DIR="$(dirname "${SCRIPT_DIR}")"

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

exec "${PROJECT_DIR}/.build/release/cantoflow" \
  --project-root "$(dirname "${PROJECT_DIR}")" \
  --stt-profile fast \
  --auto-replace \
  "${ARGS[@]+"${ARGS[@]}"}"
