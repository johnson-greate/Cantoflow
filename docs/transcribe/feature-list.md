# Transcribe File — feature list

**Status:** v1 scope locked with Johnson on 2026-06-21

**Implementation spec:** [`spec.md`](spec.md)

## CantoFlow Transcribe v1 baseline

- **引擎：** 固定使用 Qwen3-ASR 0.6B MLX 8-bit，產品只輸出 plain text；沒有 Segments、時間戳、reflow 或播放器同步，因此不需要先修 portable Whisper。
- **流程：** 拖放／選檔 + batch queue → AVFoundation 正規化音頻 → Qwen3 本機轉錄（internal chunking + 真實進度）→ Plain Text（Copy／TXT export）→ 一 click 生成會議記錄（摘要／決議／待辦／跟進人）→ MD／TXT export。
- **v1 輸入：** WAV、MP3、M4A；每個檔案視為獨立會議。
- **延後／不做：** 講者分離、影片格式、逐段 AI、時間戳、播放器、segment editing。
- **入口：** Menu 新增「轉錄檔案…」。
- **私隱：** 音頻只在本機處理；用戶點擊生成會議記錄後，才按目前 LLM provider 設定傳送完整逐字稿文字。

### Engineering reality check

- 目前 pin 的 `mlx-qwen3-asr==0.3.5` 已內建約 30 秒 energy-based chunking，並透過 `on_progress` 回傳 chunk progress。**不要在 Swift 重造 chunker。**
- 主要工程工作是：用 AVFoundation 產生 16 kHz mono WAV（避免依賴 ffmpeg）、以單一 Python worker 一次載入模型處理全 batch、把 JSONL progress／取消／錯誤接入 UI，以及建立整份 transcript 專用的 meeting-notes LLM request。
- File batch 與 push-to-talk 必須互斥，避免同時載入兩個 Qwen process。

---

## Competitor reference — inferred from Spokenly screenshots

Source: 7 reference screenshots in `refs/` (Spokenly's "Transcribe File" feature).
This section records the competitor feature set for reference. It is **not** the
CantoFlow v1 commitment; the locked scope above and `spec.md` take precedence.

## A. File input
- **Drag-and-drop zone** ("Drop your files here") + click to add.
- **Audio + video formats**: MP3, WAV, M4A, FLAC, OPUS, OGG, MP4, MOV, M4V.
  (Video = transcribe the audio track.)
- **Batch**: queue multiple files, "+ Add more files".
- Each queued file shows **duration + file size** + waveform thumbnail.
- "Ready to transcribe" modal with a big **Transcribe** action.

## B. Engine
- Model selector shown as "Whisper v3 Turbo" (gear icon → selectable).
- CantoFlow already has the engine abstraction (Whisper / SenseVoice / Qwen3).

## C. Output views
- **Plain Text** tab — full transcript, scrollable, **Copy** button.
- **Segments** tab — list of segments, each with **start timestamp + duration**
  (e.g. `00:06.399 · 5.0s`) and an **editable** text box.
- **+ Merge** control between adjacent segments.

## D. Segment Reflow
- Re-chunk the transcript: **By Characters / By Words** toggle.
- Slider: "characters to keep in each segment" (e.g. 50).
- **Apply Reflow** button.

## E. AI Processing
- Free-text box: "Ask AI to modify the entire transcript or a specific segment".
- Scope dropdown: "Process all at once" (vs per-segment).
- **Send** to run the LLM over the transcript.
- → This is where CantoFlow's **會議記錄 / meeting-notes** generation lives
  (a preset prompt: summary + decisions + action items).

## F. Speaker Identification
- Collapsible section (diarization — who said what).

## G. Export Options
- Collapsible section (likely txt / srt / vtt / md, etc.).

## H. Built-in audio player
- Play / scrub bar + elapsed/total (`00:00 / 01:59`), for reviewing against audio.

---

## Historical decision log (settled with Johnson 2026-06-20)

1. **Engine = Qwen3-ASR, plain text only — NO timestamps.** Johnson does not
   insist on the timestamp-dependent features. So the **Segments view, per-segment
   timestamps, Segment Reflow, and the synced audio player are OUT of scope.**
   This removes the Whisper/timestamp dependency entirely — no portable-whisper
   work needed for transcribe. (Could revisit only if a timestamped engine is
   added later.)
2. **Long audio:** meetings are 30–60 min, so show real chunk progress. Follow-up
   inspection confirmed the pinned MLX runtime already owns energy-based chunking;
   CantoFlow should bridge its progress rather than implement a second chunker.
3. **會議記錄 output:** one-click **"生成會議記錄"** preset (摘要 / 決議 / 待辦 /
   跟進人) over the plain-text transcript, output as Markdown. Reuse existing
   TextPolisher LLM plumbing (DeepSeek/Qwen/Ollama).
4. **v1 scope:** file input (drag-drop + batch) → Qwen3 transcribe (chunked, with
   progress) → **Plain Text** result (Copy) → **AI meeting-notes preset** →
   export (md / txt). **Defer/out:** Segments + timestamps + reflow + player-sync,
   Speaker Identification, per-segment AI, video formats (start audio-only).
5. **Entry point:** new menu item "轉錄檔案…" → window (file drop + result),
   reusing the local-ASR runner already wired for push-to-talk.
