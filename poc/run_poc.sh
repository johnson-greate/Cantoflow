#!/usr/bin/env bash
set -euo pipefail

SECONDS_TO_RECORD=8
WHISPER_BIN="./third_party/whisper.cpp/build/bin/whisper-cli"
SMALL_MODEL_PATH="./third_party/whisper.cpp/models/ggml-small.bin"
LARGE_MODEL_PATH="./third_party/whisper.cpp/models/ggml-large-v3.bin"
if [[ -f "${LARGE_MODEL_PATH}" ]]; then
  MODEL_PATH="${LARGE_MODEL_PATH}"
else
  MODEL_PATH="${SMALL_MODEL_PATH}"
fi
OUT_DIR="./poc/.out"
AUDIO_DEVICE="${AUDIO_DEVICE:-MacBook Air Microphone}"
PRECHECK_SECONDS=1
ENABLE_PRECHECK=1
COUNTDOWN_SECONDS=2
ENABLE_NORMALIZE=1
NORMALIZE_FILTER="highpass=f=100,lowpass=f=7000,loudnorm=I=-18:TP=-1.5:LRA=11"
STT_PROMPT="${STT_PROMPT:-以下係廣東話句子，請以繁體中文輸出。常見香港地名：銅鑼灣、維園、旺角、尖沙咀、中環、沙田、將軍澳、荃灣、屯門。}"

usage() {
  cat <<EOF
Usage:
  $0 [--seconds N] [--whisper PATH] [--model PATH] [--out DIR] [--audio-device NAME_OR_INDEX] [--precheck-seconds N] [--no-precheck] [--countdown-seconds N] [--no-normalize] [--stt-prompt TEXT]

Examples:
  $0
  $0 --seconds 10 --model ./third_party/whisper.cpp/models/ggml-large-v3.bin
  $0 --audio-device "MacBook Air Microphone"
  $0 --precheck-seconds 2
  $0 --countdown-seconds 2
  $0 --stt-prompt "以下係廣東話句子，請以繁體中文輸出。常見香港地名：銅鑼灣、維園。"
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
    --audio-device)
      AUDIO_DEVICE="$2"
      shift 2
      ;;
    --precheck-seconds)
      PRECHECK_SECONDS="$2"
      shift 2
      ;;
    --no-precheck)
      ENABLE_PRECHECK=0
      shift
      ;;
    --countdown-seconds)
      COUNTDOWN_SECONDS="$2"
      shift 2
      ;;
    --no-normalize)
      ENABLE_NORMALIZE=0
      shift
      ;;
    --stt-prompt)
      STT_PROMPT="$2"
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
NORMALIZED_WAV="${OUT_DIR}/sample_${STAMP}.normalized.wav"
PRECHECK_WAV="${OUT_DIR}/precheck_${STAMP}.wav"
RAW_PREFIX="${OUT_DIR}/raw_${STAMP}"
RAW_TXT="${RAW_PREFIX}.txt"
POLISHED_TXT="${OUT_DIR}/polished_${STAMP}.txt"

if [[ "${ENABLE_PRECHECK}" -eq 1 ]]; then
  echo "[0/5] Microphone precheck (${PRECHECK_SECONDS}s): ${AUDIO_DEVICE}"
  ffmpeg -hide_banner -loglevel error \
    -f avfoundation -i ":${AUDIO_DEVICE}" \
    -t "${PRECHECK_SECONDS}" \
    -ac 1 -ar 16000 -c:a pcm_s16le \
    "${PRECHECK_WAV}"

  # Parse level from recorded sample to detect near-silent input early.
  PRECHECK_LOG="$(
    ffmpeg -hide_banner -i "${PRECHECK_WAV}" -af volumedetect -f null - 2>&1 || true
  )"
  MEAN_DB="$(echo "${PRECHECK_LOG}" | awk -F': ' '/mean_volume/ {print $2}' | tail -n 1 | sed 's/ dB//')"
  MAX_DB="$(echo "${PRECHECK_LOG}" | awk -F': ' '/max_volume/ {print $2}' | tail -n 1 | sed 's/ dB//')"

  if [[ -n "${MEAN_DB}" || -n "${MAX_DB}" ]]; then
    echo "      Level check: mean=${MEAN_DB:-n/a} dB, max=${MAX_DB:-n/a} dB"
  else
    echo "      Level check: unable to parse input level."
  fi

  LOW_SIGNAL=0
  if [[ -z "${MAX_DB}" || "${MAX_DB}" == "-inf" ]]; then
    LOW_SIGNAL=1
  else
    if awk "BEGIN {exit !(${MAX_DB} < -45.0)}"; then
      LOW_SIGNAL=1
    fi
  fi

  if [[ "${LOW_SIGNAL}" -eq 1 ]]; then
    echo "      Warning: input level is very low. Move closer or increase Input volume before next run."
  fi
fi

echo "[1/5] Recording ${SECONDS_TO_RECORD}s from microphone: ${AUDIO_DEVICE}"
if [[ "${COUNTDOWN_SECONDS}" -gt 0 ]]; then
  echo "      Get ready. Recording starts in:"
  for ((s=COUNTDOWN_SECONDS; s>=1; s--)); do
    echo "      ${s}..."
    sleep 1
  done
fi
echo "      Recording now..."

# avfoundation input format is "[video]:[audio]"; using empty video and explicit audio device.
ffmpeg -hide_banner -loglevel error \
  -f avfoundation -i ":${AUDIO_DEVICE}" \
  -t "${SECONDS_TO_RECORD}" \
  -ac 1 -ar 16000 -c:a pcm_s16le \
  "${AUDIO_WAV}"

INPUT_FOR_STT="${AUDIO_WAV}"
if [[ "${ENABLE_NORMALIZE}" -eq 1 ]]; then
  echo "[2/5] Audio normalize + cleanup..."
  if ffmpeg -hide_banner -loglevel error \
      -i "${AUDIO_WAV}" \
      -af "${NORMALIZE_FILTER}" \
      -ac 1 -ar 16000 -c:a pcm_s16le \
      "${NORMALIZED_WAV}"; then
    INPUT_FOR_STT="${NORMALIZED_WAV}"
  else
    echo "      Normalize failed, fallback to raw audio."
  fi
else
  echo "[2/5] Skip normalize (--no-normalize)."
fi

echo "[3/5] Local transcription (whisper.cpp)..."
"${WHISPER_BIN}" \
  -m "${MODEL_PATH}" \
  -f "${INPUT_FOR_STT}" \
  -l yue \
  --prompt "${STT_PROMPT}" \
  -sns \
  -nth 0.35 \
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

if [[ -n "${OPENAI_API_KEY:-}" || -n "${ANTHROPIC_API_KEY:-}" ]]; then
  echo "[4/5] LLM polishing (provider: ${POLISH_PROVIDER:-auto})..."
  if [[ -n "${POLISH_MODEL:-}" ]]; then
    POLISH_CMD=(./poc/polish_text.sh "${POLISH_MODEL}")
  else
    POLISH_CMD=(./poc/polish_text.sh)
  fi

  if "${POLISH_CMD[@]}" < "${RAW_TXT}" > "${POLISHED_TXT}"; then
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
  echo "[4/5] OPENAI_API_KEY/ANTHROPIC_API_KEY not set, skip polishing (raw only)."
fi

echo "[5/5] Copying final text to clipboard..."
printf "%s" "${FINAL_TEXT}" | pbcopy

echo "Done. Text copied. Try Cmd+V in your target app."
echo "Artifacts in: ${OUT_DIR}"
