# CantoFlow Memory

Last updated: 2026-03-14

## Current State

- Repo builds successfully with `swift build -c release` in [CantoFlow_c](/Volumes/JTDev/CantoFlow/CantoFlow_c).
- `install.sh` now bootstraps fresh clones, including `whisper.cpp`, `whisper-cli`, models, and CLI setup.
- Local STT is working on this machine.
- Menu bar app now supports:
  - selectable input device
  - menu bar display of current input device
  - working Launch at Login via LaunchAgent
  - API key management UI with masked display and endpoint test
  - Gemini and Qwen polish support
  - vocabulary starter packs, export/import, and import preview

## Polish / LLM Notes

- Gemini endpoint issue was caused by `gemini-2.0-flash` returning `404` for new users.
- Default Gemini model was changed to `gemini-2.5-flash`.
- Cantonese polish prompt was strengthened to:
  - preserve Hong Kong colloquial wording
  - avoid converting口語 to formal written Chinese
  - prioritize vocabulary terms for same-sound / near-sound corrections
- Qwen polish quality is now reported by user as "幾乎完美" on a realistic Cantonese sentence.

## Vocabulary Notes

- Personal vocabulary currently loads `210` entries on this machine.
- Built-in HK common vocabulary currently loads `421` terms.
- Starter Pack #1 and #2 exist.
- Manual add/edit now warns on duplicates.
- Import now supports preview / dedup reporting before commit.

## Known Warnings

- Terminal may still show:
  - `Application performed a reentrant operation in its NSTableView delegate`
  - `error messaging the mach port for IMKCFRunLoopWakeUpReliable`
- These do not currently appear to block core STT or insertion flow.
- Vocabulary UI was further hardened by replacing `List` with `ScrollView + LazyVStack` and removing `.searchable`.

## Important Files

- [install.sh](/Volumes/JTDev/CantoFlow/install.sh)
- [handover_20260314.md](/Volumes/JTDev/CantoFlow/CantoFlow_c/handover/handover_20260314.md)
- [TextPolisher.swift](/Volumes/JTDev/CantoFlow/CantoFlow_c/Sources/CantoFlowApp/Core/TextPolisher.swift)
- [VocabularyStore.swift](/Volumes/JTDev/CantoFlow/CantoFlow_c/Sources/CantoFlowApp/Core/Vocabulary/VocabularyStore.swift)
- [SettingsView.swift](/Volumes/JTDev/CantoFlow/CantoFlow_c/Sources/CantoFlowApp/UI/Settings/SettingsView.swift)

## Next Likely Follow-ups

- Validate the updated repo on the original MacBook Air M1.
- If warnings persist, inspect remaining AppKit bridge points in Settings `Form`, `Picker`, and `TabView`.
- Expand Hong Kong colloquial vocabulary packs toward the 500-term target.
