# CantoFlow Changelog

## [0.2.1] - 2026-02-18

### Added
- **Version display**: Menu bar menu now shows app version at bottom
- **Vocabulary Management**: "Manage Vocabulary..." menu item (⌘,)
  - Add personal terms
  - Clear all terms
  - Import from text file
  - View current vocabulary count

### Changed
- **Compact overlay design**: Recording panel redesigned as capsule (280×56pt)
  - Dynamic Island style appearance
  - Reduced from 480×120pt to 280×56pt
  - Capsule shape (corner radius = height/2)
  - Smaller waveform (24 bars instead of 40)

### Fixed
- **Overlay position drift**: Panel no longer moves down with each recording
  - Added `targetFrame` to store correct position
  - `showWithAnimation()` now recalculates position each time
- **Menu cleanup**: Renamed "Quit CantoFlow_c" to "Quit CantoFlow"

### Known Issues
- Vocabulary settings uses simplified alert-based UI (SwiftUI rewrite planned for Phase 3)
- IMK warning message in console is harmless system noise

---

## [0.2.0] - 2026-02-17 (Phase 2)

### Added

#### Push-to-Talk (P2-C)
- **Hold-to-record mode**: Hold Fn (MacBook) or F15 (external keyboard) to record, release to process
- **Recording overlay panel**: Floating panel at screen bottom with real-time waveform animation
- **Accidental tap protection**: Recordings < 0.3 seconds are automatically cancelled
- **Auto-detect trigger key**: Automatically selects Fn for MacBook or F15 for Mac Mini/external keyboards
- **Multi-key support**: Configurable trigger keys (Fn, F12, F13, F14, F15)

#### Vocabulary System (P2-A)
- **Personal vocabulary**: Up to 500 custom terms stored locally
- **Hong Kong common vocabulary** (built-in, ~530 terms):
  - MTR stations (all lines, ~90 stations)
  - Place names (~120 districts and landmarks)
  - Common surnames (30)
  - Cantonese slang (~80 terms)
  - Food items (~60 terms)
  - Transportation (~30 terms)
- **Vocabulary injection**: Terms injected into Whisper prompts for better recognition
- **LLM vocabulary context**: Terms added to Claude system prompt for accurate corrections

#### LLM Integration (P2-B)
- **Vocabulary-aware polishing**: Claude uses vocabulary context for better corrections
- **Dynamic prompt assembly**: System prompt combines base instructions with vocabulary

### Changed
- Upgraded from toggle-recording to push-to-talk mode
- Menu bar now shows "Hold Fn or F15 to record" hint
- Improved status indicators (recording → transcribing → polishing → done)

### New Files
```
Sources/CantoFlowApp/
├── Core/
│   └── Vocabulary/
│       └── VocabularyStore.swift      # Vocabulary storage and injection
└── UI/
    ├── PushToTalkManager.swift        # Push-to-talk state machine
    └── Overlay/
        ├── RecordingOverlayPanel.swift # Floating recording panel
        ├── WaveformView.swift          # Real-time audio waveform
        └── OverlayManager.swift        # Overlay state management
```

### New CLI Options
```
--trigger-key KEY       Trigger key: auto, fn, f12, f13, f14, f15 (default: auto)
--no-overlay            Disable recording overlay panel
--no-vocabulary         Disable vocabulary injection
```

---

## [0.1.0] - 2026-02-17 (Phase 1)

### Added
- Initial CantoFlow POC with Whisper and FunASR backends
- Menu bar app with recording toggle (Fn/F12)
- LLM text polishing (OpenAI, Anthropic, Qwen)
- Fast IME mode with auto-paste and auto-replace
- Traditional Chinese output
- Telemetry logging

---

## Usage

### Build
```bash
cd CantoFlow_c
swift build
```

### Run
```bash
# Basic usage (auto-detect trigger key)
.build/debug/cantoflow --project-root /path/to/CantoFlow

# With fast IME mode (recommended)
.build/debug/cantoflow --project-root /path/to/CantoFlow --fast-ime

# Specify trigger key
.build/debug/cantoflow --project-root /path/to/CantoFlow --trigger-key f15

# Disable overlay
.build/debug/cantoflow --project-root /path/to/CantoFlow --no-overlay
```

### Environment Variables
```bash
export ANTHROPIC_API_KEY="your-api-key"  # For Claude polishing
export OPENAI_API_KEY="your-api-key"     # For GPT polishing
export QWEN_API_KEY="your-api-key"       # For Qwen polishing
```

### Permissions Required
- **Microphone**: For audio recording
- **Accessibility**: For text insertion and hotkey detection
- **Input Monitoring**: For Fn/F15 key detection

### Push-to-Talk Usage
1. Hold **Fn** (MacBook) or **F15** (external keyboard)
2. Speak in Cantonese
3. Release key to process
4. Text is automatically inserted at cursor position

The recording overlay shows:
- Real-time waveform animation
- Current status (Listening → Transcribing → Polishing → Done)
- Cancel (✕) and Done (✓) buttons
