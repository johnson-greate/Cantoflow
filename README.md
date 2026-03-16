# CantoFlow

> **CantoFlow** 是一個專為廣東話設計的 AI 語音輸入與文字潤飾開源工具，讓你在 macOS 與 Windows 上能以最自然的方式進行廣東話語音輸入，並自動轉換成通順、精準的書面語或口語文字。

## ✨ 核心特色

- **全域語音輸入 (Push-to-Talk)**：按下你設定的快捷鍵（macOS 支援 Apple Silicon Fn 鍵；Windows 支援任意鍵盤組合），隨時隨地在任何應用程式中進行語音輸入。
- **強大的廣東話辨識**：底層整合先進語音辨識技術 (Whisper)，精準捕捉廣東話發音。
- **AI 智能潤飾 (Text Polish)**：錄音完成後，自動將文字交由大型語言模型 (如 Qwen 通義千問或 OpenAI) 進行上下文梳理與錯別字修正，甚至自動過濾掉不自然的拼音亂碼。
- **自訂專屬詞彙庫 (Vocabulary System)**：內建超過 400+ 個香港常用詞彙，你也可以隨時加入個人專屬的專業術語或人名，讓 AI 越用越懂你。
- **高度隱私與開源**：基於 **MIT License** / **GPLv3** 開源精神，你的資料流向完全透明，更歡迎各界社群開發者貢獻程式碼共同完善！

## 🖥️ 平台支援

| 平台 | 狀態 | STT 加速 |
|------|------|----------|
| macOS (Apple Silicon) | ✅ 完整支援 | Metal GPU (~2s) |
| macOS (Intel) | ✅ 支援 | CPU (~5s) |
| Windows 10/11 x64 | ✅ 完整支援 | Vulkan GPU (~7s, Intel/AMD/NVIDIA) |

---

## 🍎 macOS 快速安裝

我們為 macOS 使用者準備了極簡的全自動安裝腳本。詳細的環境需求與手動安裝方式，請參閱 [INSTALL.md](INSTALL.md)。

1. **下載專案**
   ```bash
   git clone https://github.com/johnson-greate/Cantoflow.git
   cd Cantoflow
   ```

2. **執行自動安裝腳本**
   ```bash
   bash install.sh
   ```
   *腳本會自動安裝 Homebrew 依賴、下載/編譯 `whisper.cpp`、下載必要模型、編譯 app、建立全域捷徑，並導引你設定 API Keys。*

3. **設定 API Key**
   你需要在大語言模型供應商 (例如 Aliyun DashScope 通義千問) 取得 API Key，並填入 `~/.cantoflow.env` 檔案中：
   ```env
   DASHSCOPE_API_KEY="sk-你的密鑰"
   ```

4. **開始暢所欲言！**
   啟動程式：
   ```bash
   cantoflow
   ```
   首次啟動時，請依系統提示授權：
   - Microphone
   - Accessibility
   - Input Monitoring

   你可以點擊右上角 Menu Bar 圖示進入 **Settings...** 去自訂你最順手的錄音快捷鍵，設定好後，長按該鍵說出廣東話，放開按鍵後，文字就會自動輸入到你當前的視窗。若要提升專有名詞、香港用詞與 vocab 校正效果，可在 **Settings > API Keys** 輸入 `DASHSCOPE_API_KEY` 啟用 Qwen 潤飾。

---

## 🪟 Windows 安裝

完整 Windows 安裝說明（包括 Vulkan GPU 加速設定）請參閱 **[docs/windows-setup-guide.md](docs/windows-setup-guide.md)**。

### 快速開始

**前置條件：** Windows 10/11 x64、.NET 10 SDK、Git

```powershell
# 1. 安裝 .NET 10 SDK（如尚未安裝）
winget install Microsoft.DotNet.SDK.10

# 2. Clone repo
git clone https://github.com/johnson-greate/Cantoflow.git C:\Cantoflow

# 3. Build + Run
cd C:\Cantoflow\windows
dotnet run --project src\CantoFlow.App
```

### Whisper 模型（必要）

從 CantoFlow GitHub Releases 下載 **`whisper-vulkan-win-x64.zip`**（預編譯 Vulkan GPU 版，17MB），解壓後複製到 `%APPDATA%\CantoFlow\`。

再下載 Whisper 模型 `ggml-large-v3-turbo-q5_0.bin`（560MB）放入 `%APPDATA%\CantoFlow\models\`。

詳細步驟見 [Windows Setup Guide](docs/windows-setup-guide.md)。

### Windows 功能概覽

- **系統托盤圖示**：點擊開始/停止錄音；顯示上次 STT/LLM 耗時
- **錄音浮窗**：屏幕下方居中顯示錄音狀態與聲音電平
- **Settings 視窗**：
  - General — 自訂熱鍵
  - Vocabulary — 管理個人詞彙（新增/編輯/移除；匯入入門詞庫）
  - API Keys — 設定 Qwen / OpenAI 等 API Key
- **Vulkan GPU 加速**：Intel Iris Xe 約 7 秒，遠優於 CPU-only 的 49 秒

---

## 🤝 參與貢獻 (Contributing)

CantoFlow 目前正處於積極開發的階段，我們非常歡迎各位網友基於開源協議共同使用與改進本項目！如果你有任何好點子，或者發現了 Bug，歡迎隨時：
1. 提交 [Issue](https://github.com/johnson-greate/Cantoflow/issues) 與我們討論。
2. Fork 此專案，並發送 Pull Request (PR) 貢獻你的程式碼。

*CantoFlow 致力於提升粵語使用者的數位輸入體驗與私隱保護水平，感謝你的支持與使用！*

---

### Sponsor & Supported By
**Greate (HK) Limited**
🌐 [http://www.greate.com.hk](http://www.greate.com.hk)
