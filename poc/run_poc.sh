#!/usr/bin/env bash
set -euo pipefail

SECONDS_TO_RECORD=8
WHISPER_BIN="./third_party/whisper.cpp/build/bin/whisper-cli"
MODEL_PATH="./third_party/whisper.cpp/models/ggml-small.bin"
OUT_DIR="./poc/.out"

usage() {
  cat <<EOF
Usage:
  $0 [--seconds N] [--whisper PATH] [--model PATH] [--out DIR]

Examples:
  $0
  $0 --seconds 10 --model ./third_party/whisper.cpp/models/ggml-small.bin
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --seconds)
      SECONDS_TO_RECORD="$2"
      shift 2
      ;;
    --whisper)
      WHISPER_BIN="$2"
      shift 2
      ;;
    --model)
      MODEL_PATH="$2"
      shift 2
      ;;
    --out)
      OUT_DIR="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage
      exit 1
      ;;
  esac
done

if ! command -v ffmpeg >/dev/null 2>&1; then
  echo "ffmpeg is required but not found. Install with: brew install ffmpeg" >&2
  exit 1
fi

if [[ ! -x "${WHISPER_BIN}" ]]; then
  echo "whisper binary not found/executable: ${WHISPER_BIN}" >&2
  exit 1
fi

if [[ ! -f "${MODEL_PATH}" ]]; then
  echo "model file not found: ${MODEL_PATH}" >&2
  exit 1
fi

mkdir -p "${OUT_DIR}"
STAMP="$(date +%Y%m%d_%H%M%S)"
AUDIO_WAV="${OUT_DIR}/sample_${STAMP}.wav"
RAW_PREFIX="${OUT_DIR}/raw_${STAMP}"
RAW_TXT="${RAW_PREFIX}.txt"
POLISHED_TXT="${OUT_DIR}/polished_${STAMP}.txt"

echo "[1/4] Recording ${SECONDS_TO_RECORD}s from default microphone..."
echo "      Please start speaking after 1 second..."
sleep 1

# avfoundation device ":0" picks default audio input.
ffmpeg -hide_banner -loglevel error \
  -f avfoundation -i ":0" \
  -t "${SECONDS_TO_RECORD}" \
  -ac 1 -ar 16000 -c:a pcm_s16le \
  "${AUDIO_WAV}"

echo "[2/4] Local transcription (whisper.cpp)..."
"${WHISPER_BIN}" \
  -m "${MODEL_PATH}" \
  -f "${AUDIO_WAV}" \
  -l yue \
  -otxt \
  -of "${RAW_PREFIX}" \
  -np >/dev/null

if [[ ! -f "${RAW_TXT}" ]]; then
  echo "Raw transcript file missing: ${RAW_TXT}" >&2
  exit 1
fi

RAW_CONTENT="$(cat "${RAW_TXT}")"
echo ""
echo "===== RAW TRANSCRIPT ====="
echo "${RAW_CONTENT}"
echo "=========================="
echo ""

FINAL_TEXT="${RAW_CONTENT}"

if [[ -n "${ANTHROPIC_API_KEY:-}" ]]; then
  echo "[3/4] LLM polishing (Anthropic)..."
  if ./poc/polish_text.sh < "${RAW_TXT}" > "${POLISHED_TXT}"; then
    FINAL_TEXT="$(cat "${POLISHED_TXT}")"
    echo ""
    echo "===== POLISHED TRANSCRIPT ====="
    echo "${FINAL_TEXT}"
    echo "==============================="
    echo ""
  else
    echo "Polish failed. Fallback to raw transcript."
  fi
else
  echo "[3/4] ANTHROPIC_API_KEY not set, skip polishing (raw only)."
fi

echo "[4/4] Copying final text to clipboard..."
printf "%s" "${FINAL_TEXT}" | pbcopy

echo "Done. Text copied. Try Cmd+V in your target app."
echo "Artifacts in: ${OUT_DIR}"

