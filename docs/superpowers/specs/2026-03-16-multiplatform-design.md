# CantoFlow Multi-Platform Design Spec

**Date:** 2026-03-16
**Status:** Approved for Phase 1 (Windows)
**Author:** CantoFlow team

---

## Background

CantoFlow is a Cantonese STT menu bar app for macOS. This spec covers extending it to Windows (Phase 1) and mobile thin clients (Phase 2), so that a Windows PC + Android/iPhone user can have the same push-to-talk → LLM Polish experience.

**Primary user for Windows + mobile:** Boss uses Windows PC + Android phone. Developer uses macOS + iPhone 12 Pro.

---

## Repository Structure

```
CantoFlow/
├── app/          ← macOS (existing Swift, unchanged)
├── windows/      ← Phase 1: C# .NET desktop app + transcription server
├── android/      ← Phase 2: Kotlin Android IME thin client
├── ios/          ← Phase 2: Swift iOS IME thin client
└── shared/       ← OpenAPI spec (API contract between server and mobile clients)
```

---

## Shared API Contract (`shared/`)

Single OpenAPI spec. Windows implements the server side; Android and iOS implement the client side. This is the single source of truth — no API drift.

### Endpoints

**POST `/transcribe`**
```
Request:  multipart/form-data
  audio: <WAV file, 16kHz mono>

Response 200:
{
  "text":     "polished text (廣東話)",
  "raw":      "raw STT output",
  "provider": "qwen" | "openai" | "gemini" | "anthropic" | "none",
  "polish_ms": 1800,
  "stt_ms":   4200
}

Response 503:
{ "error": "server_busy" }
```

**GET `/health`**
```
Response 200:
{
  "status":  "ok",
  "version": "20260316.1234",
  "polish_available": true
}
```

### Security

- Server binds only to Tailscale interface (`100.x.x.x`), never `0.0.0.0`
- No additional auth layer needed — Tailscale VPN is the trust boundary
- Port default: `8765`, user-configurable in Settings

---

## Phase 1: Windows App (`windows/`)

### Overview

The Windows app has two responsibilities:
1. **Desktop app** — push-to-talk STT for the PC user (feature parity with macOS)
2. **Transcription server** — serves audio → polished text requests from mobile thin clients over Tailscale

Both use the same whisper.cpp pipeline and LLM polish config.

### Technology Stack

| Component | Technology |
|-----------|-----------|
| Language | C# 12 / .NET 8 |
| System tray | `NotifyIcon` (WinForms) |
| Settings UI | WPF or WinForms |
| Global hotkey | `RegisterHotKey` Win32 API |
| Audio capture | NAudio (WASAPI) |
| STT | whisper.cpp Windows binary (CLI, same approach as macOS) |
| LLM Polish | HttpClient → same provider APIs (Qwen, OpenAI, Gemini, Anthropic) |
| Auto-paste | `SendInput` Win32 API + UIAutomation for accessibility |
| HTTP server | ASP.NET Core minimal API, embedded in the app process |
| API keys | `%APPDATA%\CantoFlow\cantoflow.env` (mirrors `~/.cantoflow.env` on macOS) |
| Telemetry | `%APPDATA%\CantoFlow\.out\telemetry.jsonl` (same schema as macOS) |

### Component Breakdown

#### System Tray App
- Tray icon with right-click menu: Start/Stop Recording, Settings, Quit
- Status indicator: idle / recording / processing
- Version shown in menu (from binary timestamp, same logic as macOS)

#### Push-to-Talk
- Default trigger: configurable hotkey (e.g. F15, Ctrl+Shift+Space)
- Hold to record, release to process
- Minimum recording duration: 1500ms (same as macOS)
- Skip auto-paste in terminal apps (Windows Terminal, cmd.exe, PowerShell) — same safety rule as macOS

#### STT Pipeline
Same logical flow as macOS `STTPipeline.stopAndProcess()`:
```
1. Detect if focused app is terminal
2. FastIME: paste raw text (non-terminal only)
3. Whisper STT (local whisper.cpp Windows build)
4. LLM Polish (if API key available)
5. FastIME: replace raw with polished
6. Log telemetry
```

#### Embedded HTTP Server
- Starts with the app, runs on Tailscale IP only
- `POST /transcribe`: receives WAV, runs through shared STT+Polish pipeline, returns JSON
- `GET /health`: returns status + polish availability
- Concurrent request limit: 1 (STT is CPU-heavy; queue or reject if busy)
- Toggle in Settings: "Enable mobile transcription server"
- Shows Tailscale IP + port in Settings for easy copy to mobile

#### API Key Management
- Settings UI has same fields as macOS: Gemini, DashScope/Qwen, OpenAI, Anthropic
- Stored in `%APPDATA%\CantoFlow\cantoflow.env` (same KEY="value" format)
- Same dual-source logic: env file loaded at startup, Settings UI writes back to env file
- Same restart-required modal when keys are changed (same UX as macOS fix from 2026-03-16)

#### Vocabulary
- Stored in `%APPDATA%\CantoFlow\vocabulary\`
- Same JSON format as macOS (`~/Library/Application Support/CantoFlow/`)
- Injected into LLM Polish prompt (same logic as macOS `VocabularyStore`)
- Mobile requests from Android/iOS use the same vocab on the server side automatically

### Settings UI

Tabs mirroring macOS:
- **General** — hotkey, auto-paste, auto-replace, polish style, launch at startup
- **Vocabulary** — same CRUD as macOS
- **API Keys** — same fields, same sync-to-env-file behaviour
- **Server** — enable/disable mobile server, port, show Tailscale IP (read-only)

### Distribution

- Single `.exe` installer (NSIS or WiX), self-contained (no .NET runtime required)
- whisper.cpp Windows binary shipped with installer at: `%APPDATA%\CantoFlow\whisper\whisper-cli.exe`
- Model file at: `%APPDATA%\CantoFlow\whisper\models\ggml-large-v3-turbo.bin`
- On first run, if model missing → show download dialog with direct URL to ggml-large-v3-turbo.bin
- If `%APPDATA%\CantoFlow\cantoflow.env` does not exist on first launch → create it with empty template (same KEY="" format as macOS)

### Terminal App Detection (Windows)

Auto-paste is skipped if the foreground process name is in this list (same safety rule as macOS):

```
WindowsTerminal.exe, cmd.exe, powershell.exe, pwsh.exe, wt.exe,
ConEmu64.exe, mintty.exe, alacritty.exe, Code.exe (VSCode integrated terminal)
```

Detection via `GetForegroundWindow()` → `GetWindowThreadProcessId()` → `GetProcessImageFileName()`.

### FastIME Undo-and-Replace (Windows)

When replacing raw text with polished text (non-terminal apps only):
1. `SendInput` Ctrl+Z (undo raw paste)
2. `Task.Delay(50)` — 50ms pause (same as macOS, required for target app to process undo)
3. `SendInput` Ctrl+V (paste polished text from clipboard)

`autoReplace` defaults to `false` (same conservative default as macOS).

### API Key Lookup Order (Windows)

Same two-source priority as macOS `TextPolisher.resolvedAPIKey()`:
1. **Process environment variables** (`Environment.GetEnvironmentVariable()`) — checked first
2. **`cantoflow.env` file** (`%APPDATA%\CantoFlow\cantoflow.env`) — fallback

LLM provider auto-priority: **Gemini > Qwen/DashScope > OpenAI > Anthropic** (same as macOS).

### Tailscale IP Detection (Windows)

Query Tailscale local API at `http://localhost:41112/localapi/v0/status` (requires Tailscale running).
Parse response for the first `100.x.x.x` address assigned to this machine.
If Tailscale not running or not installed → server shows "Tailscale not detected" warning in Settings; server does not start.

### Version String

Embedded as a build-time constant using a pre-build MSBuild task that writes `yyyyMMdd.HHmm` (UTC build time) into `BuildVersion.cs`. Same format as macOS binary mtime approach.

### Telemetry Format

Entries separated by `\n\n` (double newline) to match the macOS `TelemetryLogger` format. Same JSON schema.

---

## Phase 2: Mobile Thin Clients (Overview)

Both Android and iOS act as **thin clients**: capture audio → POST to Windows PC via Tailscale → receive polished text → inject into focused app. No local AI model on device.

### Android (`android/`) — IME keyboard

- Kotlin, `InputMethodService` + Jetpack Compose keyboard UI
- Hold mic button → record → release → POST WAV → receive text → `InputConnection.commitText()`
- Settings activity: PC Tailscale hostname + port
- Requires Tailscale app running on the phone

### iOS (`ios/`) — IME keyboard

- Swift, `UIInputViewController` keyboard extension
- Same UX as Android
- `AVAudioEngine` for audio capture (requires Full Access enabled in iOS Settings)
- `textDocumentProxy.insertText()` for text injection
- Requires iOS 16+, Tailscale app running

### Shared Mobile Behaviour

- On connection failure: show error in keyboard UI ("Cannot reach PC")
- Health check on keyboard open: GET `/health` to verify server is up
- Settings: Tailscale hostname configurable (e.g. `my-pc.tail12345.ts.net:8765`)
- Audio format: WAV 16kHz mono (same as macOS recording format)

---

## What Is NOT in Scope

- CantoFlow Cloud (no multi-user server)
- Android/iOS running local Whisper on device
- Web app / browser extension
- Real-time streaming STT (chunked audio); full recording then POST is sufficient

---

## Open Questions for Phase 2

1. iOS keyboard extension memory limit (~50MB) — needs profiling with real audio + URLSession
2. Android: handle Tailscale not connected gracefully (show setup instructions in IME settings)
3. Consider mDNS/Bonjour auto-discovery of PC on local network as alternative to manual Tailscale hostname entry
