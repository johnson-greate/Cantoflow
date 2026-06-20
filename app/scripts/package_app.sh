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
mkdir -p "${RESOURCES_DIR}/asr"

# Copy binary
cp "${PROJECT_DIR}/.build/release/cantoflow" "${MACOS_DIR}/cantoflow"

# Copy Info.plist
cp "${PROJECT_DIR}/Resources/Info.plist" "${CONTENTS_DIR}/Info.plist"

# Bundle the optional local-ASR bridge and installer so Models remains usable
# when CantoFlow.app is launched directly instead of from a source checkout.
cp "$(dirname "${PROJECT_DIR}")/scripts/local_asr_bridge.py" "${RESOURCES_DIR}/asr/"
cp "$(dirname "${PROJECT_DIR}")/scripts/prepare_qwen3_asr.py" "${RESOURCES_DIR}/asr/"
cp "$(dirname "${PROJECT_DIR}")/scripts/install-local-asr.sh" "${RESOURCES_DIR}/asr/"
chmod +x "${RESOURCES_DIR}/asr/"*.py "${RESOURCES_DIR}/asr/"*.sh

# Create PkgInfo
echo -n "APPL????" > "${CONTENTS_DIR}/PkgInfo"

# Prefer a stable Apple Development identity when one is available. TCC
# permissions (Accessibility / Input Monitoring) are tied to the app's code
# requirement; ad-hoc signing changes that identity on every rebuild.
SIGNING_IDENTITY="${CANTOFLOW_CODESIGN_IDENTITY:-}"
if [[ -z "${SIGNING_IDENTITY}" ]]; then
    SIGNING_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
        | sed -n 's/.*"\(Apple Development:[^"]*\)".*/\1/p' \
        | head -n 1)"
fi

if [[ -n "${SIGNING_IDENTITY}" ]]; then
    echo "Signing app bundle with ${SIGNING_IDENTITY}..."
    codesign --force --deep --timestamp=none --sign "${SIGNING_IDENTITY}" "${APP_DIR}"
else
    echo "No development identity found; falling back to ad-hoc signing."
    codesign --force --deep --sign - "${APP_DIR}"
fi

echo ""
echo "App bundle created: ${APP_DIR}"
echo ""
echo "To install:"
echo "  cp -r '${APP_DIR}' /Applications/"
echo ""
echo "Or run the install script:"
echo "  ${SCRIPT_DIR}/install.sh"
