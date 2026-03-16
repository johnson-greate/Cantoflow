# Windows Vulkan Build Reference
### 學術參考文章 — 普通用戶無需閱讀

> **寫給後人的話：** 呢份文章記錄咗我哋第一次喺 Windows 上將 whisper.cpp 用 Vulkan GPU 加速的完整過程，包括所有錯誤同解決方法。如果將來需要重新 build（例如 whisper.cpp 有重大更新），呢份文章係完整 reference。普通用戶只需從 GitHub Releases 下載 `whisper-vulkan-win-x64.zip` 即可，完全無需做呢份文章的步驟。

_實驗機器：Core i5-12th gen + Intel Iris Xe, Windows 11, 2026-03-16_

---

## 為什麼需要重新 build？

官方 [ggml-org/whisper.cpp releases](https://github.com/ggml-org/whisper.cpp/releases) 只提供：
- `whisper-bin-x64.zip` — 純 CPU（`OPENVINO=0, VULKAN=0`）
- `whisper-cublas-*.zip` — NVIDIA CUDA 專用
- 其他：BLAS、macOS xcframework、Java

**Intel 集成顯卡（Iris Xe / UHD Graphics）唔在任何預編譯版本入面。**

實測：純 CPU 版本跑 large-v3-turbo-q5_0 需要 **49 秒**；Vulkan 版本同樣 model 只需 **6–15 秒**（視乎錄音長度），質量相同。

---

## 踩過的坑（按時序）

| 錯誤 | 根本原因 | 解決方法 |
|---|---|---|
| `【獲獎】賈麥麵` | `ggml-base.bin`太小 + `-l zh`（普通話） | 自動選最佳 model + `-l auto` |
| `HQw 曼HQw 曼HQw` | `ProcessStartInfo.Arguments` 破壞 UTF-8 CJK 字符 | 改用 `ArgumentList` |
| STT 39 秒 | stdout pipe buffer（4KB）滿了，child process 卡住 | `ReadToEndAsync()` 並行 drain |
| `I 游h 游b 游b` | BLAS build v1.8.3 與 q5_0 model 不兼容 | 換回 `whisper-bin-x64.zip` |
| `I Ζ Ζ Ζ Ζ Ζ` | BLAS build + `--beam-size 1` 不被識別 | 移除 `--best-of`/`--beam-size` |
| `今h 今h 今h` | `-l yue` 在新版 binary 不支援 | 改為 `-l auto` |
| `OPENVINO = 0` | 官方 binary 未 compile OpenVINO | 改用 Vulkan 路線 |
| STT 49 秒（仍然）| `VULKAN = 0`，binary 冇 Vulkan support | 從源碼 build with `GGML_VULKAN=ON` |

---

## Build 環境要求

| 工具 | 來源 | 備注 |
|---|---|---|
| Git | `winget install Git.Git` | 通常已安裝 |
| CMake | `winget install Kitware.CMake` | 通常已安裝 |
| Visual Studio 2022（Community 或 BuildTools）| 機器上已有 VS 18 Community | MSVC 19.50+ |
| Vulkan SDK | `winget install KhronosGroup.VulkanSDK` | **必須先裝** |

> **注意**：`winget install Microsoft.VisualStudio.2022.BuildTools` 在此機器上快速完成是因為 Visual Studio Community 已預裝（`C:\Program Files\Microsoft Visual Studio\18\Community\`）。

---

## Build 步驟

### 1. 安裝 Vulkan SDK
```powershell
winget install KhronosGroup.VulkanSDK
```
重開 PowerShell 確保環境變數生效。

### 2. Clone whisper.cpp
```powershell
git clone https://github.com/ggml-org/whisper.cpp C:\whisper-src
```

### 3. CMake Configure
```powershell
cd C:\whisper-src
cmake -B build_vulkan -DGGML_VULKAN=ON -DCMAKE_BUILD_TYPE=Release
```

成功標誌：
```
-- Vulkan found
-- Including Vulkan backend
-- Build files have been written to: C:/whisper-src/build_vulkan
```

Warning `C4244`（int64_t → uint32_t）係正常，非致命。

### 4. Build（5–15 分鐘）
```powershell
cmake --build C:\whisper-src\build_vulkan --config Release -j8
```

完成標誌：
```
whisper-cli.vcxproj -> C:\whisper-src\build_vulkan\bin\Release\whisper-cli.exe
```

### 5. 驗證 Vulkan 已編入
```powershell
& "C:\whisper-src\build_vulkan\bin\Release\whisper-cli.exe" --help 2>&1 | Select-String "Vulkan"
```

應見到：
```
ggml_vulkan: Found 1 Vulkan devices:
ggml_vulkan: 0 = Intel(R) UHD Graphics (Intel Corporation) | uma: 1 | fp16: 1
```

### 6. 打包 Distribution zip
```powershell
New-Item -ItemType Directory -Force C:\whisper-vulkan-cantoflow
Copy-Item "C:\whisper-src\build_vulkan\bin\Release\whisper-cli.exe" C:\whisper-vulkan-cantoflow\
Copy-Item "C:\whisper-src\build_vulkan\bin\Release\ggml.dll" C:\whisper-vulkan-cantoflow\
Copy-Item "C:\whisper-src\build_vulkan\bin\Release\ggml-cpu.dll" C:\whisper-vulkan-cantoflow\
Copy-Item "C:\whisper-src\build_vulkan\bin\Release\ggml-base.dll" C:\whisper-vulkan-cantoflow\
Copy-Item "C:\whisper-src\build_vulkan\bin\Release\ggml-vulkan.dll" C:\whisper-vulkan-cantoflow\
Copy-Item "C:\whisper-src\build_vulkan\bin\Release\whisper.dll" C:\whisper-vulkan-cantoflow\
Compress-Archive -Path C:\whisper-vulkan-cantoflow\* -DestinationPath C:\whisper-vulkan-win-x64.zip -Force
```

上傳到 GitHub Releases，tag `whisper-vulkan-v1.0`。

---

## 性能數據（i5-12th gen + Iris Xe）

測試音頻：11.4 秒廣東話錄音

| 設定 | encode time | total time |
|---|---|---|
| CPU only（`whisper-bin-x64`）| 47,624ms / 2 runs | 49,084ms |
| Vulkan（此 build，無優化）| 9,372ms / 2 runs | 14,904ms |
| Vulkan + `-ac 768` + greedy | 5,746ms / 2 runs | 6,725ms |

**生產設定（app 現用）：**
```
-t 8 -ac 768 -bo 1 -bs 1 -l auto --no-timestamps
```

---

## 將來更新 whisper.cpp

如 whisper.cpp 有重大更新需要重新 build：

```powershell
cd C:\whisper-src
git pull
cmake --build build_vulkan --config Release -j8
# 重新打包 zip 並更新 GitHub Releases
```

無需重新 cmake configure，除非 CMakeLists.txt 有重大改動。

---

## 相關文件

- [windows-setup-guide.md](windows-setup-guide.md) — 普通用戶安裝指南（下載 pre-built zip）
- [current_status.md](current_status.md) — 當前開發狀態
