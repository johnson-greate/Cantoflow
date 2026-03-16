# CantoFlow Windows Setup Guide
_Verified working: 2026-03-16_

> **關於 whisper-cli：** 本指南使用預編譯的 Vulkan 版 whisper-cli。如需從源碼重新編譯（例如 whisper.cpp 重大更新），請參閱 [windows-vulkan-build-reference.md](windows-vulkan-build-reference.md)。普通安裝無需閱讀該文章。

---

## 結果預覽

正確完成後：
- STT ~13s（Intel Iris Xe Vulkan GPU）
- 輸出正確廣東話繁體中文
- QWEN LLM polish ~3s
- 總延遲 ~16s

---

## 前置條件

- Windows 10/11 x64
- Internet 連線（下載約 600MB）

---

## Part 1：安裝 CantoFlow App

### 1.1 安裝 .NET 10 SDK
```powershell
winget install Microsoft.DotNet.SDK.10
```

### 1.2 Clone repo
```powershell
git clone https://github.com/johnson-greate/Cantoflow.git C:\Users\sztan\Cantoflow
```

### 1.3 Build + Run
```powershell
cd C:\Users\sztan\Cantoflow\windows
dotnet run --project src\CantoFlow.App
```

---

## Part 2：安裝 whisper-cli（Vulkan GPU 加速版）

### 2.1 下載預編譯 Vulkan binary

從 CantoFlow GitHub Releases 下載 **`whisper-vulkan-win-x64.zip`**

### 2.2 複製到 CantoFlow 資料夾
解壓，將所有文件（`whisper-cli.exe` + 5 個 `.dll`）複製到：
```
%APPDATA%\CantoFlow\
```
（即 `C:\Users\<用戶名>\AppData\Roaming\CantoFlow\`）

### 2.3 下載 Whisper model
建立 models 資料夾：
```
%APPDATA%\CantoFlow\models\
```

下載 `ggml-large-v3-turbo-q5_0.bin`（560MB）：
```
https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo-q5_0.bin
```
放入 `%APPDATA%\CantoFlow\models\`

---

## Part 3：Vulkan GPU 加速（重要！冇呢步 STT 要 49 秒）

### 3.1 安裝 Vulkan SDK
```powershell
winget install KhronosGroup.VulkanSDK
```
同意授權，等安裝完成。

### 3.2 確認 MSVC 編譯器可用
```powershell
cmake --version
```
如果有版本號，繼續下一步。如果提示找不到 cmake：
```powershell
winget install Kitware.CMake
```

### 3.3 Clone whisper.cpp source
```powershell
git clone https://github.com/ggml-org/whisper.cpp C:\whisper-src
```

### 3.4 Configure with Vulkan
```powershell
cd C:\whisper-src
cmake -B build_vulkan -DGGML_VULKAN=ON -DCMAKE_BUILD_TYPE=Release
```

成功輸出應包含：
```
-- Vulkan found
-- Including Vulkan backend
-- Build files have been written to: C:/whisper-src/build_vulkan
```

### 3.5 Build（需要 5–15 分鐘）
```powershell
cmake --build C:\whisper-src\build_vulkan --config Release -j8
```

等到出現：
```
whisper-cli.vcxproj -> C:\whisper-src\build_vulkan\bin\Release\whisper-cli.exe
```

### 3.6 替換 binary
```powershell
copy C:\whisper-src\build_vulkan\bin\Release\whisper-cli.exe "$env:APPDATA\CantoFlow\whisper-cli.exe"
xcopy /Y C:\whisper-src\build_vulkan\bin\Release\*.dll "$env:APPDATA\CantoFlow\"
```

### 3.7 驗證 Vulkan 啟動
```powershell
& "$env:APPDATA\CantoFlow\whisper-cli.exe" --help 2>&1 | Select-String "Vulkan|Intel|AMD|NVIDIA"
```

應該見到：
```
ggml_vulkan: Found 1 Vulkan devices:
ggml_vulkan: 0 = Intel(R) UHD Graphics (Intel Corporation) | uma: 1 | fp16: 1
```

---

## Part 4：API Keys 設定

### 4.1 建立 env 文件
建立 `%APPDATA%\CantoFlow\cantoflow.env`，內容：
```
QWEN_API_KEY=sk-xxxxxxxxxxxxxxxx
```

或透過 CantoFlow Settings UI → API Keys tab 輸入。

### 4.2 重啟 CantoFlow
Settings 改動後需重啟才生效。

---

## Part 5：手動測試（可選，用於 debug）

```powershell
& "$env:APPDATA\CantoFlow\whisper-cli.exe" `
  -m "$env:APPDATA\CantoFlow\models\ggml-large-v3-turbo-q5_0.bin" `
  -f "$env:APPDATA\CantoFlow\.out\<最新wav文件>" `
  -otxt -l auto --no-timestamps -t 8 -ac 768 --best-of 1 --beam-size 1 `
  2>&1 | Select-String "encode time|total time|auto-detected|Vulkan"
```

正常輸出：
```
ggml_vulkan: 0 = Intel(R) UHD Graphics
whisper_full_with_state: auto-detected language: zh (p = 0.99)
encode time =  5745ms / 2 runs
total time  =  6724ms
```

---

## 速度參考（Intel i5-12th gen + Iris Xe）

| 設定 | STT 時間 |
|---|---|
| CPU only（原始）| ~49s |
| Vulkan only | ~15s |
| Vulkan + -ac 768 + greedy | ~6–13s |
| Apple M 系列（對比）| ~2s |

---

## 常見問題

### Q: 輸出「HQw 曼HQw」或亂碼
**A:** 舊版 code 的 bug（`Arguments` string 破壞 UTF-8）。確保用最新 code：
```powershell
cd C:\Users\sztan\Cantoflow && git pull
```

### Q: 輸出「今h 今h 今h」
**A:** 語言 flag 問題。最新 code 用 `-l auto`，git pull 後重啟。

### Q: 輸出「I Ζ Ζ Ζ Ζ」
**A:** 下載咗 BLAS build 的 whisper-cli。換返 `whisper-bin-x64.zip`（普通版）。

### Q: STT 仍然 49 秒
**A:** Vulkan binary 未替換，或 whisper-cli.exe 係舊版 CPU-only build。重做 Part 3.6。

### Q: `ggml_vulkan: no device found`
**A:** Intel Graphics Driver 過舊。到 Intel 官網下載最新 Arc & Iris Xe Graphics driver。

### Q: 輸出普通話（簡體字）
**A:** 正常，`-l auto` 有時 detect 做 `zh`。app 本身有 Cantonese --prompt 輔助，live 錄音效果比 manual test 好。

---

## 更新 CantoFlow

```powershell
cd C:\Users\sztan\Cantoflow
git pull
dotnet run --project windows\src\CantoFlow.App
```

whisper binary 唔需要重新 build，除非 whisper.cpp 有重大更新。
