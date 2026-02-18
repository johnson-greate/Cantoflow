# PRD：CantoFlow Mobile — 私有語音伺服器 + iOS 鍵盤輸入法
# PRD: CantoFlow Mobile — Private STT Server + iOS Keyboard Extension

**版本 / Version:** 0.1 Draft
**日期 / Date:** 2026-02-18
**作者 / Author:** Johnson Tam
**狀態 / Status:** 待審閱 / Pending Review

---

## 一、背景與動機 / Background & Motivation

### 中文
CantoFlow 現時是一個 macOS 專屬工具，依賴本地 Whisper.cpp 進行粵語語音轉文字。用戶希望在 iOS 裝置上獲得相同能力，同時維持現有的私隱保護原則——語音數據不上任何第三方雲端。

解決方案：以用戶自有的 Mac Mini 作為私人語音識別伺服器，iOS 裝置透過已部署的 Tailscale 私有網絡連接，實現與 Typeless 相近的使用體驗，但語音數據全程只在用戶私人設備間流轉。

### English
CantoFlow is currently macOS-only, relying on local Whisper.cpp for Cantonese STT. The user wants the same capability on iOS while maintaining the existing privacy principle — no voice data reaches any third-party cloud.

Solution: use the user's own Mac Mini as a private STT server. iOS devices connect via the already-deployed Tailscale private network, delivering a Typeless-like experience where voice data flows only between the user's own devices.

---

## 二、目標 / Goals

### 必須達成 / Must Have
- [ ] iOS Custom Keyboard Extension，可在任何 app 的文字輸入欄位插入粵語轉錄文字
- [ ] Mac Mini 作為私有 STT 伺服器，運行 Whisper（Metal GPU 加速）
- [ ] 透過 Tailscale 私有網絡通信，語音不上任何第三方服務
- [ ] 支援 Qwen LLM 潤色（可開關）
- [ ] 總延遲（錄音結束至文字出現）≤ 10 秒（無 polish）

### 應該達成 / Should Have
- [ ] 鍵盤介面顯示錄音狀態及處理進度
- [ ] 當 Mac Mini 離線時，提供清晰的錯誤提示
- [ ] 詞彙表（Vocabulary）注入支援，延續現有個人詞彙功能

### 暫不包括 / Out of Scope (v1)
- Android 支援（下一階段）
- 多用戶 / 多台 iOS 裝置共用（下一階段）
- 自動語言偵測（只支援粵語）
- 離線 fallback（Mac Mini 離線時不降級）

---

## 三、用戶故事 / User Stories

**US-01：基本錄音輸入**
> 用戶在任何 iOS app（WhatsApp、Notes、Mail 等）長按鍵盤上的麥克風按鈕錄音，鬆開後數秒內，粵語語音被轉換為繁體中文並自動插入光標位置。

**US-02：LLM 潤色**
> 轉錄完成後，文字自動經 Qwen 潤色（去口頭禪、修正語序、轉繁體），最終版本才插入。

**US-03：伺服器離線提示**
> 當 Mac Mini 不可達時，鍵盤顯示「伺服器離線」提示，不靜默失敗。

**US-04：詞彙表支援**
> 個人詞彙（香港地名、人名、品牌等）注入 Whisper prompt，提升識別準確度。

---

## 四、系統架構 / System Architecture

```
┌─────────────────────────────────────────────────────┐
│                  Tailscale 私有網絡                   │
│              (WireGuard E2E 加密，無第三方)            │
│                                                     │
│  ┌──────────────────┐      ┌─────────────────────┐  │
│  │  iPhone 12 Pro   │      │    Mac Mini         │  │
│  │  100.73.85.57    │      │  100.86.153.57      │  │
│  │                  │      │                     │  │
│  │ ┌──────────────┐ │      │ ┌─────────────────┐ │  │
│  │ │  Keyboard    │ │      │ │  CantoFlow      │ │  │
│  │ │  Extension   │ │      │ │  STT Server     │ │  │
│  │ │              │ │ HTTP │ │  (FastAPI)      │ │  │
│  │ │ 1. 錄音      │ │─────▶│ │                 │ │  │
│  │ │ 2. 壓縮 Opus │ │      │ │ 1. 接收音頻     │ │  │
│  │ │ 3. POST /stt │ │      │ │ 2. Whisper.cpp  │ │  │
│  │ │ 4. 等待文字  │ │◀─────│ │    (Metal GPU)  │ │  │
│  │ │ 5. insertText│ │ JSON │ │ 3. Qwen polish  │ │  │
│  │ └──────────────┘ │      │ │ 4. 回傳 JSON    │ │  │
│  └──────────────────┘      │ └─────────────────┘ │  │
│                             │         │           │  │
│                             │    ┌────▼────┐      │  │
│                             │    │  Qwen   │      │  │
│                             │    │ (雲端,  │      │  │
│                             │    │ 文字只) │      │  │
│                             │    └─────────┘      │  │
│                             └─────────────────────┘  │
└─────────────────────────────────────────────────────┘
```

**數據流說明 / Data Flow:**
1. 用戶在 iOS 鍵盤按下錄音鍵
2. 錄音（16kHz mono WAV），鬆開觸發上傳
3. 音頻壓縮為 Opus（~30KB/15秒）
4. 透過 Tailscale POST 至 Mac Mini `100.86.153.57:8765/stt`
5. Mac Mini 呼叫 Whisper.cpp（Metal GPU）轉錄
6. （可選）文字送 Qwen API 潤色
7. JSON 回傳 iPhone
8. Keyboard Extension 呼叫 `insertText()` 插入

---

## 五、API 設計 / API Design

### 伺服器基礎 URL / Base URL
```
http://100.86.153.57:8766/
```
（使用新 port 8766，避免與現有 FunASR server port 8765 衝突）

### 端點 / Endpoints

#### `GET /health`
伺服器健康檢查，供 iOS 端啟動時確認連接。

**Response:**
```json
{
  "status": "ok",
  "whisper_model": "ggml-large-v3-turbo",
  "metal_enabled": true,
  "polish_available": true
}
```

#### `POST /stt`
主要轉錄端點。

**Request:** `multipart/form-data`
| 欄位 | 類型 | 必填 | 說明 |
|---|---|---|---|
| `audio` | File | ✅ | 音頻檔案（Opus 或 WAV，16kHz mono）|
| `language` | string | - | 預設 `yue`（粵語）|
| `polish` | bool | - | 是否啟用 LLM 潤色，預設 `true` |
| `script` | string | - | `traditional`（預設）或 `simplified` |

**Response:**
```json
{
  "raw_text": "我自己都有大陸客戶...",
  "final_text": "我都有大陸客戶...",
  "polish_status": "ok",
  "provider": "qwen",
  "latency_ms": {
    "stt": 4200,
    "polish": 2800,
    "total": 7000
  }
}
```

**Error Response:**
```json
{
  "error": "server_unavailable",
  "message": "Whisper model not loaded"
}
```

### 認證 / Authentication
請求 Header 加入 API Key：
```
X-CantoFlow-Key: <shared_secret>
```
金鑰存於 Mac Mini 的 `~/.cantoflow.env`，iOS 端存於 Keychain。

---

## 六、iOS Keyboard Extension 設計 / iOS Keyboard Extension Design

### 技術規格 / Technical Specs
- **類型：** Custom Keyboard Extension（`UIInputViewController`）
- **音頻格式：** AVAudioEngine → 16kHz mono → Opus（使用 `libopus` 或 `AVAudioConverter` + AAC）
- **最低 iOS 版本：** iOS 16
- **語言：** Swift

### 鍵盤 UI 佈局 / Keyboard UI Layout
```
┌──────────────────────────────────────┐
│  [繁] [簡]              [🌐] [⌫]    │  ← 頂列：繁/簡切換，語言鍵，退格
├──────────────────────────────────────┤
│                                      │
│         按住錄音 / 鬆開發送           │  ← 中央錄音區
│                                      │
│    ████████████░░░░░░  3.2s 🎙️       │  ← 錄音時：波形 + 計時
│                                      │
│    ⏳ 轉錄中...                       │  ← 處理時：狀態提示
│                                      │
├──────────────────────────────────────┤
│  [space]     [return]                │  ← 底列
└──────────────────────────────────────┘
```

### 狀態機 / State Machine
```
idle → recording → uploading → transcribing → (polishing) → done → idle
                                                         ↓
                                                    error (shown 2s)
```

### 重要限制 / iOS Extension Constraints
| 限制 | 數值 | 影響 |
|---|---|---|
| 記憶體上限 | ~120MB | Whisper 模型不可在手機端跑（故需伺服器）|
| 背景執行 | 有限 | 需在 active session 內完成請求 |
| 麥克風權限 | 需用戶授權 | Extension 需要 `NSMicrophoneUsageDescription` |
| 網絡權限 | 需開啟 | Keyboard Extension 預設無網絡，需 `RequestsOpenAccess` |

⚠️ **重要：** `RequestsOpenAccess = true` 會在 App Store 審核時增加審查力度，用戶亦需在系統設定中手動開啟「完整存取」。這是 iOS 鍵盤存取網絡的必要條件。

---

## 七、Mac Mini 伺服器設定 / Mac Mini Server Setup

### 所需安裝 / Prerequisites
- Whisper.cpp（已在 MacBook Air 上編譯，需在 Mac Mini 重新編譯）
- Python 3.13 + venv（已有）
- `~/.cantoflow.env`（複製 API keys）
- Tailscale（已安裝）

### 服務管理 / Service Management
使用 `launchd` LaunchAgent 確保 Mac Mini 重啟後自動啟動伺服器：
```xml
<!-- ~/Library/LaunchAgents/com.cantoflow.server.plist -->
```

### 伺服器新 Python 模組 / New Server Module
在 `funasr_server/` 目錄下新增 `whisper_server.py`（或擴展現有 `server.py`）：
- Port 8766
- 接受音頻上傳
- 呼叫 `whisper-cli` 子進程（與 macOS 版本相同邏輯）
- 整合 Qwen polish（移植自 `TextPolisher.swift` 邏輯）

---

## 八、安全考慮 / Security

| 層面 | 方案 |
|---|---|
| 網絡傳輸 | Tailscale WireGuard（E2E 加密，無需額外 TLS）|
| 認證 | 共享 API Key（`X-CantoFlow-Key` Header）|
| 金鑰儲存（iOS）| iOS Keychain |
| 金鑰儲存（Mac Mini）| `~/.cantoflow.env`（chmod 600）|
| 語音數據 | 只在私有 Tailscale 網絡內傳輸，不觸碰公網 |
| Qwen polish | 只傳送**文字**至 DashScope，語音永不上雲 |

---

## 九、效能目標 / Performance Targets

| 指標 | 目標 | 備註 |
|---|---|---|
| 音頻上傳（15秒錄音）| < 300ms | Tailscale 本地網絡 |
| Whisper 推理（Mac Mini）| < 6,000ms | 取決於 Mac Mini 的 GPU |
| Qwen polish | < 3,500ms | 與現時相近 |
| **總延遲（有 polish）** | **< 10,000ms** | 目標 |
| **總延遲（無 polish）** | **< 6,500ms** | 目標 |
| 伺服器可用率 | > 95% | Mac Mini 需常開 |

---

## 十、開發分階段計劃 / Phased Plan

### Phase 1：Mac Mini STT Server（伺服器端）
**目標：** 在 Mac Mini 上跑一個可接受音頻、回傳文字的 HTTP server
**工作：**
- [ ] 在 Mac Mini 上安裝 Whisper.cpp 及編譯（Metal 支援）
- [ ] 新增 `funasr_server/whisper_server.py`（FastAPI，port 8766）
- [ ] 實作 `POST /stt` 及 `GET /health` endpoint
- [ ] 移植 Qwen polish 邏輯（Python）
- [ ] 設定 `launchd` LaunchAgent 自動啟動
- [ ] 在 MacBook Air 用 `curl` 透過 Tailscale 測試

**驗收標準：**
```bash
curl -X POST http://100.86.153.57:8766/stt \
  -H "X-CantoFlow-Key: <key>" \
  -F "audio=@test.wav" \
  | jq .final_text
# → "轉錄文字成功出現"
```

### Phase 2：iOS Keyboard Extension MVP
**目標：** 能錄音並在任何 app 插入文字的最小可用鍵盤
**工作：**
- [ ] 建立 Xcode 項目（App + Keyboard Extension target）
- [ ] 實作錄音（`AVAudioEngine`，16kHz mono）
- [ ] 實作 HTTP 上傳至 Mac Mini（URLSession）
- [ ] 實作 `insertText()` 插入結果
- [ ] 基本 UI（錄音按鈕、狀態提示）
- [ ] Keychain 儲存 API Key

### Phase 3：完整 UI + 詞彙表
**目標：** 生產可用品質
**工作：**
- [ ] 波形視覺化
- [ ] 繁/簡切換按鈕
- [ ] 個人詞彙表同步（Mac Mini 共享詞彙表）
- [ ] 錯誤處理及離線提示
- [ ] Opus 音頻壓縮（減少上傳大小）

### Phase 4：Android（未來）
- Android InputMethodService
- 與 iOS 共用伺服器端

---

## 十一、未解決問題 / Open Questions

| # | 問題 | 需要決定 |
|---|---|---|
| 1 | Mac Mini 的 Whisper.cpp 是否需要重新編譯？ | 需確認 Mac Mini 的 chip（M1/M2/Intel）|
| 2 | iOS App 如何分發？ | TestFlight（自用）或 App Store |
| 3 | API Key 的 rotation 機制？ | 目前設計為靜態，夠用嗎？ |
| 4 | 音頻格式：Opus vs AAC？ | Opus 壓縮率更好但需第三方 lib；AAC 原生支援 |
| 5 | Mac Mini 離線時是否需要降級至 macOS 本地 Whisper？ | 暫定 Out of Scope |

---

## 十二、依賴關係 / Dependencies

| 依賴 | 目前狀態 |
|---|---|
| Tailscale（Mac Mini + iPhone）| ✅ 已部署 |
| Whisper.cpp（Mac Mini）| ❌ 需安裝 |
| Python FastAPI（Mac Mini）| ❌ 需安裝 |
| `~/.cantoflow.env`（Mac Mini）| ❌ 需複製 |
| Xcode（iOS 開發）| ❓ 需確認 |
| Apple Developer Account（iOS 部署）| ❓ 需確認 |
