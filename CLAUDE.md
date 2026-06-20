# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

CantoFlow 係廣東話語音轉繁體中文嘅 push-to-talk STT 工具，做畀 AI Trade Training Course 學生用。溝通用廣東話；所有學生面向 UI 一律用中文。

## Repo 佈局（monorepo）

| 路徑 | 內容 |
|------|------|
| `app/` | macOS Menu Bar app（Swift Package Manager）。**詳見 `app/CLAUDE.md`** — build、STT pipeline、config、known bugs 全部喺嗰度 |
| `windows/` | Windows app（.NET，`CantoFlow.Windows.slnx`） |
| `scripts/` | Local ASR bridge（Python）+ 安裝輔助 |
| `third_party/whisper.cpp` | Whisper binary 同模型（`whisper-cli`、`ggml-*.bin`） |
| `install-student.sh` | 學生一鍵安裝（`curl … | bash`） |
| `docs/current_status.md` | macOS / Windows / 學生分發 / corporate server 嘅最新進度 — 改嘢前先睇 |

開始任何 app 工作前，先讀返對應子目錄嘅 CLAUDE.md（`app/CLAUDE.md`）。

## Build

- **macOS**: `cd app && swift build`（debug）或 `app/scripts/build.sh`（release）。binary 喺 `app/.build/{debug,release}/cantoflow`。啟動新 binary **必須先 Quit 舊 app**。
- **Windows**: `dotnet build windows/CantoFlow.Windows.slnx`（一般喺 Calvin 部 Windows 機 build/test，唔喺 Mac）。
- **無 test framework** — 驗證靠實際 run app 同睇 `.out/telemetry.jsonl`，唔好假設有 `swift test` / `dotnet test` 可以證明 work。

## 學生分發 — install-student.sh 已知 bug

⚠️ 用戶答 Y 安裝 Ollama 時，內層 `curl | sh`（Ollama installer）會食咗外層 bash 嘅 stdin，靜靜雞搞壞 launcher heredoc（`~/bin/cantoflow` 變返舊 dev 版），最後出 `syntax error near unexpected token 'else'`。改 installer 時要避開呢個：launcher 寫去 temp file，Ollama 嘅 read prompt 用 `/dev/tty`。clean Mac 測試**仲未做過**。

## Commit 慣例

- 相關改動一次過 commit，唔好拆成好多細 commit。
- Conventional prefix：`feat:` / `fix:` / `docs:`（可加 scope，如 `fix(stability):`）。
- 預設 branch 係 `main`；要 commit/push 嗰陣，如果喺 `main` 上先開 branch。
