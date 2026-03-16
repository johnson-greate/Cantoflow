# CantoFlow — Current Status
_Last updated: 2026-03-16_

---

## macOS App

| Feature | Status |
|---|---|
| Push-to-talk STT (Whisper) | Working |
| LLM Polish (Qwen/DashScope) | Working |
| FastIME raw paste + replace | Working |
| Vocabulary injection | Working |
| Correction watcher (vocab learning) | Working |
| Telemetry logging | Working |
| Settings UI — General / Vocabulary / API Keys tabs | Working |
| Settings ↔ `~/.cantoflow.env` bidirectional sync | Working |
| Restart modal on API key change | Working |
| Launch at Login | Working |

---

## Windows App — Overall State

**Status: Working but STT too slow (~20–25s). OpenVINO setup in progress.**

Calvin's machine: Core i5 12th gen, Intel Iris Xe integrated GPU, no NVIDIA GPU.
End-to-end pipeline confirmed working: hotkey → NAudio record → whisper-cli → QWEN polish → clipboard paste.

### What Works
- Tray menu matches macOS layout (header · hotkey hint · input device · **Start/Stop Recording** · 上次 stats · Copy Last Result · Open Output Folder · Quit · Version)
- Recording overlay capsule: dark pill, bottom-center of screen, 🎙 Recording… / ⏳ Transcribing…, green RMS level bar
- Hotkey configurable via Settings UI (click textbox, press combo, save)
- API keys masked + saved to `%APPDATA%\CantoFlow\cantoflow.env`
- HK vocabulary starter packs 1+2 injected into Whisper `--prompt` and LLM polish prompt
- QWEN LLM polish working (~1s)
- Telemetry logged to `%APPDATA%\CantoFlow\.out\telemetry.jsonl`

---

## Windows STT Configuration

### Models in `%APPDATA%\CantoFlow\models\`
| File | Size | Active? |
|---|---|---|
| `ggml-base.bin` | 144 MB | No — too small, hallucinates |
| `ggml-large-v3-turbo.bin` | 1.5 GB | No — q5_0 takes priority |
| `ggml-large-v3-turbo-q5_0.bin` | 560 MB | **YES** (priority #1 in AppConfig) |

AppConfig preference order: `q5_0` → `large-v3-turbo` → `large-v3` → `medium` → `base`

### Binary in `%APPDATA%\CantoFlow\`
- **Current**: `whisper-bin-x64.zip` (Jan 15 2026, from ggml-org/whisper.cpp)
- **OpenVINO built-in**: confirmed via `--help` → `-oved D, --ov-e-device DNAME [CPU]`

### WhisperRunner flags (latest)
```
-m <model> -f <wav> -otxt -l auto --no-timestamps -t 8
```
- `-l auto`: auto-detect language (was `yue` → caused "今h今h" hallucination)
- `-t 8`: use all CPU threads
- Stdout + stderr drained concurrently to prevent pipe buffer deadlock

---

## OpenVINO Setup — IN PROGRESS on Calvin's machine

**Goal**: Intel Iris Xe GPU encoder inference → target ~3–6s STT

### Steps done
- [x] `pip install openvino` → openvino 2026.0.0
- [x] `pip install openai-whisper` → installed (torch + deps)
- [x] `git clone https://github.com/ggml-org/whisper.cpp C:\whisper-src`
- [ ] **STUCK** at: `python models\convert-whisper-to-openvino.py --model large-v3-turbo`

### Error
```
ImportError: cannot import name 'mo' from 'openvino.tools'
```
`openvino.tools.mo` (Model Optimizer) was removed in openvino 2024+.

### Next step to try
```powershell
pip install "openvino-dev[pytorch,onnx]"
python C:\whisper-src\models\convert-whisper-to-openvino.py --model large-v3-turbo
```
If that fails, downgrade:
```powershell
pip install "openvino==2023.3.0" "openvino-dev[pytorch,onnx]==2023.3.0"
python C:\whisper-src\models\convert-whisper-to-openvino.py --model large-v3-turbo
```

### Once encoder XML is generated
```powershell
copy C:\whisper-src\ggml-large-v3-turbo-encoder-openvino.xml "%APPDATA%\CantoFlow\models\"
copy C:\whisper-src\ggml-large-v3-turbo-encoder-openvino.bin "%APPDATA%\CantoFlow\models\"
```
App auto-detects XML via `AppConfig.WhisperOpenVinoEncoder` → adds `-oved GPU` automatically.

---

## Windows Bug History (this session)

| Output | Cause | Fix |
|---|---|---|
| "【獲獎】賈麥麵" | `ggml-base.bin` + `-l zh` | Auto-detect model + `-l yue` |
| "HQw 曼HQw" | `Arguments` string mangles UTF-8 CJK chars | Switch to `ArgumentList` |
| 39s STT | Stdout pipe buffer deadlock + no `-t` threads | Drain pipes concurrently + `-t 8` |
| "I 游h 游b" | BLAS build incompatible with q5_0 model | Revert to `whisper-bin-x64` |
| "I Ζ Ζ Ζ" | BLAS build + unrecognised `--beam-size` flag | Remove `--best-of 1 --beam-size 1` |
| "今h 今h" | `-l yue` not supported in new binary | Change to `-l auto` |

---

## Latest Commits (Windows)
```
17ee7cb  fix: -l auto instead of yue; fix OpenVINO flag name to -oved
aaedf02  fix: remove --best-of/--beam-size, restore beam search
e55e2c7  fix: q5_0 first in model priority; auto-detect OpenVINO encoder
f61d125  fix: ArgumentList for UTF-8 encoding; overlay bottom-center
80a2edf  fix: large-v3-turbo auto-detect, -l yue, center overlay
d7c786a  feat: tray menu matches macOS + recording overlay capsule
```

---

## Pending Features

| Feature | Priority | Notes |
|---|---|---|
| OpenVINO encoder conversion | 🔴 High | Blocked on `openvino-dev` import error |
| `Version 00000000.0000` fix | 🟡 Medium | BuildVersion not set on Windows |
| Vocabulary list UI in Settings | 🟡 Medium | Matching macOS add/edit/remove UI |
| Keychron mic button mapping | 🟡 Medium | Test on real hardware first |
| Inno Setup installer | 🟢 Low | After STT speed is acceptable |
| Android IME thin client | ⏸ Deferred | |
| iOS IME thin client | ⏸ Deferred | |
