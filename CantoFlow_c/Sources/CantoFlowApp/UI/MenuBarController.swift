import AppKit

/// UI state for the menu bar
enum UIState: String {
    case idle
    case recording
    case processing
}

/// Menu bar controller for CantoFlow_c
final class MenuBarController: NSObject {
    private let config: AppConfig
    private let pipeline: STTPipeline

    private var statusItem: NSStatusItem!
    private let menu = NSMenu()
    private var toggleItem: NSMenuItem?

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
        let hint = NSMenuItem(title: "Fn or F12: Start / Stop", action: nil, keyEquivalent: "")
        hint.isEnabled = false
        menu.addItem(hint)
        menu.addItem(NSMenuItem.separator())

        let toggle = NSMenuItem(title: "Start Recording", action: #selector(toggleRecordingFromMenu), keyEquivalent: "")
        toggle.target = self
        menu.addItem(toggle)
        toggleItem = toggle

        let openOut = NSMenuItem(title: "Open Output Folder", action: #selector(openOutputFolder), keyEquivalent: "")
        openOut.target = self
        menu.addItem(openOut)

        menu.addItem(NSMenuItem.separator())

        let quit = NSMenuItem(title: "Quit CantoFlow_c", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    // MARK: - UI Updates

    private func updateStatusUI() {
        guard let button = statusItem.button else { return }

        let title: String
        let symbolName: String
        let tint: NSColor?

        switch state {
        case .idle:
            title = " CantoFlow_c"
            symbolName = "mic.fill"
            tint = nil
        case .recording:
            title = " CantoFlow_c REC"
            symbolName = "record.circle.fill"
            tint = NSColor.systemRed
        case .processing:
            title = " CantoFlow_c..."
            symbolName = "hourglass.circle.fill"
            tint = NSColor.systemOrange
        }

        button.title = title
        button.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "CantoFlow_c")
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
            try pipeline.startRecording()
            state = .recording
            NotificationManager.shared.notify("Recording started")
        } catch {
            NotificationManager.shared.notifyError("Failed to start recording: \(error.localizedDescription)")
            state = .idle
        }
    }

    private func stopRecordingAndProcess() {
        guard state == .recording else { return }

        state = .processing

        Task {
            do {
                let result = try await pipeline.stopAndProcess()
                await MainActor.run {
                    NotificationManager.shared.notifySuccess(
                        recordMs: result.recordingMs,
                        sttMs: result.sttMs,
                        polishMs: result.polishMs
                    )
                    state = .idle
                }
            } catch let error as PipelineError {
                await MainActor.run {
                    switch error {
                    case .recordingTooShort(let ms):
                        NotificationManager.shared.notify("Recording too short (\(ms)ms). Hold Fn for at least 1.5s.")
                    default:
                        NotificationManager.shared.notifyError(error.localizedDescription)
                    }
                    state = .idle
                }
            } catch {
                await MainActor.run {
                    NotificationManager.shared.notifyError(error.localizedDescription)
                    state = .idle
                }
            }
        }
    }
}
