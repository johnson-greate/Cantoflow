#!/usr/bin/env bash
set -euo pipefail

# Builds a drag-to-Applications DMG for CantoFlow.
#
# NOTE: the .app is signed with an "Apple Development" cert (not Developer ID),
# so it is NOT notarized. On a student's Mac the first launch needs:
#   System Settings → Privacy & Security → "Open Anyway".
# Once you enrol in the paid Apple Developer Program, add a Developer ID
# signature + `xcrun notarytool submit` + `xcrun stapler staple` here and the
# Open-Anyway step disappears.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "${SCRIPT_DIR}")"
APP_NAME="CantoFlow"
APP_DIR="${PROJECT_DIR}/.build/${APP_NAME}.app"
DMG_PATH="${PROJECT_DIR}/.build/${APP_NAME}.dmg"

# 1. Build + sign the .app bundle.
"${SCRIPT_DIR}/package_app.sh"

# 2. Stage only the .app so the DMG contains nothing else.
STAGING="$(mktemp -d)"
trap 'rm -rf "${STAGING}"' EXIT
cp -R "${APP_DIR}" "${STAGING}/"

# 3. Build the DMG with an Applications drop-link layout.
rm -f "${DMG_PATH}"
create-dmg \
  --volname "${APP_NAME}" \
  --window-pos 200 120 \
  --window-size 600 380 \
  --icon-size 110 \
  --icon "${APP_NAME}.app" 150 180 \
  --app-drop-link 450 180 \
  --hide-extension "${APP_NAME}.app" \
  --no-internet-enable \
  "${DMG_PATH}" \
  "${STAGING}" || true   # create-dmg may exit non-zero even when the DMG is fine

if [[ -f "${DMG_PATH}" ]]; then
  echo ""
  echo "DMG created: ${DMG_PATH}"
  ls -lh "${DMG_PATH}"
else
  echo "ERROR: DMG was not created" >&2
  exit 1
fi
