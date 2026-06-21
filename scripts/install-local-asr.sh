#!/usr/bin/env bash
set -euo pipefail

ENGINE="all"
if [[ "${1:-}" == "--engine" && -n "${2:-}" ]]; then
    ENGINE="$2"
fi

case "$ENGINE" in
    all|sensevoice|qwen3-asr) ;;
    *) echo "Unknown engine: $ENGINE (use sensevoice, qwen3-asr, or all)" >&2; exit 2 ;;
esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ASR_HOME="${CANTOFLOW_ASR_HOME:-$HOME/Library/Application Support/CantoFlow/asr-runtime}"
VENV="$ASR_HOME/venv"
MODELS_DIR="$ASR_HOME/models"
SENSE_DIR="$MODELS_DIR/sensevoice-small-int8-2025-09-09"
QWEN_DIR="$MODELS_DIR/qwen3-asr-0.6b-8bit"
SENSE_ARCHIVE="sherpa-onnx-sense-voice-zh-en-ja-ko-yue-int8-2025-09-09.tar.bz2"
SENSE_URL="https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/$SENSE_ARCHIVE"

find_uv() {
    if command -v uv >/dev/null 2>&1; then command -v uv; return; fi
    if [[ -x "$HOME/.local/bin/uv" ]]; then echo "$HOME/.local/bin/uv"; return; fi
    if [[ -x "/opt/homebrew/bin/uv" ]]; then echo "/opt/homebrew/bin/uv"; return; fi
    return 1
}

UV="$(find_uv || true)"
if [[ -z "$UV" ]]; then
    echo "uv is required. Install it with: brew install uv" >&2
    exit 2
fi

mkdir -p "$ASR_HOME" "$MODELS_DIR" "$ASR_HOME/cache"
if [[ ! -x "$VENV/bin/python3" ]]; then
    echo "Creating Python 3.12 runtime…"
    "$UV" venv --python 3.12 "$VENV"
fi

PYTHON="$VENV/bin/python3"
export UV_CACHE_DIR="$ASR_HOME/cache/uv"
export HF_HOME="$ASR_HOME/cache/huggingface"
# Override both cache vars so a user-set value (possibly on a removable volume)
# can't redirect the download away from the app-local cache.
export HF_HUB_CACHE="$ASR_HOME/cache/huggingface/hub"
export HUGGINGFACE_HUB_CACHE="$ASR_HOME/cache/huggingface/hub"

install_common() {
    "$UV" pip install --python "$PYTHON" "opencc-python-reimplemented==0.1.7"
}

install_sensevoice() {
    echo "Installing SenseVoice runtime…"
    "$UV" pip install --python "$PYTHON" "sherpa-onnx==1.13.3" "soundfile==0.13.1"

    if [[ -f "$SENSE_DIR/model.int8.onnx" && -f "$SENSE_DIR/tokens.txt" ]]; then
        echo "SenseVoiceSmall INT8 is already installed."
        return
    fi

    local temp_dir extracted_dir
    temp_dir="$(mktemp -d)"
    echo "Downloading SenseVoiceSmall INT8 (about 166 MB)…"
    curl -L --fail --retry 3 --progress-bar "$SENSE_URL" -o "$temp_dir/$SENSE_ARCHIVE"
    tar -xjf "$temp_dir/$SENSE_ARCHIVE" -C "$temp_dir"
    extracted_dir="$temp_dir/${SENSE_ARCHIVE%.tar.bz2}"
    [[ -f "$extracted_dir/model.int8.onnx" ]] || { echo "SenseVoice archive is incomplete" >&2; exit 3; }
    rm -rf "$SENSE_DIR"
    mv "$extracted_dir" "$SENSE_DIR"
    rm -rf "$temp_dir"
    echo "SenseVoiceSmall INT8 ready."
}

install_qwen() {
    echo "Installing Qwen3-ASR MLX runtime…"
    "$UV" pip install --python "$PYTHON" "mlx-qwen3-asr==0.3.5"

    # Treat as installed only when BOTH the 8-bit checkpoint AND the base HF
    # snapshot are present — mlx_qwen3_asr.load_model still resolves the base repo
    # ("Qwen/Qwen3-ASR-0.6B") via the local HF cache at runtime, so the snapshot
    # must stay. (Earlier builds deleted it, which broke offline loading with
    # "Cannot find an appropriate cached snapshot folder".)
    # Match the runtime loader: refs/main must point to a snapshot that has
    # config.json + tokenizer (vocab.json, merges.txt). A bare repo / orphan
    # snapshot is NOT usable offline.
    local repo_dir="$HF_HOME/hub/models--Qwen--Qwen3-ASR-0.6B"
    local sha snapshot_ok=0
    sha="$(tr -d '[:space:]' < "$repo_dir/refs/main" 2>/dev/null || true)"
    if [[ -n "$sha" && -f "$repo_dir/snapshots/$sha/config.json" \
        && -f "$repo_dir/snapshots/$sha/vocab.json" && -f "$repo_dir/snapshots/$sha/merges.txt" ]]; then
        snapshot_ok=1
    fi
    if [[ -f "$QWEN_DIR/config.json" ]] \
        && find "$QWEN_DIR" -maxdepth 1 -name '*.safetensors' -print -quit | grep -q . \
        && [[ "$snapshot_ok" == "1" ]]; then
        echo "Qwen3-ASR 0.6B 8-bit is already installed."
        return
    fi

    rm -rf "$QWEN_DIR"
    "$PYTHON" "$SCRIPT_DIR/prepare_qwen3_asr.py" \
        --model "Qwen/Qwen3-ASR-0.6B" \
        --bits 8 \
        --group-size 64 \
        --output-dir "$QWEN_DIR"

    # IMPORTANT: keep the base HF snapshot under $HF_HOME — runtime load_model
    # needs it (offline). It lives inside the app's asr-runtime so it is local,
    # always-present, and independent of the user's global HF cache (which may be
    # on a removable volume).
}

install_common
if [[ "$ENGINE" == "all" || "$ENGINE" == "sensevoice" ]]; then install_sensevoice; fi
if [[ "$ENGINE" == "all" || "$ENGINE" == "qwen3-asr" ]]; then install_qwen; fi

# uv's wheel/download cache is app-specific and no longer needed after the
# environment has been populated.
rm -rf "$UV_CACHE_DIR"

echo "Local ASR installation complete: $ENGINE"
