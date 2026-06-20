#!/usr/bin/env python3
"""Download Qwen3-ASR 0.6B and save a local MLX 8-bit checkpoint.

The conversion follows mlx-qwen3-asr's upstream scripts/convert.py flow, while
using its public loader so tied weights are materialized consistently.
"""

from __future__ import annotations

import argparse
import json
import shutil
from pathlib import Path

import mlx.core as mx
import mlx.utils as mlx_utils

from mlx_qwen3_asr import load_model
from mlx_qwen3_asr.convert import quantize_model
from mlx_qwen3_asr.load_models import _ModelHolder


TOKENIZER_FILES = (
    "config.json",
    "tokenizer.json",
    "tokenizer_config.json",
    "vocab.json",
    "merges.txt",
    "special_tokens_map.json",
)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--model", default="Qwen/Qwen3-ASR-0.6B")
    parser.add_argument("--output-dir", required=True, type=Path)
    parser.add_argument("--bits", default=8, type=int, choices=(4, 8))
    parser.add_argument("--group-size", default=64, type=int)
    args = parser.parse_args()

    print(f"Downloading/loading {args.model}…", flush=True)
    model, _ = load_model(args.model, dtype=mx.float16)
    source_dir = Path(_ModelHolder.get_resolved_path(args.model, dtype=mx.float16))

    print(f"Quantizing to {args.bits}-bit…", flush=True)
    quantize_model(model, bits=args.bits, group_size=args.group_size)
    mx.eval(model.parameters())

    args.output_dir.mkdir(parents=True, exist_ok=True)
    weights = dict(mlx_utils.tree_flatten(model.parameters()))
    mx.save_safetensors(str(args.output_dir / "weights.safetensors"), weights)

    for filename in TOKENIZER_FILES:
        source = source_dir / filename
        if source.exists():
            shutil.copy2(source, args.output_dir / filename)

    (args.output_dir / "quantization_config.json").write_text(
        json.dumps({"bits": args.bits, "group_size": args.group_size}, indent=2),
        encoding="utf-8",
    )
    print(f"Qwen3-ASR {args.bits}-bit model ready: {args.output_dir}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
