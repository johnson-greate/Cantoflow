#!/usr/bin/env python3
"""Small process bridge between the Swift app and local ASR runtimes."""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path


def to_hong_kong_traditional(text: str, enabled: bool) -> str:
    if not enabled:
        return text
    try:
        from opencc import OpenCC

        return OpenCC("s2hk").convert(text)
    except Exception as exc:  # Keep ASR usable if OpenCC is unavailable.
        print(f"warning: Traditional Chinese conversion skipped: {exc}")
        return text


def transcribe_sensevoice(audio: Path, model_dir: Path) -> tuple[str, str]:
    import sherpa_onnx
    import soundfile as sf

    model = model_dir / "model.int8.onnx"
    tokens = model_dir / "tokens.txt"
    if not model.is_file() or not tokens.is_file():
        raise FileNotFoundError(f"SenseVoice model is incomplete: {model_dir}")

    recognizer = sherpa_onnx.OfflineRecognizer.from_sense_voice(
        model=str(model),
        tokens=str(tokens),
        num_threads=max(1, min(4, os.cpu_count() or 1)),
        language="yue",
        use_itn=True,
        debug=False,
    )
    samples, sample_rate = sf.read(str(audio), dtype="float32", always_2d=True)
    stream = recognizer.create_stream()
    stream.accept_waveform(sample_rate, samples[:, 0])
    recognizer.decode_stream(stream)
    return stream.result.text.strip(), "yue"


def transcribe_qwen(audio: Path, model_dir: Path, context: str) -> tuple[str, str]:
    from mlx_qwen3_asr import transcribe

    result = transcribe(
        str(audio),
        model=str(model_dir),
        language="Cantonese",
        context=context,
        verbose=False,
    )
    return result.text.strip(), result.language


def atomic_write(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(text, encoding="utf-8")
    temporary.replace(path)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--engine", required=True, choices=("sensevoice", "qwen3-asr"))
    parser.add_argument("--audio", required=True, type=Path)
    parser.add_argument("--model-dir", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--context", default="")
    parser.add_argument("--traditional", action="store_true")
    args = parser.parse_args()

    if not args.audio.is_file():
        raise FileNotFoundError(args.audio)

    if args.engine == "sensevoice":
        text, language = transcribe_sensevoice(args.audio, args.model_dir)
    else:
        text, language = transcribe_qwen(args.audio, args.model_dir, args.context)

    text = to_hong_kong_traditional(text, args.traditional).strip()
    if not text:
        raise RuntimeError("ASR returned empty text")

    atomic_write(args.output, text)
    print(json.dumps({"engine": args.engine, "language": language, "chars": len(text)}, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
