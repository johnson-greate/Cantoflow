#!/usr/bin/env bash
set -euo pipefail

# Usage:
#   echo "raw text" | ./poc/polish_text.sh [model]

MODEL="${1:-claude-sonnet-4-5-20250929}"

if [[ -z "${ANTHROPIC_API_KEY:-}" ]]; then
  echo "ANTHROPIC_API_KEY is not set" >&2
  exit 1
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
EOF
)"

REQUEST_JSON="$(jq -n \
  --arg model "${MODEL}" \
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
  exit 1
fi

POLISHED="$(echo "${RESPONSE}" | jq -r '.content[] | select(.type=="text") | .text')"
if [[ -z "${POLISHED}" ]]; then
  echo "Failed to parse polished text from API response" >&2
  exit 1
fi

echo "${POLISHED}"

