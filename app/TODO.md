# CantoFlow TODO

## Phase 3 - UI Polish & Features

### High Priority

- [ ] **SwiftUI Settings Window** - Replace alert-based vocabulary UI
  - Proper table view with edit/delete per item
  - Search/filter functionality
  - Category management (place, person, slang, etc.)
  - Export functionality
  - Use `NSHostingController` to embed in AppKit app
  - File: `Sources/CantoFlowApp/UI/Settings/VocabularySettingsWindow.swift`

- [ ] **Preferences Window** - General app settings
  - Trigger key selection (with live preview)
  - STT backend selection (Whisper/FunASR)
  - Polish provider selection
  - Fast IME toggle
  - Overlay display mode
  - Startup at login

### Medium Priority

- [ ] **Overlay improvements**
  - Add recording duration timer
  - Show transcription preview in real-time
  - Animated status transitions

- [ ] **Vocabulary features**
  - Bulk import from CSV
  - Sync across devices (iCloud)
  - Vocabulary categories with toggles
  - Frequency tracking (most used terms)

- [ ] **Audio feedback**
  - Optional beep on recording start/stop
  - Haptic feedback (if supported)

### Low Priority

- [ ] **Statistics dashboard**
  - Daily/weekly usage charts
  - Accuracy trends
  - Most corrected words

- [ ] **Keyboard shortcuts**
  - Customizable hotkeys
  - Global shortcut for quick settings access

- [ ] **Localization**
  - English UI strings
  - Simplified Chinese option

---

## Technical Debt

- [ ] Fix NSTableView crashes (investigate view lifecycle)
- [ ] Add unit tests for VocabularyStore
- [ ] Add UI tests for overlay panel
- [ ] Code signing and notarization for distribution
- [ ] DMG installer package

---

## Completed

- [x] Push-to-Talk mode (Phase 2)
- [x] Vocabulary injection (Phase 2)
- [x] Compact overlay design (0.2.1)
- [x] Version display in menu (0.2.1)
- [x] Vocabulary management (alert-based, 0.2.1)
- [x] Overlay position drift fix (0.2.1)
