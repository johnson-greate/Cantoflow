# Canton Flow — Strategic Update: Commercial Vision

> From Personal Tool to Commercial Product

| Field | Value |
|---|---|
| Version | 2.0 |
| Date | 2026-02-17 |
| Status | Strategic Planning |
| Scope | Product repositioning, competitive analysis, go-to-market |

---

## 1. Vision Update

Canton Flow 不再只是一個個人工具。目標是成為**廣東話語音輸入的首選產品**，服務所有以廣東話為母語的用戶，最終覆蓋 macOS、Windows、iOS、Android 全平台，以可出售的商業軟件水平推向市場。

**Core Thesis：** 全球約 8,500 萬廣東話使用者目前沒有一個專為廣東話優化的商業級語音輸入工具。Wispr Flow 和 Typeless 雖然支援多語言，但廣東話只是 100+ 語言中的一個，缺乏深度優化。Canton Flow 的機會是做「窄而深」——在廣東話這個垂直市場做到最好。

---

## 2. Competitive Landscape

### 2.1 Competitor Matrix

| Dimension | Wispr Flow | Typeless | Canton Flow |
|---|---|---|---|
| **Funding** | $81M (Menlo Ventures) | Unknown | Bootstrapped |
| **Pricing** | Free / $12mo Pro / $10mo Teams / Enterprise | Free / Pro | TBD（目標：Wispr 七折） |
| **Platforms** | Mac, Windows, iOS (Android waitlist) | Mac, Windows, iOS, Android | Phase 1: macOS → All platforms |
| **Languages** | 100+ | 100+ | 廣東話為核心，逐步擴展 |
| **廣東話深度** | 一般（100+ 語言之一） | 一般 | 專屬優化（詞庫、口語轉書面語） |
| **Privacy** | 雲端轉錄，SOC2/HIPAA/ISO27001 | 雲端轉錄，透明度存疑 | 本地語音識別，僅文字上雲 |
| **Compliance** | SOC 2 Type II, HIPAA, ISO 27001 | 無 | 需後續取得 |
| **Transcription** | 100% 雲端 | 100% 雲端 | 本地 Whisper（音頻不離開設備） |
| **Accuracy** | ~97.2% (English) | Good | TBD（廣東話專屬模型） |
| **Speed claim** | 4x typing (220 wpm) | 6x typing | 4-5x typing（目標） |

### 2.2 Wispr Flow Deep Analysis

**Strengths（Canton Flow 需正視的）：**

- $81M 融資，團隊來自 Stanford，Reid Hoffman (LinkedIn co-founder) 親自背書
- SOC 2 Type II + HIPAA + ISO 27001 合規認證齊全
- 客戶包括 Amazon, Nvidia, OpenAI, Vercel, Replit 等頂級科技公司
- 出色的產品打磨：Personal Dictionary, Snippet Library, Tone per App
- Vibe Coding 場景已有專門優化（Cursor, VS Code file tagging）

**Weaknesses（Canton Flow 的機會）：**

- **語音處理 100% 雲端**：即使有 Privacy Mode，音頻必須傳送到伺服器，這是架構性限制
- **廣東話是 100+ 語言之一**：無專屬詞庫、無口語轉書面語深度優化
- **Data Controls 頁面承認**用到 OpenAI 等第三方 LLM，數據流轉複雜
- Privacy Mode 關閉時，數據可能被用於模型訓練
- 無 Android 版本（仍在 waitlist）
- 月費 $12（Pro）對亞洲市場偏高

### 2.3 Canton Flow Competitive Advantages

| # | Advantage | Why It Matters |
|---|---|---|
| 1 | **音頻永不離開設備** | 架構性隱私優勢，無論競爭對手加多少合規認證都無法複製 |
| 2 | **廣東話深度優化** | 專屬詞庫（港鐵站名、地名、俗語）、口語轉書面語、繁體中文 |
| 3 | **可離線使用**（語音識別層） | 飛機上、地鐵裡、弱網環境仍可用基本功能 |
| 4 | **價格更親民** | 目標：Wispr Pro 七折（~$8-9/month） |
| 5 | **Vibe Coding 廣東話場景** | 用廣東話口述代碼需求、debug 思路、commit messages |
| 6 | **透明度** | 開源或半開源，用戶可自行驗證隱私聲明 |

### 2.4 Canton Flow Competitive Risks

| Risk | Severity | Mitigation |
|---|---|---|
| Wispr Flow 加強廣東話支援 | High | 速度是護城河——先建立用戶基礎和詞庫生態 |
| 缺乏合規認證（SOC2 等） | High | Phase 2+ 規劃取得認證；初期強調「音頻不離開設備」的架構優勢 |
| 一人開發，資源有限 | High | 專注 macOS MVP，驗證市場後再擴展平台 |
| Wispr 已有頂級企業客戶背書 | Medium | 定位不同——Canton Flow 是廣東話社群的產品，非企業通用工具 |

---

## 3. Product Positioning

### 3.1 Tagline Options

- "Canton Flow — 用聲說話，用心書寫"
- "Canton Flow — 廣東話語音輸入，快過打字五倍"
- "Canton Flow — 你講嘢，我幫你寫"

### 3.2 Target Users (Priority Order)

| Segment | Description | Platform Priority | Pain Point |
|---|---|---|---|
| 🥇 HK/GD 開發者 | 用廣東話做 vibe coding 的開發者 | macOS | Wispr/Typeless 廣東話識別差，無專屬口語處理 |
| 🥈 HK 知識工作者 | 每日大量文字輸出的白領、記者、律師 | macOS → Windows | 打字慢，現有語音輸入廣東話支援差 |
| 🥉 HK/GD 學生 | 需要快速寫筆記、報告的大學生 | iOS → Android | 價格敏感，需要免費或低價方案 |
| 4️⃣ 海外廣東話社群 | 澳洲、加拿大、英國、美國的廣東話移民 | All platforms | 需要在英文環境中快速輸入廣東話 |

### 3.3 Pricing Strategy

以 Wispr Flow 為錨定，打七折：

| Plan | Wispr Flow | Canton Flow (Target) | Notes |
|---|---|---|---|
| Free | 2,000 words/week | 3,000 words/week | 比 Wispr 更慷慨的免費額度 |
| Pro | $12/mo ($144/yr) | $8/mo ($80/yr) | 約七折，對亞洲市場更有吸引力 |
| Teams | $10/user/mo | $7/user/mo | 後續開發 |
| Student | (無) | $4/mo | 學生專屬半價，Canton Flow 獨有 |

---

## 4. Commercial-Grade Requirements

從個人工具升級到商業軟件，需要在以下維度達到出售水平：

### 4.1 Design & Polish

| Dimension | Requirement | Reference |
|---|---|---|
| UI Design | 達到 App Store Featured 水平的視覺設計 | Wispr Flow, Bear, Raycast |
| Onboarding | 首次使用引導流程，3 步內完成設定 | — |
| Animation | 流暢的 micro-interactions（錄音波形、狀態切換） | — |
| Iconography | 專業 App Icon + Menu Bar icon set | — |
| Localization | 繁體中文（主）、簡體中文、英文 | — |
| Accessibility | VoiceOver 支援、高對比模式 | Apple HIG |

### 4.2 Privacy & Compliance Roadmap

| Phase | Milestone | Timeline |
|---|---|---|
| Now | 架構層面「音頻不離開設備」 | ✅ Phase 1 |
| v1.0 Launch | Privacy Policy + Terms of Service 法律文件 | Launch |
| v1.0 Launch | Data Controls 頁面（透明說明數據流向） | Launch |
| v1.5 | 獨立安全審計（第三方報告） | Launch + 3 months |
| v2.0 | SOC 2 Type II 認證 | Launch + 6-12 months |
| v2.5 | HIPAA 合規（如進入醫療市場） | Launch + 12 months |

### 4.3 Platform Expansion Roadmap

| Phase | Platform | Tech Stack | Timeline |
|---|---|---|---|
| v1.0 | macOS | Swift + SwiftUI | Current |
| v1.5 | iOS | Swift + SwiftUI (shared core) | v1.0 + 2 months |
| v2.0 | Windows | C++ / Rust + WinUI 3 or Electron | v1.0 + 4-6 months |
| v2.5 | Android | Kotlin + Jetpack Compose | v2.0 + 2-3 months |

**Cross-platform Core：** Whisper.cpp (C++) 和 LLM client logic 可在所有平台共用，UI 層各平台原生。

### 4.4 Business Infrastructure

| Item | Requirement |
|---|---|
| 法律實體 | 香港有限公司或美國 LLC（視上架策略） |
| 支付系統 | Apple IAP (iOS/macOS) + Stripe (Web) + Google Play Billing |
| 用戶帳號 | 帳號系統（Apple Sign In + Google Sign In + Email） |
| 後端 | 用戶管理、訂閱管理、詞庫同步（如需跨設備） |
| Analytics | 匿名使用統計（遵守 GDPR/PDPO） |
| Customer Support | Help Center + In-app feedback |

---

## 5. Updated Development Phases

原始 6-9 週計劃擴展為商業產品路線：

| Phase | Focus | Deliverable | Est. |
|---|---|---|---|
| Phase 0-1 | Core MVP（已完成） | 麥克風 → Whisper → Console | ✅ Done |
| Phase 2 | LLM + Vocab + Push-to-Talk | 完整 pipeline 可用 | Current |
| Phase 3 | Text Insertion | AX API + Clipboard fallback | 1-2 weeks |
| Phase 4 | UI & UX (Commercial Grade) | Menu Bar App + Overlay + Settings | 2-3 weeks |
| Phase 5 | Polish & Hardening | Error handling, edge cases, perf | 1-2 weeks |
| **=== MVP Complete (macOS) ===** | | | |
| Phase 6 | Legal & Business Setup | 公司註冊、隱私政策、條款、定價頁 | 2-4 weeks |
| Phase 7 | Beta Testing | 邀請 50-100 廣東話用戶測試 | 4 weeks |
| Phase 8 | macOS Launch | App Store 上架 | — |
| Phase 9 | iOS Version | 共用 Core + iOS UI | 6-8 weeks |
| Phase 10 | Windows Version | Cross-platform core + Windows UI | 8-12 weeks |
| Phase 11 | Android Version | Kotlin + Jetpack Compose | 6-8 weeks |

---

## 6. Key Strategic Decisions Pending

| # | Decision | Options | Recommendation | Decide By |
|---|---|---|---|---|
| 1 | 開源 or 閉源？ | A) 全開源 B) Core 開源 + Premium 閉源 C) 全閉源 | B — Core 開源建立信任，Premium 功能收費 | Before Beta |
| 2 | 法律實體註冊地？ | A) 香港 B) 美國 Delaware C) 兩者都有 | A 先行，美國市場大時再加 B | Phase 6 |
| 3 | 自建 LLM 還是繼續用 Anthropic？ | A) 純 Anthropic B) Anthropic + 自建小模型 C) 全自建 | A for v1, B for v2 | v1.5 |
| 4 | 跨設備詞庫同步？ | A) iCloud B) 自建後端 C) 不同步 | A for Apple ecosystem, B for cross-platform | Phase 9 |
| 5 | 名稱「Canton Flow」最終確認？ | A) Canton Flow B) 其他 | 確認前做商標查詢 | Before Beta |

---

## 7. Wispr Flow Feature Parity Checklist

Canton Flow 要達到商業可售水平，需要對標 Wispr Flow 的核心功能：

| Wispr Feature | Canton Flow Status | Priority | Notes |
|---|---|---|---|
| Voice dictation in every app | 🔧 Phase 3 | P0 | AX API + Clipboard |
| AI auto-edits (filler removal, self-correction) | 🔧 Phase 2 | P0 | Claude System Prompt |
| Personal dictionary | 🔧 Phase 2 | P0 | Vocabulary System |
| 100+ languages | ❌ Not planned for v1 | P2 | 廣東話 + 英文 + 普通話先行 |
| Different tones per app | ❌ | P2 | v1.5 加入 |
| Snippet library (voice shortcuts) | ❌ | P1 | v1.0 後快速加入 |
| Whisper mode (低聲輸入) | ❌ | P1 | Whisper.cpp 已有不錯的低音支援 |
| Cross-device sync | ❌ | P2 | Phase 9+ |
| SOC 2 Type II | ❌ | P1 | Phase 6+ |
| HIPAA | ❌ | P3 | 視市場需求 |
| Team admin controls | ❌ | P3 | Phase 10+ |
| Vibe Coding file tagging | ❌ | P1 | 殺手功能 — 用廣東話 tag Cursor 檔案 |
| **Canton Flow Unique** | | | |
| 廣東話專屬詞庫（地名、俗語） | 🔧 Phase 2 | P0 | 競品無 |
| 口語轉書面語 | 🔧 Phase 2 | P0 | 競品無深度優化 |
| 本地語音識別（音頻不上雲） | ✅ Phase 1 | P0 | 架構性優勢 |
| 離線基本模式 | ✅ Phase 1 | P0 | 競品無 |
| 學生價 | ❌ | P1 | 競品無 |

---

*End of Strategic Update*
