#!/usr/bin/env bash
set -euo pipefail

SECONDS_TO_RECORD=8
WHISPER_BIN="./third_party/whisper.cpp/build/bin/whisper-cli"
SMALL_MODEL_PATH="./third_party/whisper.cpp/models/ggml-small.bin"
TURBO_MODEL_PATH="./third_party/whisper.cpp/models/ggml-large-v3-turbo.bin"
LARGE_MODEL_PATH="./third_party/whisper.cpp/models/ggml-large-v3.bin"
STT_PROFILE="${STT_PROFILE:-balanced}"
MODEL_PATH="${MODEL_PATH:-}"
MODEL_SOURCE="manual"
OUT_DIR="./poc/.out"
AUDIO_DEVICE="${AUDIO_DEVICE:-MacBook Air Microphone}"
PRECHECK_SECONDS=1
ENABLE_PRECHECK=1
COUNTDOWN_SECONDS=2
ENABLE_NORMALIZE=1
NORMALIZE_FILTER="highpass=f=100,lowpass=f=7000,loudnorm=I=-18:TP=-1.5:LRA=11"
STT_PROMPT="${STT_PROMPT:-以下係廣東話句子，請以繁體中文輸出。常見香港地名：銅鑼灣、維園、旺角、尖沙咀、中環、沙田、將軍澳、荃灣、屯門。}"
ENABLE_TELEMETRY=1
TELEMETRY_FILE=""
FAST_IME=0
AUTO_PASTE=0
AUTO_REPLACE=1

usage() {
  cat <<EOF
Usage:
  $0 [--seconds N] [--whisper PATH] [--model PATH] [--stt-profile fast|balanced|accurate] [--out DIR] [--audio-device NAME_OR_INDEX] [--precheck-seconds N] [--no-precheck] [--countdown-seconds N] [--no-normalize] [--stt-prompt TEXT] [--fast-ime] [--auto-paste] [--no-auto-replace] [--no-telemetry] [--telemetry-file PATH]

Examples:
  $0
  $0 --seconds 10 --stt-profile fast
  $0 --audio-device "MacBook Air Microphone"
  $0 --precheck-seconds 2
  $0 --countdown-seconds 2
  $0 --stt-prompt "以下係廣東話句子，請以繁體中文輸出。常見香港地名：銅鑼灣、維園。"
  $0 --fast-ime --auto-paste
  $0 --telemetry-file ./poc/.out/telemetry.jsonl
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
    --stt-profile)
      STT_PROFILE="$2"
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
    --fast-ime)
      FAST_IME=1
      AUTO_PASTE=1
      shift
      ;;
    --auto-paste)
      AUTO_PASTE=1
      shift
      ;;
    --no-auto-paste)
      AUTO_PASTE=0
      shift
      ;;
    --no-auto-replace)
      AUTO_REPLACE=0
      shift
      ;;
    --no-telemetry)
      ENABLE_TELEMETRY=0
      shift
      ;;
    --telemetry-file)
      TELEMETRY_FILE="$2"
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

if [[ -z "${MODEL_PATH}" ]]; then
  MODEL_SOURCE="auto"
  case "${STT_PROFILE}" in
    fast)
      if [[ -f "${TURBO_MODEL_PATH}" ]]; then
        MODEL_PATH="${TURBO_MODEL_PATH}"
      elif [[ -f "${LARGE_MODEL_PATH}" ]]; then
        MODEL_PATH="${LARGE_MODEL_PATH}"
      else
        MODEL_PATH="${SMALL_MODEL_PATH}"
      fi
      ;;
    balanced|accurate)
      if [[ -f "${LARGE_MODEL_PATH}" ]]; then
        MODEL_PATH="${LARGE_MODEL_PATH}"
      elif [[ -f "${TURBO_MODEL_PATH}" ]]; then
        MODEL_PATH="${TURBO_MODEL_PATH}"
      else
        MODEL_PATH="${SMALL_MODEL_PATH}"
      fi
      ;;
    *)
      echo "Invalid --stt-profile: ${STT_PROFILE}. Use fast|balanced|accurate." >&2
      exit 1
      ;;
  esac
fi

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

echo "STT profile: ${STT_PROFILE} (source: ${MODEL_SOURCE})"
echo "STT model:   ${MODEL_PATH}"

mkdir -p "${OUT_DIR}"
if [[ -z "${TELEMETRY_FILE}" ]]; then
  TELEMETRY_FILE="${OUT_DIR}/telemetry.jsonl"
fi
STAMP="$(date +%Y%m%d_%H%M%S)"
AUDIO_WAV="${OUT_DIR}/sample_${STAMP}.wav"
NORMALIZED_WAV="${OUT_DIR}/sample_${STAMP}.normalized.wav"
PRECHECK_WAV="${OUT_DIR}/precheck_${STAMP}.wav"
RAW_PREFIX="${OUT_DIR}/raw_${STAMP}"
RAW_TXT="${RAW_PREFIX}.txt"
POLISHED_TXT="${OUT_DIR}/polished_${STAMP}.txt"

now_ms() {
  perl -MTime::HiRes=time -e 'printf("%.0f\n", time()*1000)'
}

RUN_START_MS="$(now_ms)"
PRECHECK_LATENCY_MS=0
RECORD_LATENCY_MS=0
NORMALIZE_LATENCY_MS=0
STT_LATENCY_MS=0
POLISH_LATENCY_MS=0
CLIPBOARD_LATENCY_MS=0
POLISH_PROVIDER_EFFECTIVE="none"
POLISH_STATUS="not_run"
FAST_IME_RAW_STATUS="not_run"
FAST_IME_REPLACE_STATUS="not_run"
FIRST_INSERT_LATENCY_MS=0
RAW_AUTO_PASTED=0

clipboard_copy_text() {
  local text="$1"
  local clip_start clip_end
  clip_start="$(now_ms)"
  printf "%s" "${text}" | pbcopy
  clip_end="$(now_ms)"
  CLIPBOARD_LATENCY_MS="$((CLIPBOARD_LATENCY_MS + clip_end - clip_start))"
}

send_cmd_v() {
  osascript -e 'tell application "System Events" to keystroke "v" using {command down}' >/dev/null 2>&1
}

send_cmd_z() {
  osascript -e 'tell application "System Events" to keystroke "z" using {command down}' >/dev/null 2>&1
}

notify_user() {
  local message="$1"
  osascript -e "display notification \"${message}\" with title \"CantoFlow POC\"" >/dev/null 2>&1 || true
}

if [[ "${ENABLE_PRECHECK}" -eq 1 ]]; then
  PRECHECK_START_MS="$(now_ms)"
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
  PRECHECK_END_MS="$(now_ms)"
  PRECHECK_LATENCY_MS="$((PRECHECK_END_MS - PRECHECK_START_MS))"
fi

RECORD_START_MS="$(now_ms)"
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
RECORD_END_MS="$(now_ms)"
RECORD_LATENCY_MS="$((RECORD_END_MS - RECORD_START_MS))"

INPUT_FOR_STT="${AUDIO_WAV}"
if [[ "${ENABLE_NORMALIZE}" -eq 1 ]]; then
  NORMALIZE_START_MS="$(now_ms)"
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
  NORMALIZE_END_MS="$(now_ms)"
  NORMALIZE_LATENCY_MS="$((NORMALIZE_END_MS - NORMALIZE_START_MS))"
else
  echo "[2/5] Skip normalize (--no-normalize)."
fi

STT_START_MS="$(now_ms)"
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
STT_END_MS="$(now_ms)"
STT_LATENCY_MS="$((STT_END_MS - STT_START_MS))"

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

if [[ "${FAST_IME}" -eq 1 ]]; then
  echo "[3.5/5] Fast IME: copy raw transcript first..."
  clipboard_copy_text "${RAW_CONTENT}"
  FIRST_INSERT_LATENCY_MS="$(( $(now_ms) - RUN_START_MS ))"
  FAST_IME_RAW_STATUS="copied"

  if [[ "${AUTO_PASTE}" -eq 1 ]]; then
    if send_cmd_v; then
      RAW_AUTO_PASTED=1
      FAST_IME_RAW_STATUS="auto_pasted"
      notify_user "Raw transcript inserted, polishing in background..."
    else
      FAST_IME_RAW_STATUS="copy_only"
      echo "      Auto paste failed. Raw text is in clipboard."
    fi
  fi
fi

if [[ -n "${OPENAI_API_KEY:-}" || -n "${ANTHROPIC_API_KEY:-}" ]]; then
  POLISH_START_MS="$(now_ms)"
  case "${POLISH_PROVIDER:-auto}" in
    openai)
      POLISH_PROVIDER_EFFECTIVE="openai"
      ;;
    anthropic)
      POLISH_PROVIDER_EFFECTIVE="anthropic"
      ;;
    *)
      if [[ -n "${OPENAI_API_KEY:-}" ]]; then
        POLISH_PROVIDER_EFFECTIVE="openai"
      else
        POLISH_PROVIDER_EFFECTIVE="anthropic"
      fi
      ;;
  esac

  echo "[4/5] LLM polishing (provider: ${POLISH_PROVIDER:-auto})..."
  if [[ -n "${POLISH_MODEL:-}" ]]; then
    POLISH_CMD=(./poc/polish_text.sh "${POLISH_MODEL}")
  else
    POLISH_CMD=(./poc/polish_text.sh)
  fi

  if "${POLISH_CMD[@]}" < "${RAW_TXT}" > "${POLISHED_TXT}"; then
    FINAL_TEXT="$(cat "${POLISHED_TXT}")"
    POLISH_STATUS="ok"
    echo ""
    echo "===== POLISHED TRANSCRIPT ====="
    echo "${FINAL_TEXT}"
    echo "==============================="
    echo ""

    if [[ "${FAST_IME}" -eq 1 ]]; then
      echo "      Fast IME: replacing raw with polished..."
      clipboard_copy_text "${FINAL_TEXT}"
      if [[ "${AUTO_PASTE}" -eq 1 && "${AUTO_REPLACE}" -eq 1 && "${RAW_AUTO_PASTED}" -eq 1 ]]; then
        if send_cmd_z; then
          sleep 0.05
          if send_cmd_v; then
            FAST_IME_REPLACE_STATUS="undo_then_paste"
            notify_user "Polished text replaced raw."
          else
            FAST_IME_REPLACE_STATUS="undo_only"
            echo "      Replace paste failed. Polished text is in clipboard."
          fi
        else
          FAST_IME_REPLACE_STATUS="copy_only"
          echo "      Undo failed. Polished text is in clipboard."
        fi
      else
        FAST_IME_REPLACE_STATUS="copy_only"
      fi
    fi
  else
    POLISH_STATUS="failed"
    echo "Polish failed. Fallback to raw transcript."
  fi
  POLISH_END_MS="$(now_ms)"
  POLISH_LATENCY_MS="$((POLISH_END_MS - POLISH_START_MS))"
else
  echo "[4/5] OPENAI_API_KEY/ANTHROPIC_API_KEY not set, skip polishing (raw only)."
fi

if [[ "${FAST_IME}" -eq 0 ]]; then
  echo "[5/5] Copying final text to clipboard..."
  clipboard_copy_text "${FINAL_TEXT}"
else
  echo "[5/5] Fast IME mode completed."
fi

RUN_END_MS="$(now_ms)"
TOTAL_LATENCY_MS="$((RUN_END_MS - RUN_START_MS))"

echo ""
echo "===== LATENCY (ms) ====="
echo "precheck=${PRECHECK_LATENCY_MS} record=${RECORD_LATENCY_MS} normalize=${NORMALIZE_LATENCY_MS} stt=${STT_LATENCY_MS} polish=${POLISH_LATENCY_MS} clipboard=${CLIPBOARD_LATENCY_MS} total=${TOTAL_LATENCY_MS}"
if [[ "${FIRST_INSERT_LATENCY_MS}" -gt 0 ]]; then
  echo "first_insert=${FIRST_INSERT_LATENCY_MS}"
fi
echo "========================"

echo "Done. Text copied. Try Cmd+V in your target app."
echo "Artifacts in: ${OUT_DIR}"

if [[ "${ENABLE_TELEMETRY}" -eq 1 ]]; then
  if command -v jq >/dev/null 2>&1; then
    mkdir -p "$(dirname "${TELEMETRY_FILE}")"
    jq -nc \
      --arg timestamp "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      --arg model_path "${MODEL_PATH}" \
      --arg audio_device "${AUDIO_DEVICE}" \
      --arg provider "${POLISH_PROVIDER_EFFECTIVE}" \
      --arg polish_status "${POLISH_STATUS}" \
      --arg stt_profile "${STT_PROFILE}" \
      --arg model_source "${MODEL_SOURCE}" \
      --arg fast_ime_raw_status "${FAST_IME_RAW_STATUS}" \
      --arg fast_ime_replace_status "${FAST_IME_REPLACE_STATUS}" \
      --arg raw_file "${RAW_TXT}" \
      --arg polished_file "${POLISHED_TXT}" \
      --arg raw_text "${RAW_CONTENT}" \
      --arg final_text "${FINAL_TEXT}" \
      --argjson seconds_requested "${SECONDS_TO_RECORD}" \
      --argjson fast_ime "${FAST_IME}" \
      --argjson auto_paste "${AUTO_PASTE}" \
      --argjson auto_replace "${AUTO_REPLACE}" \
      --argjson precheck_ms "${PRECHECK_LATENCY_MS}" \
      --argjson record_ms "${RECORD_LATENCY_MS}" \
      --argjson normalize_ms "${NORMALIZE_LATENCY_MS}" \
      --argjson stt_ms "${STT_LATENCY_MS}" \
      --argjson polish_ms "${POLISH_LATENCY_MS}" \
      --argjson clipboard_ms "${CLIPBOARD_LATENCY_MS}" \
      --argjson total_ms "${TOTAL_LATENCY_MS}" \
      --argjson first_insert_ms "${FIRST_INSERT_LATENCY_MS}" \
      --argjson raw_chars "${#RAW_CONTENT}" \
      --argjson final_chars "${#FINAL_TEXT}" \
      '{
        timestamp: $timestamp,
        seconds_requested: $seconds_requested,
        stt_profile: $stt_profile,
        model_source: $model_source,
        model_path: $model_path,
        audio_device: $audio_device,
        provider: $provider,
        polish_status: $polish_status,
        fast_ime: {
          enabled: ($fast_ime == 1),
          auto_paste: ($auto_paste == 1),
          auto_replace: ($auto_replace == 1),
          raw_status: $fast_ime_raw_status,
          replace_status: $fast_ime_replace_status
        },
        latency_ms: {
          precheck: $precheck_ms,
          record: $record_ms,
          normalize: $normalize_ms,
          stt: $stt_ms,
          polish: $polish_ms,
          clipboard: $clipboard_ms,
          first_insert: $first_insert_ms,
          total: $total_ms
        },
        text_stats: {
          raw_chars: $raw_chars,
          final_chars: $final_chars
        },
        artifacts: {
          raw_file: $raw_file,
          polished_file: $polished_file
        },
        raw_text: $raw_text,
        final_text: $final_text
      }' >> "${TELEMETRY_FILE}"
    echo "Telemetry appended: ${TELEMETRY_FILE}"
  else
    echo "Telemetry skipped: jq not found."
  fi
fi
