# CantoFlow — Thread Handoff

_Date: 2026-03-19_

---

## 事故摘要

**2026-03-18 18:06** — JTDev 外置硬碟在 CantoFlow 運行期間被強制卸載（force unmount）。CantoFlow binary 本身在 JTDev 上，kernel 讀取記憶體映射頁面失敗，觸發 **SIGBUS**，進程 PID 80401 被殺死。

Crash report：
```
/Users/johnsontam/Library/Logs/DiagnosticReports/cantoflow-2026-03-18-180653.ips
ktriageinfo: "Object has no pager because the backing vnode was force unmounted"
```

重啟後出現兩個連鎖問題，共修了三個 bug。

---

## Bug 1 — STT 完全失效（exit 6 / Metal GPU crash）

### 症狀
每次錄音後 menu bar 顯示：
```
Error: STT failed: Transcription failed (exit 6):
WARNING: Using native backtrace. Set GGML_BACKTRACE_LLDB...
```
`.out/` 有 WAV 錄音，但無對應 `raw_*.txt`，telemetry 無條目。

### 根本原因
硬碟強制斷線時，whisper-cli 子進程（正在使用 Metal GPU）被強殺，Metal GPU 指令佇列未能正常清理。之後每次 CantoFlow 啟動 whisper-cli 子進程，ggml Metal 初始化時 SIGABRT（exit 6）。

從 terminal 直接執行 whisper-cli 正常，因為 shell session 與 app 的 Metal context 有別。

### 修復
**File**: `app/Sources/CantoFlowApp/Core/WhisperRunner.swift`

在 `transcribe()` 加入 Metal crash fallback：
```swift
} catch WhisperError.transcriptionFailed(let code, _) where code == 6 && metalEnabled {
    // Exit 6 = SIGABRT inside ggml — Metal GPU crash
    WhisperRunner._metalSupported = false  // 此後用 CPU
    runResult = try await runWhisper(..., metalEnabled: false)
}
```
- Metal crash 時靜默切換 CPU 重試
- 同時失效 Metal cache，本次進程後續錄音均用 CPU
- 重啟 app 後會重新嘗試 Metal（自動恢復）

---

## Bug 2 — 識別完全亂碼（Prompt 包含壞例子）

### 症狀
STT 恢復後，識別輸出：`"TACSI TACSI CRCR、上不上頭"`（完全亂碼）

### 根本原因
`VocabularyStore.generateWhisperPrompt()` 的 prompt 包含：
```
例如「測試」絕對不要寫成「Thick see」
```
Whisper 的 initial_prompt 直接影響輸出分佈。Prompt 入面有 `Thick see` 呢個英文音譯例子，whisper 反而**學到**可以用英文音譯拼音輸出，說「測試測試」變成 `TACSI TACSI`。

此 bug 在硬碟斷線前已存在，但被 Metal crash 掩蓋，今次才發現。

### 修復
**File**: `app/Sources/CantoFlowApp/Core/Vocabulary/VocabularyStore.swift`

```swift
// 修改前
var prompt = "這是一段香港廣東話錄音，請直接輸出繁體中文字，絕對不要輸出任何英文音譯拼音，例如「測試」絕對不要寫成「Thick see」。"

// 修改後
var prompt = "以下係廣東話句子，必須以繁體中文輸出。"
```

---

## Bug 3 — Menu Bar 無法分辨 GPU / CPU 模式

### 症狀
Menu Bar 只顯示 `上次: 17字 · STT 4.6s · 共 6.4s`，無法得知當次用 Metal GPU 定 CPU fallback。

### 修復
三個文件修改：

**`STTPipeline.swift`** — `PipelineResult` 加 `metalEnabled: Bool` 欄位：
```swift
struct PipelineResult {
    ...
    let metalEnabled: Bool
}
```

**`STTPipeline.swift`** — `stopAndProcess()` 傳入值：
```swift
metalEnabled: sttResult.sttBreakdown?.metalEnabled ?? false
```

**`MenuBarController.swift`** — `updateTelemetryItem()` 顯示標籤：
```swift
let accel = result.metalEnabled ? "GPU" : "CPU"
let title = "上次: \(chars)字 · STT \(sttSec)s [\(accel)]\(polishLabel) · 共 \(totalSec)s"
```

效果：
```
上次: 17字 · STT 4.6s [GPU] · LLM 1.8s · 共 6.4s   ← 正常
上次: 17字 · STT 28.3s [CPU] · LLM 1.8s · 共 30.1s  ← Metal fallback 中
```

---

## 現時狀態（2026-03-19 早上）

| 項目 | 狀態 |
|------|------|
| CantoFlow 進程 | 運行中（每次啟動用 `cantoflow`） |
| Metal GPU | ✅ 正常（最後一次確認 GPU，4.6s） |
| STT 識別質量 | ✅ 正常（「試測試，收唔收到？1234」準確識別） |
| LLM Polish | ✅ Qwen（`QWEN_API_KEY` 已設定） |
| 事故來源 volume | JTDev（歷史事件；目前已不再作為運行路徑） |
| Binary 位置 | `/Volumes/JT2TB/CantoFlow/app/.build/release/cantoflow` |
| 啟動指令 | `cantoflow`（symlink → `app/scripts/run.sh`） |

---

## 已知風險

**Repo 如再次整體搬位** — `app` 與 `third_party/whisper.cpp` 的 build cache 可能殘留舊路徑，導致 Swift module cache 或 `whisper-cli` rpath 失效。現已在 launcher / install script 加入自動修復，但如有異常，優先重建 release binary 與 `whisper.cpp`。

---

## 本 Session 修改文件

| 文件 | 改動 |
|------|------|
| `app/Sources/CantoFlowApp/Core/WhisperRunner.swift` | Metal crash (exit 6) → 自動 CPU fallback + cache 失效 |
| `app/Sources/CantoFlowApp/Core/Vocabulary/VocabularyStore.swift` | 移除 prompt 中的壞例子 `Thick see` |
| `app/Sources/CantoFlowApp/Core/STTPipeline.swift` | `PipelineResult` 加 `metalEnabled`；model fallback 尊重 CPU state |
| `app/Sources/CantoFlowApp/UI/MenuBarController.swift` | Menu bar 顯示 `[GPU]` / `[CPU]` 標籤 |
