#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "${SCRIPT_DIR}")"
APP_NAME="CantoFlow"
LEGACY_APP_NAME="CantoFlow_c"

APP_SOURCE="${PROJECT_DIR}/.build/${APP_NAME}.app"
APP_DEST="/Applications/${APP_NAME}.app"
LEGACY_APP_DEST="/Applications/${LEGACY_APP_NAME}.app"

# Build and package if not already done
if [[ ! -d "${APP_SOURCE}" ]]; then
    echo "App bundle not found. Building first..."
    "${SCRIPT_DIR}/package_app.sh"
fi

# Check if app exists in /Applications
if [[ -d "${APP_DEST}" ]]; then
    echo "Removing existing ${APP_NAME}.app..."
    rm -rf "${APP_DEST}"
fi

if [[ -d "${LEGACY_APP_DEST}" ]]; then
    echo "Removing legacy ${LEGACY_APP_NAME}.app..."
    rm -rf "${LEGACY_APP_DEST}"
fi

echo "Installing ${APP_NAME}.app to /Applications..."
cp -r "${APP_SOURCE}" "${APP_DEST}"

echo ""
echo "Installation complete!"
echo ""
echo "To run CantoFlow:"
echo "  open /Applications/${APP_NAME}.app --args --project-root $(dirname "${PROJECT_DIR}")"
echo ""
echo "Or from command line:"
echo "  /Applications/${APP_NAME}.app/Contents/MacOS/cantoflow --project-root $(dirname "${PROJECT_DIR}")"
echo ""
echo "Required permissions (grant in System Settings > Privacy & Security):"
echo "  - Microphone"
echo "  - Accessibility"
echo "  - Input Monitoring"
