#!/usr/bin/env bash
#
# CantoFlow — Student One-Liner Installer
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/johnson-greate/Cantoflow/main/install-student.sh | bash
#
# What it does:
#   1. Downloads CantoFlow.app to /Applications/
#   2. Downloads whisper-cli (speech recognition engine)
#   3. Downloads Whisper model (~1.5GB, one-time)
#   4. Creates config file and launcher script
#   5. Optionally installs Ollama + local LLM for offline polish
#
set -euo pipefail

# ── Configuration ──────────────────────────────────────────────────────────────
REPO="johnson-greate/Cantoflow"
RELEASE_TAG="student-v1"
CANTOFLOW_DIR="${HOME}/CantoFlow"
WHISPER_DIR="${CANTOFLOW_DIR}/third_party/whisper.cpp"
WHISPER_BIN_DIR="${WHISPER_DIR}/build/bin"
WHISPER_MODEL_DIR="${WHISPER_DIR}/models"
APP_INSTALL_DIR="/Applications"
BIN_DIR="${HOME}/bin"

# Whisper model from Hugging Face
MODEL_NAME="ggml-large-v3-turbo.bin"
MODEL_URL="https://huggingface.co/ggerganov/whisper.cpp/resolve/main/${MODEL_NAME}"

# GitHub Release asset URLs
RELEASE_BASE="https://github.com/${REPO}/releases/download/${RELEASE_TAG}"
APP_ZIP_URL="${RELEASE_BASE}/CantoFlow.app.zip"
WHISPER_ZIP_URL="${RELEASE_BASE}/whisper-cli.zip"

# ── Colours ────────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

info()  { printf "${BLUE}[CantoFlow]${NC} %s\n" "$1"; }
ok()    { printf "${GREEN}[CantoFlow]${NC} %s\n" "$1"; }
warn()  { printf "${YELLOW}[CantoFlow]${NC} %s\n" "$1"; }
fail()  { printf "${RED}[CantoFlow]${NC} %s\n" "$1"; exit 1; }

# ── Pre-flight checks ─────────────────────────────────────────────────────────
info "CantoFlow 學員安裝程式"
echo ""

# Check macOS
[[ "$(uname)" == "Darwin" ]] || fail "此安裝程式只支援 macOS。"

# Check architecture
ARCH="$(uname -m)"
[[ "${ARCH}" == "arm64" ]] || fail "此版本只支援 Apple Silicon (M1/M2/M3/M4)。你的架構: ${ARCH}"

# Check curl
command -v curl >/dev/null 2>&1 || fail "找不到 curl，請安裝 Xcode Command Line Tools: xcode-select --install"

# ── Step 1: Create directory structure ─────────────────────────────────────────
info "建立目錄結構..."
mkdir -p "${WHISPER_BIN_DIR}"
mkdir -p "${WHISPER_MODEL_DIR}"
mkdir -p "${CANTOFLOW_DIR}/.out"
mkdir -p "${BIN_DIR}"

# ── Step 2: Download and install CantoFlow.app ─────────────────────────────────
if [[ -d "${APP_INSTALL_DIR}/CantoFlow.app" ]]; then
    warn "發現已安裝的 CantoFlow.app，將會覆蓋更新。"
    rm -rf "${APP_INSTALL_DIR}/CantoFlow.app"
fi

info "下載 CantoFlow.app..."
TMP_APP="$(mktemp -d)/CantoFlow.app.zip"
curl -fSL --progress-bar -o "${TMP_APP}" "${APP_ZIP_URL}" || fail "下載 CantoFlow.app 失敗。請檢查網路連線。"

info "安裝到 /Applications/..."
ditto -x -k "${TMP_APP}" "${APP_INSTALL_DIR}/"
rm -f "${TMP_APP}"

# Remove quarantine flag (bypass Gatekeeper for unsigned app)
xattr -rd com.apple.quarantine "${APP_INSTALL_DIR}/CantoFlow.app" 2>/dev/null || true

ok "CantoFlow.app 已安裝。"

# ── Step 3: Download whisper-cli ───────────────────────────────────────────────
if [[ -x "${WHISPER_BIN_DIR}/whisper-cli" ]]; then
    ok "whisper-cli 已存在，跳過下載。"
else
    info "下載 whisper-cli（語音辨識引擎）..."
    TMP_WHISPER="$(mktemp -d)/whisper-cli.zip"
    curl -fSL --progress-bar -o "${TMP_WHISPER}" "${WHISPER_ZIP_URL}" || fail "下載 whisper-cli 失敗。"

    unzip -o -q "${TMP_WHISPER}" -d "${WHISPER_BIN_DIR}/"
    chmod +x "${WHISPER_BIN_DIR}/whisper-cli"
    rm -f "${TMP_WHISPER}"

    # Remove quarantine
    xattr -rd com.apple.quarantine "${WHISPER_BIN_DIR}/whisper-cli" 2>/dev/null || true

    ok "whisper-cli 已安裝。"
fi

# ── Step 4: Download Whisper model ─────────────────────────────────────────────
MODEL_PATH="${WHISPER_MODEL_DIR}/${MODEL_NAME}"
if [[ -f "${MODEL_PATH}" ]]; then
    MODEL_SIZE=$(stat -f%z "${MODEL_PATH}" 2>/dev/null || echo 0)
    if (( MODEL_SIZE > 1000000000 )); then
        ok "Whisper 模型已存在（$(echo "scale=1; ${MODEL_SIZE}/1073741824" | bc)GB），跳過下載。"
    else
        warn "Whisper 模型檔案太小，重新下載..."
        rm -f "${MODEL_PATH}"
    fi
fi

if [[ ! -f "${MODEL_PATH}" ]]; then
    info "下載 Whisper 語音辨識模型（約 1.5GB，請耐心等候）..."
    curl -fSL --progress-bar -o "${MODEL_PATH}" "${MODEL_URL}" || fail "下載 Whisper 模型失敗。請檢查網路連線後重試。"
    ok "Whisper 模型下載完成。"
fi

# ── Step 5: Create ~/.cantoflow.env ────────────────────────────────────────────
ENV_FILE="${HOME}/.cantoflow.env"
if [[ ! -f "${ENV_FILE}" ]]; then
    info "建立 API 設定檔 ~/.cantoflow.env ..."
    cat > "${ENV_FILE}" << 'ENVEOF'
# CantoFlow API 密鑰設定
# 填入任一 API key 即可啟用 LLM 文字潤飾功能（將口語修正為自然廣東話）
# 不填也可以使用，只是不會有 LLM 潤飾

# Qwen（阿里雲 DashScope）— 免費額度充足，推薦
DASHSCOPE_API_KEY=""

# Google Gemini — 免費額度充足
GEMINI_API_KEY=""

# OpenAI
OPENAI_API_KEY=""

# 本機 LLM（需先安裝 Ollama）
LOCAL_LLM_ENDPOINT="http://localhost:11434/v1/chat/completions"
LOCAL_LLM_MODEL="gemma4:e2b"
ENVEOF
    ok "設定檔已建立: ~/.cantoflow.env"
else
    ok "設定檔已存在，保留現有設定。"
fi

# ── Step 6: Create ~/bin/cantoflow launcher ────────────────────────────────────
LAUNCHER="${BIN_DIR}/cantoflow"
info "建立啟動腳本 ~/bin/cantoflow ..."
cat > "${LAUNCHER}" << 'LAUNCHEREOF'
#!/bin/bash
set -euo pipefail

APP_BINARY="/Applications/CantoFlow.app/Contents/MacOS/cantoflow"
PROJECT_DIR="${HOME}/CantoFlow"

# Load API keys
if [[ -f "${HOME}/.cantoflow.env" ]]; then
    set -a
    source "${HOME}/.cantoflow.env"
    set +a
fi

# Local LLM defaults
export LOCAL_LLM_ENDPOINT="${LOCAL_LLM_ENDPOINT:-http://localhost:11434/v1/chat/completions}"
export LOCAL_LLM_MODEL="${LOCAL_LLM_MODEL:-gemma4:e2b}"

# Kill existing instances
pkill -f "CantoFlow.app/Contents/MacOS/cantoflow" 2>/dev/null && sleep 0.5 || true

exec "${APP_BINARY}" --project-root "${PROJECT_DIR}" --stt-profile fast --auto-replace "$@"
LAUNCHEREOF
chmod +x "${LAUNCHER}"
ok "啟動腳本已建立。"

# Add ~/bin to PATH if not already there
if [[ ":${PATH}:" != *":${BIN_DIR}:"* ]]; then
    SHELL_RC=""
    if [[ -f "${HOME}/.zshrc" ]]; then
        SHELL_RC="${HOME}/.zshrc"
    elif [[ -f "${HOME}/.bashrc" ]]; then
        SHELL_RC="${HOME}/.bashrc"
    fi
    if [[ -n "${SHELL_RC}" ]] && ! grep -q 'export PATH=.*\$HOME/bin' "${SHELL_RC}" 2>/dev/null; then
        echo 'export PATH="$HOME/bin:$PATH"' >> "${SHELL_RC}"
        info "已將 ~/bin 加入 PATH（${SHELL_RC}）"
    fi
fi

# ── Step 7: Optional Ollama installation ───────────────────────────────────────
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
info "可選：安裝本機 LLM（Ollama + Gemma4）"
echo "  這讓你可以完全離線使用 CantoFlow，無需 API key。"
echo "  需要額外下載約 2.5GB。"
echo ""

read -r -p "  是否安裝 Ollama + Gemma4 本機模型？[y/N] " INSTALL_OLLAMA
if [[ "${INSTALL_OLLAMA}" =~ ^[Yy]$ ]]; then
    if command -v ollama >/dev/null 2>&1; then
        ok "Ollama 已安裝。"
    else
        info "安裝 Ollama..."
        curl -fsSL https://ollama.com/install.sh | sh || warn "Ollama 自動安裝失敗，請到 https://ollama.com 手動下載。"
    fi

    if command -v ollama >/dev/null 2>&1; then
        info "下載 Gemma4:e2b 模型（約 2.5GB）..."
        ollama pull gemma4:e2b || warn "模型下載失敗，請稍後手動執行: ollama pull gemma4:e2b"
        ok "本機 LLM 安裝完成！"
        echo ""
        echo "  使用本機 LLM:  cantoflow --polish-provider local"
        echo "  使用雲端 LLM:  cantoflow"
    fi
else
    info "跳過 Ollama 安裝。之後可以手動安裝: https://ollama.com"
fi

# ── Done ───────────────────────────────────────────────────────────────────────
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
ok "CantoFlow 安裝完成！"
echo ""
echo "  首次使用前，請在「系統設定」中授予以下權限："
echo "    1. 輔助使用（Accessibility）"
echo "    2. 輸入監控（Input Monitoring）"
echo "    3. 麥克風（Microphone）"
echo ""
echo "  啟動方式："
echo "    cantoflow                          — 使用雲端 LLM 潤飾"
echo "    cantoflow --polish-provider local  — 使用本機 LLM 潤飾"
echo "    cantoflow --polish-provider none   — 不使用 LLM 潤飾"
echo ""
echo "  設定 API key（可選，用於雲端 LLM 潤飾）："
echo "    編輯 ~/.cantoflow.env"
echo ""
echo "  按住 Fn 鍵說話，放開即轉文字。"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
