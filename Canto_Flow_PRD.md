# CantoFlow — Product Requirements Document

> 廣東話智能語音輸入系統

| Field | Value |
|---|---|
| Version | 1.0 |
| Date | 2026-02-16 |
| Author | Johnson Tam |
| Status | Draft |
| Platform | macOS (Apple Silicon) |

---

## 1. Executive Summary

CantoFlow 是一個專為廣東話用戶設計的本地優先、隱私安全的 AI 語音輸入系統。系統運行於 macOS 平台，採用「本地語音識別 + 雲端大模型文字整理」的雙層架構，確保用戶的音頻數據永遠不離開本機。

**Background：** Typeless 等現有語音輸入工具雖然功能強大，但經第三方安全審計（@medmuspg 逆向工程分析）發現存在重大隱私風險：音頻 100% 雲端處理、過度收集用戶數據（URL、App 名稱、剪貼簿內容）、過多 Accessibility 權限要求等。CantoFlow 旨在從架構層面徹底解決這些問題。

**Core Value Proposition：** 語音數據永遠不離開你的電腦。

---

## 2. Problem Statement

| Problem | Impact | Priority |
|---|---|---|
| 現有工具將音頻全部傳送至雲端，存在 keylogger 等級的監控風險 | 密碼、機密信息洩露風險 | P0 - Critical |
| 廣東話口語識別精度不足，常被識別為普通話 | 輸入效率低，需大量手動修正 | P0 - Critical |
| 缺乏廣東話口語轉書面語的智能整理 | 輸出文字不夠專業，可讀性差 | P1 - High |
| 現有工具要求過多系統權限（Accessibility、畫面錄製、鏡頭等） | 用戶信任度低 | P1 - High |

---

## 3. Project Goals

### 3.1 Core Objectives

1. **隱私優先：** 音頻數據永遠不離開本機，僅將轉錄文字傳送至雲端大模型進行整理。
2. **廣東話專屬：** 針對廣東話語音特徵優化，支援口語轉書面語的智能轉換。
3. **無縫體驗：** 像輸入法一樣的操作體驗，識別結果自動貼入當前 Focus 位置。
4. **最小權限：** 僅要求麥克風和 Accessibility 兩個權限，不收集任何額外數據。

### 3.2 Non-Goals (v1.0)

- 不支援 iOS / Android / Windows（僅 macOS）
- 不提供即時翻譯功能
- 不做多人協作功能
- 不做 App Store 上架（個人使用）
- 不做自訂語音模型訓練

---

## 4. System Architecture

### 4.1 Architecture Overview

系統採用三層架構，各層職責清晰分離：

```
┌─────────────────────────────────────────────────┐
│  Layer 1: LOCAL VOICE RECOGNITION (On-Device)   │
│  whisper.cpp / whisper-small-cantonese           │
│  Audio → Raw Cantonese Text                      │
└──────────────────────┬──────────────────────────┘
                       │
              ↓ Text Only (No Audio Leaves Device)
                       │
┌──────────────────────┴──────────────────────────┐
│  Layer 2: CLOUD LLM PROCESSING (Anthropic)      │
│  Claude API via Anthropic SDK                    │
│  Raw Text → Polished Text                        │
└──────────────────────┬──────────────────────────┘
                       │
                  ↓ Polished Text
                       │
┌──────────────────────┴──────────────────────────┐
│  Layer 3: SYSTEM INPUT (macOS Accessibility)     │
│  AXUIElement API + Cmd+V Fallback                │
│  Polished Text → Current Focus Position          │
└─────────────────────────────────────────────────┘
```

### 4.2 Technology Stack

| Layer | Technology | Rationale |
|---|---|---|
| UI / System | Swift + SwiftUI | 原生 macOS 體驗，直接調用 Accessibility API |
| Voice Recognition | whisper.cpp (Core ML) | 本地運行，Apple Silicon 優化，無需 Python 環境 |
| Cantonese Model | whisper-small-cantonese | 廣東話專屬 fine-tune，推理速度 0.055s/sample |
| LLM Processing | Anthropic Claude API | 文字整理、糾錯、口語轉書面語 |
| Text Insertion | AXUIElement + NSPasteboard | 雙策略：AX API 優先，Cmd+V Fallback |
| Hotkey | Carbon HotKey / MASShortcut | 全局快捷鍵觸發錄音 |
| Audio Capture | AVAudioEngine | macOS 原生音頻捕獲 |

### 4.3 Data Flow

| Step | Action | Data | Location |
|---|---|---|---|
| 1 | 用戶按下快捷鍵開始說話 | Audio stream | ✅ Local |
| 2 | AVAudioEngine 捕獲音頻 | PCM audio buffer | ✅ Local |
| 3 | whisper.cpp 轉錄為文字 | Raw Cantonese text | ✅ Local |
| 4 | 音頻 Buffer 立即銷毀 | (已刪除) | ✅ Local |
| 5 | 文字傳送至 Anthropic API | Text only (HTTPS) | ☁️ Cloud |
| 6 | Claude 整理文字並回傳 | Polished text | ☁️ → Local |
| 7 | 透過 AX API 或 Cmd+V 貼入 | Final text | ✅ Local |

**關鍵安全邊界：** Step 4 與 Step 5 之間。音頻在 Step 4 已銷毀，Step 5 僅傳送文字。

---

## 5. Functional Requirements

### 5.1 FR-01: Voice Capture

| Item | Description |
|---|---|
| Trigger | 全局快捷鍵（預設 Cmd+Shift+Space）開始/停止錄音 |
| Audio Format | 16kHz, 16-bit, mono PCM |
| Feedback | 錄音時在 Menu Bar 顯示動畫指示器 |
| Max Duration | 單次錄音上限 5 分鐘（可配置） |
| Silence Detection | 靜音超過 3 秒自動停止（可配置） |

### 5.2 FR-02: Local Speech-to-Text

| Item | Description |
|---|---|
| Engine | whisper.cpp with Core ML acceleration |
| Model | whisper-small-cantonese（預設），可切換至 large |
| Language | 廣東話（yue）為主，支援自動偵測語言 |
| Output | 繁體中文粗轉錄文字 |
| Performance Target | 延遲 < 1 秒（M1/M2 MacBook） |
| Offline Mode | 完全離線可用，不需任何網絡連接 |

**Model Options：**

| Model | Size | CER | Speed | Use Case |
|---|---|---|---|---|
| alvanlii/whisper-small-cantonese | ~244M | ~8% | 0.055s/sample (Flash Attn) | MVP 首選，輕量快速 |
| simonl0909/whisper-large-v2-cantonese | ~1.5G | 7.65% | 0.714s/sample | 精度優先 |
| openai/whisper-large-v3 (yue) | ~1.5G | ~8% WER | Medium | 原版大模型 |
| Large + Small Speculative Decoding | ~1.75G | 7.67% | 0.137s/sample | 精度+速度平衡 |

### 5.3 FR-03: LLM Text Processing

| Item | Description |
|---|---|
| Provider | Anthropic Claude API (via SDK) |
| Model | claude-sonnet-4-5-20250929（建議）或用戶自選 |
| Processing Tasks | 口語轉書面語、去除口頭禪、修正錯字、整理句式結構 |
| System Prompt | 可自定義，預設包含廣東話特定規則（見 Section 7） |
| Fallback | 網絡不可用時直接輸出 Whisper 粗轉錄文字 |
| API Key | 用戶自行提供，儲存於 macOS Keychain |
| Streaming | 支援 streaming response，減少感知延遲 |

### 5.4 FR-04: Text Insertion

| Item | Description |
|---|---|
| Primary Method | macOS Accessibility API (AXUIElementSetAttributeValue + kAXSelectedTextAttribute) |
| Fallback Method | 模擬 Cmd+V 貼上（先儲存再還原剪貼簿） |
| Target | 當前 Focus 的任何文字輸入欄位 |
| Supported Apps | 原生 macOS App、Electron App、瀏覽器輸入欄 |
| Clipboard Protection | Fallback 模式下自動保存及還原剪貼簿原有內容 |

**Insertion Strategy：**

```
嘗試 AXUIElementSetAttributeValue
    ├── 成功 → 完成
    └── 失敗 → 保存剪貼簿 → 複製文字 → 模擬 Cmd+V → 還原剪貼簿
```

### 5.5 FR-05: User Interface

| Item | Description |
|---|---|
| App Type | macOS Menu Bar App（無 Dock 圖示） |
| Main UI | Menu Bar 下拉菜單 + 一個小型狀態視窗 |
| Recording Indicator | Menu Bar 圖示變色 + 微小動畫 |
| History Panel | 本地儲存最近 50 條轉錄記錄（可配置） |
| Settings | 快捷鍵、模型選擇、API Key、System Prompt 自定義 |

---

## 6. Security Architecture

### 6.1 Security Comparison: Typeless vs CantoFlow

| Security Dimension | Typeless | CantoFlow |
|---|---|---|
| 音頻處理 | 100% 雲端（AWS Ohio） | 100% 本地（whisper.cpp） |
| 傳送至雲端的數據 | 音頻 + URL + App 名 + 更多 | 僅轉錄文字 |
| 權限要求 | Accessibility + 畫面錄製 + 鏡頭 + Bluetooth + 更多 | 僅 Accessibility + 麥克風 |
| 本地資料儲存 | SQLite 明文儲存 URL、App 名等 | 僅儲存轉錄歷史（可加密） |
| API Key 儲存 | 不明確 | macOS Keychain（系統級加密） |
| 公司透明度 | WHOIS 非公開，無法人名稱 | 個人項目，完全自控 |
| Keylogger 風險 | 有疑慮（過多權限） | 無（不監控鍵盤輸入） |
| 離線可用性 | 不可用（音頻需雲端處理） | 語音識別可離線，LLM 整理需網絡 |

### 6.2 Security Principles

1. **Principle of Least Privilege：** 僅要求必要的最少權限（麥克風 + Accessibility）。
2. **Audio Never Leaves：** 音頻數據永遠不傳送至任何外部伺服器，處理完畢後立即從記憶體中銷毀。
3. **No Data Collection：** 不收集 URL、App 名稱、剪貼簿內容、鍵盤輸入等任何額外數據。
4. **Transparent Architecture：** 用戶可完全審查源碼，了解每一位數據的去向。
5. **Secure Key Storage：** API Key 儲存於 macOS Keychain，不以明文形式存在於任何檔案中。

### 6.3 Permissions Matrix

| Permission | Required | Purpose |
|---|---|---|
| 麥克風 | ✅ Yes | 捕獲用戶語音 |
| Accessibility | ✅ Yes | 向當前 Focus App 插入文字 |
| 網絡 | ✅ Yes | 調用 Anthropic API（僅傳送文字） |
| 畫面錄製 | ❌ No | — |
| 鏡頭 | ❌ No | — |
| Bluetooth | ❌ No | — |
| 位置 | ❌ No | — |
| 通訊錄 | ❌ No | — |

---

## 7. LLM Prompt Design

CantoFlow 的核心競爭力之一在於其 System Prompt 設計。

### 7.1 Default System Prompt

```
你是一個廣東話語音輸入助手。你會收到一段由語音識別系統轉錄的廣東話粗文字，你的任務是：

1. 保持用戶的原意，不要過度改寫
2. 修正語音識別的錯字（根據上下文推斷正確用詞）
3. 去除口頭禪（即係、其實、呀、嗯、嗱咁等）
4. 將廣東話口語轉換為適當的書面語（但保留廣東話特有表達）
5. 整理句式結構，加上適當標點符號
6. 僅輸出整理後的文字，不要加任何解釋或前綴

重要規則：
- 如果用戶中途改口，只保留最終意圖
- 如果語音識別明顯錯誤，根據上下文推斷正確詞語
- 保持段落結構，不要將所有內容合併為一段
- 如果用戶明顯在口述代碼或技術術語，保持原樣不修改
```

### 7.2 Prompt Customization

用戶可在 Settings 中自定義 System Prompt，例如：

- **純轉錄模式：** 僅修正錯字，不做口語轉書面語
- **正式書面模式：** 將所有口語轉為標準書面中文
- **中英混合模式：** 保留 code-switching 的英文詞彙
- **特定領域模式：** 加入醫療、法律、金融等專業術語庫

---

## 8. Development Phases

| Phase | Milestone | Deliverables | Est. Duration |
|---|---|---|---|
| Phase 0 | Environment Setup | Xcode project、whisper.cpp 編譯、Anthropic SDK 整合 | 1 週 |
| Phase 1 | Core Pipeline MVP | 麥克風錄音 → Whisper 轉錄 → Console 輸出 | 1-2 週 |
| Phase 2 | LLM Integration | Anthropic API 調用、System Prompt 設計、Fallback 機制 | 1 週 |
| Phase 3 | Text Insertion | AX API 插入 + Cmd+V Fallback + 剪貼簿保護 | 1-2 週 |
| Phase 4 | UI & UX | Menu Bar App、狀態指示、設定介面、歷史記錄 | 1-2 週 |
| Phase 5 | Polish & Hardening | 錯誤處理、Edge cases、性能優化、Keychain 儲存 | 1 週 |

**Total Estimated：** 6-9 週

### Phase Gate Criteria

每個 Phase 結束時需滿足以下條件才能進入下一階段：

- **Phase 0 → 1：** whisper.cpp 能在本機成功載入廣東話模型並運行
- **Phase 1 → 2：** 能透過麥克風錄音並在 Console 看到廣東話轉錄結果
- **Phase 2 → 3：** Claude API 能成功將粗轉錄整理為可讀文字
- **Phase 3 → 4：** 整理後的文字能自動插入至少 3 個不同 App（如 Notes、Safari、VS Code）
- **Phase 4 → 5：** Menu Bar App 能完成完整的 end-to-end 流程

---

## 9. Technical Risks & Mitigations

| Risk | Severity | Likelihood | Mitigation |
|---|---|---|---|
| Whisper 廣東話識別精度不足（特別是促音、俗語） | High | Medium | 用 large 模型 + Speculative Decoding；利用 LLM 層糾錯 |
| AX API 在部分 App 不生效（如 Electron） | Medium | High | Fallback 到 Cmd+V 模擬貼上 |
| Anthropic API 延遲影響用戶體驗 | Medium | Medium | Streaming response；顯示粗轉錄後漸進替換 |
| 網絡不可用時無法使用 LLM | Low | Low | Graceful fallback 到 Whisper 粗轉錄輸出 |
| whisper.cpp 在舊機型上性能不足 | Low | Low | 提供模型大小選擇（tiny/small/medium） |
| 廣東話+英文 code-switching 識別困難 | Medium | Medium | System Prompt 指引 LLM 保留英文詞彙；考慮 initial_prompt 引導 |

---

## 10. Success Criteria

| Metric | Target | Measurement |
|---|---|---|
| 端到端延遲 | < 3 秒（包含 LLM 處理） | Whisper < 1s + API < 2s |
| 廣東話識別精度 | CER < 10%（日常對話） | 每月抽樣測試 |
| LLM 整理滿意度 | 用戶不需手動修改的比例 > 80% | 主觀評估 |
| 權限要求 | 僅 2 個（麥克風 + Accessibility） | 系統檢查 |
| 音頻數據外洩 | 0 bytes 音頻傳送至外部 | 網絡監控驗證 |
| 離線可用性 | Whisper 轉錄可離線運行 | 斷網測試 |

---

## 11. Project Structure (Suggested)

```
CantonFlow/
├── CantonFlow.xcodeproj
├── CantonFlow/
│   ├── App/
│   │   ├── CantonFlowApp.swift          # App entry point (Menu Bar)
│   │   └── AppDelegate.swift            # Lifecycle management
│   ├── Core/
│   │   ├── AudioCapture/
│   │   │   ├── AudioEngine.swift        # AVAudioEngine wrapper
│   │   │   └── SilenceDetector.swift    # VAD logic
│   │   ├── Whisper/
│   │   │   ├── WhisperEngine.swift      # whisper.cpp Swift bridge
│   │   │   └── ModelManager.swift       # Model loading & switching
│   │   ├── LLM/
│   │   │   ├── AnthropicClient.swift    # Anthropic SDK wrapper
│   │   │   ├── PromptManager.swift      # System prompt management
│   │   │   └── StreamHandler.swift      # Streaming response handler
│   │   └── TextInsertion/
│   │       ├── AccessibilityInserter.swift  # AX API method
│   │       ├── PasteInserter.swift          # Cmd+V fallback
│   │       └── ClipboardGuard.swift         # Clipboard save/restore
│   ├── UI/
│   │   ├── MenuBarView.swift            # Menu bar dropdown
│   │   ├── StatusIndicator.swift        # Recording animation
│   │   ├── HistoryView.swift            # Transcription history
│   │   └── SettingsView.swift           # Preferences panel
│   ├── Services/
│   │   ├── HotkeyManager.swift          # Global hotkey registration
│   │   ├── KeychainManager.swift        # Secure API key storage
│   │   └── HistoryStore.swift           # Local history persistence
│   └── Resources/
│       └── Models/                      # whisper.cpp model files
├── Libraries/
│   └── whisper.cpp/                     # whisper.cpp as submodule
└── README.md
```

---

## 12. Appendix

### 12.1 Cantonese-Specific Whisper Notes

- **Language Code：** Whisper large-v3 引入獨立的廣東話代碼 `yue`，舊版本使用 `zh`
- **繁簡體：** 可用 `initial_prompt` 引導輸出繁體中文，例如 `"以下是廣東話的句子。"`
- **口語 vs 書面語：** Whisper 有時會將廣東話口語「翻譯」為標準普通話書面語，需要在 LLM 層處理
- **Speculative Decoding：** 用 small 模型做 assistant，large 模型做 main，速度提升 5x，精度基本不變

### 12.2 Key References

- Whisper Cantonese Discussion: `github.com/openai/whisper/discussions/25`
- whisper.cpp Project: `github.com/ggerganov/whisper.cpp`
- whisper-small-cantonese: `huggingface.co/alvanlii/whisper-small-cantonese`
- macOS AX Text Insertion: `levelup.gitconnected.com/swift-macos-insert-text-to-other-active-applications`
- Typeless Security Analysis: `x.com/medmuspg/status/2021198792524169650`
- Anthropic SDK Documentation: `docs.anthropic.com`

### 12.3 Glossary

| Term | Definition |
|---|---|
| CER | Character Error Rate，字元錯誤率 |
| WER | Word Error Rate，詞語錯誤率 |
| STT | Speech-to-Text，語音轉文字 |
| AX API | macOS Accessibility API，用於跨 App 操作 |
| Core ML | Apple 的機器學習框架，可加速本地推理 |
| Speculative Decoding | 用小模型加速大模型推理的技術 |
| Keychain | macOS 系統級密碼管理器 |
| VAD | Voice Activity Detection，語音活動檢測 |
| code-switching | 對話中交替使用兩種語言（如廣東話夾英文） |

---

*End of Document*
