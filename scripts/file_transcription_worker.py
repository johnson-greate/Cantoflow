#!/usr/bin/env python3
"""Batch file-transcription worker for CantoFlow Transcribe.

Loads Qwen3-ASR once and processes a manifest of files sequentially, streaming
JSONL progress events on stdout. Diagnostics go to stderr only. This worker is
SEPARATE from the push-to-talk bridge (local_asr_bridge.py) and must not change
that contract.

Contract: docs/transcribe/spec.md §15.
"""

from __future__ import annotations

import argparse
import json
import sys
import time
import traceback
from pathlib import Path


def emit(event: dict) -> None:
    """Write one JSONL event to stdout and flush immediately."""
    sys.stdout.write(json.dumps({"v": 1, **event}, ensure_ascii=False) + "\n")
    sys.stdout.flush()


def log(message: str) -> None:
    """Diagnostics go to stderr; stdout is reserved for JSONL events."""
    sys.stderr.write(message + "\n")
    sys.stderr.flush()


def to_hk_traditional(text: str, enabled: bool) -> str:
    if not enabled:
        return text
    try:
        from opencc import OpenCC

        return OpenCC("s2hk").convert(text)
    except Exception as exc:  # keep transcript usable if OpenCC missing
        log(f"warning: OpenCC s2hk skipped: {exc}")
        return text


def atomic_write(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(text, encoding="utf-8")
    tmp.replace(path)


def load_manifest(path: Path) -> tuple[list[dict], str]:
    data = json.loads(path.read_text(encoding="utf-8"))
    files = data.get("files")
    if not isinstance(files, list) or not files:
        raise ValueError("manifest has no files")
    for entry in files:
        if not entry.get("id") or not entry.get("input_wav") or not entry.get("output_txt"):
            raise ValueError("manifest file entry missing id/input_wav/output_txt")
    return files, (data.get("context") or "")


def run(files: list[dict], context: str, model, transcribe, traditional: bool) -> int:
    """Process all files with a pre-loaded model. Returns process exit code."""
    total = len(files)
    emit({"event": "worker_ready", "total_files": total})

    succeeded = 0
    failed = 0
    batch_start = time.monotonic()

    for index, entry in enumerate(files, start=1):
        file_id = entry["id"]
        input_wav = entry["input_wav"]
        output_txt = Path(entry["output_txt"])
        emit({"event": "file_started", "file_id": file_id, "file_index": index, "total_files": total})
        started = time.monotonic()
        try:
            if not Path(input_wav).is_file():
                raise FileNotFoundError(input_wav)

            def on_progress(payload: dict, _file_id: str = file_id) -> None:
                if "progress" not in payload:
                    return
                emit({
                    "event": "asr_progress",
                    "file_id": _file_id,
                    "progress": float(payload.get("progress", 0.0) or 0.0),
                    "chunk_index": int(payload.get("chunk_index", 0) or 0),
                    "total_chunks": int(payload.get("total_chunks", 0) or 0),
                    "processed_audio_sec": float(payload.get("processed_audio_sec", 0.0) or 0.0),
                    "audio_duration_sec": float(payload.get("audio_duration_sec", 0.0) or 0.0),
                })

            result = transcribe(
                input_wav,
                model=model,
                context=context,
                language="Cantonese",
                return_timestamps=False,
                diarize=False,
                return_chunks=False,
                verbose=False,
                on_progress=on_progress,
            )

            text = to_hk_traditional((result.text or "").strip(), traditional).strip()
            if not text:
                emit({"event": "file_failed", "file_id": file_id, "code": "empty_transcript",
                      "message": "未辨識到語音內容"})
                failed += 1
                continue

            atomic_write(output_txt, text)
            emit({
                "event": "file_completed",
                "file_id": file_id,
                "output_txt": str(output_txt),
                "chars": len(text),
                "language": result.language or "",
                "truncated": bool(getattr(result, "truncated", False)),
                "duration_ms": int((time.monotonic() - started) * 1000),
            })
            succeeded += 1
        except Exception as exc:  # individual file failure → continue with the rest
            log(f"file {file_id} failed: {exc}\n{traceback.format_exc()}")
            emit({"event": "file_failed", "file_id": file_id, "code": "transcribe_failed",
                  "message": str(exc)[:200]})
            failed += 1

    emit({"event": "batch_completed", "succeeded": succeeded, "failed": failed,
          "duration_ms": int((time.monotonic() - batch_start) * 1000)})
    return 0


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--manifest", required=True, type=Path)
    parser.add_argument("--model-dir", required=True, type=Path)
    parser.add_argument("--output-dir", required=True, type=Path)  # informational
    parser.add_argument("--traditional", action="store_true")
    args = parser.parse_args()

    # Worker-level failures (manifest / model) → non-zero exit.
    try:
        files, context = load_manifest(args.manifest)
    except Exception as exc:
        log(f"manifest error: {exc}")
        return 2

    try:
        from mlx_qwen3_asr import load_model, transcribe
        model, _ = load_model(str(args.model_dir))
    except Exception as exc:
        log(f"model load failed: {exc}\n{traceback.format_exc()}")
        return 3

    return run(files, context, model, transcribe, args.traditional)


if __name__ == "__main__":
    raise SystemExit(main())
