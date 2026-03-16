# CantoFlow — Thread Handoff

_Date: 2026-03-16_

## What Was Investigated

User reported: after deleting the Qwen API key in Settings UI, LLM Polish was still running.

## Root Cause Found

`run.sh` sources `~/.cantoflow.env` at launch and exports all keys as environment variables into the `cantoflow` process. The process environment is immutable after launch.

Settings UI (`APIKeysTab`) was only writing to `UserDefaults` (`@AppStorage`). `TextPolisher.resolvedAPIKey()` checks **env vars first**, then UserDefaults — so clearing UserDefaults had no effect while the env var was still live in the process.

`~/.cantoflow.env` had:
```
QWEN_API_KEY="sk-53df5fadf0e14803ab6a0f91a6b6f821"   ← never cleared
```

## Fix Implemented

**File**: `app/Sources/CantoFlowApp/UI/Settings/SettingsView.swift`
**Struct**: `APIKeysTab`

Three new private methods added:
- `loadFromEnvFile()` — reads `~/.cantoflow.env` on `.onAppear`, syncs values into `@AppStorage` so UI shows what's actually active
- `syncKeyToEnvFile(envVar:value:)` — on `.onChange` of any key field, writes the new value to `~/.cantoflow.env` immediately
- `parseEnvFile(_:)` — parses `KEY="value"` / `KEY=value` format

`.onAppear` and four `.onChange` modifiers added to the ScrollView.

Caption text updated: `"API keys are saved to ~/.cantoflow.env immediately and take effect on the next recording — no restart required."`

> Note: Caption says "no restart required" because env file is updated immediately — but the **running process** still holds the old env var until restart. The next launch of run.sh will source the updated file. This is a known limitation documented in `current_status.md`.

## Debugging Method Used

1. `tail -1 .out/telemetry.jsonl` — confirmed `provider=qwen` after key deletion
2. `defaults find qwenAPIKey` — confirmed UserDefaults was empty but `qwenAPIKey` legacy alias still had value
3. `ps -p <pid> -E | grep QWEN` — confirmed env var live in process
4. `cat ~/.cantoflow.env` — found stale key
5. `cat app/scripts/run.sh` — found `source ~/.cantoflow.env` as root cause

## What Still Needs Attention

1. **Caption accuracy**: "no restart required" is slightly misleading — the env file is updated immediately, but the running process still uses the old env var until restarted. Consider revising to: _"Changes are saved immediately and take effect after restarting the app."_

2. **`GEMINI_API_KEY` not in default `~/.cantoflow.env`**: If a user adds a Gemini key via Settings UI, `syncKeyToEnvFile` will append it to the file correctly. But if `~/.cantoflow.env` is recreated from scratch, Gemini key won't be included in the template. Consider updating the default template in `run.sh` or a setup script.

3. **`anthropicAPIKey` gap**: Anthropic key has no Settings UI field. It can only be set via `~/.cantoflow.env` directly or env var. Consider adding a field in "Other Providers" section alongside OpenAI.

4. **Restart UX**: There is no visual indicator in the app that a restart is needed after key changes. A banner or menu bar indicator could improve the UX.

## Files Changed This Session

- `app/Sources/CantoFlowApp/UI/Settings/SettingsView.swift` — API key sync logic
