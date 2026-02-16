# CantoFlow M1 Quick POC (No Xcode)

呢個 POC 目標係用你而家部 MacBook Air M1，快速驗證核心 pipeline：

1. 錄音（mic）
2. 本地 whisper.cpp 做廣東話轉錄
3. （可選）用 Anthropic 做文字整理
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

## 2) 準備 model（先用 small）

你可以先用 official `small`，再之後換 cantonese fine-tune。

```bash
cd third_party/whisper.cpp
bash ./models/download-ggml-model.sh small
```

假設 model 路徑：

`third_party/whisper.cpp/models/ggml-small.bin`

## 3) （可選）設定 Anthropic API key

```bash
export ANTHROPIC_API_KEY="your_key_here"
```

## 4) Run POC

喺 repo root：

```bash
chmod +x poc/run_poc.sh poc/polish_text.sh
./poc/run_poc.sh \
  --seconds 8 \
  --model ./third_party/whisper.cpp/models/ggml-small.bin \
  --whisper ./third_party/whisper.cpp/build/bin/whisper-cli
```

## 5) Expected output

- 終端會顯示：
  - raw transcript
  - polished transcript（如果有 API key）
- 最終文字會自動 `pbcopy`，你可以去任何 app `Cmd+V` 貼上。

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

