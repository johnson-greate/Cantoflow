# Transcribe File — inferred feature list (from Spokenly screenshots)

Source: 7 reference screenshots in `refs/` (Spokenly's "Transcribe File" feature).
This is the inferred feature set + notes on what maps cleanly to CantoFlow's
local-ASR stack and what needs a decision. Feeds the eventual `spec.md`.

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

## CantoFlow decisions (settled with Johnson 2026-06-20)

1. **Engine = Qwen3-ASR, plain text only — NO timestamps.** Johnson does not
   insist on the timestamp-dependent features. So the **Segments view, per-segment
   timestamps, Segment Reflow, and the synced audio player are OUT of scope.**
   This removes the Whisper/timestamp dependency entirely — no portable-whisper
   work needed for transcribe. (Could revisit only if a timestamped engine is
   added later.)
2. **Long audio:** meetings are 30–60 min, so chunk the audio + show progress
   (Qwen3 has context limits). This is the main engineering work that remains.
3. **會議記錄 output:** one-click **"生成會議記錄"** preset (摘要 / 決議 / 待辦 /
   跟進人) over the plain-text transcript, output as Markdown. Reuse existing
   TextPolisher LLM plumbing (DeepSeek/Qwen/Ollama).
4. **v1 scope:** file input (drag-drop + batch) → Qwen3 transcribe (chunked, with
   progress) → **Plain Text** result (Copy) → **AI meeting-notes preset** →
   export (md / txt). **Defer/out:** Segments + timestamps + reflow + player-sync,
   Speaker Identification, per-segment AI, video formats (start audio-only).
5. **Entry point:** new menu item "轉錄檔案…" → window (file drop + result),
   reusing the local-ASR runner already wired for push-to-talk.
