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

    /// Overlay panel for recording feedback
    private var overlayPanel: RecordingOverlayPanel?

    /// Reference to PushToTalkManager (set by AppDelegate)
    weak var pushToTalkManager: PushToTalkManager?

    /// Whether to show overlay during recording
    var showOverlay: Bool = true

    private var state: UIState = .idle {
        didSet {
            DispatchQueue.main.async { [weak self] in
                self?.updateStatusUI()
            }
        }
    }

    init(config: AppConfig, pipeline: STTPipeline) {
        self.config = config
        self.pipeline = pipeline
        super.init()

        DispatchQueue.main.async {
            self.setupStatusItem()
            self.setupMenu()
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
        let hint = NSMenuItem(title: "Hold Fn or F15 to record", action: nil, keyEquivalent: "")
        hint.isEnabled = false
        menu.addItem(hint)
        menu.addItem(NSMenuItem.separator())

        let toggle = NSMenuItem(title: "Start Recording", action: #selector(toggleRecordingFromMenu), keyEquivalent: "")
        toggle.target = self
        menu.addItem(toggle)
        toggleItem = toggle

        menu.addItem(NSMenuItem.separator())

        let manageVocab = NSMenuItem(title: "Manage Vocabulary...", action: #selector(openVocabularySettings), keyEquivalent: ",")
        manageVocab.target = self
        menu.addItem(manageVocab)

        let openOut = NSMenuItem(title: "Open Output Folder", action: #selector(openOutputFolder), keyEquivalent: "")
        openOut.target = self
        menu.addItem(openOut)

        menu.addItem(NSMenuItem.separator())

        let quit = NSMenuItem(title: "Quit CantoFlow", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        // Version info (disabled, for display only)
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        let versionItem = NSMenuItem(title: "Version \(version) (\(build))", action: nil, keyEquivalent: "")
        versionItem.isEnabled = false
        menu.addItem(versionItem)
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
            toggleItem?.title = "Start Recording"
        case .recording:
            toggleItem?.title = "Stop Recording"
        case .processing:
            toggleItem?.title = "Processing..."
        }
    }

    // MARK: - Overlay Management

    private func showRecordingOverlay() {
        guard showOverlay else { return }

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }

            if self.overlayPanel == nil {
                self.overlayPanel = RecordingOverlayPanel.create()
                self.overlayPanel?.onCancel = { [weak self] in
                    self?.cancelRecording()
                }
                self.overlayPanel?.onDone = { [weak self] in
                    self?.stopRecordingAndProcess()
                }
            }

            self.overlayPanel?.setState(.recording)
            self.overlayPanel?.showWithAnimation()
        }
    }

    private func hideOverlay() {
        DispatchQueue.main.async { [weak self] in
            self?.overlayPanel?.hideWithAnimation()
        }
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

    @objc private func openVocabularySettings() {
        VocabularySettingsWindow.shared.showWindow()
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
            // Set up audio level callback for waveform visualization BEFORE starting
            pipeline.onAudioLevelUpdate = { [weak self] level in
                self?.overlayPanel?.updateAudioLevel(level)
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
        overlayPanel?.setState(.transcribing)

        Task {
            do {
                let result = try await pipeline.stopAndProcess()
                await MainActor.run {
                    overlayPanel?.setState(.complete)
                    NotificationManager.shared.notifySuccess(
                        recordMs: result.recordingMs,
                        sttMs: result.sttMs,
                        polishMs: result.polishMs
                    )
                    state = .idle
                    pushToTalkManager?.markProcessingComplete()
                }
            } catch let error as PipelineError {
                await MainActor.run {
                    hideOverlay()
                    switch error {
                    case .recordingTooShort(let ms):
                        NotificationManager.shared.notify("Recording too short (\(ms)ms). Hold for at least 0.3s.")
                    default:
                        NotificationManager.shared.notifyError(error.localizedDescription)
                    }
                    state = .idle
                    pushToTalkManager?.markProcessingComplete()
                }
            } catch {
                await MainActor.run {
                    hideOverlay()
                    NotificationManager.shared.notifyError(error.localizedDescription)
                    state = .idle
                    pushToTalkManager?.markProcessingComplete()
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
