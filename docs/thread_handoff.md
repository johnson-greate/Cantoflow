# CantoFlow — Thread Handoff

_Date: 2026-03-27_

---

## 本輪重點

本輪已完成兩條主線：

1. 修正 macOS `LaunchAgent` one-shot 問題，改成由 `launchd` supervised 托管。
2. 修正 global `cantoflow` 啟動器與雙 menubar 實例問題，確保啟動前先安全退出，再交由 `launchd` 或 app bundle 啟動。

目前使用者已確認：
- `push-to-talk` (`F15`) 恢復正常
- menubar 不再雙開
- `cantoflow` 已使用新的「先 clean quit，再 launchd kickstart」流程

---

## 已完成修復

### 1. LaunchAgent supervision

**問題**
- 之前 `~/Library/LaunchAgents/com.cantoflow.launchagent.plist`
  - `RunAtLoad = 1`
  - `KeepAlive = 0`
- 造成 app clean exit / abnormal exit 後都變成 one-shot，`launchctl print` 長時間停在 `not running`

**修復**
- `LaunchAtLoginManager` 改成統一生成：
  - stable wrapper: `~/Library/Application Support/CantoFlow/launchd-wrapper.sh`
  - stable working dir: `~/Library/Application Support/CantoFlow`
  - `ProgramArguments` 只指向上述 wrapper
  - `KeepAlive = { SuccessfulExit = false }`

**原因**
- `KeepAlive = true` 會連使用者手動 Quit 都強制拉起，UX 太差
- `SuccessfulExit = false` 的行為更接近需要：
  - `exit 0`：不重拉
  - crash / SIGKILL / 非 0 退出：自動重拉

**實際驗證**
- `kill -9` launchd 托管中的 app 後，`launchd` 成功自動拉起新 PID
- `osascript -e 'tell application "CantoFlow" to quit'` 後，`launchctl print` 顯示 `last exit code = 0` 且 job 保持 `not running`

---

### 2. Global launcher / manual launch path

**問題**
- 使用者真正執行的 global command 不是 repo 內 `app/scripts/run.sh`
- 而是本機 `~/bin/cantoflow`
- 舊版 `~/bin/cantoflow` 只是 `open -a "/Applications/CantoFlow.app"`，不會先關舊實例，也不會優先走 launchd supervision

**修復**
- 本機 `~/bin/cantoflow` 已換成新 wrapper，行為是：
  1. 記錄 `~/Library/Logs/CantoFlow.manual.log`
  2. 若已有 CantoFlow instance，先 `osascript` 請 app clean quit
  3. 最多等 5 秒，仍未退出才 `TERM` / `KILL`
  4. 若已安裝 LaunchAgent 且無額外 args，執行
     `launchctl kickstart -k gui/<uid>/com.cantoflow.launchagent`
  5. 否則才 `open -n /Applications/CantoFlow.app --args ...`

**同步回 repo**
- root `install.sh` 已更新，將來重裝時會重建同一套 `~/bin/cantoflow`
- `INSTALL.md` 也已同步新做法

---

### 3. 雙 menubar 問題

**根因**
- 同時有兩個 app instance 在跑：
  - 一個是手動 `open /Applications/CantoFlow.app`
  - 一個是 `launchd` 托管的 `/Applications/CantoFlow.app/Contents/MacOS/cantoflow`

**修復後狀態**
- `cantoflow` 現在先 clean quit 舊 instance，再由 launchd kickstart
- 使用者最新一次測試已只剩單一 PID

手動 log 證據：
```text
[2026-03-26T23:38:51Z] manual-launch request
[2026-03-26T23:38:51Z] request-clean-quit
[2026-03-26T23:38:51Z] launch-via-launchd | label=com.cantoflow.launchagent
```

---

### 4. F15 push-to-talk 一度失效

**根因**
- 重新打包 / 重簽 `/Applications/CantoFlow.app` 後，macOS TCC 權限需要重新確認
- log 明確顯示：
  - `Warning: Failed to create CGEvent tap. Enable Accessibility + Input Monitoring.`
  - `Warning: Failed to create learning hotkey event tap.`

**處理**
- 使用者重新授權後，`F15` 已恢復正常

這不是 hotkey code regression，而是 TCC permission state 問題。

---

## 目前狀態

截至 2026-03-27 07:58 HKT：

- 最新 commit：`e437c9f`
- commit message：`fix(macos): supervise app launch and harden launcher flow`
- `launchd` supervision：✅ working
- abnormal exit relaunch：✅ verified
- clean quit no relaunch：✅ verified
- global `cantoflow`：✅ 先 clean quit，再 supervised start
- `F15` push-to-talk：✅ working
- menubar duplicate instances：✅ resolved

目前工作樹：
- repo 內已 clean
- 只剩未追蹤 `.claude/`

---

## 重要檔案

- `app/Sources/CantoFlowApp/Utils/LaunchAtLoginManager.swift`
- `app/Sources/CantoFlowApp/Utils/RuntimeHealthMonitor.swift`
- `app/Sources/CantoFlowApp/AppDelegate.swift`
- `app/Sources/CantoFlowApp/UI/MenuBarController.swift`
- `app/Sources/CantoFlowApp/UI/Settings/SettingsWindowController.swift`
- `app/scripts/run.sh`
- `install.sh`
- `INSTALL.md`

本機運行相關：
- `~/Library/LaunchAgents/com.cantoflow.launchagent.plist`
- `~/Library/Application Support/CantoFlow/launchd-wrapper.sh`
- `~/Library/Logs/CantoFlow.launchd.log`
- `~/Library/Application Support/CantoFlow/runtime_health.log`
- `~/Library/Logs/CantoFlow.manual.log`

---

## 建議後續觀察

接下來先讓使用者試跑幾日，重點觀察：

1. `launchd` 托管下，是否仍會無故掉線
2. `runtime_health.log` 是否持續出現 unexpected exits
3. `CantoFlow.launchd.log` 是否再出現 event tap / permission 相關錯誤
4. 是否再出現雙開或手動啟動繞過 supervision 的情況

若之後再出問題，先看兩份 log：

```bash
tail -n 50 ~/Library/Logs/CantoFlow.launchd.log
tail -n 50 ~/Library/Application\ Support/CantoFlow/runtime_health.log
```

若是手動啟動流程問題，再加看：

```bash
tail -n 50 ~/Library/Logs/CantoFlow.manual.log
```

---

## 下次接手時的最短檢查清單

```bash
git rev-parse --short HEAD
launchctl print gui/$(id -u)/com.cantoflow.launchagent | sed -n '1,80p'
ps -Ao pid=,ppid=,stat=,command= | rg '/Applications/CantoFlow.app/Contents/MacOS/cantoflow'
tail -n 30 ~/Library/Logs/CantoFlow.launchd.log
tail -n 30 ~/Library/Application\ Support/CantoFlow/runtime_health.log
tail -n 30 ~/Library/Logs/CantoFlow.manual.log
```

預期：
- 只有一個 CantoFlow PID
- `launchd` job 若在跑，應顯示 `state = running`
- clean quit 後 `last exit code = 0`
- abnormal kill 後應被重拉
