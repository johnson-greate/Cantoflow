import AppKit

/// UI state for the menu bar
enum UIState: String {
    case idle
    case recording
    case processing
}

/// Menu bar controller for CantoFlow_c
final class MenuBarController: NSObject, PushToTalkDelegate {
    private let config: AppConfig
    private let pipeline: STTPipeline

    private var statusItem: NSStatusItem!
    private let menu = NSMenu()
    private var toggleItem: NSMenuItem?

    // Last transcription telemetry display
    private var telemetryItem: NSMenuItem?

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
        // ── Usage hint ─────────────────────────────────────────────────────────
        let hint = NSMenuItem(title: "Hold Fn or F15 to record", action: nil, keyEquivalent: "")
        hint.isEnabled = false
        menu.addItem(hint)

        menu.addItem(.separator())

        // ── Recording control (most prominent) ─────────────────────────────────
        let toggle = NSMenuItem(
            title: "Start Recording",
            action: #selector(toggleRecordingFromMenu),
            keyEquivalent: "r"
        )
        toggle.target = self
        toggle.image = menuImage("mic.fill")
        menu.addItem(toggle)
        toggleItem = toggle
        applyBoldTitle("Start Recording", to: toggle)

        menu.addItem(.separator())

        // ── Last transcription telemetry ───────────────────────────────────────
        let telemetry = NSMenuItem(title: "上次: — 未有記錄 —", action: nil, keyEquivalent: "")
        telemetry.isEnabled = false
        menu.addItem(telemetry)
        telemetryItem = telemetry

        menu.addItem(.separator())

        // ── Settings & utilities ───────────────────────────────────────────────
        let settings = NSMenuItem(
            title: "Settings...",
            action: #selector(openSettings),
            keyEquivalent: ","
        )
        settings.target = self
        settings.image = menuImage("gear")
        menu.addItem(settings)

        let openOut = NSMenuItem(
            title: "Open Output Folder",
            action: #selector(openOutputFolder),
            keyEquivalent: ""
        )
        openOut.target = self
        openOut.image = menuImage("folder")
        menu.addItem(openOut)

        menu.addItem(.separator())

        // ── Quit ───────────────────────────────────────────────────────────────
        let quit = NSMenuItem(
            title: "Quit CantoFlow",
            action: #selector(quitApp),
            keyEquivalent: "q"
        )
        quit.target = self
        menu.addItem(quit)

        // Version info (disabled, display only) — dynamic: binary mtime yyyyMMdd.HHmm
        let versionItem = NSMenuItem(
            title: "Version \(appBuildVersion)",
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

    /// Applies bold system font to a menu item's attributed title.
    private func applyBoldTitle(_ title: String, to item: NSMenuItem) {
        let boldFont = NSFont.boldSystemFont(ofSize: NSFont.systemFontSize)
        item.attributedTitle = NSAttributedString(
            string: title,
            attributes: [.font: boldFont]
        )
    }

    // MARK: - Telemetry Display

    private func updateTelemetryItem(_ result: PipelineResult) {
        let chars = result.finalText.count
        let sttSec    = String(format: "%.1f", Double(result.sttMs)    / 1000.0)
        let polishSec = String(format: "%.1f", Double(result.polishMs) / 1000.0)
        let totalSec  = String(format: "%.1f", Double(result.sttMs + result.polishMs) / 1000.0)

        let polishLabel = result.polishMs > 0 ? " · LLM \(polishSec)s" : ""
        let title = "上次: \(chars)字 · STT \(sttSec)s\(polishLabel) · 共 \(totalSec)s"

        // Called from inside MainActor.run {} — already on main thread.
        // Direct assignment avoids an extra GCD block lifecycle.
        telemetryItem?.title = title
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
            title = " REC"
            symbolName = "record.circle.fill"
            tint = NSColor.systemRed
        case .processing:
            title = " ..."
            symbolName = "hourglass.circle.fill"
            tint = NSColor.systemOrange
        }

        button.title = title
        button.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "CantoFlow")
        button.imagePosition = .imageLeading
        button.contentTintColor = tint

        switch state {
        case .idle:
            toggleItem?.image = menuImage("mic.fill")
            if let item = toggleItem { applyBoldTitle("Start Recording", to: item) }
        case .recording:
            toggleItem?.attributedTitle = nil
            toggleItem?.title = "Stop Recording"
            toggleItem?.image = menuImage("stop.circle.fill")
        case .processing:
            toggleItem?.attributedTitle = nil
            toggleItem?.title = "Processing..."
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

    @objc private func openSettings() {
        SettingsWindowController.shared.show()
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
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
                    NotificationManager.shared.notify("Microphone permission denied.")
                }
            }
        }
    }

    private func startRecordingNow() {
        guard state == .idle else { return }

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
            NotificationManager.shared.notifyError("Failed to start recording: \(error.localizedDescription)")
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
                    self.state = .idle
                    self.pushToTalkManager?.markProcessingComplete()
                }
            } catch let error as PipelineError {
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.hideOverlay()
                    switch error {
                    case .recordingTooShort(let ms):
                        NotificationManager.shared.notify("Recording too short (\(ms)ms). Hold for at least 0.3s.")
                    default:
                        NotificationManager.shared.notifyError(error.localizedDescription)
                    }
                    self.state = .idle
                    self.pushToTalkManager?.markProcessingComplete()
                }
            } catch {
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.hideOverlay()
                    NotificationManager.shared.notifyError(error.localizedDescription)
                    self.state = .idle
                    self.pushToTalkManager?.markProcessingComplete()
                }
            }
        }
    }

    private func cancelRecording() {
        guard state == .recording else { return }
        pipeline.cancelRecording()
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
}
