#!/usr/bin/env bash
set -euo pipefail

# Usage:
#   echo "raw text" | ./poc/polish_text.sh [model]
# Env:
#   POLISH_PROVIDER=auto|openai|anthropic
#   OPENAI_API_KEY / OPENAI_MODEL
#   ANTHROPIC_API_KEY / ANTHROPIC_MODEL

PROVIDER="${POLISH_PROVIDER:-auto}"
OPENAI_MODEL="${OPENAI_MODEL:-gpt-4o-mini}"
ANTHROPIC_MODEL="${ANTHROPIC_MODEL:-claude-sonnet-4-5-20250929}"

if [[ -n "${1:-}" ]]; then
  case "$1" in
    openai|anthropic|auto)
      PROVIDER="$1"
      ;;
    *)
      # Backward-compatible model override:
      # - provider=openai -> OPENAI_MODEL
      # - provider=anthropic -> ANTHROPIC_MODEL
      # - provider=auto -> whichever provider gets selected
      MODEL_OVERRIDE="$1"
      ;;
  esac
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "jq is required but not found. Install with: brew install jq" >&2
  exit 1
fi

RAW_TEXT="$(cat)"
if [[ -z "${RAW_TEXT}" ]]; then
  echo "Input text is empty" >&2
  exit 1
fi

SYSTEM_PROMPT="$(cat <<'EOF'
你是一個廣東話語音輸入助手。你會收到一段由語音識別系統轉錄的廣東話粗文字，你的任務是：
1. 保持用戶原意，不要過度改寫
2. 修正語音識別錯字（按上下文）
3. 去除口頭禪（即係、其實、呀、嗯、嗱咁等）
4. 將廣東話口語轉成自然書面語（保留香港用語）
5. 整理句式及標點
6. 只輸出整理後文字，不要解釋
7. 對地名、人名、品牌名等專有名詞採取保守策略：除非非常確定，否則保留原文，不要自行替換成其他地名
8. 尤其避免把香港地名錯改為其他地區地名（例如銅鑼灣、維園、旺角、尖沙咀、中環等）
EOF
)"

if [[ "${PROVIDER}" == "auto" ]]; then
  if [[ -n "${OPENAI_API_KEY:-}" ]]; then
    PROVIDER="openai"
  elif [[ -n "${ANTHROPIC_API_KEY:-}" ]]; then
    PROVIDER="anthropic"
  else
    echo "No API key found. Set OPENAI_API_KEY or ANTHROPIC_API_KEY." >&2
    exit 1
  fi
fi

if [[ -n "${MODEL_OVERRIDE:-}" ]]; then
  if [[ "${PROVIDER}" == "openai" ]]; then
    OPENAI_MODEL="${MODEL_OVERRIDE}"
  else
    ANTHROPIC_MODEL="${MODEL_OVERRIDE}"
  fi
fi

call_openai() {
  if [[ -z "${OPENAI_API_KEY:-}" ]]; then
    echo "OPENAI_API_KEY is not set" >&2
    return 1
  fi

  REQUEST_JSON="$(jq -n \
    --arg model "${OPENAI_MODEL}" \
    --arg system "${SYSTEM_PROMPT}" \
    --arg text "${RAW_TEXT}" \
    '{
      model: $model,
      temperature: 0.2,
      max_completion_tokens: 1024,
      messages: [
        { role: "system", content: $system },
        { role: "user", content: $text }
      ]
    }'
  )"

  RESPONSE="$(
    curl -sS https://api.openai.com/v1/chat/completions \
      -H "Authorization: Bearer ${OPENAI_API_KEY}" \
      -H "content-type: application/json" \
      -d "${REQUEST_JSON}"
  )"

  ERROR_MSG="$(echo "${RESPONSE}" | jq -r '.error.message // empty')"
  if [[ -n "${ERROR_MSG}" ]]; then
    echo "OpenAI API error: ${ERROR_MSG}" >&2
    return 1
  fi

  POLISHED="$(echo "${RESPONSE}" | jq -r '.choices[0].message.content // empty')"
  if [[ -z "${POLISHED}" ]]; then
    echo "Failed to parse polished text from OpenAI response" >&2
    return 1
  fi

  echo "${POLISHED}"
}

call_anthropic() {
  if [[ -z "${ANTHROPIC_API_KEY:-}" ]]; then
    echo "ANTHROPIC_API_KEY is not set" >&2
    return 1
  fi

  REQUEST_JSON="$(jq -n \
    --arg model "${ANTHROPIC_MODEL}" \
    --arg system "${SYSTEM_PROMPT}" \
    --arg text "${RAW_TEXT}" \
    '{
      model: $model,
      max_tokens: 1024,
      temperature: 0.2,
      system: $system,
      messages: [
        {
          role: "user",
          content: [
            {
              type: "text",
              text: $text
            }
          ]
        }
      ]
    }'
  )"

  RESPONSE="$(
    curl -sS https://api.anthropic.com/v1/messages \
      -H "x-api-key: ${ANTHROPIC_API_KEY}" \
      -H "anthropic-version: 2023-06-01" \
      -H "content-type: application/json" \
      -d "${REQUEST_JSON}"
  )"

  ERROR_MSG="$(echo "${RESPONSE}" | jq -r '.error.message // empty')"
  if [[ -n "${ERROR_MSG}" ]]; then
    echo "Anthropic API error: ${ERROR_MSG}" >&2
    return 1
  fi

  POLISHED="$(echo "${RESPONSE}" | jq -r '.content[] | select(.type=="text") | .text')"
  if [[ -z "${POLISHED}" ]]; then
    echo "Failed to parse polished text from Anthropic response" >&2
    return 1
  fi

  echo "${POLISHED}"
}

case "${PROVIDER}" in
  openai)
    call_openai
    ;;
  anthropic)
    call_anthropic
    ;;
  *)
    echo "Unsupported provider: ${PROVIDER}. Use auto|openai|anthropic." >&2
    exit 1
    ;;
esac
