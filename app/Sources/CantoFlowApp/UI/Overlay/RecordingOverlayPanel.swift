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

    /// Cancellable work item for the .complete auto-hide delay
    private var autoHideWorkItem: DispatchWorkItem?

    // MARK: - Constants (Compact Capsule Design - 25% smaller)

    private static let panelWidth: CGFloat = 210
    private static let panelHeight: CGFloat = 42
    private static let cornerRadius: CGFloat = 21  // height / 2 for capsule
    private static let bottomMargin: CGFloat = 80

    /// Stored correct position (to prevent drift)
    private var targetFrame: NSRect = .zero

    // MARK: - Singleton

    /// The single shared overlay panel. Allocated once at startup and never deallocated.
    ///
    /// Keeping a static strong reference, combined with `isReleasedWhenClosed = false`,
    /// ensures AppKit never destroys the underlying NSPanel C++ object while a
    /// CA::Transaction or a lingering closure still references it.  Creating and
    /// destroying the panel on every dictation was the root cause of the
    /// `_Block_release` crash inside `CA::Transaction::commit`.
    static let shared = RecordingOverlayPanel(
        contentRect: .zero,
        styleMask: [],
        backing: .buffered,
        defer: false
    )

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

    // MARK: - Setup

    private func setupPanel() {
        // CRITICAL: Prevent AppKit from releasing the panel's underlying C++ object
        // when it is closed or hidden via orderOut().  Without this, AppKit decrements
        // the retain count on close, causing a use-after-free the next time a CA
        // animation or a pending GCD block references the (now-freed) panel object,
        // resulting in _Block_release crashing inside CA::Transaction::commit.
        isReleasedWhenClosed = false

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

        // Cancel button (left side) - smaller
        cancelButton.frame = NSRect(x: 8, y: (Self.panelHeight - 22) / 2, width: 22, height: 22)
        cancelButton.bezelStyle = .circular
        cancelButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Cancel")
        cancelButton.imageScaling = .scaleProportionallyDown
        cancelButton.target = self
        cancelButton.action = #selector(cancelClicked)
        cancelButton.isBordered = false
        cancelButton.refusesFirstResponder = true
        containerView.addSubview(cancelButton)

        // Done button (right side) - smaller
        doneButton.frame = NSRect(x: Self.panelWidth - 30, y: (Self.panelHeight - 22) / 2, width: 22, height: 22)
        doneButton.bezelStyle = .circular
        doneButton.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: "Done")
        doneButton.contentTintColor = .systemGreen
        doneButton.imageScaling = .scaleProportionallyDown
        doneButton.target = self
        doneButton.action = #selector(doneClicked)
        doneButton.isBordered = false
        doneButton.refusesFirstResponder = true
        containerView.addSubview(doneButton)

        // Waveform view (center, compact - 25% smaller)
        let waveformWidth: CGFloat = 105
        let waveformHeight: CGFloat = 24
        waveformView.frame = NSRect(
            x: (Self.panelWidth - waveformWidth) / 2,
            y: (Self.panelHeight - waveformHeight) / 2,
            width: waveformWidth,
            height: waveformHeight
        )
        waveformView.barColor = .systemBlue
        containerView.addSubview(waveformView)

        // Status label (overlaid on waveform, centered)
        statusLabel.frame = NSRect(x: 36, y: (Self.panelHeight - 16) / 2, width: Self.panelWidth - 72, height: 16)
        statusLabel.stringValue = ""
        statusLabel.alignment = .center
        statusLabel.font = .systemFont(ofSize: 10, weight: .medium)
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

    /// Update UI for the current overlay state.
    /// MUST be called from the main thread — setState() callers are all main-thread.
    /// Running UI mutations synchronously (no DispatchQueue.main.async wrapper) prevents
    /// the GCD block from being released inside a CA::Transaction::commit, which was the
    /// root cause of the _Block_release crash observed on macOS 26 beta.
    private func updateUIForState() {
        assert(Thread.isMainThread, "updateUIForState must be called on the main thread")

        // Cancel any pending auto-hide from a previous .complete state.
        // Without this, a second recording starting before the 0.4 s timer fires
        // would have its panel hidden mid-recording.
        autoHideWorkItem?.cancel()
        autoHideWorkItem = nil

        switch overlayState {
        case .recording:
            statusLabel.isHidden = true
            waveformView.isHidden = false
            cancelButton.isEnabled = true
            doneButton.isEnabled = true
            waveformView.barColor = .systemBlue
            waveformView.setMode(.live)

        case .transcribing:
            statusLabel.stringValue = "語音辨識中..."
            statusLabel.isHidden = false
            waveformView.isHidden = false
            cancelButton.isEnabled = false
            doneButton.isEnabled = false
            waveformView.barColor = .systemGray
            waveformView.setMode(.processing)

        case .polishing:
            statusLabel.stringValue = "潤飾中..."
            statusLabel.isHidden = false
            waveformView.isHidden = false
            cancelButton.isEnabled = false
            doneButton.isEnabled = false
            waveformView.barColor = .systemOrange
            waveformView.setMode(.processing)

        case .complete:
            statusLabel.stringValue = "✓ 完成"
            statusLabel.isHidden = false
            waveformView.isHidden = true
            cancelButton.isEnabled = false
            doneButton.isEnabled = false
            // Cancellable auto-hide: if setState(.recording) is called before
            // 0.4 s elapses (second recording started quickly), cancel() prevents
            // the hide from firing on the newly-shown panel.
            let item = DispatchWorkItem { [weak self] in
                self?.hideWithAnimation()
            }
            autoHideWorkItem = item
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: item)

        case .cancelled:
            hideWithAnimation()
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
