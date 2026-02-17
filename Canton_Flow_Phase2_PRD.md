# Canton Flow — Phase 2 PRD

> LLM Integration, Vocabulary System & Push-to-Talk

| Field | Value |
|---|---|
| Version | 1.0 |
| Date | 2026-02-17 |
| Phase | 2 of 5 |
| Depends on | Phase 1 Complete (Mic → Whisper → Console output) |
| Status | Draft |

---

## 1. Phase 2 Overview

Phase 2 包含三個並行的工作流：

| ID | Feature | Description |
|---|---|---|
| P2-A | Vocabulary System | 個人詞庫 + 香港常用詞庫，提升 Whisper 識別精度及 LLM 糾錯能力 |
| P2-B | LLM Integration | 接入 Anthropic Claude API，將粗轉錄整理為可用文字 |
| P2-C | Push-to-Talk | 按住 Fn（或 F15）錄音，放開停止 |

**建議開發順序：** P2-C → P2-B → P2-A（先改善錄音體驗，再接 LLM，最後加詞庫提升精度）

---

## 2. P2-A: Vocabulary System

### 2.1 概述

Vocabulary System 分為兩個獨立的詞庫，共同服務於兩個目標：

1. **引導 Whisper：** 透過 `initial_prompt` 將詞庫注入 Whisper，提升識別精度
2. **引導 LLM：** 將詞庫附加到 Claude 的 System Prompt，讓 LLM 在整理時優先使用正確用詞

### 2.2 Personal Vocabulary（個人詞庫）

用戶在 Settings UI 中自行輸入和管理的詞庫。

| Item | Description |
|---|---|
| Purpose | 收錄用戶個人常用的專有名詞、人名、公司名、技術術語等 |
| UI Location | Settings → Personal Vocabulary |
| Input Method | 文字輸入框，每行一個詞條，支援「詞條 + 備註」格式 |
| Storage | 本地 JSON 檔（`~/Library/Application Support/CantonFlow/personal_vocab.json`） |
| Capacity | 上限 500 條（避免 prompt 過長） |
| Operations | 新增、編輯、刪除、搜索、匯入/匯出 CSV |

**詞條格式：**

```json
{
  "entries": [
    {
      "term": "Anthropic",
      "pronunciation_hint": "安佐匹克",
      "category": "company",
      "notes": "AI 公司"
    },
    {
      "term": "Claude",
      "pronunciation_hint": "克勞德",
      "category": "product",
      "notes": ""
    }
  ]
}
```

**UI Wireframe（Settings → Personal Vocabulary）：**

```
┌─────────────────────────────────────────────┐
│  Personal Vocabulary                    [+]  │
├─────────────────────────────────────────────┤
│  🔍 Search...                                │
├──────────────────┬──────────┬───────────────┤
│  Term            │ Category │ Hint          │
├──────────────────┼──────────┼───────────────┤
│  Anthropic       │ Company  │ 安佐匹克       │
│  Claude          │ Product  │ 克勞德         │
│  whisper.cpp     │ Tech     │               │
│  黃大仙          │ Place    │               │
├──────────────────┴──────────┴───────────────┤
│  [Import CSV]  [Export CSV]    500 max       │
└─────────────────────────────────────────────┘
```

### 2.3 Hong Kong Common Vocabulary（香港常用詞庫）

系統內建的香港地名、人名及常用口語詞庫。隨 App 附帶，用戶可開關但不可編輯。

| Item | Description |
|---|---|
| Purpose | 涵蓋 Whisper 常見錯誤的香港專有詞彙 |
| Maintenance | 由開發者維護，隨 App 更新 |
| Storage | App bundle 內的 JSON 檔案（唯讀） |
| Toggle | Settings 中可獨立開關此詞庫 |
| Categories | 地名、人名、口語/俗語、食物、交通 |

**詞庫分類及範例：**

| Category | Examples | Est. Count |
|---|---|---|
| 地名 — 港鐵站 | 鰂魚涌、筲箕灣、荔景、太子、尖沙咀、旺角、深水埗、觀塘、彩虹、調景嶺 | ~100 |
| 地名 — 地區 | 西環、北角、鰂魚涌、石硤尾、黃大仙、慈雲山、秀茂坪、將軍澳、天水圍、元朗 | ~80 |
| 地名 — 地標 | 維多利亞港、太平山頂、金紫荊廣場、獅子山、大澳、赤柱 | ~50 |
| 人名 — 常見姓氏 | 陳、黃、李、張、梁、王、劉、林、吳、鄭 | ~30 |
| 口語 / 俗語 | 搞掂、得閒、收皮、嬲、攰、唔該、冇問題、揸主意、傾偈、食嘢 | ~150 |
| 食物 | 菠蘿油、奶茶、叉燒飯、腸粉、燒賣、魚蛋、雞蛋仔、碗仔翅 | ~80 |
| 交通 | 小巴、巴士、的士、天星小輪、山頂纜車、港鐵、東鐵線、屯馬線 | ~40 |
| **Total** | | **~530** |

### 2.4 Vocabulary Integration Points

詞庫在 pipeline 中有兩個注入點：

```
                  ┌───────────────┐
                  │  Vocab Lists  │
                  │  (Personal +  │
                  │   HK Common)  │
                  └──────┬────────┘
                         │
            ┌────────────┼────────────┐
            ▼                         ▼
   ┌─────────────────┐     ┌──────────────────┐
   │  Injection #1   │     │  Injection #2    │
   │  Whisper         │     │  Claude API      │
   │  initial_prompt  │     │  System Prompt   │
   └─────────────────┘     └──────────────────┘
```

**Injection #1 — Whisper `initial_prompt`：**

Whisper 支援 `initial_prompt` 參數，可以引導模型優先識別特定詞彙。將詞庫中的 `term` 串聯成一段文字注入。

```
// Pseudocode
let vocabTerms = personalVocab.terms + hkCommonVocab.terms
let prompt = "以下是廣東話的句子。" + vocabTerms.joined(separator: "、")
whisper.transcribe(audio, language: "yue", initial_prompt: prompt)
```

**注意事項：**
- Whisper `initial_prompt` 有長度限制（~224 tokens），需要做截斷
- 優先注入 Personal Vocabulary（用戶自己嘅詞最重要）
- 截斷策略：Personal 全部 → HK Common 按 category 優先級填充

**Injection #2 — Claude System Prompt：**

將詞庫作為參考附加到 System Prompt 尾部。

```
// Appended to default system prompt
---
以下是用戶的個人詞庫，請在整理文字時優先使用這些正確用詞：
Anthropic（AI 公司）、Claude（AI 產品）、whisper.cpp（語音識別引擎）...

以下是香港常用詞彙，如果語音識別結果中出現近似詞，請替換為正確寫法：
鰂魚涌、筲箕灣、深水埗、觀塘...
```

---

## 3. P2-B: LLM Integration

### 3.1 Anthropic API Integration

| Item | Description |
|---|---|
| SDK | Anthropic Swift SDK（如果可用）或直接 HTTP 調用 |
| Model | claude-sonnet-4-5-20250929（預設），可在 Settings 切換 |
| API Key | 用戶自行輸入，儲存於 macOS Keychain |
| Endpoint | `https://api.anthropic.com/v1/messages` |
| Streaming | 啟用 streaming，減少感知延遲 |
| Timeout | 10 秒 timeout，超時走 fallback |

### 3.2 Request Structure

每次請求的結構：

```json
{
  "model": "claude-sonnet-4-5-20250929",
  "max_tokens": 4096,
  "stream": true,
  "system": "<default_system_prompt + vocab_injection>",
  "messages": [
    {
      "role": "user",
      "content": "<whisper_raw_transcription>"
    }
  ]
}
```

### 3.3 System Prompt Assembly

System Prompt 由三個部分動態組裝：

```
┌─────────────────────────────────┐
│  Part 1: Base Prompt            │  ← 固定的廣東話整理規則
│  (見 Phase 1 PRD Section 7)     │
├─────────────────────────────────┤
│  Part 2: User Custom Prompt     │  ← 用戶自定義的額外指令（可選）
├─────────────────────────────────┤
│  Part 3: Vocabulary Injection   │  ← 從 Vocab System 動態生成
│  - Personal Vocabulary          │
│  - HK Common Vocabulary         │
└─────────────────────────────────┘
```

### 3.4 Response Handling

| Scenario | Behavior |
|---|---|
| Streaming 成功 | 即時替換 Whisper 粗轉錄文字為 Claude 整理後文字 |
| API 返回錯誤 | 直接使用 Whisper 粗轉錄文字，Menu Bar 顯示警告圖示 |
| 網絡不可用 | 直接使用 Whisper 粗轉錄文字，顯示「離線模式」提示 |
| Timeout (>10s) | 直接使用 Whisper 粗轉錄文字 |
| API Key 未設定 | 直接使用 Whisper 粗轉錄文字，Settings 中提示設定 |

### 3.5 Progressive Output Strategy

用戶體驗上採用漸進式輸出：

```
Timeline:
  0.0s  ← 用戶放開按鍵，錄音停止
  0.3s  ← Whisper 完成轉錄
  0.4s  ← 粗轉錄文字先插入到 Focus 位置（讓用戶立即看到結果）
  0.4s  ← 同時發送 API 請求給 Claude
  1.5s  ← Claude streaming 回傳開始
  2.0s  ← 自動選取已插入的粗轉錄文字，替換為 Claude 整理版本
```

**替換邏輯：**

1. 記錄插入時的文字長度和位置
2. Claude 回傳完成後，用 AX API 選取該範圍的文字
3. 替換為整理後的文字
4. 如果用戶已經手動修改了粗轉錄（光標位置已變），則不替換，改為顯示通知讓用戶自行決定

### 3.6 Cost Estimation

| Usage Pattern | Words/Day | Tokens/Day (est.) | Monthly Cost (Sonnet) |
|---|---|---|---|
| Light（偶爾使用） | ~500 | ~2,000 | < $0.50 |
| Medium（日常工作） | ~3,000 | ~12,000 | < $2.00 |
| Heavy（全日使用） | ~10,000 | ~40,000 | < $6.00 |

---

## 4. P2-C: Push-to-Talk (按住錄音)

### 4.1 Hardware Context

用戶有兩個工作環境，鍵盤配置不同，因此需要支援多種觸發鍵：

| Environment | Machine | Keyboard | Trigger Key | Reason |
|---|---|---|---|---|
| Office | Mac Mini M4 | 外接機械鍵盤（無 Apple Fn 鍵） | **F15**（鍵盤右上角） | 機械鍵盤無 🌐/Fn，F15 係最不常用的實體鍵 |
| Home | MacBook Air M1 | 原裝鍵盤 | **Fn (🌐)** | 內建鍵盤有 Fn 鍵，位置順手 |

**設計含義：**

1. 觸發鍵必須可配置，不能寫死
2. 設定應跟隨機器（每部 Mac 獨立設定），而非 iCloud 同步
3. Fn 和 F-key 的偵測機制不同，需要分別處理

### 4.2 技術可行性分析

| Key | Feasibility | Detection Method | Notes |
|---|---|---|---|
| **Fn (🌐)** | ✅ 可行 | `flagsChanged` + `.function` modifier flag | MacBook 內建鍵盤；需注意系統預設的 Emoji/Input Source 切換行為 |
| **F15** | ✅ 可行 | `CGEvent` tap 或 `addGlobalMonitorForEvents` 偵測 keyCode `113` 的 keyDown/keyUp | 外接機械鍵盤；F15 幾乎無系統預設行為，衝突風險極低 |
| **Right Option** | ✅ 備選 | `flagsChanged` + `.option` + keyCode 區分左右 | 通用備選方案 |

**Fn vs F15 偵測差異：**

| | Fn (🌐) | F15 |
|---|---|---|
| Event Type | `.flagsChanged`（modifier key） | `.keyDown` / `.keyUp`（普通按鍵） |
| 有 keyUp 事件？ | 無直接 keyUp，需透過 modifier flags 變化推斷 | ✅ 有明確 keyDown 和 keyUp |
| keyCode | 無獨立 keyCode（係 modifier flag） | `113` (0x71) |
| 系統衝突 | Emoji picker / Input Source 切換 | 幾乎無衝突 |
| 偵測可靠度 | 中（modifier flag 可能被其他鍵組合干擾） | 高（獨立 keyDown/keyUp 事件） |

**結論：** F15 在技術上反而更乾淨、更可靠。Fn 可行但需額外處理 edge cases。

### 4.3 Key Detection 技術方案

因為 Fn 和 F15 屬於不同類型的按鍵，需要兩套偵測邏輯，統一包裝在 `PushToTalkManager` 中。

**F15 偵測（外接機械鍵盤 — Mac Mini M4）：**

```swift
// F15 有明確的 keyDown / keyUp，偵測最直接可靠
let f15KeyCode: UInt16 = 113

NSEvent.addGlobalMonitorForEvents(matching: [.keyDown, .keyUp]) { event in
    guard event.keyCode == f15KeyCode else { return }
    
    if event.type == .keyDown && !isRecording {
        startRecording()
    } else if event.type == .keyUp && isRecording {
        stopRecordingAndProcess()
    }
}
```

**Fn 偵測（MacBook Air M1 內建鍵盤）：**

```swift
// Fn 是 modifier key，只有 flagsChanged 事件，無獨立 keyDown/keyUp
NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { event in
    let fnPressed = event.modifierFlags.contains(.function)
    
    if fnPressed && !isRecording {
        startRecording()
    } else if !fnPressed && isRecording {
        stopRecordingAndProcess()
    }
}
```

**統一介面設計：**

```swift
// PushToTalkManager 對外只暴露統一介面
protocol TriggerKeyDelegate {
    func triggerKeyDown()   // 開始錄音
    func triggerKeyUp()     // 停止錄音
}

// 內部根據 Settings 中的 triggerKey 設定，選擇對應的偵測邏輯
enum TriggerKeyType {
    case fn                           // modifier-based (.flagsChanged)
    case functionKey(UInt16)          // keyDown/keyUp (F13=105, F14=107, F15=113)
    case modifierKey(NSEvent.ModifierFlags)  // e.g. right option
}
```

**權限要求：**

| Permission | Why |
|---|---|
| Accessibility | `addGlobalMonitorForEvents` 偵測鍵盤事件需要 Accessibility 權限 |
| Input Monitoring (macOS 10.15+) | 全局鍵盤監聽需要 Input Monitoring 權限 |

**注意：** Input Monitoring 是一個額外的權限，之前 PRD 未提及。需在首次啟動時引導用戶授權。這與 Typeless 的過多權限不同——我們只用它來偵測單一觸發鍵，不記錄任何鍵盤輸入內容。

### 4.3 Push-to-Talk 狀態機

```
                    ┌──────────┐
                    │          │
          Key Down  │   IDLE   │
        ┌──────────▶│          │◀──────────┐
        │           └──────────┘           │
        │                                  │
        │ Error                   Pipeline │
        │ (mic fail)              Complete │
        │                                  │
   ┌────┴─────┐  Fn Up    ┌───────────────┤
   │          │──────────▶│               │
   │ RECORDING│           │  PROCESSING   │
   │          │           │               │
   └──────────┘           └───────────────┘
        │                        │
        │  < 0.3s (too short)    │
        └──────────────────────▶ CANCELLED
```

| State | Description | Visual Feedback |
|---|---|---|
| IDLE | 等待用戶按鍵 | Menu Bar 顯示正常圖示 |
| RECORDING | Fn 被按住，正在錄音 | Menu Bar 圖示變紅 + 脈動動畫 |
| PROCESSING | 錄音完成，Whisper + LLM 處理中 | Menu Bar 顯示旋轉載入圖示 |
| CANCELLED | 按住時間太短（<0.3s），視為誤觸 | 短暫顯示取消提示後回到 IDLE |

### 4.4 Detailed Behavior

| Item | Description |
|---|---|
| Trigger (Start) | Fn key down（全局，任何 App 中） |
| Trigger (Stop) | Fn key up |
| Min Duration | < 0.3 秒視為誤觸，不觸發處理 |
| Max Duration | 5 分鐘（可配置），超過自動停止並處理 |
| Audio Feedback | 開始時播放短促提示音（可選，預設關閉） |
| Visual Feedback | Menu Bar 圖示狀態變化 |
| Debounce | 連續快速按放（<0.5s 間隔）只觸發一次 |
| During Processing | 如果 Pipeline 正在處理上一段，新的按鍵錄音排隊等候 |

### 4.5 Recording Overlay UI (Floating Panel)

錄音期間，在螢幕下方居中位置顯示一個半透明的 Floating Panel，讓用戶清晰知道系統正在收音。

**設計參考：** 類似 Typeless 的 Listening UI（見附件圖片）。

**Wireframe：**

```
┌──────────────────────────────────────────────────────┐
│                                                      │
│                                                      │
│               (App content area)                     │
│                                                      │
│                                                      │
│   ┌──────────────────────────────────────────────┐   │
│   │  ✕        Listening...              [✓ Done] │   │
│   │                                              │   │
│   │  ●●● ▎▎▎▎▎▎▎▎▎▎▎▎▎▎▎▎▎▎▎▎▎▎▎▎▎▎▎▎▎▎▎▎ ●●● │   │
│   │            Listening...                      │   │
│   │          MacBook Pro Mic                     │   │
│   │                                              │   │
│   └──────────────────────────────────────────────┘   │
│                                                      │
└──────────────────────────────────────────────────────┘
         ↑ Screen bottom, horizontally centered
```

**Panel 規格：**

| Item | Description |
|---|---|
| Type | NSPanel (floating, non-activating) — 不搶走當前 App 的 focus |
| Position | 螢幕底部居中，距離底部約 80pt |
| Size | 寬 ~480pt，高 ~120pt（按螢幕比例自適應） |
| Background | 深色半透明毛玻璃效果（NSVisualEffectView, `.dark` material） |
| Corner Radius | 16pt |
| Level | `.floating`（置頂，但不阻擋操作） |
| Animation | 出現時從底部滑入 + fade in，消失時滑出 + fade out |

**Panel 元素：**

| Element | Description |
|---|---|
| 取消按鈕（✕） | 左上角，點擊取消錄音，等同於快速放開 Fn（CANCELLED 狀態） |
| 狀態標題 | 居中頂部，顯示當前狀態文字 |
| 音頻波形動畫 | 中間主體區域，實時反映麥克風音量的波形條 |
| 確認按鈕（✓） | 右上角，綠色圓形，點擊立即停止錄音並觸發處理（等同放開 Fn） |
| 音源標示 | 底部小字，顯示當前麥克風名稱（如「MacBook Pro Mic」） |

**狀態變化：**

| State | Title Text | Waveform | Buttons |
|---|---|---|---|
| RECORDING | "Listening..." | 🔵 實時藍色波形動畫 | ✕ Cancel, ✓ Done |
| PROCESSING (Whisper) | "Transcribing..." | ⏸ 波形靜止，變灰 | 無（自動進行） |
| PROCESSING (LLM) | "Polishing..." | ⏸ 旋轉載入指示器 | 無（自動進行） |
| COMPLETE | "Done ✓" | 無 | 無（0.5s 後自動消失） |
| CANCELLED | （Panel 直接消失） | — | — |

**音頻波形動畫規格：**

| Item | Description |
|---|---|
| Style | 垂直條形（bars），約 30-40 條 |
| Color | 藍色（#007AFF），與系統強調色一致 |
| Data Source | AVAudioEngine 的實時音量 level（RMS） |
| Update Rate | 60fps（與螢幕刷新同步） |
| Idle State | 錄音開始前 / 靜音時，波形條降至最低高度（小圓點） |

**關鍵交互邏輯：**

1. **不搶 Focus：** Panel 使用 `NSPanel` + `nonactivatingPanel` style mask，確保不影響當前 App 的焦點（否則 Fn 放開時文字會插入錯誤位置）
2. **滑鼠可穿透：** 除了 ✕ 和 ✓ 按鈕區域，Panel 其餘部分對滑鼠事件透明
3. **多螢幕支援：** Panel 顯示在當前滑鼠所在的螢幕底部
4. **收合模式（可選）：** Settings 中可選擇「Minimal Mode」，僅在 Menu Bar 顯示狀態，不彈出 Overlay

### 4.6 Fn Key Conflict Handling

macOS 對 Fn 鍵有預設行為（Emoji picker、Input Source 切換等），需要處理衝突。

| macOS Setting | Fn Key Behavior | Canton Flow Impact |
|---|---|---|
| "Press 🌐 to: Change Input Source" | Fn 短按切換輸入法 | ⚠️ 衝突 — Canton Flow 的按住行為仍可工作，但短按會觸發系統行為 |
| "Press 🌐 to: Show Emoji & Symbols" | Fn 短按打開 Emoji | ⚠️ 同上 |
| "Press 🌐 to: Do Nothing" | Fn 無預設行為 | ✅ 最佳設定 |

**建議處理方式：**

1. 首次設定時，引導用戶將 Fn 鍵設為「Do Nothing」（System Settings → Keyboard → "Press 🌐 key to"）
2. 提供 Settings 選項讓用戶改用其他按鍵（如 Right Option、F13-F15）
3. 短按 Fn（<0.3s）不觸發錄音，讓系統預設行為正常工作（與 macOS 共存）

---

## 5. Settings UI Updates

Phase 2 需要在 Settings 中新增以下面板：

```
Settings Window
├── General（Phase 1 已有）
│   ├── Launch at Login
│   └── ...
├── Push-to-Talk ← NEW
│   ├── Trigger Key: [Auto-detect ▾] (Fn / F15 / F13 / F14 / Right Option / Custom)
│   │   └── Auto-detect: MacBook → Fn, External keyboard → F15
│   ├── Min Hold Duration: [0.3s]
│   ├── Max Duration: [5 min]
│   ├── Audio Feedback: [Off ▾]
│   ├── Fn Key Setup Guide (link to system settings)
│   ├── Recording Overlay: [Full ▾] (Full / Minimal / Off)
│   └── Show on: [Active Screen ▾] (Active Screen / Primary Screen)
├── Vocabulary ← NEW
│   ├── Tab: Personal Vocabulary
│   │   ├── Vocabulary Table (term, category, hint)
│   │   ├── [Add] [Edit] [Delete] buttons
│   │   ├── [Import CSV] [Export CSV]
│   │   └── Count: xx/500
│   └── Tab: HK Common Vocabulary
│       ├── Toggle: [Enabled ✓]
│       ├── Category toggles (地名, 人名, 口語, 食物, 交通)
│       └── Preview list (read-only)
├── LLM ← NEW
│   ├── API Key: [••••••••] [Show] [Clear]
│   │   └── "Stored in macOS Keychain"
│   ├── Model: [claude-sonnet-4-5-20250929 ▾]
│   ├── Streaming: [Enabled ✓]
│   ├── Progressive Output: [Enabled ✓]
│   │   └── "先顯示粗轉錄，Claude 完成後自動替換"
│   ├── Timeout: [10s]
│   ├── System Prompt:
│   │   ├── [Use Default ✓]
│   │   └── Custom Prompt: [multiline text editor]
│   └── [Test Connection] button
└── Whisper（Phase 1 已有，Phase 2 擴展）
    ├── Model: [whisper-small-cantonese ▾]
    └── Use Vocabulary in initial_prompt: [Enabled ✓] ← NEW
```

---

## 6. File Structure Updates

Phase 2 新增的檔案：

```
CantonFlow/
├── Core/
│   ├── LLM/                          ← NEW
│   │   ├── AnthropicClient.swift     # API 調用、streaming 處理
│   │   ├── PromptAssembler.swift     # System Prompt 動態組裝
│   │   ├── StreamHandler.swift       # SSE streaming 解析
│   │   └── LLMFallback.swift         # 錯誤處理、fallback 邏輯
│   ├── Vocabulary/                    ← NEW
│   │   ├── VocabularyStore.swift     # 詞庫讀寫、管理
│   │   ├── PersonalVocab.swift       # 個人詞庫 CRUD
│   │   ├── HKCommonVocab.swift       # 香港詞庫載入
│   │   └── VocabInjector.swift       # 注入 Whisper prompt + Claude prompt
│   ├── AudioCapture/
│   │   └── PushToTalkManager.swift   ← NEW: Fn key 監聽 + 狀態機
│   └── TextInsertion/
│       └── ProgressiveReplacer.swift ← NEW: 粗轉錄→整理文字替換邏輯
├── UI/
│   ├── Overlay/
│   │   ├── RecordingOverlayPanel.swift   ← NEW: NSPanel floating window
│   │   ├── WaveformView.swift            ← NEW: 實時音頻波形動畫
│   │   └── OverlayStateManager.swift     ← NEW: 狀態驅動 UI 更新
│   ├── Settings/
│   │   ├── PushToTalkSettingsView.swift  ← NEW
│   │   ├── VocabularySettingsView.swift  ← NEW
│   │   ├── LLMSettingsView.swift         ← NEW
│   │   └── VocabEditorView.swift         ← NEW
│   └── StatusIndicator.swift             ← UPDATE: 新增 PROCESSING 狀態
├── Services/
│   └── KeychainManager.swift             ← UPDATE: 新增 API Key 管理
└── Resources/
    └── hk_common_vocab.json              ← NEW: 香港常用詞庫數據
```

---

## 7. Phase Gate Criteria

Phase 2 完成需滿足以下所有條件：

| # | Criteria | Verification |
|---|---|---|
| 1 | 按住 Fn 鍵開始錄音，放開停止，端到端流程完整 | 手動測試 |
| 2 | 誤觸保護：按住 < 0.3 秒不觸發處理 | 手動測試 |
| 3 | 錄音時螢幕底部彈出 Floating Panel，顯示波形動畫，放開後自動消失 | 手動測試 |
| 4 | Overlay Panel 不搶走當前 App 的 focus | 錄音完成後文字插入正確位置 |
| 5 | Whisper 粗轉錄文字先輸出到 Console | Console log 驗證 |
| 4 | Claude API 成功接收粗轉錄並回傳整理後文字 | Console log 驗證 |
| 5 | Fallback 機制：斷網/無 API Key 時仍可使用 Whisper 粗轉錄 | 斷網測試 |
| 6 | API Key 儲存在 Keychain，非明文 | Keychain Access 檢查 |
| 7 | Personal Vocabulary UI 可新增、編輯、刪除詞條 | 手動測試 |
| 8 | HK Common Vocabulary 可載入並在 Settings 中開關 | 手動測試 |
| 9 | 詞庫成功注入 Whisper initial_prompt | Log 驗證 prompt 內容 |
| 10 | 詞庫成功注入 Claude System Prompt | Log 驗證 API 請求 |

---

## 8. Technical Risks (Phase 2 Specific)

| Risk | Severity | Mitigation |
|---|---|---|
| Fn 鍵系統衝突（Emoji picker） | Medium | 引導用戶設定 + 提供備選按鍵 |
| Input Monitoring 權限用戶拒絕 | High | 清晰說明用途，強調「僅偵測觸發鍵，不記錄任何輸入」 |
| Whisper initial_prompt 長度限制導致詞庫截斷 | Low | 優先注入 Personal Vocab，按優先級截斷 HK Common |
| Progressive Output 替換時用戶已移動光標 | Medium | 偵測光標位置變化，不強制替換，改為通知 |
| Claude API 偶發高延遲 (>5s) | Medium | Streaming 顯示中間結果 + timeout 10s 走 fallback |
| 香港詞庫遺漏重要詞彙 | Low | 用戶可透過 Personal Vocab 補充；後續版本持續擴充 |

---

## 9. Open Decisions

以下問題需在開發過程中確定：

| # | Question | Options | Recommendation |
|---|---|---|---|
| 1 | Anthropic SDK 用 Swift 原生 HTTP 定係有 official Swift SDK？ | A) URLSession 直接調用 B) 社區 Swift SDK | 先用 A，穩定後再評估 |
| 2 | Progressive Output 是否預設開啟？ | A) 預設開 B) 預設關 | A — 用戶可在 Settings 關閉 |
| 3 | 香港詞庫要不要開放用戶提交 PR？ | A) 開放 B) 僅開發者維護 | B for v1，個人項目不需要 |
| 4 | Fn 鍵不可用時的 onboarding 流程？ | A) 強制引導 B) 靜默 fallback 到其他鍵 | A — 首次使用時引導設定 |

---

*End of Phase 2 PRD*
