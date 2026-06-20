#!/usr/bin/env bash
set -euo pipefail

# Generate a Spokenly-ready Cantonese polish prompt from CantoFlow personal vocab.
# Usage:
#   scripts/generate_spokenly_prompt.sh
#   scripts/generate_spokenly_prompt.sh /path/to/output.txt

VOCAB_FILE="${HOME}/Library/Application Support/CantoFlow/personal_vocab.json"
OUTPUT_FILE="${1:-}"

if [[ ! -f "${VOCAB_FILE}" ]]; then
  echo "Vocabulary file not found: ${VOCAB_FILE}" >&2
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "jq is required but not found." >&2
  exit 1
fi

PROMPT_HEADER=$(cat <<'EOF'
你是一位精通香港廣東話口語的資深編輯。你的任務是把語音轉錄粗稿做最小必要修正，整理成地道自然的香港廣東話繁體中文。

規則：
1. 保持原意，不擴寫、不總結、不補充資訊。
2. 優先保留香港口語，不要擅自改成正式書面語。
3. 只修正明顯誤聽：同音字、近音字、英文音譯拼音、錯標點。
4. 若下列詞庫有對應詞（相同/近似/同音/近音），優先修正為詞庫寫法。
5. 專有名詞（人名/地名/公司名/產品名）採保守策略：有詞庫就跟詞庫，無把握就保留原文。
6. 必須輸出繁體中文。
7. 只輸出修正後文字，不要解釋，不要加引號。

優先詞庫（自動生成）：
EOF
)

TERMS=$(
  jq -r '
    .entries
    | map(
        select(.term != null and (.term | type == "string"))
        | select((.notes // "") | test("語音修訂自動學習") | not)
        | select(.term | test("[\\n\\r]") | not)
        | select(.term | length >= 2 and length <= 32)
      )
    | unique_by(.term)
    | sort_by(
        (if .category == "tech" then 0
         elif .category == "company" then 1
         elif .category == "product" then 2
         elif .category == "person" then 3
         elif .category == "action" then 4
         elif .category == "slang" then 5
         elif .category == "place" then 6
         elif .category == "food" then 7
         else 8 end),
        .term
      )
    | .[:120]
    | map(.term)
    | join("、")
  ' "${VOCAB_FILE}"
)

FULL_PROMPT="${PROMPT_HEADER}"$'\n'"${TERMS}"$'\n'

if [[ -n "${OUTPUT_FILE}" ]]; then
  printf "%s" "${FULL_PROMPT}" > "${OUTPUT_FILE}"
  echo "Generated Spokenly prompt: ${OUTPUT_FILE}"
else
  printf "%s" "${FULL_PROMPT}"
fi

