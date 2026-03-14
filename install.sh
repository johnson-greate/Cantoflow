#!/usr/bin/env bash
set -euo pipefail

echo "=========================================="
echo "    歡迎安裝 CantoFlow (macOS 專用) 🚀"
echo "=========================================="
echo ""

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_DIR="$ROOT_DIR/CantoFlow_c"
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

if [[ ! -x "$WHISPER_BIN" ]]; then
    echo "🔨 正在編譯 whisper.cpp..."
    cmake -B "$WHISPER_DIR/build" -S "$WHISPER_DIR"
    cmake --build "$WHISPER_DIR/build" -j 8
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

# 5. Build the Swift Package
log_step "編譯 CantoFlow"
cd "$APP_DIR"
swift build -c release
echo "✅ 編譯成功！"

# 6. Setup Global Command
log_step "設定全域捷徑"
BIN_DIR="$HOME/bin"
mkdir -p "$BIN_DIR"

# Ensure we get the absolute path to the run script
SCRIPT_PATH="$(pwd)/scripts/run.sh"

ln -sf "$SCRIPT_PATH" "$BIN_DIR/cantoflow"
chmod +x "$SCRIPT_PATH"

echo "✅ 捷徑已建立: $BIN_DIR/cantoflow -> $SCRIPT_PATH"

# 7. Check PATH configuration
if [[ ":$PATH:" != *":$BIN_DIR:"* ]]; then
    echo "⚠️ 警告: $BIN_DIR 尚未加入到你的環境變數 PATH 中。"
    echo "💡 建議執行以下指令將其加入 (以 Zsh 為例):"
    echo "    echo 'export PATH=\"\$HOME/bin:\$PATH\"' >> ~/.zshrc && source ~/.zshrc"
fi

# 8. Env setup wizard for API Keys
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
