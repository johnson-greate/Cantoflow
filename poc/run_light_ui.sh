#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname "$0")/.." >/dev/null 2>&1 && pwd -P)"
APP_PATH="${ROOT_DIR}/CantoFlow.app"

if [[ ! -d "${APP_PATH}" ]]; then
  "${ROOT_DIR}/poc/package_light_ui_app.sh"
fi

if [[ $# -eq 0 ]]; then
  open "${APP_PATH}"
else
  # Debug path when you need custom args:
  "${APP_PATH}/Contents/MacOS/CantoFlow" "$@"
fi
