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

## 2) 準備 model（建議先裝 fast + balanced）

建議先下載兩個：

- `large-v3-turbo`（快，for Fast IME）
- `large-v3`（準，for balanced）

```bash
cd third_party/whisper.cpp
bash ./models/download-ggml-model.sh large-v3-turbo
bash ./models/download-ggml-model.sh large-v3
```

假設 model 路徑：

`third_party/whisper.cpp/models/ggml-large-v3-turbo.bin`

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
  --stt-profile fast \
  --fast-ime \
  --auto-paste \
  --audio-device "MacBook Air Microphone" \
  --precheck-seconds 1 \
  --countdown-seconds 2 \
  --whisper ./third_party/whisper.cpp/build/bin/whisper-cli
```

## 5) Expected output

- 終端會顯示：
  - raw transcript
  - polished transcript（如果有 API key）
  - latency summary（precheck/record/normalize/stt/polish/total）
- 最終文字會自動 `pbcopy`，你可以去任何 app `Cmd+V` 貼上。
- 開 `--fast-ime` 時會先插 raw，再嘗試以 polished 覆蓋
- 每次 run 會 append telemetry 到：`poc/.out/telemetry.jsonl`

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

STT profile（唔指定 `--model` 時生效）：

```bash
./poc/run_poc.sh --stt-profile fast      # 優先 large-v3-turbo，否則 large-v3
./poc/run_poc.sh --stt-profile balanced  # 優先 large-v3（預設）
./poc/run_poc.sh --stt-profile accurate  # 目前同 balanced
```

Fast IME mode：

```bash
./poc/run_poc.sh --fast-ime --auto-paste
```

可選：

```bash
./poc/run_poc.sh --fast-ime --auto-paste --no-auto-replace
```

如果你想對特定詞做 bias（例如地名、人名），可以覆蓋 STT prompt：

```bash
./poc/run_poc.sh \
  --stt-prompt "以下係廣東話句子，請以繁體中文輸出。常見香港地名：銅鑼灣、維園、中環、尖沙咀。"
```

Telemetry options：

```bash
./poc/run_poc.sh --no-telemetry
./poc/run_poc.sh --telemetry-file ./poc/.out/telemetry.jsonl
```

快速睇平均 latency（毫秒）：

```bash
jq -s '
  {
    runs: length,
    avg_total_ms: (map(.latency_ms.total) | add / length),
    avg_first_insert_ms: (map(.latency_ms.first_insert) | add / length),
    avg_stt_ms: (map(.latency_ms.stt) | add / length),
    avg_polish_ms: (map(.latency_ms.polish) | add / length)
  }
' ./poc/.out/telemetry.jsonl
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
