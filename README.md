# CantoFlow

> **CantoFlow** 是一個專為廣東話設計的 AI 語音輸入與文字潤飾開源工具，讓你在 macOS 上能以最自然的方式進行廣東話語音輸入，並自動轉換成通順、精準的書面語或口語文字。

## ✨ 核心特色

- **全域語音輸入 (Push-to-Talk)**：長按你專屬設定的快捷鍵 (支援全新 Apple Silicon 地球鍵 / Fn 鍵、或是任意鍵盤組合)，隨時隨地在任何應用程式中進行語音輸入。
- **強大的廣東話辨識**：底層整合先進語音辨識技術 (Whisper)，精準捕捉廣東話發音。
- **AI 智能潤飾 (Text Polish)**：錄音完成後，自動將文字交由大型語言模型 (如 Qwen 通義千問或 OpenAI) 進行上下文梳理與錯別字修正，甚至自動過濾掉不自然的拼音亂碼。
- **自訂專屬詞彙庫 (Vocabulary System)**：內建超過 400+ 個香港常用詞彙，你也可以隨時加入個人專屬的專業術語或人名，讓 AI 越用越懂你。
- **高度隱私與開源**：基於 **MIT License** / **GPLv3** 開源精神，你的資料流向完全透明，更歡迎各界社群開發者貢獻程式碼共同完善！

## 🚀 快速安裝與使用

我們為 macOS 使用者準備了極簡的全自動安裝腳本。詳細的環境需求與手動安裝方式，請參閱我們的 [INSTALL.md](INSTALL.md)。

1. **下載專案**
   ```bash
   git clone https://github.com/johnson-greate/Cantoflow.git
   cd Cantoflow
   ```

2. **執行自動安裝腳本**
   ```bash
   bash install.sh
   ```
   *腳本會自動為你檢查編譯環境、建立全域捷徑，並導引你設定 API Keys。*

3. **設定 API Key**
   你需要在大語言模型供應商 (例如 Aliyun DashScope 通義千問) 取得 API Key，並填入 `~/.cantoflow.env` 檔案中：
   ```env
   DASHSCOPE_API_KEY="sk-你的密鑰"
   ```

4. **開始暢所欲言！**
   啟動程式：
   ```bash
   cantoflow
   ```
   你可以點擊右上角 Menu Bar 圖示進入 **Settings...** 去自訂你最順手的錄音快捷鍵，設定好後，長按該鍵說出廣東話，放開按鍵後，完美的文字就會自動輸入到你當前的視窗！

## 🤝 參與貢獻 (Contributing)

CantoFlow 目前正處於積極開發的階段，我們非常歡迎各位網友基於開源協議共同使用與改進本項目！如果你有任何好點子，或者發現了 Bug，歡迎隨時：
1. 提交 [Issue](https://github.com/johnson-greate/Cantoflow/issues) 與我們討論。
2. Fork 此專案，並發送 Pull Request (PR) 貢獻你的程式碼。

*CantoFlow 致力於提升粵語使用者的數位輸入體驗與私隱保護水平，感謝你的支持與使用！*

---

### Sponsor & Supported By
**Greate (HK) Limited**  
🌐 [http://www.greate.com.hk](http://www.greate.com.hk)
