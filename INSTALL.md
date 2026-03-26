# CantoFlow 安裝指南 (Installation Guide)

歡迎來到 CantoFlow！這是一個專為廣東話設計的 AI 語音輸入與文字潤飾開源工具。為了讓每位網友都能輕鬆上手，我們準備了自動化安裝腳本與完整的手動安裝說明。

---

## 🚀 方法一：自動安裝 (推薦)

我們提供了一個自動化腳本，會幫你檢查依賴工具、安裝 `whisper.cpp` 與模型、編譯程式碼、安裝 `/Applications/CantoFlow.app`，並設定好全域捷徑。

1. 打開終端機 (Terminal)。
2. 切換到你下載或 git clone 下來的 `CantoFlow` 資料夾：
   ```bash
   cd /path/to/CantoFlow
   ```
3. 執行安裝腳本：
   ```bash
   bash install.sh
   ```
4. 腳本執行完畢後，你就可以在任何地方直接輸入 `cantoflow` 來啟動程式了！

自動安裝腳本會完成以下工作：
- 檢查 Xcode Command Line Tools / Swift
- 檢查或安裝 Homebrew 依賴：`cmake`、`ffmpeg`、`jq`
- clone `third_party/whisper.cpp`
- 編譯 `whisper-cli`
- 下載 `large-v3-turbo`、`large-v3`、`small` 模型
- 編譯 `app`
- 安裝 `/Applications/CantoFlow.app`
- 建立 `~/bin/cantoflow`
- 建立 `~/.cantoflow.env`

---

## 🛠 方法二：手動安裝

如果你想了解背後的運作原理，或是遇到自動安裝失敗的情況，可以參考以下手動步驟：

### 1. 系統需求
- **macOS**: 僅支援 macOS (推薦 Apple Silicon M1/M2/M3/M4 以獲得最佳效能)。
- **Xcode Command Line Tools**: 必須安裝 Swift 編譯器。
  ```bash
  xcode-select --install
  ```

### 2. 編譯專案
先安裝 STT 依賴：
```bash
brew install cmake ffmpeg jq
mkdir -p third_party
git clone https://github.com/ggerganov/whisper.cpp.git third_party/whisper.cpp
cmake -B third_party/whisper.cpp/build -S third_party/whisper.cpp
cmake --build third_party/whisper.cpp/build -j 8
cd third_party/whisper.cpp/models
bash ./download-ggml-model.sh large-v3-turbo
bash ./download-ggml-model.sh large-v3
bash ./download-ggml-model.sh small
cd /path/to/CantoFlow
```

然後編譯 Swift app：
進入 Swift 程式碼所在目錄，並以 Release 模式進行編譯：
```bash
cd app
swift build -c release
```

### 3. 安裝 App Bundle
先把 app bundle 安裝到 `/Applications`：

```bash
cd app
./scripts/package_app.sh
./scripts/install.sh
```

### 4. 設定全域捷徑 (Global Command)
為了讓你能在任何地方打 `cantoflow` 就能啟動，建議建立一個 wrapper script 到 `~/bin/cantoflow`。它會先安全退出現有 app，再交給 launchd supervision 或直接開啟 `/Applications/CantoFlow.app`，避免 menubar 雙開。

1. 確保 `~/bin` 目錄存在：
   ```bash
   mkdir -p ~/bin
   ```
2. 建立 launcher script：
   ```bash
   cat > ~/bin/cantoflow <<'EOF'
   #!/bin/bash
   set -euo pipefail

   LOG_FILE="${HOME}/Library/Logs/CantoFlow.manual.log"
   APP_BUNDLE="/Applications/CantoFlow.app"
   APP_BINARY="${APP_BUNDLE}/Contents/MacOS/cantoflow"
   LAUNCH_AGENT_LABEL="com.cantoflow.launchagent"
   LAUNCH_AGENT_PLIST="${HOME}/Library/LaunchAgents/${LAUNCH_AGENT_LABEL}.plist"
   BASE_ARGS=(
     --project-root "/path/to/CantoFlow"
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

   terminate_existing_instances() {
     local pids=()
     while IFS= read -r pid; do
       [[ -n "${pid}" ]] || continue
       pids+=("${pid}")
     done < <(pgrep -f "${APP_BINARY}" || true)

     [[ "${#pids[@]}" -eq 0 ]] && return
     kill "${pids[@]}" 2>/dev/null || true
     sleep 1
     kill -9 "${pids[@]}" 2>/dev/null || true
   }

   if [[ ! -x "${APP_BINARY}" ]]; then
     echo "Installed app not found at ${APP_BINARY}" >&2
     exit 1
   fi

   log_line "manual-launch request"

   if pgrep -f "${APP_BINARY}" >/dev/null 2>&1; then
     log_line "request-clean-quit"
     osascript -e 'tell application "CantoFlow" to quit' >/dev/null 2>&1 || true
     sleep 1
   fi

   terminate_existing_instances

   if [[ "$#" -eq 0 ]] && [[ -f "${LAUNCH_AGENT_PLIST}" ]]; then
     log_line "launch-via-launchd | label=${LAUNCH_AGENT_LABEL}"
     launchctl kickstart -k "gui/$(id -u)/${LAUNCH_AGENT_LABEL}"
     exit 0
   fi

   log_line "launch-via-open"
   /usr/bin/open -n "${APP_BUNDLE}" --args "${BASE_ARGS[@]}" "$@"
   EOF
   chmod 755 ~/bin/cantoflow
   ```
3. 確保 `~/bin` 已經加入到你的系統 `PATH` 中 (可以在 `~/.zshrc` 或 `~/.bash_profile` 內加入 `export PATH="$HOME/bin:$PATH"`)。

---

## ⚙️ 第一步：設定你的 API Key

無論你是用哪種方式安裝，這是你開始使用前最重要的設定！
CantoFlow 支援將透過語音轉成的文字，交由遠端的 LLM (大型語言模型) 進行順暢的廣東話潤飾。

1. 在你的家目錄建立一個環境變數檔：
   ```bash
   nano ~/.cantoflow.env
   ```
2. 將你的 API Keys 填入 (依你所選用的模型而定)，例如：
   ```env
   # Qwen (通義千問) API Key
   DASHSCOPE_API_KEY="sk-xxxxxxxxxxxxxxxxxxxxxxxx"

   # OpenAI API Key (如果有使用)
   OPENAI_API_KEY="sk-proj-xxxxxxxxxxxxxxxxxxxxxxxx"
   ```
3. 儲存檔案 (`Ctrl+O`, `Enter`, `Ctrl+X`)。

---

## 🎤 開始使用

設定完成後，只要在 Terminal 內輸入：
```bash
cantoflow
```

1. 程式啟動後，會在右上角的 Menu Bar 出現圖示。
2. 你可以前往 **Menu Bar > Settings > General** 設定你的**專屬觸發快捷鍵** (支援 Fn / Globe 鍵或任何組合)。
3. 長按你設定的快捷鍵，開始說話，放開後自動送出並潤飾文字到你當前游標鎖定的視窗！

若程式開到但未能錄音或未能上字，請先檢查：
- `System Settings > Privacy & Security > Microphone`
- `System Settings > Privacy & Security > Accessibility`
- `System Settings > Privacy & Security > Input Monitoring`
- `System Settings > Sound > Input` 是否選中正確麥克風

歡迎使用 CantoFlow，也期待你提交 PR (Pull Requests) 與 Issues 與社群共同成長！
