import AppKit
import AVFoundation

/// State of the recording overlay
enum OverlayState {
    case recording
    case transcribing
    case polishing
    case complete
    case cancelled
}

/// Floating panel that shows recording status and waveform
final class RecordingOverlayPanel: NSPanel {
    /// Overlay state
    private(set) var overlayState: OverlayState = .recording {
        didSet {
            updateUIForState()
        }
    }

    // MARK: - UI Components

    private let containerView = NSVisualEffectView()
    private let cancelButton = NSButton()
    private let doneButton = NSButton()
    private let statusLabel = NSTextField()
    private let waveformView = WaveformView()
    private let micLabel = NSTextField()
    private let spinnerView = NSProgressIndicator()

    // MARK: - Callbacks

    var onCancel: (() -> Void)?
    var onDone: (() -> Void)?

    // MARK: - Constants

    private static let panelWidth: CGFloat = 480
    private static let panelHeight: CGFloat = 120
    private static let cornerRadius: CGFloat = 16
    private static let bottomMargin: CGFloat = 80

    // MARK: - Audio Monitoring

    private var audioEngine: AVAudioEngine?
    private var levelUpdateTimer: Timer?

    // MARK: - Initialization

    override init(
        contentRect: NSRect,
        styleMask style: NSWindow.StyleMask,
        backing backingStoreType: NSWindow.BackingStoreType,
        defer flag: Bool
    ) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        setupPanel()
        setupUI()
    }

    /// Create a recording overlay panel positioned at the bottom of the screen
    static func create() -> RecordingOverlayPanel {
        // Get the screen with the mouse
        let mouseLocation = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouseLocation, $0.frame, false) } ?? NSScreen.main

        let screenFrame = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1920, height: 1080)

        // Position at bottom center
        let x = screenFrame.origin.x + (screenFrame.width - panelWidth) / 2
        let y = screenFrame.origin.y + bottomMargin

        let rect = NSRect(x: x, y: y, width: panelWidth, height: panelHeight)
        return RecordingOverlayPanel(contentRect: rect, styleMask: [], backing: .buffered, defer: false)
    }

    // MARK: - Setup

    private func setupPanel() {
        // Panel settings
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]

        // Don't become key window (keep focus on current app)
        becomesKeyOnlyIfNeeded = true
    }

    private func setupUI() {
        // Container with vibrancy effect
        containerView.frame = NSRect(x: 0, y: 0, width: Self.panelWidth, height: Self.panelHeight)
        containerView.material = .hudWindow
        containerView.blendingMode = .behindWindow
        containerView.state = .active
        containerView.wantsLayer = true
        containerView.layer?.cornerRadius = Self.cornerRadius
        containerView.layer?.masksToBounds = true

        contentView = containerView

        // Cancel button (top left)
        cancelButton.frame = NSRect(x: 16, y: Self.panelHeight - 36, width: 24, height: 24)
        cancelButton.bezelStyle = .circular
        cancelButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Cancel")
        cancelButton.target = self
        cancelButton.action = #selector(cancelClicked)
        cancelButton.isBordered = false
        containerView.addSubview(cancelButton)

        // Done button (top right)
        doneButton.frame = NSRect(x: Self.panelWidth - 40, y: Self.panelHeight - 36, width: 24, height: 24)
        doneButton.bezelStyle = .circular
        doneButton.image = NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: "Done")
        doneButton.contentTintColor = .systemGreen
        doneButton.target = self
        doneButton.action = #selector(doneClicked)
        doneButton.isBordered = false
        containerView.addSubview(doneButton)

        // Status label (top center)
        statusLabel.frame = NSRect(x: 50, y: Self.panelHeight - 36, width: Self.panelWidth - 100, height: 24)
        statusLabel.stringValue = "Listening..."
        statusLabel.alignment = .center
        statusLabel.font = .systemFont(ofSize: 14, weight: .medium)
        statusLabel.textColor = .labelColor
        statusLabel.isBezeled = false
        statusLabel.drawsBackground = false
        statusLabel.isEditable = false
        statusLabel.isSelectable = false
        containerView.addSubview(statusLabel)

        // Waveform view (center)
        waveformView.frame = NSRect(x: 20, y: 30, width: Self.panelWidth - 40, height: 50)
        waveformView.barColor = .systemBlue
        containerView.addSubview(waveformView)

        // Spinner (hidden by default)
        spinnerView.frame = NSRect(x: (Self.panelWidth - 24) / 2, y: 45, width: 24, height: 24)
        spinnerView.style = .spinning
        spinnerView.isHidden = true
        containerView.addSubview(spinnerView)

        // Mic label (bottom center)
        micLabel.frame = NSRect(x: 20, y: 8, width: Self.panelWidth - 40, height: 16)
        micLabel.stringValue = getMicrophoneName()
        micLabel.alignment = .center
        micLabel.font = .systemFont(ofSize: 11)
        micLabel.textColor = .secondaryLabelColor
        micLabel.isBezeled = false
        micLabel.drawsBackground = false
        micLabel.isEditable = false
        micLabel.isSelectable = false
        containerView.addSubview(micLabel)
    }

    // MARK: - State Management

    func setState(_ state: OverlayState) {
        overlayState = state
    }

    private func updateUIForState() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }

            switch self.overlayState {
            case .recording:
                self.statusLabel.stringValue = "Listening..."
                self.waveformView.isHidden = false
                self.spinnerView.isHidden = true
                self.spinnerView.stopAnimation(nil)
                self.cancelButton.isEnabled = true
                self.doneButton.isEnabled = true
                self.waveformView.barColor = .systemBlue

            case .transcribing:
                self.statusLabel.stringValue = "Transcribing..."
                self.waveformView.isHidden = false
                self.spinnerView.isHidden = true
                self.cancelButton.isEnabled = false
                self.doneButton.isEnabled = false
                self.waveformView.barColor = .systemGray
                self.waveformView.setIdle()

            case .polishing:
                self.statusLabel.stringValue = "Polishing..."
                self.waveformView.isHidden = true
                self.spinnerView.isHidden = false
                self.spinnerView.startAnimation(nil)
                self.cancelButton.isEnabled = false
                self.doneButton.isEnabled = false

            case .complete:
                self.statusLabel.stringValue = "Done"
                self.waveformView.isHidden = true
                self.spinnerView.isHidden = true
                self.spinnerView.stopAnimation(nil)
                self.cancelButton.isEnabled = false
                self.doneButton.isEnabled = false
                // Auto-hide after delay
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                    self?.hideWithAnimation()
                }

            case .cancelled:
                self.hideWithAnimation()
            }
        }
    }

    // MARK: - Audio Level Monitoring

    func startAudioMonitoring() {
        stopAudioMonitoring()

        audioEngine = AVAudioEngine()
        guard let engine = audioEngine else { return }

        let inputNode = engine.inputNode
        let format = inputNode.outputFormat(forBus: 0)

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.processAudioBuffer(buffer)
        }

        do {
            try engine.start()
            waveformView.startAnimation()
        } catch {
            print("Failed to start audio monitoring: \(error)")
        }
    }

    func stopAudioMonitoring() {
        waveformView.stopAnimation()

        if let engine = audioEngine {
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
        }
        audioEngine = nil

        levelUpdateTimer?.invalidate()
        levelUpdateTimer = nil
    }

    private func processAudioBuffer(_ buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData?[0] else { return }
        let frameLength = Int(buffer.frameLength)

        // Calculate RMS level
        var sum: Float = 0
        for i in 0..<frameLength {
            sum += channelData[i] * channelData[i]
        }
        let rms = sqrt(sum / Float(frameLength))

        // Convert to dB and normalize
        let db = 20 * log10(max(rms, 0.0001))
        let normalizedLevel = (db + 60) / 60 // Normalize to 0-1 range (assuming -60dB to 0dB range)

        DispatchQueue.main.async { [weak self] in
            self?.waveformView.updateLevel(normalizedLevel)
        }
    }

    // MARK: - Show/Hide Animation

    func showWithAnimation() {
        alphaValue = 0
        orderFront(nil)

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            self.animator().alphaValue = 1

            // Slide up from below
            var frame = self.frame
            frame.origin.y += 20
            self.setFrame(frame, display: false)

            frame.origin.y -= 20
            self.animator().setFrame(frame, display: true)
        }

        startAudioMonitoring()
    }

    func hideWithAnimation() {
        stopAudioMonitoring()

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.15
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            self.animator().alphaValue = 0

            // Slide down
            var frame = self.frame
            frame.origin.y -= 20
            self.animator().setFrame(frame, display: true)
        }, completionHandler: { [weak self] in
            self?.orderOut(nil)
        })
    }

    // MARK: - Actions

    @objc private func cancelClicked() {
        onCancel?()
    }

    @objc private func doneClicked() {
        onDone?()
    }

    // MARK: - Helpers

    private func getMicrophoneName() -> String {
        let devices = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInMicrophone, .externalUnknown],
            mediaType: .audio,
            position: .unspecified
        ).devices

        if let device = devices.first {
            return device.localizedName
        }
        return "Microphone"
    }

    // MARK: - Window Behavior

    override var canBecomeKey: Bool {
        return false // Don't steal focus from other apps
    }

    override var canBecomeMain: Bool {
        return false
    }
}
