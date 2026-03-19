#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "${SCRIPT_DIR}")"
APP_NAME="CantoFlow"

cd "${PROJECT_DIR}"

# Build release binary
echo "Building release binary..."
swift build -c release

# Create app bundle structure
APP_DIR="${PROJECT_DIR}/.build/${APP_NAME}.app"
CONTENTS_DIR="${APP_DIR}/Contents"
MACOS_DIR="${CONTENTS_DIR}/MacOS"
RESOURCES_DIR="${CONTENTS_DIR}/Resources"

echo "Creating app bundle at ${APP_DIR}..."
rm -rf "${APP_DIR}"
mkdir -p "${MACOS_DIR}"
mkdir -p "${RESOURCES_DIR}"

# Copy binary
cp "${PROJECT_DIR}/.build/release/cantoflow" "${MACOS_DIR}/cantoflow"

# Copy Info.plist
cp "${PROJECT_DIR}/Resources/Info.plist" "${CONTENTS_DIR}/Info.plist"

# Create PkgInfo
echo -n "APPL????" > "${CONTENTS_DIR}/PkgInfo"

# Sign the app (ad-hoc signing for local use)
echo "Signing app bundle..."
codesign --force --deep --sign - "${APP_DIR}"

echo ""
echo "App bundle created: ${APP_DIR}"
echo ""
echo "To install:"
echo "  cp -r '${APP_DIR}' /Applications/"
echo ""
echo "Or run the install script:"
echo "  ${SCRIPT_DIR}/install.sh"
