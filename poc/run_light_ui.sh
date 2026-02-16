#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname "$0")/.." >/dev/null 2>&1 && pwd -P)"
cd "${ROOT_DIR}/light_ui"

# Default behavior:
# - Fn/Globe toggles recording
# - fast STT profile
# - fast IME on (raw first, polish then replace)
swift run cantoflow-light-ui \
  --project-root "${ROOT_DIR}" \
  --stt-profile fast \
  "$@"

