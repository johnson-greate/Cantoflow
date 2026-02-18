# CantoFlow_c — Claude 開發筆記

## 專案概況
- macOS Menu Bar app，語音轉繁體中文（Cantonese STT）
- 使用 **Swift Package Manager**（`swift build`），非 Xcode project
- Binary: `.build/debug/cantoflow`

## Build & Run
```bash
cd /Users/johnson_tam/Documents/CantoFlow/CantoFlow_c
swift build
# 重啟 app（先 Quit 舊的再啟動新 binary）
```

## 已知臭蟲與修法

### [FIXED v0.2.3] Terminal 不上字
**症狀**：STT 正常（output folder 有 raw file），但文字不出現在 Terminal
**根因**：`STTPipeline.swift` 中 terminal paste 路徑被困在 `config.autoReplace`（預設 `false`）條件裡，永遠不執行
**修法**：`STTPipeline.swift` — terminal paste 只需 `autoPaste=true`，不需要 `autoReplace`
```swift
// 錯誤（舊）
if config.autoPaste && config.autoReplace {
    if rawAutoPasted { ... }
    else if isTerminal { ... }  // 永遠進不來
}

// 正確（新）
if config.autoPaste && config.autoReplace && rawAutoPasted { ... }
else if config.autoPaste && isTerminal { ... }  // 獨立條件
```

### [FIXED v0.2.3] Menu Bar 版本號顯示錯誤（永遠顯示 1.0.0）
**症狀**：Menu 底部顯示 `Version 1.0.0 (1)` 而非實際版本
**根因**：SPM plain-executable build 中 `Bundle.main.infoDictionary` 讀不到 `Info.plist`，永遠使用 fallback 值
**修法**：新增 `AppVersion.swift`，用 Swift 常量代替 Bundle 讀取
```swift
// AppVersion.swift — 升版本時同步更新這裡和 Info.plist
let appShortVersion = "0.2.3"
let appBuildNumber  = "1"
```
**注意**：升版本需同步改 `AppVersion.swift` **和** `Resources/Info.plist`

## 架構重點
- **Text 輸出流程**：`STTPipeline.stopAndProcess()` → `TextInserter`
  - AX API（優先）→ Clipboard + Cmd+V（fallback）
  - Terminal 偵測：`isFrontmostAppTerminal()` — 跳過 raw paste，直接 paste polished text
- **FastIME 模式**（預設 on）：先 paste raw → Qwen polish → undo + paste polished
- **Config 預設值**：`fastIME=true`, `autoPaste=true`, `autoReplace=false`
- **版本常量**：`Sources/CantoFlowApp/AppVersion.swift`
