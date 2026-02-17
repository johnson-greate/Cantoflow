#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname "$0")/.." >/dev/null 2>&1 && pwd -P)"
LIGHT_UI_DIR="${ROOT_DIR}/light_ui"
APP_NAME="CantoFlow.app"
APP_DIR="${ROOT_DIR}/${APP_NAME}"
CONTENTS_DIR="${APP_DIR}/Contents"
MACOS_DIR="${CONTENTS_DIR}/MacOS"
RESOURCES_DIR="${CONTENTS_DIR}/Resources"

echo "[1/4] Building light UI binary..."
cd "${LIGHT_UI_DIR}"
swift build

echo "[2/4] Creating app bundle at ${APP_DIR} ..."
mkdir -p "${MACOS_DIR}" "${RESOURCES_DIR}"

echo "${ROOT_DIR}" > "${RESOURCES_DIR}/project_root.txt"

echo "[3/4] Copying executable..."
cp -f "${LIGHT_UI_DIR}/.build/debug/cantoflow-light-ui" "${MACOS_DIR}/cantoflow-light-ui-bin"
chmod +x "${MACOS_DIR}/cantoflow-light-ui-bin"

cat > "${MACOS_DIR}/CantoFlow" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

EXEC_DIR="$(cd -- "$(dirname "$0")" >/dev/null 2>&1 && pwd -P)"
BUNDLE_DIR="$(cd -- "${EXEC_DIR}/../.." >/dev/null 2>&1 && pwd -P)"
DEFAULT_PROJECT_ROOT="$(cat "${BUNDLE_DIR}/Contents/Resources/project_root.txt" 2>/dev/null || true)"
if [[ -z "${DEFAULT_PROJECT_ROOT}" ]]; then
  DEFAULT_PROJECT_ROOT="$(cd -- "${BUNDLE_DIR}/.." >/dev/null 2>&1 && pwd -P)"
fi
PROJECT_ROOT="${CANTOFLOW_PROJECT_ROOT:-${DEFAULT_PROJECT_ROOT}}"

exec "${EXEC_DIR}/cantoflow-light-ui-bin" \
  --project-root "${PROJECT_ROOT}" \
  --stt-profile fast \
  "$@"
EOF
chmod +x "${MACOS_DIR}/CantoFlow"

cat > "${CONTENTS_DIR}/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleExecutable</key>
  <string>CantoFlow</string>
  <key>CFBundleIdentifier</key>
  <string>com.johnsontam.cantoflow</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>CantoFlow</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>0.1.0</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>LSMinimumSystemVersion</key>
  <string>13.0</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSAppleEventsUsageDescription</key>
  <string>CantoFlow needs Automation access to paste and replace text via System Events.</string>
  <key>NSMicrophoneUsageDescription</key>
  <string>CantoFlow needs microphone access for voice input.</string>
</dict>
</plist>
EOF

echo "[4/4] Done."
echo "App bundle created: ${APP_DIR}"
echo "Launch with: open \"${APP_DIR}\""
