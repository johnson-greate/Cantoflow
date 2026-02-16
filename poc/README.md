# CantoFlow M1 Quick POC (No Xcode)

呢個 POC 目標係用你而家部 MacBook Air M1，快速驗證核心 pipeline：

1. 錄音（mic）
2. 本地 whisper.cpp 做廣東話轉錄
3. （可選）用 OpenAI / Anthropic 做文字整理
4. 將結果 copy 去 clipboard（`pbcopy`）

> 呢個版本刻意唔做 AX 自動插字、唔做 menu bar app，純 CLI proof。

## 0) Prerequisites

- macOS Apple Silicon
- `brew`
- `ffmpeg`
- `jq`
- `cmake`
- `git`

安裝（如果未有）：

```bash
brew install ffmpeg jq cmake
```

## 1) 準備 whisper.cpp

```bash
mkdir -p third_party
cd third_party
git clone https://github.com/ggerganov/whisper.cpp.git
cd whisper.cpp
cmake -B build
cmake --build build -j
```

## 2) 準備 model（建議 large-v3）

建議先下載 `large-v3`（粵語效果通常比 small 穩定），disk 會大啲。

```bash
cd third_party/whisper.cpp
bash ./models/download-ggml-model.sh large-v3
```

假設 model 路徑：

`third_party/whisper.cpp/models/ggml-large-v3.bin`

如果你想保留輕量 fallback：

```bash
bash ./models/download-ggml-model.sh small
```

## 3) （可選）設定 LLM API key（OpenAI 優先）

```bash
export OPENAI_API_KEY="your_key_here"
# or:
# export ANTHROPIC_API_KEY="your_key_here"
```

Provider 選擇規則：

- `POLISH_PROVIDER=auto`（預設）：有 `OPENAI_API_KEY` 就用 OpenAI，否則用 Anthropic
- `POLISH_PROVIDER=openai|anthropic`：手動指定 provider

可選 model：

```bash
export OPENAI_MODEL="gpt-4o-mini"
export ANTHROPIC_MODEL="claude-sonnet-4-5-20250929"
# 或用單一覆蓋：
export POLISH_MODEL="gpt-4o-mini"
```

## 4) Run POC

喺 repo root：

```bash
chmod +x poc/run_poc.sh poc/polish_text.sh
./poc/run_poc.sh \
  --seconds 12 \
  --audio-device "MacBook Air Microphone" \
  --precheck-seconds 1 \
  --countdown-seconds 2 \
  --model ./third_party/whisper.cpp/models/ggml-large-v3.bin \
  --whisper ./third_party/whisper.cpp/build/bin/whisper-cli
```

## 5) Expected output

- 終端會顯示：
  - raw transcript
  - polished transcript（如果有 API key）
- 最終文字會自動 `pbcopy`，你可以去任何 app `Cmd+V` 貼上。

如果你部機有多個 input device，建議固定內置 mic：

```bash
./poc/run_poc.sh --audio-device "MacBook Air Microphone"
```

建議保持 precheck 開啟（預設會先做 1 秒 input level check）：

```bash
./poc/run_poc.sh --precheck-seconds 1
```

normalize 亦建議保持開啟（預設啟用）；如要關：

```bash
./poc/run_poc.sh --no-normalize
```

如果你想對特定詞做 bias（例如地名、人名），可以覆蓋 STT prompt：

```bash
./poc/run_poc.sh \
  --stt-prompt "以下係廣東話句子，請以繁體中文輸出。常見香港地名：銅鑼灣、維園、中環、尖沙咀。"
```

## 6) Why this is useful

你可以喺 M1 先驗證三件事：

- 本地 STT latency 大概可唔可接受
- 廣東話 transcript quality
- LLM polish 對文字可讀性提升幾多

等返公司 M4 mini 先再做：

- Swift/Xcode app structure
- AX auto insertion
- hotkey/menu bar/setting UI
- Keychain / permission UX
