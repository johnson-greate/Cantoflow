# CantoFlow — Current Status

_Last updated: 2026-03-16_

## Build Status

- **Release binary**: up to date (`swift build -c release` completed 2026-03-16)
- **Active branch**: `main`
- **Version**: auto-generated from binary mtime (`yyyyMMdd.HHmm` format)

## Working Features

| Feature | Status |
|---------|--------|
| Push-to-talk STT (Whisper) | Working |
| LLM Polish (Qwen/DashScope) | Working |
| FastIME raw paste + replace | Working |
| Terminal detection (skip raw paste) | Working |
| Vocabulary injection | Working |
| Correction watcher (vocab learning) | Working |
| Telemetry logging | Working |
| Settings UI — General / Vocabulary / API Keys tabs | Working |
| Launch at Login | Working |

## Recently Fixed (2026-03-16)

### Settings UI ↔ `~/.cantoflow.env` Sync

**Problem**: Clearing an API key in Settings UI only cleared `UserDefaults`, but `~/.cantoflow.env` (sourced by `run.sh` at launch) still had the old key. The process environment is immutable after launch, so clearing from UI had no effect until restart — and even then, the env file still held the old value.

**Root cause confirmed via**:
1. Telemetry showed `provider=qwen` after UI key was cleared
2. `ps -E` on the running process confirmed env var still present
3. `cat ~/.cantoflow.env` showed stale key value
4. Process was launched from `run.sh` which sources `~/.cantoflow.env`

**Fix** (`SettingsView.swift` — `APIKeysTab`):
- Added `loadFromEnvFile()` — on Settings appear, reads `~/.cantoflow.env` and populates UI fields with the actually-active values
- Added `syncKeyToEnvFile(envVar:value:)` — on any key change, immediately writes to `~/.cantoflow.env`
- Added `parseEnvFile()` — parses `KEY="value"` format
- Added `.onAppear` and `.onChange` modifiers to trigger the above
- Updated caption text to reflect new behaviour

**Verification**: After restart with clean env file → `provider=none`, `polish_status=not_run`. Re-adding key + restart → `provider=qwen`, `polish_status=ok`.

## Known Limitations

- API key changes in Settings UI require an **app restart** to take effect (env vars are baked into the process at launch time by `run.sh`)
- `anthropicAPIKey` has no Settings UI field (can only be set via `~/.cantoflow.env` or CLI env var)
- `~/.cantoflow.env` does not include `GEMINI_API_KEY` by default (added to UI sync but user must add the line manually to the file for it to persist across Settings resets)
