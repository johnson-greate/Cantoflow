#!/usr/bin/env bash
set -euo pipefail

echo "=========================================="
echo "    歡迎安裝 CantoFlow (macOS 專用) 🚀"
echo "=========================================="
echo ""

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_DIR="$ROOT_DIR/app"
APP_INSTALL_SCRIPT="$APP_DIR/scripts/install.sh"

# Parse optional flags
PREBUILT_BINARY=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --prebuilt)
            PREBUILT_BINARY="$2"
            shift 2
            ;;
        *) shift ;;
    esac
done
THIRD_PARTY_DIR="$ROOT_DIR/third_party"
WHISPER_DIR="$THIRD_PARTY_DIR/whisper.cpp"
WHISPER_BIN="$WHISPER_DIR/build/bin/whisper-cli"
MODEL_DIR="$WHISPER_DIR/models"
REQUIRED_BREW_PACKAGES=(cmake ffmpeg jq)
REQUIRED_MODELS=(large-v3-turbo large-v3 small)

log_step() {
    echo ""
    echo "▶ $1"
}

build_release_binary() {
    local build_output

    if build_output="$(cd "$APP_DIR" && swift build -c release 2>&1)"; then
        printf '%s\n' "$build_output"
        return 0
    fi

    printf '%s\n' "$build_output"
    if [[ "$build_output" == *"PCH was compiled with module cache path"* ]] || [[ "$build_output" == *"missing required module 'SwiftShims'"* ]]; then
        echo "⚠️ 偵測到 Swift module cache 與目前 repo 路徑不一致，正在 clean 後重建..."
        (
            cd "$APP_DIR"
            swift package clean
            rm -rf .build
            swift build -c release
        )
        return 0
    fi

    return 1
}

build_whisper_binary() {
    cmake -B "$WHISPER_DIR/build" -S "$WHISPER_DIR"
    cmake --build "$WHISPER_DIR/build" -j 8
}

whisper_binary_usable() {
    [[ -x "$WHISPER_BIN" ]] || return 1

    local whisper_output
    if whisper_output="$("$WHISPER_BIN" --help 2>&1 >/dev/null)"; then
        return 0
    fi

    printf '%s\n' "$whisper_output"
    return 1
}

have_all_models() {
    [[ -f "$MODEL_DIR/ggml-large-v3-turbo.bin" ]] &&
    [[ -f "$MODEL_DIR/ggml-large-v3.bin" ]] &&
    [[ -f "$MODEL_DIR/ggml-small.bin" ]]
}

# 1. Check for Xcode Command Line Tools
if ! command -v swift &> /dev/null; then
    echo "⚠️ 找不到 Swift 編譯器。正在為您啟動 Xcode Command Line Tools 安裝程序..."
    xcode-select --install
    echo "❗ 請在彈出的視窗完成安裝後，重新執行此安裝腳本 (bash install.sh)。"
    exit 1
fi

echo "✅ 系統檢查通過: 已經安裝 Swift。"

# 2. Check Homebrew dependencies
log_step "檢查 Homebrew 依賴"
if ! command -v brew &> /dev/null; then
    echo "❌ 找不到 Homebrew。請先安裝 Homebrew: https://brew.sh"
    exit 1
fi

MISSING_PACKAGES=()
for pkg in "${REQUIRED_BREW_PACKAGES[@]}"; do
    if ! brew list --versions "$pkg" >/dev/null 2>&1; then
        MISSING_PACKAGES+=("$pkg")
    fi
done

if [[ ${#MISSING_PACKAGES[@]} -gt 0 ]]; then
    echo "📦 正在安裝缺少的套件: ${MISSING_PACKAGES[*]}"
    brew install "${MISSING_PACKAGES[@]}"
else
    echo "✅ Homebrew 依賴已齊全。"
fi

# 3. Prepare whisper.cpp
log_step "準備 whisper.cpp"
mkdir -p "$THIRD_PARTY_DIR"

if [[ ! -d "$WHISPER_DIR/.git" ]]; then
    git clone https://github.com/ggerganov/whisper.cpp.git "$WHISPER_DIR"
else
    echo "✅ 發現現有 whisper.cpp repo，跳過 clone。"
fi

if ! whisper_binary_usable; then
    echo "🔨 正在編譯 whisper.cpp..."
    rm -rf "$WHISPER_DIR/build"
    build_whisper_binary
else
    echo "✅ whisper-cli 已存在，跳過編譯。"
fi

# 4. Download models
log_step "檢查 Whisper 模型"
if have_all_models; then
    echo "✅ 所需模型已存在。"
else
    pushd "$MODEL_DIR" >/dev/null
    for model in "${REQUIRED_MODELS[@]}"; do
        model_file="ggml-${model}.bin"
        if [[ ! -f "$MODEL_DIR/$model_file" ]]; then
            echo "⬇️ 下載模型: $model"
            bash ./download-ggml-model.sh "$model"
        else
            echo "✅ 模型已存在: $model_file"
        fi
    done
    popd >/dev/null
fi

# 5. Build the Swift Package (or use pre-built binary)
log_step "安裝 CantoFlow binary"
mkdir -p "$APP_DIR/.build/release"
if [[ -n "$PREBUILT_BINARY" ]]; then
    if [[ ! -f "$PREBUILT_BINARY" ]]; then
        echo "❌ 找不到預編譯 binary: $PREBUILT_BINARY"
        exit 1
    fi
    TARGET_BINARY="$APP_DIR/.build/release/cantoflow"
    PREBUILT_REALPATH="$(cd "$(dirname "$PREBUILT_BINARY")" && pwd)/$(basename "$PREBUILT_BINARY")"
    TARGET_REALPATH="$(cd "$(dirname "$TARGET_BINARY")" && pwd)/$(basename "$TARGET_BINARY")"
    if [[ "$PREBUILT_REALPATH" != "$TARGET_REALPATH" ]]; then
        cp "$PREBUILT_BINARY" "$TARGET_BINARY"
    fi
    chmod +x "$TARGET_BINARY"
    echo "✅ 使用預編譯 binary（跳過 Swift 編譯）"
else
    build_release_binary
    echo "✅ 編譯成功！"
fi

cd "$ROOT_DIR"

# 6. Install app bundle
log_step "安裝 CantoFlow.app"
"$APP_INSTALL_SCRIPT"

# 7. Setup Global Command
log_step "設定全域捷徑"
BIN_DIR="$HOME/bin"
mkdir -p "$BIN_DIR"
CANTO_LAUNCHER="$BIN_DIR/cantoflow"
cat > "$CANTO_LAUNCHER" <<'EOF'
#!/bin/bash
set -euo pipefail

LOG_FILE="${HOME}/Library/Logs/CantoFlow.manual.log"
APP_BUNDLE="/Applications/CantoFlow.app"
APP_BINARY="${APP_BUNDLE}/Contents/MacOS/cantoflow"
LAUNCH_AGENT_LABEL="com.cantoflow.launchagent"
LAUNCH_AGENT_PLIST="${HOME}/Library/LaunchAgents/${LAUNCH_AGENT_LABEL}.plist"
BASE_ARGS=(
  --project-root "__CANTOFLOW_PROJECT_ROOT__"
  --stt-profile fast
  --auto-replace
)

mkdir -p "$(dirname "${LOG_FILE}")"

log_line() {
  {
    printf '[%s] %s' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$1"
    printf '\n'
  } >> "${LOG_FILE}"
}

wait_for_app_pid() {
  local deadline=$((SECONDS + 10))
  local pid=""
  while (( SECONDS < deadline )); do
    pid="$(pgrep -n -f "${APP_BINARY}" || true)"
    if [[ -n "${pid}" ]]; then
      printf '%s\n' "${pid}"
      return 0
    fi
    sleep 0.2
  done
  return 1
}

terminate_existing_instances() {
  local pids=()
  while IFS= read -r pid; do
    [[ -n "${pid}" ]] || continue
    pids+=("${pid}")
  done < <(pgrep -f "${APP_BINARY}" || true)

  if [[ "${#pids[@]}" -eq 0 ]]; then
    return
  fi

  log_line "terminate-existing | pids=${pids[*]}"
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

  log_line "force-terminate-existing | pids=${pids[*]}"
  kill -9 "${pids[@]}" 2>/dev/null || true
}

safe_quit_existing_instances() {
  if pgrep -f "${APP_BINARY}" >/dev/null 2>&1; then
    log_line "request-clean-quit"
    osascript -e 'tell application "CantoFlow" to quit' >/dev/null 2>&1 || true

    local deadline=$((SECONDS + 5))
    while (( SECONDS < deadline )); do
      if ! pgrep -f "${APP_BINARY}" >/dev/null 2>&1; then
        return
      fi
      sleep 0.2
    done
  fi

  terminate_existing_instances
}

if [[ ! -x "${APP_BINARY}" ]]; then
  echo "Installed app not found at ${APP_BINARY}" >&2
  exit 1
fi

{
  printf '[%s] manual-launch request | cwd=%s | args=' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$(pwd)"
  printf '%q ' "${BASE_ARGS[@]}" "$@"
  printf '\n'
} >> "${LOG_FILE}"

safe_quit_existing_instances

if [[ "$#" -eq 0 ]] && [[ -f "${LAUNCH_AGENT_PLIST}" ]]; then
  log_line "launch-via-launchd | label=${LAUNCH_AGENT_LABEL}"
  launchctl kickstart -k "gui/$(id -u)/${LAUNCH_AGENT_LABEL}"
  if pid="$(wait_for_app_pid)"; then
    echo "CantoFlow started via launchd (pid ${pid})"
  else
    echo "CantoFlow launch requested via launchd; app pid not observed yet"
  fi
  exit 0
fi

log_line "launch-via-open"
/usr/bin/open -n "${APP_BUNDLE}" --args "${BASE_ARGS[@]}" "$@"
if pid="$(wait_for_app_pid)"; then
  echo "CantoFlow started via app bundle (pid ${pid})"
else
  echo "CantoFlow open requested; app pid not observed yet"
fi
EOF
python3 - <<'PY' "$CANTO_LAUNCHER" "$ROOT_DIR"
from pathlib import Path
import sys
launcher = Path(sys.argv[1])
root = sys.argv[2]
launcher.write_text(launcher.read_text().replace("__CANTOFLOW_PROJECT_ROOT__", root))
PY
chmod 755 "$CANTO_LAUNCHER"

echo "✅ 捷徑已建立: $CANTO_LAUNCHER"

# 8. Check PATH configuration
if [[ ":$PATH:" != *":$BIN_DIR:"* ]]; then
    echo "⚠️ 警告: $BIN_DIR 尚未加入到你的環境變數 PATH 中。"
    echo "💡 建議執行以下指令將其加入 (以 Zsh 為例):"
    echo "    echo 'export PATH=\"\$HOME/bin:\$PATH\"' >> ~/.zshrc && source ~/.zshrc"
fi

# 9. Env setup wizard for API Keys
ENV_FILE="$HOME/.cantoflow.env"
if [ ! -f "$ENV_FILE" ]; then
    echo ""
    echo "📝 發現您尚未建立 ~/.cantoflow.env 設定檔。"
    echo "   正在為您建立基礎設定檔..."
    cat << 'EOF' > "$ENV_FILE"
# CantoFlow API 密鑰設定
# 請填入您申請的 API Key

# 預設 AI 修正模型: Qwen (通義千問 / DashScope)
DASHSCOPE_API_KEY=""

# 舊版相容別名（可不填）
QWEN_API_KEY=""

# (可選) 如果您想使用 OpenAI:
OPENAI_API_KEY=""

# (可選) 如果您想使用 Anthropic:
ANTHROPIC_API_KEY=""
EOF
    chmod 600 "$ENV_FILE"
    echo "✅ 設定檔已建立在: $ENV_FILE"
    echo "❗ 請記得開啟它並填入您的 API Keys: nano ~/.cantoflow.env"
else
    echo "✅ 發現現有的設定檔: $ENV_FILE"
fi

echo ""
echo "=========================================="
echo "🎉 CantoFlow 安裝完成！"
echo "=========================================="
echo "👉 您現在可以直接在終端機輸入 'cantoflow' 來啟動應用程式。"
echo "👉 已安裝 whisper-cli 與模型，fresh clone 後可直接進行本地 STT。"
echo "👉 啟動後，請到右上角 Menu Bar 設定您的專屬語音快捷鍵！"
echo ""
