# FunASR Cantonese Server

FunASR 廣東話 ASR HTTP Server，為 CantoFlow 提供快速語音識別。

## 模型

使用阿里達摩院 FunASR 廣東話模型：
- `speech_paraformer-large-vad-punc_asr-nlu_zh-cantonese`

## 安裝

```bash
cd funasr_server
./run_server.sh
```

首次運行會自動：
1. 創建 Python venv
2. 安裝依賴（funasr, torch, fastapi 等）
3. 下載模型（約 1-2GB）

## 使用

### 啟動服務器

```bash
./run_server.sh         # CPU 模式
./run_server.sh --gpu   # GPU 模式（如有 CUDA）
```

服務器默認在 `http://127.0.0.1:8765` 運行。

### API 端點

#### POST /transcribe

上傳音頻文件進行轉錄。

```bash
curl -X POST http://127.0.0.1:8765/transcribe \
  -F "audio=@recording.wav" \
  -F "language=yue" \
  -F "hotwords=銅鑼灣 維園 旺角"
```

**回應：**
```json
{
  "text": "我想去銅鑼灣",
  "latency_ms": 320,
  "language": "yue",
  "model": "speech_paraformer-large-vad-punc_asr-nlu_zh-cantonese"
}
```

#### GET /health

健康檢查。

#### GET /ready

就緒檢查（模型是否已載入）。

## 與 CantoFlow_c 整合

在 CantoFlow_c 中使用 FunASR：

```bash
./cantoflow --stt-backend funasr --funasr-host 127.0.0.1 --funasr-port 8765
```

## 環境變量

- `FUNASR_HOST`: 服務器地址（默認：127.0.0.1）
- `FUNASR_PORT`: 服務器端口（默認：8765）
- `FUNASR_USE_GPU`: 設為 1 啟用 GPU

## 延遲對比

| Backend | 延遲 | 優點 |
|---------|------|------|
| whisper.cpp | ~4-5s | 離線、隱私 |
| FunASR | ~300ms | 快速、廣東話專用 |
