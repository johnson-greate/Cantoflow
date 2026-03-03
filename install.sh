#!/usr/bin/env bash
set -e

echo "=========================================="
echo "    歡迎安裝 CantoFlow (macOS 專用) 🚀"
echo "=========================================="
echo ""

# 1. Check for Xcode Command Line Tools
if ! command -v swift &> /dev/null; then
    echo "⚠️ 找不到 Swift 編譯器。正在為您啟動 Xcode Command Line Tools 安裝程序..."
    xcode-select --install
    echo "❗ 請在彈出的視窗完成安裝後，重新執行此安裝腳本 (bash install.sh)。"
    exit 1
fi

echo "✅ 系統檢查通過: 已經安裝 Swift。"

# 2. Build the Swift Package
echo "🔨 正在編譯 CantoFlow (這可能需要幾分鐘的時間)..."
cd CantoFlow_c
swift build -c release
echo "✅ 編譯成功！"

# 3. Setup Global Command
echo "🔗 正在設定全域捷徑 (Global Command)..."
BIN_DIR="$HOME/bin"
mkdir -p "$BIN_DIR"

# Ensure we get the absolute path to the run script
SCRIPT_PATH="$(pwd)/scripts/run.sh"

ln -sf "$SCRIPT_PATH" "$BIN_DIR/cantoflow"
chmod +x "$SCRIPT_PATH"

echo "✅ 捷徑已建立: $BIN_DIR/cantoflow -> $SCRIPT_PATH"

# 4. Check PATH configuration
if [[ ":$PATH:" != *":$BIN_DIR:"* ]]; then
    echo "⚠️ 警告: $BIN_DIR 尚未加入到你的環境變數 PATH 中。"
    echo "💡 建議執行以下指令將其加入 (以 Zsh 為例):"
    echo "    echo 'export PATH=\"\$HOME/bin:\$PATH\"' >> ~/.zshrc && source ~/.zshrc"
fi

# 5. Env setup wizard for API Keys
ENV_FILE="$HOME/.cantoflow.env"
if [ ! -f "$ENV_FILE" ]; then
    echo ""
    echo "📝 發現您尚未建立 ~/.cantoflow.env 設定檔。"
    echo "   正在為您建立基礎設定檔..."
    cat << 'EOF' > "$ENV_FILE"
# CantoFlow API 密鑰設定
# 請填入您申請的 API Key

# 預設 AI 修正模型: Qwen (通義千問)
DASHSCOPE_API_KEY=""

# (可選) 如果您想使用 OpenAI:
OPENAI_API_KEY=""
EOF
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
echo "👉 啟動後，請到右上角 Menu Bar 設定您的專屬語音快捷鍵！"
echo ""
