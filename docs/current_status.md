# CantoFlow — Current Status
_Last updated: 2026-03-17_

---

## macOS App

| Feature | Status |
|---|---|
| Push-to-talk STT (Whisper) | ✅ Working |
| LLM Polish (Qwen/DashScope) | ✅ Working |
| FastIME raw paste + replace | ✅ Working |
| Vocabulary injection | ✅ Working |
| Correction watcher (vocab learning) | ✅ Working |
| Telemetry logging | ✅ Working |
| Settings UI — General / Vocabulary / API Keys tabs | ✅ Working |
| Settings ↔ `~/.cantoflow.env` bidirectional sync | ✅ Working |
| Restart modal on API key change | ✅ Working |
| Launch at Login | ✅ Working |

---

## Windows App

**Status: Working. STT ~16s (Vulkan GPU on Intel Iris Xe). Accuracy excellent.**

Calvin's machine: Core i5 12th gen, Intel Iris Xe integrated GPU.
End-to-end pipeline confirmed: hotkey → NAudio record → whisper-cli (Vulkan) → QWEN polish → clipboard paste.
Cantonese accuracy confirmed good — "昨晚我食咗過橋米線，今早六點半起身，慢慢抹洗，慢慢出門，返到公司天氣好好" recognised correctly.

### What Works
- Tray menu matches macOS layout (header · hotkey hint · input device · **Start/Stop Recording** · 上次 stats · Copy Last Result · Open Output Folder · Quit · Version)
- Recording overlay capsule: dark pill, bottom-center of screen, 🎙 Recording… / ⏳ Transcribing…, green RMS level bar
- Hotkey configurable via Settings UI
- API keys masked + saved to `%APPDATA%\CantoFlow\cantoflow.env`
- Vocabulary tab in Settings: personal terms add/edit/remove, category filter, search, Starter Pack #1/#2 import
- Personal vocabulary persisted to `%APPDATA%\CantoFlow\personal_vocab.json`
- HK vocabulary starter packs 1+2 injected into Whisper `--prompt` and LLM polish prompt
- QWEN LLM polish working (~1–2s)
- Version number: runtime exe mtime format `yyyyMMdd.HHmm` (e.g. `20260316.1844`) ✅ Fixed
- Telemetry logged to `%APPDATA%\CantoFlow\.out\telemetry.jsonl`

---

## Windows STT Configuration

### Binary in `%APPDATA%\CantoFlow\`
- **Current**: `whisper-cli.exe` — **Vulkan build** (built from source with `-DGGML_VULKAN=ON`)
- Hosted on GitHub Releases as `whisper-vulkan-win-x64.zip` (17 MB)
  - Tag: `whisper-vulkan-v1.0` at https://github.com/johnson-greate/Cantoflow/releases
- Vulkan device confirmed: `Intel(R) UHD Graphics (Intel Corporation) | uma: 1 | fp16: 1`

### Models in `%APPDATA%\CantoFlow\models\`
| File | Size | Active? |
|---|---|---|
| `ggml-large-v3-turbo-q5_0.bin` | 560 MB | **YES** (priority #1 in AppConfig) |
| `ggml-large-v3-turbo.bin` | 1.5 GB | No — q5_0 takes priority |

AppConfig preference order: `q5_0` → `large-v3-turbo` → `large-v3` → `medium` → `base`

### WhisperRunner flags
```
-m <model> -f <wav> -otxt -l auto --no-timestamps -t 8 -ac 768 -bo 1 -bs 1
```
- `-l auto`: auto-detect language (廣東話 correctly identified)
- `-ac 768`: audio context 768 = halves encoder time
- `-bo 1 -bs 1`: greedy decode (faster, no quality loss for Cantonese)
- `-t 8`: use all CPU threads
- Uses `ArgumentList` (not `Arguments`) to avoid UTF-8 CJK corruption on Windows
- Stdout + stderr drained concurrently to prevent 4KB pipe buffer deadlock
- OpenVINO: auto-detects `*-encoder-openvino.xml` in models dir → adds `-oved GPU`

### Speed (Intel Iris Xe, Vulkan)
| Audio length | STT time |
|---|---|
| ~11s | ~6.7s |
| ~17s | ~16s |

---

## Windows Bug History

| Output | Cause | Fix |
|---|---|---|
| "【獲獎】賈麥麵" | `ggml-base.bin` + `-l zh` | Auto-detect model + `-l auto` |
| "HQw 曼HQw" | `Arguments` string mangles UTF-8 CJK | Switch to `ArgumentList` |
| 39s STT | Stdout pipe buffer deadlock | Drain pipes concurrently |
| "I 游h 游b" | BLAS build incompatible with q5_0 | Revert to `whisper-bin-x64` |
| "I Ζ Ζ Ζ" | BLAS build + unrecognised flags | Remove BLAS build |
| "今h 今h" | `-l yue` unsupported in new binary | Change to `-l auto` |
| STT 49s → 16s | CPU-only binary | Build Vulkan from source |
| `Version 00000000.0000` | Compile-time const, no bundle on SPM | Runtime exe mtime |

---

## Corporate STT Server — PLANNED (hardware pending)

**Goal**: Shared Whisper service on 8× Intel Arc A770 Linux server for 5 users (LAN + VPN).

**Hardware** (OEM by 震有智聯 + Intel 大灣區創新中心):
- CPU: 2× Intel 6530
- RAM: 512 GB (16×32 GB)
- GPU: **8× Intel Arc A770** (16 GB each)
- Network: Dual 10 GbE

**Expected STT speed on server**: ~1–2s per utterance (vs ~16s on client Iris Xe)

**Implementation plan**: `docs/plans/2026-03-17-corporate-stt-server.md`

**Architecture** (when server arrives):
```
Client (macOS/Windows) → HTTPS + Bearer Token
                         ↓
  CantoFlow.Server (.NET, systemd on Linux)
  ├── Auth: Bearer token per user (/etc/cantoflow/tokens.conf)
  ├── GPU Worker Pool: 8 slots, GGML_VK_VISIBLE_DEVICES=N
  ├── WhisperRunner: real whisper-cli via Vulkan
  └── Polish: Qwen API → Ollama local LLM → raw text
```

**Blocked on**: hardware customs/logistics clearance (ETA unknown as of 2026-03-17)

---

## Pending Features

| Feature | Priority | Notes |
|---|---|---|
| Corporate STT server | 🔴 High | Blocked on hardware arrival; plan written |
| Keychron mic button mapping | 🟡 Medium | Test on real hardware first |
| Inno Setup installer | 🟢 Low | After STT speed acceptable on all clients |
| Android IME thin client | ⏸ Deferred | After server is live |
| iOS IME thin client | ⏸ Deferred | After server is live |

---

## Recent Commits
```
91378bc  docs: add corporate STT server implementation plan
a1ced8b  feat(windows): vocabulary UI, runtime version, README Windows section
ed1533c  fix: capture finalText as let to satisfy Swift concurrency in MainActor.run
f165ff3  ci: drop macos-13 (deprecated), arm64-only binary release
8559c32  ci: add GitHub Actions build/release workflow and --prebuilt install flag
```
