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

/// Compact floating panel that shows recording status and waveform (Dynamic Island style)
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

    // MARK: - Callbacks

    var onCancel: (() -> Void)?
    var onDone: (() -> Void)?

    // MARK: - Constants (Compact Capsule Design)

    private static let panelWidth: CGFloat = 280
    private static let panelHeight: CGFloat = 56
    private static let cornerRadius: CGFloat = 28  // height / 2 for capsule
    private static let bottomMargin: CGFloat = 80

    /// Stored correct position (to prevent drift)
    private var targetFrame: NSRect = .zero

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
        let panel = RecordingOverlayPanel(contentRect: rect, styleMask: [], backing: .buffered, defer: false)
        panel.targetFrame = rect  // Store the correct position
        return panel
    }

    // MARK: - Setup

    private func setupPanel() {
        // Panel settings - critical for not stealing focus
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]

        // Critical: Don't become key window (keep focus on current app)
        becomesKeyOnlyIfNeeded = true

        // Ensure mouse events pass through non-interactive areas
        ignoresMouseEvents = false
    }

    private func setupUI() {
        // Container with vibrancy effect (capsule shape)
        containerView.frame = NSRect(x: 0, y: 0, width: Self.panelWidth, height: Self.panelHeight)
        containerView.material = .hudWindow
        containerView.blendingMode = .behindWindow
        containerView.state = .active
        containerView.wantsLayer = true
        containerView.layer?.cornerRadius = Self.cornerRadius
        containerView.layer?.masksToBounds = true

        contentView = containerView

        // Cancel button (left side) - small, circular
        cancelButton.frame = NSRect(x: 12, y: (Self.panelHeight - 28) / 2, width: 28, height: 28)
        cancelButton.bezelStyle = .circular
        cancelButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Cancel")
        cancelButton.imageScaling = .scaleProportionallyDown
        cancelButton.target = self
        cancelButton.action = #selector(cancelClicked)
        cancelButton.isBordered = false
        cancelButton.refusesFirstResponder = true
        containerView.addSubview(cancelButton)

        // Done button (right side) - small, circular
        doneButton.frame = NSRect(x: Self.panelWidth - 40, y: (Self.panelHeight - 28) / 2, width: 28, height: 28)
        doneButton.bezelStyle = .circular
        doneButton.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: "Done")
        doneButton.contentTintColor = .systemGreen
        doneButton.imageScaling = .scaleProportionallyDown
        doneButton.target = self
        doneButton.action = #selector(doneClicked)
        doneButton.isBordered = false
        doneButton.refusesFirstResponder = true
        containerView.addSubview(doneButton)

        // Waveform view (center, compact)
        let waveformWidth: CGFloat = 140
        let waveformHeight: CGFloat = 32
        waveformView.frame = NSRect(
            x: (Self.panelWidth - waveformWidth) / 2,
            y: (Self.panelHeight - waveformHeight) / 2,
            width: waveformWidth,
            height: waveformHeight
        )
        waveformView.barColor = .systemBlue
        containerView.addSubview(waveformView)

        // Status label (overlaid on waveform, centered)
        statusLabel.frame = NSRect(x: 48, y: (Self.panelHeight - 20) / 2, width: Self.panelWidth - 96, height: 20)
        statusLabel.stringValue = ""
        statusLabel.alignment = .center
        statusLabel.font = .systemFont(ofSize: 12, weight: .medium)
        statusLabel.textColor = .labelColor
        statusLabel.isBezeled = false
        statusLabel.drawsBackground = false
        statusLabel.isEditable = false
        statusLabel.isSelectable = false
        statusLabel.isHidden = true  // Only show during processing states
        containerView.addSubview(statusLabel)
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
                self.statusLabel.isHidden = true
                self.waveformView.isHidden = false
                self.cancelButton.isEnabled = true
                self.doneButton.isEnabled = true
                self.waveformView.barColor = .systemBlue
                self.waveformView.setMode(.live)

            case .transcribing:
                self.statusLabel.stringValue = "Transcribing..."
                self.statusLabel.isHidden = false
                self.waveformView.isHidden = false
                self.cancelButton.isEnabled = false
                self.doneButton.isEnabled = false
                self.waveformView.barColor = .systemGray
                self.waveformView.setMode(.processing)

            case .polishing:
                self.statusLabel.stringValue = "Polishing..."
                self.statusLabel.isHidden = false
                self.waveformView.isHidden = false
                self.cancelButton.isEnabled = false
                self.doneButton.isEnabled = false
                self.waveformView.barColor = .systemOrange
                self.waveformView.setMode(.processing)

            case .complete:
                self.statusLabel.stringValue = "✓ Done"
                self.statusLabel.isHidden = false
                self.waveformView.isHidden = true
                self.cancelButton.isEnabled = false
                self.doneButton.isEnabled = false
                // Auto-hide after short delay
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                    self?.hideWithAnimation()
                }

            case .cancelled:
                self.hideWithAnimation()
            }
        }
    }

    // MARK: - Audio Level (called from AudioCapture)

    /// Update waveform with audio level from AudioCapture
    func updateAudioLevel(_ level: Float) {
        guard overlayState == .recording else { return }
        waveformView.updateLevel(level)
    }

    // MARK: - Show/Hide Animation

    func showWithAnimation() {
        // CRITICAL: Always reset to correct position FIRST to prevent drift
        recalculateTargetFrame()
        setFrame(targetFrame, display: false)

        // Start hidden and below target position
        alphaValue = 0
        var startFrame = targetFrame
        startFrame.origin.y -= 20
        setFrame(startFrame, display: false)

        orderFront(nil)

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            self.animator().alphaValue = 1
            self.animator().setFrame(self.targetFrame, display: true)
        }

        waveformView.startAnimation()
    }

    func hideWithAnimation() {
        waveformView.stopAnimation()

        var endFrame = frame
        endFrame.origin.y -= 20

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.15
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            self.animator().alphaValue = 0
            self.animator().setFrame(endFrame, display: true)
        }, completionHandler: { [weak self] in
            self?.orderOut(nil)
        })
    }

    /// Recalculate target frame position (for multi-monitor or screen changes)
    private func recalculateTargetFrame() {
        let mouseLocation = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouseLocation, $0.frame, false) } ?? NSScreen.main
        let screenFrame = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1920, height: 1080)

        let x = screenFrame.origin.x + (screenFrame.width - Self.panelWidth) / 2
        let y = screenFrame.origin.y + Self.bottomMargin

        targetFrame = NSRect(x: x, y: y, width: Self.panelWidth, height: Self.panelHeight)
    }

    // MARK: - Actions

    @objc private func cancelClicked() {
        onCancel?()
    }

    @objc private func doneClicked() {
        onDone?()
    }

    // MARK: - Window Behavior

    override var canBecomeKey: Bool {
        return false // Don't steal focus from other apps
    }

    override var canBecomeMain: Bool {
        return false
    }

    // Prevent activation
    override func mouseDown(with event: NSEvent) {
        // Don't activate panel on mouse down
        // Just pass through to button handlers
    }
}
