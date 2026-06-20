import AppKit

/// UI state for the menu bar
enum UIState: String {
    case idle
    case recording
    case processing
}

/// Menu bar controller for CantoFlow
final class MenuBarController: NSObject, PushToTalkDelegate {
    private let config: AppConfig
    private let pipeline: STTPipeline
    private let textInserter = TextInserter()

    private var statusItem: NSStatusItem!
    private let menu = NSMenu()
    private var toggleItem: NSMenuItem?

    // Last transcription telemetry display
    private var telemetryItem: NSMenuItem?
    private var runtimeStatusItem: NSMenuItem?
    
    // Copy integration
    private var lastResultText: String?
    private var copyResultItem: NSMenuItem?
    private var learningStatusItem: NSMenuItem?
    
    // Usage hint display
    private var hintItem: NSMenuItem?
    private var inputDeviceItem: NSMenuItem?

    // Output style (polish style) radio items (first-layer)
    private var polishStyleItems: [NSMenuItem] = []

    // File transcription menu item (title reflects batch-active state)
    private var transcribeItem: NSMenuItem?

    /// Reference to PushToTalkManager (set by AppDelegate)
    weak var pushToTalkManager: PushToTalkManager?

    /// Whether to show overlay during recording
    var showOverlay: Bool = true

    private var state: UIState = .idle {
        didSet {
            // state is only ever mutated on the main thread (startRecordingNow,
            // stopRecordingAndProcess via MainActor.run, cancelRecording).
            // Calling updateStatusUI() directly avoids creating a GCD block that
            // could be released during a CA::Transaction::commit and cause a crash.
            updateStatusUI()
        }
    }

    init(config: AppConfig, pipeline: STTPipeline) {
        self.config = config
        self.pipeline = pipeline
        super.init()

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.setupStatusItem()
            self.setupMenu()
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(self.handleLearningStatusChange(_:)),
                name: .cantoFlowLearningStatusDidChange,
                object: nil
            )
            // Wire the settings window to the live pipeline
            SettingsWindowController.shared.pipeline = self.pipeline
            // Wire overlay panel callbacks once. The panel is a singleton that lives
            // for the entire app lifetime, so [weak self] on MenuBarController is
            // sufficient — no need to create/destroy the panel per recording.
            let panel = RecordingOverlayPanel.shared
            panel.onCancel = { [weak self] in self?.cancelRecording() }
            panel.onDone   = { [weak self] in self?.stopRecordingAndProcess() }
        }
    }

    // MARK: - Setup

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        guard let button = statusItem.button else { return }
        button.target = self
        button.action = #selector(onStatusButtonClick)
        button.sendAction(on: [.leftMouseUp])
        updateStatusUI()
    }

    private func setupMenu() {
        menu.delegate = self
        // ── Usage hint ─────────────────────────────────────────────────────────
        let hint = NSMenuItem(title: "按住 Fn 或 F15 錄音", action: nil, keyEquivalent: "")
        hint.isEnabled = false
        menu.addItem(hint)
        hintItem = hint

        let inputDevice = NSMenuItem(title: "輸入: \(AudioDeviceManager.shared.currentSelectionDisplayName())", action: nil, keyEquivalent: "")
        inputDevice.isEnabled = false
        menu.addItem(inputDevice)
        inputDeviceItem = inputDevice

        menu.addItem(.separator())

        // ── Recording control (most prominent) ─────────────────────────────────
        let toggle = NSMenuItem(
            title: "開始錄音",
            action: #selector(toggleRecordingFromMenu),
            keyEquivalent: "r"
        )
        toggle.target = self
        toggle.image = menuImage("mic.fill")
        menu.addItem(toggle)
        toggleItem = toggle
        applyBoldTitle("開始錄音", to: toggle)

        // ── File transcription ─────────────────────────────────────────────────
        let transcribe = NSMenuItem(
            title: "轉錄檔案…",
            action: #selector(openTranscribe),
            keyEquivalent: ""
        )
        transcribe.target = self
        transcribe.image = menuImage("waveform.badge.plus")
        menu.addItem(transcribe)
        transcribeItem = transcribe

        // ── Output style (polish style) — flat radio items on the first layer ───
        let styleHeader = NSMenuItem(title: "輸出風格", action: nil, keyEquivalent: "")
        styleHeader.isEnabled = false
        menu.addItem(styleHeader)

        polishStyleItems = PolishStyle.allCases.map { style in
            let item = NSMenuItem(
                title: style.displayName,
                action: #selector(selectPolishStyle(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = style.rawValue
            menu.addItem(item)
            return item
        }
        updatePolishStyleChecks()

        menu.addItem(.separator())

        // ── Last transcription telemetry ───────────────────────────────────────
        let telemetry = NSMenuItem(title: "上次: — 未有記錄 —", action: nil, keyEquivalent: "")
        telemetry.isEnabled = false
        menu.addItem(telemetry)
        telemetryItem = telemetry

        let runtimeStatus = NSMenuItem(title: "重啟: —", action: nil, keyEquivalent: "")
        runtimeStatus.isEnabled = false
        menu.addItem(runtimeStatus)
        runtimeStatusItem = runtimeStatus
        
        let copyResult = NSMenuItem(
            title: "複製上次結果",
            action: #selector(copyLastResultToClipboard),
            keyEquivalent: "c"
        )
        copyResult.target = self
        copyResult.image = menuImage("doc.on.doc")
        copyResult.isEnabled = false
        menu.addItem(copyResult)
        copyResultItem = copyResult

        let learningStatus = NSMenuItem(title: "學習: 尚無記錄", action: nil, keyEquivalent: "")
        learningStatus.isEnabled = false
        menu.addItem(learningStatus)
        learningStatusItem = learningStatus

        let learnSelection = NSMenuItem(
            title: "學習選中文字",
            action: #selector(learnSelectedText),
            keyEquivalent: "l"
        )
        learnSelection.target = self
        learnSelection.image = menuImage("text.badge.plus")
        menu.addItem(learnSelection)

        menu.addItem(.separator())

        // ── Settings & utilities ───────────────────────────────────────────────
        let settings = NSMenuItem(
            title: "設定...",
            action: #selector(openSettings),
            keyEquivalent: ","
        )
        settings.target = self
        settings.image = menuImage("gear")
        menu.addItem(settings)

        let openOut = NSMenuItem(
            title: "打開輸出資料夾",
            action: #selector(openOutputFolder),
            keyEquivalent: ""
        )
        openOut.target = self
        openOut.image = menuImage("folder")
        menu.addItem(openOut)

        let openRuntimeLog = NSMenuItem(
            title: "打開運行日誌",
            action: #selector(openRuntimeLog),
            keyEquivalent: ""
        )
        openRuntimeLog.target = self
        openRuntimeLog.image = menuImage("doc.text.magnifyingglass")
        menu.addItem(openRuntimeLog)

        let runningInfo = NSMenuItem(
            title: "運行資訊…",
            action: #selector(showRunningInfo),
            keyEquivalent: ""
        )
        runningInfo.target = self
        runningInfo.image = menuImage("internaldrive")
        menu.addItem(runningInfo)

        menu.addItem(.separator())

        // ── Quit ───────────────────────────────────────────────────────────────
        let quit = NSMenuItem(
            title: "結束 CantoFlow",
            action: #selector(quitApp),
            keyEquivalent: "q"
        )
        quit.target = self
        menu.addItem(quit)

        // Version info (disabled, display only) — dynamic: binary mtime yyyyMMdd.HHmm
        let versionItem = NSMenuItem(
            title: "版本 \(appBuildVersion)",
            action: nil,
            keyEquivalent: ""
        )
        versionItem.isEnabled = false
        menu.addItem(versionItem)
    }

    // MARK: - Helpers

    /// Returns a small SF Symbol image sized for menu items.
    private func menuImage(_ symbolName: String) -> NSImage? {
        let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
        return NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(config)
    }

    /// CantoFlow menu-bar mark: rounded waveform bars mirroring the app icon's
    /// Voice Capsule. Rendered as a template image so the system tints it for
    /// light/dark menu bars.
    private func cantoFlowMarkImage() -> NSImage {
        let height: CGFloat = 16
        let barWidth: CGFloat = 2.2
        let gap: CGFloat = 1.8
        // Bar heights trace the icon's forward-flowing waveform contour.
        let ratios: [CGFloat] = [0.40, 0.66, 0.88, 1.0, 0.74, 0.52]
        let width = CGFloat(ratios.count) * barWidth + CGFloat(ratios.count - 1) * gap
        let image = NSImage(size: NSSize(width: width, height: height), flipped: false) { _ in
            for (i, ratio) in ratios.enumerated() {
                let barHeight = max(barWidth, ratio * height)
                let x = CGFloat(i) * (barWidth + gap)
                let y = (height - barHeight) / 2
                let rect = NSRect(x: x, y: y, width: barWidth, height: barHeight)
                NSColor.black.setFill()
                NSBezierPath(roundedRect: rect, xRadius: barWidth / 2, yRadius: barWidth / 2).fill()
            }
            return true
        }
        image.isTemplate = true
        return image
    }

    /// Applies bold system font to a menu item's attributed title.
    private func applyBoldTitle(_ title: String, to item: NSMenuItem) {
        let boldFont = NSFont.boldSystemFont(ofSize: NSFont.systemFontSize)
        item.attributedTitle = NSAttributedString(
            string: title,
            attributes: [.font: boldFont]
        )
    }

    // MARK: - Telemetry & Display Update

    func updateHint(keyName: String) {
        hintItem?.title = "按住 \(keyName) 錄音 · 按 F14 學習"
    }

    func updateInputDevice(name: String) {
        inputDeviceItem?.title = "輸入: \(name)"
    }

    func updateRuntimeStatus(launchesToday: Int, restartsToday: Int, previousExitSummary: String) {
        runtimeStatusItem?.title = "重啟: 今日啟動 \(launchesToday) 次 / 重啟 \(restartsToday) 次 · 上次退出: \(previousExitSummary)"
    }

    private func updateTelemetryItem(_ result: PipelineResult) {
        let chars = result.finalText.count
        let sttSec    = String(format: "%.1f", Double(result.sttMs)    / 1000.0)
        let polishSec = String(format: "%.1f", Double(result.polishMs) / 1000.0)
        let totalSec  = String(format: "%.1f", Double(result.sttMs + result.polishMs) / 1000.0)

        let accel = result.metalEnabled ? "GPU" : "CPU"
        let polishLabel = result.polishMs > 0 ? " · LLM \(polishSec)s" : ""
        let title = "上次: \(chars)字 · \(result.sttModel) \(sttSec)s [\(accel)]\(polishLabel) · 共 \(totalSec)s"

        // Called from inside MainActor.run {} — already on main thread.
        // Direct assignment avoids an extra GCD block lifecycle.
        telemetryItem?.title = title
        
        lastResultText = result.finalText
        copyResultItem?.isEnabled = true
    }

    // MARK: - UI Updates

    private func updateStatusUI() {
        guard let button = statusItem.button else { return }

        let title: String
        let symbolName: String
        let tint: NSColor?

        switch state {
        case .idle:
            title = " CantoFlow"
            symbolName = "mic.fill"
            tint = nil
        case .recording:
            title = " 錄音中"
            symbolName = "record.circle.fill"
            tint = NSColor.systemRed
        case .processing:
            title = " 處理中"
            symbolName = "hourglass.circle.fill"
            tint = NSColor.systemOrange
        }

        button.title = title
        if case .idle = state {
            // Idle: show the CantoFlow waveform mark instead of a generic mic glyph.
            button.image = cantoFlowMarkImage()
        } else {
            button.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "CantoFlow")
        }
        button.imagePosition = .imageLeading
        button.contentTintColor = tint

        switch state {
        case .idle:
            toggleItem?.image = menuImage("mic.fill")
            if let item = toggleItem { applyBoldTitle("開始錄音", to: item) }
        case .recording:
            toggleItem?.attributedTitle = nil
            toggleItem?.title = "停止錄音"
            toggleItem?.image = menuImage("stop.circle.fill")
        case .processing:
            toggleItem?.attributedTitle = nil
            toggleItem?.title = "處理中..."
            toggleItem?.image = nil
        }
    }

    // MARK: - Overlay Management

    private func showRecordingOverlay() {
        guard showOverlay else { return }
        // Use the singleton — no creation/destruction per recording.
        // The panel is retained for the lifetime of the process.
        let panel = RecordingOverlayPanel.shared
        panel.setState(.recording)
        panel.showWithAnimation()
    }

    private func hideOverlay() {
        RecordingOverlayPanel.shared.hideWithAnimation()
    }

    // MARK: - Actions

    @objc private func onStatusButtonClick() {
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func toggleRecordingFromMenu() {
        toggleRecording()
    }

    @objc private func openOutputFolder() {
        NSWorkspace.shared.open(config.outDir)
    }

    @objc private func openRuntimeLog() {
        NSWorkspace.shared.open(RuntimeHealthMonitor.shared.runtimeLogURL())
    }

    @objc private func openSettings() {
        SettingsWindowController.shared.show()
    }

    @objc private func openTranscribe() {
        MainActor.assumeIsolated {
            TranscribeWindowController.showShared(config: config)
        }
    }

    @objc private func showRunningInfo() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let info = RunningInfo.collect(config: self.config)
            DispatchQueue.main.async {
                let alert = NSAlert()
                alert.messageText = "CantoFlow 運行資訊"
                alert.informativeText = info.summary()
                alert.addButton(withTitle: "好")
                alert.addButton(withTitle: "複製")
                NSApp.activate(ignoringOtherApps: true)
                if alert.runModal() == .alertSecondButtonReturn {
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString("CantoFlow 運行資訊\n\(info.summary())", forType: .string)
                }
            }
        }
    }

    @objc private func selectPolishStyle(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String else { return }
        UserDefaults.standard.set(raw, forKey: "polishStyle")
        updatePolishStyleChecks()
    }

    /// Reflect the current polishStyle (which may also change in Settings) as a
    /// checkmark on the matching submenu item.
    private func updatePolishStyleChecks() {
        let current = UserDefaults.standard.string(forKey: "polishStyle") ?? PolishStyle.cantonese.rawValue
        polishStyleItems.forEach { item in
            item.state = (item.representedObject as? String == current) ? .on : .off
        }
    }

    @objc private func quitApp() {
        RuntimeHealthMonitor.shared.markGracefulTermination(reason: "user_quit_menu")
        NSApp.terminate(nil)
    }

    @objc private func copyLastResultToClipboard() {
        guard let text = lastResultText else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        
        let preview = text.count > 15 ? text.prefix(15) + "..." : text
        NotificationManager.shared.notify("已複製: \(preview)")
    }

    @MainActor @objc private func learnSelectedText() {
        triggerLearning()
    }

    @MainActor
    func triggerLearning() {
        switch CorrectionWatcher.shared.learnNow() {
        case .added(let terms):
            let list = terms.joined(separator: "、")
            LearningFeedback.shared.record("F14 learned correction", detail: list)
            NotificationManager.shared.notify("已學習修訂：\(list)", title: "CantoFlow 學習")
            return
        case .alreadyKnown(let terms):
            let list = terms.joined(separator: "、")
            LearningFeedback.shared.record("F14 correction already known", detail: list)
            NotificationManager.shared.notify("修訂詞已在詞庫中：\(list)", title: "CantoFlow 學習")
            return
        case .unchanged, .noActiveSession, .regionNotFound, .noCandidates, .unreadableField:
            LearningFeedback.shared.record("F14 correction learning fell back")
            break
        }

        learnCurrentSelectionFallback()
    }

    @MainActor
    private func learnCurrentSelectionFallback() {
        guard let selectedText = textInserter.captureSelectedText(),
              let term = sanitizeSelectedTerm(selectedText) else {
            LearningFeedback.shared.record("F14 learning failed", detail: "no correction result and AX selected text unavailable")
            NotificationManager.shared.notify("未能學習修訂，也未能讀取目前選中文字。", title: "CantoFlow 學習")
            return
        }

        let entry = VocabEntry(
            term: term,
            pronunciationHint: nil,
            category: .other,
            notes: "手動選取學習"
        )

        if VocabularyStore.shared.addPersonalEntry(entry) {
            LearningFeedback.shared.record("F14 learned selection", detail: term)
            NotificationManager.shared.notify("已加入詞庫：\(term)", title: "CantoFlow 學習")
            print("[LearnSelectedText] Added vocabulary: \(term)")
        } else {
            LearningFeedback.shared.record("F14 selection skipped", detail: term)
            NotificationManager.shared.notify("詞庫已存在或容量已滿：\(term)", title: "CantoFlow 學習")
            print("[LearnSelectedText] Skipped vocabulary: \(term)")
        }
    }

    @objc private func handleLearningStatusChange(_ notification: Notification) {
        guard let summary = notification.userInfo?["summary"] as? String else { return }
        learningStatusItem?.title = "學習: \(summary)"
    }

    private func sanitizeSelectedTerm(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard !trimmed.contains("\n"), !trimmed.contains("\r") else { return nil }
        guard trimmed.count <= 32 else { return nil }
        let punctuation = CharacterSet.punctuationCharacters
        let symbols = CharacterSet.symbols
        let whitespace = CharacterSet.whitespacesAndNewlines
        guard trimmed.unicodeScalars.contains(where: {
            !punctuation.contains($0) && !symbols.contains($0) && !whitespace.contains($0)
        }) else {
            return nil
        }
        return trimmed
    }

    // MARK: - Recording Control

    /// Toggle recording state (called by hotkey or menu)
    func toggleRecording() {
        switch state {
        case .idle:
            startRecording()
        case .recording:
            stopRecordingAndProcess()
        case .processing:
            NSSound.beep()
        }
    }

    private func startRecording() {
        guard state == .idle else { return }

        pipeline.requestMicrophonePermission { [weak self] granted in
            DispatchQueue.main.async {
                if granted {
                    self?.startRecordingNow()
                } else {
                    NotificationManager.shared.notify("麥克風權限被拒絕，請在系統設定中開啟。")
                }
            }
        }
    }

    private func startRecordingNow() {
        guard state == .idle else { return }

        // Don't start a second ASR consumer while a file batch owns the engine.
        guard ASRWorkCoordinator.shared.tryAcquire(.pushToTalk) else {
            NotificationManager.shared.notify("檔案轉錄進行中，請先停止再錄音。")
            return
        }

        do {
            // Set up audio level callback for waveform visualization BEFORE starting.
            // RecordingOverlayPanel.shared is always alive; no weak capture needed.
            pipeline.onAudioLevelUpdate = { level in
                RecordingOverlayPanel.shared.updateAudioLevel(level)
            }

            try pipeline.startRecording()
            state = .recording
            showRecordingOverlay()
        } catch {
            ASRWorkCoordinator.shared.release(.pushToTalk)
            NotificationManager.shared.notifyError("錄音啟動失敗: \(error.localizedDescription)")
            state = .idle
        }
    }

    private func stopRecordingAndProcess() {
        guard state == .recording else { return }

        state = .processing
        RecordingOverlayPanel.shared.setState(.transcribing)

        Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await self.pipeline.stopAndProcess()
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    RecordingOverlayPanel.shared.setState(.complete)
                    self.updateTelemetryItem(result)
                    NotificationManager.shared.notifySuccess(
                        recordMs: result.recordingMs,
                        sttMs: result.sttMs,
                        polishMs: result.polishMs
                    )
                    ASRWorkCoordinator.shared.release(.pushToTalk)
                    self.state = .idle
                    self.pushToTalkManager?.markProcessingComplete()
                }
            } catch let error as PipelineError {
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.hideOverlay()
                    switch error {
                    case .recordingTooShort(let ms):
                        NotificationManager.shared.notify("錄音太短（\(ms)ms），請按住至少 0.3 秒。")
                    default:
                        NotificationManager.shared.notifyError(error.localizedDescription)
                    }
                    ASRWorkCoordinator.shared.release(.pushToTalk)
                    self.state = .idle
                    self.pushToTalkManager?.markProcessingComplete()
                }
            } catch {
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.hideOverlay()
                    NotificationManager.shared.notifyError(error.localizedDescription)
                    ASRWorkCoordinator.shared.release(.pushToTalk)
                    self.state = .idle
                    self.pushToTalkManager?.markProcessingComplete()
                }
            }
        }
    }

    private func cancelRecording() {
        guard state == .recording else { return }
        pipeline.cancelRecording()
        ASRWorkCoordinator.shared.release(.pushToTalk)
        hideOverlay()
        state = .idle
    }

    // MARK: - PushToTalkDelegate

    func pushToTalkDidStartRecording() {
        startRecording()
    }

    func pushToTalkDidStopRecording(duration: TimeInterval) {
        stopRecordingAndProcess()
    }

    func pushToTalkDidCancel(reason: String) {
        cancelRecording()
        NotificationManager.shared.notify(reason)
    }

    func pushToTalkStateDidChange(_ state: PushToTalkState) {
        // Additional state change handling if needed
    }

    func pushToTalkDidLoseEventTap() {
        NotificationManager.shared.notifyError(
            "快捷鍵監聽已失效，請重新啟動 CantoFlow。如持續出現，請到系統設定重新開啟「輔助使用」及「輸入監控」權限。"
        )
    }
}

// MARK: - NSMenuDelegate

extension MenuBarController: NSMenuDelegate {
    /// Refresh the output-style checkmarks when the submenu opens, so a change
    /// made in Settings is reflected here too.
    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === self.menu {
            updatePolishStyleChecks()
            let active = MainActor.assumeIsolated { TranscribeWindowController.shared?.isBatchActive ?? false }
            transcribeItem?.title = active ? "檔案轉錄中…" : "轉錄檔案…"
        }
    }
}
