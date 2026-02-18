# CantoFlow_c — Claude 開發筆記

## Autonomy Settings
- Do not ask for confirmation on file edits
- Do not ask for confirmation on running tests
- Proceed autonomously unless encountering destructive operations
- Only pause for: deleting files, external API calls, git push

## 專案概況
- macOS Menu Bar app，廣東話語音轉繁體中文 (STT)
- 使用 **Swift Package Manager**（`swift build`），**非 Xcode project**
- Binary: `.build/debug/cantoflow`
- 當前版本：`0.2.3`（見 `AppVersion.swift` + `Resources/Info.plist`）

---

## Build & Run

```bash
cd /Users/johnson_tam/Documents/CantoFlow/CantoFlow_c
swift build
# 必須先 Quit 舊的 app，才能啟動新 binary
.build/debug/cantoflow
```

**Project root**（whisper.cpp 等第三方依賴）在：
```
/Users/johnson_tam/Documents/CantoFlow/
```

---

## 檔案結構

```
Sources/CantoFlowApp/
├── AppConfig.swift          # 所有 CLI flags 與預設值
├── AppVersion.swift         # 版本號常量（升版本必改）
├── AppDelegate.swift        # App entry point
├── main.swift
├── Core/
│   ├── STTPipeline.swift    # 主流程：錄音 → STT → Polish → Insert
│   ├── AudioCapture.swift   # 麥克風錄音
│   ├── WhisperRunner.swift  # 調用 whisper-cli binary
│   ├── FunASRRunner.swift   # FunASR HTTP server
│   ├── TextPolisher.swift   # Qwen/OpenAI/Anthropic LLM polish
│   ├── TextInserter.swift   # AX API + Clipboard+CmdV 文字輸出
│   └── Vocabulary/
│       └── VocabularyStore.swift  # 個人詞庫 + 香港內建詞庫
├── UI/
│   ├── MenuBarController.swift    # Menu Bar 主控制器
│   ├── HotkeyManager.swift        # Fn/F15 全局熱鍵
│   ├── PushToTalkManager.swift    # 按住說話邏輯
│   └── Overlay/
│       ├── OverlayManager.swift
│       ├── RecordingOverlayPanel.swift  # 錄音中浮動面板
│       └── WaveformView.swift
└── Utils/
    ├── ClipboardGuard.swift       # 剪貼板保護（paste 後還原）
    ├── NotificationManager.swift
    └── TelemetryLogger.swift      # 延遲數據記錄 (.out/telemetry.jsonl)
Resources/
└── Info.plist               # CFBundleShortVersionString（升版本必改）
```

---

## 重要架構：STT Pipeline 主流程

`STTPipeline.stopAndProcess()` 的執行順序：

```
1. isFrontmostAppTerminal()    ← 錄音釋放時立即偵測，之後 focus 可能轉移
2. FastIME raw paste            ← 若 fastIME=true AND autoPaste=true AND !isTerminal
3. Whisper/FunASR STT          ← 4-5s (Whisper) / ~300ms (FunASR)
4. Qwen/LLM polish             ← ~1-2s（若有 API key）
5. FastIME replace / insert    ← 見下方邏輯
6. 寫 telemetry log
```

**FastIME 插入邏輯（v0.2.3 修復後）**：
```swift
if config.autoPaste && config.autoReplace && rawAutoPasted {
    // 普通 app：undo raw → paste polished
} else if config.autoPaste && isTerminal {
    // Terminal：raw 被跳過，直接 paste polished（不需要 autoReplace）
}

if !config.fastIME {
    // 非 FastIME 模式：直接 paste finalText
}
```

---

## Config 預設值（AppConfig.swift）

| 參數 | 預設 | CLI flag |
|------|------|----------|
| `fastIME` | `true` | `--fast-ime` / `--no-fast-ime` |
| `autoPaste` | `true` | `--auto-paste` / `--no-auto-paste` |
| `autoReplace` | `false` | `--auto-replace` / `--no-auto-replace` |
| `sttBackend` | `.whisper` | `--stt-backend whisper\|funasr` |
| `sttProfile` | `.fast` | `--stt-profile fast\|balanced\|accurate` |
| `polishProvider` | `.auto` | `--polish-provider auto\|qwen\|openai\|anthropic\|none` |
| `triggerKey` | `"auto"` | `--trigger-key fn\|f12\|f13\|f14\|f15` |
| `showOverlay` | `true` | `--no-overlay` |
| `useVocabulary` | `true` | `--no-vocabulary` |
| `useMetalGPU` | `true` | `--no-metal` |

---

## LLM Polish 設定

**Provider 優先順序（auto 模式）**：Qwen > OpenAI > Anthropic

**環境變量**：
- `QWEN_API_KEY` — DashScope API key
- `QWEN_MODEL` — 預設 `qwen3.5-plus`（**thinking 已禁用**，否則 ~100s）
- `OPENAI_API_KEY` / `OPENAI_MODEL`（預設 `gpt-4o-mini`）
- `ANTHROPIC_API_KEY` / `ANTHROPIC_MODEL`（預設 `claude-sonnet-4-5-20250929`）

**注意**：Qwen `enable_thinking: false` 是必要的，thinking mode 約 100 秒，不適合 STT。

---

## Whisper 模型路徑

```
third_party/whisper.cpp/build/bin/whisper-cli
third_party/whisper.cpp/models/ggml-large-v3-turbo.bin  ← fast profile 首選
third_party/whisper.cpp/models/ggml-large-v3.bin         ← balanced/accurate 首選
third_party/whisper.cpp/models/ggml-small.bin            ← fallback
```

---

## Terminal 偵測清單（TextInserter.swift）

以下 bundle ID 被視為 terminal，**跳過 raw paste**（防止 newline 執行命令）：
```
com.apple.Terminal, com.googlecode.iterm2, dev.warp.desktop,
net.kovidgoyal.kitty, com.microsoft.VSCode, io.alacritty, co.zeit.hyper
```

---

## 升版本 Checklist

升版本號**必須同時修改兩個地方**：
1. `Sources/CantoFlowApp/AppVersion.swift` — `appShortVersion`
2. `Resources/Info.plist` — `CFBundleShortVersionString`

原因：SPM plain-executable build 中 `Bundle.main.infoDictionary` 讀不到 `Info.plist`（沒有 .app bundle），所以 MenuBar 從 `AppVersion.swift` 常量讀取版本。

---

## 已知臭蟲與修法

### [FIXED v0.2.3] Terminal 不上字
**症狀**：STT 正常（`.out/` 有 raw file），但文字不出現在 Terminal 視窗
**根因**：`STTPipeline.swift` 的 terminal paste 路徑被困在
`if config.autoPaste && config.autoReplace`（`autoReplace` 預設 `false`），永遠不執行
**修法**：把 terminal paste 抽出為獨立 `else if`，只需 `autoPaste`，不需 `autoReplace`
**位置**：`STTPipeline.swift` `stopAndProcess()` 的 fastIME replace 段

### [FIXED v0.2.3] Menu Bar 版本號永遠顯示 1.0.0
**症狀**：Menu 底部顯示硬編碼 fallback 值 `Version 1.0.0 (1)`
**根因**：SPM build 的 executable 沒有 `.app` bundle，`Bundle.main.infoDictionary` 為 nil
**修法**：新增 `AppVersion.swift` 常量，`MenuBarController.swift` 改用常量代替 Bundle 讀取

### [FIXED v0.2.2] Terminal 雙重輸出 / Cmd+Z 問題
**症狀**：Terminal 中 Cmd+Z 不能 undo 文字，且 pasted newline 會執行 shell 命令
**修法**：`TextInserter.isFrontmostAppTerminal()` 偵測 terminal bundle ID，跳過 FastIME raw paste

---

## Permissions Required（首次運行需授權）
- Microphone — 錄音
- Accessibility — 熱鍵偵測 + 文字插入
- Input Monitoring — Fn/F15 按鍵偵測
