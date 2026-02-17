#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname "$0")/.." >/dev/null 2>&1 && pwd -P)"
SOURCE_APP="${ROOT_DIR}/CantoFlow.app"
TARGET_APP="${1:-/Applications/CantoFlow.app}"

usage() {
  cat <<EOF
Usage:
  $0 [target_app_path]

Examples:
  $0
  $0 /Applications/CantoFlow.app
  $0 /Users/$(whoami)/Applications/CantoFlow.app
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

echo "[1/3] Build + package CantoFlow.app..."
"${ROOT_DIR}/poc/package_light_ui_app.sh"

if [[ ! -d "${SOURCE_APP}" ]]; then
  echo "Source app bundle not found: ${SOURCE_APP}" >&2
  exit 1
fi

TARGET_PARENT="$(dirname "${TARGET_APP}")"
echo "[2/3] Install to ${TARGET_APP} ..."

nearest_existing_parent() {
  local path="$1"
  while [[ ! -e "${path}" && "${path}" != "/" ]]; do
    path="$(dirname "${path}")"
  done
  echo "${path}"
}

install_without_sudo() {
  mkdir -p "${TARGET_PARENT}"
  rm -rf "${TARGET_APP}"
  cp -R "${SOURCE_APP}" "${TARGET_APP}"
  xattr -dr com.apple.quarantine "${TARGET_APP}" >/dev/null 2>&1 || true
}

install_with_sudo() {
  sudo mkdir -p "${TARGET_PARENT}"
  sudo rm -rf "${TARGET_APP}"
  sudo cp -R "${SOURCE_APP}" "${TARGET_APP}"
  sudo xattr -dr com.apple.quarantine "${TARGET_APP}" >/dev/null 2>&1 || true
  # Ensure current user can update/reinstall later without permission pain.
  sudo chown -R "$(id -u):$(id -g)" "${TARGET_APP}" >/dev/null 2>&1 || true
}

EXISTING_PARENT="$(nearest_existing_parent "${TARGET_PARENT}")"
if [[ -w "${EXISTING_PARENT}" ]]; then
  install_without_sudo
else
  echo "Need admin permission to write ${TARGET_PARENT} (nearest existing: ${EXISTING_PARENT})."
  install_with_sudo
fi

echo "[3/3] Done."
echo "Installed app: ${TARGET_APP}"
echo "Launch with: open \"${TARGET_APP}\""
