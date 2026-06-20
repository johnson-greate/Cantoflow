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
    private let elapsedLabel = NSTextField()
    private let stateDot = NSView()
    private let waveformView = WaveformView()

    // MARK: - Callbacks

    var onCancel: (() -> Void)?
    var onDone: (() -> Void)?

    /// Cancellable work item for the .complete auto-hide delay
    private var autoHideWorkItem: DispatchWorkItem?
    private var elapsedTimer: Timer?
    private var recordingStartedAt: Date?

    // MARK: - CantoFlow capsule design

    private static let panelWidth: CGFloat = 272
    private static let panelHeight: CGFloat = 56
    private static let cornerRadius: CGFloat = 28
    private static let bottomMargin: CGFloat = 80
    private static let accentColor = NSColor(
        calibratedRed: 0.48,
        green: 0.95,
        blue: 0.76,
        alpha: 1
    )

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
        // A dark graphite glass surface gives CantoFlow its own identity while
        // retaining enough translucency to feel native on macOS.
        containerView.frame = NSRect(x: 0, y: 0, width: Self.panelWidth, height: Self.panelHeight)
        containerView.material = .hudWindow
        containerView.blendingMode = .behindWindow
        containerView.state = .active
        containerView.appearance = NSAppearance(named: .darkAqua)
        containerView.wantsLayer = true
        containerView.layer?.cornerRadius = Self.cornerRadius
        containerView.layer?.masksToBounds = true
        containerView.layer?.backgroundColor = NSColor(
            calibratedWhite: 0.055,
            alpha: 0.82
        ).cgColor
        containerView.layer?.borderWidth = 0.7
        containerView.layer?.borderColor = NSColor.white.withAlphaComponent(0.14).cgColor

        contentView = containerView

        // Quiet secondary action.
        cancelButton.frame = NSRect(x: 11, y: 15, width: 26, height: 26)
        cancelButton.bezelStyle = .circular
        cancelButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Cancel")
        cancelButton.imageScaling = .scaleProportionallyDown
        cancelButton.target = self
        cancelButton.action = #selector(cancelClicked)
        cancelButton.isBordered = false
        cancelButton.refusesFirstResponder = true
        cancelButton.contentTintColor = NSColor.white.withAlphaComponent(0.72)
        cancelButton.wantsLayer = true
        cancelButton.layer?.cornerRadius = 13
        cancelButton.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.08).cgColor
        containerView.addSubview(cancelButton)

        // Primary action reads as "stop and use this recording", not an old-style
        // form confirmation checkmark.
        doneButton.frame = NSRect(x: Self.panelWidth - 37, y: 15, width: 26, height: 26)
        doneButton.bezelStyle = .circular
        doneButton.image = NSImage(systemSymbolName: "stop.fill", accessibilityDescription: "Finish recording")
        doneButton.contentTintColor = NSColor(calibratedWhite: 0.08, alpha: 1)
        doneButton.imageScaling = .scaleProportionallyDown
        doneButton.target = self
        doneButton.action = #selector(doneClicked)
        doneButton.isBordered = false
        doneButton.refusesFirstResponder = true
        doneButton.wantsLayer = true
        doneButton.layer?.cornerRadius = 13
        doneButton.layer?.backgroundColor = Self.accentColor.cgColor
        containerView.addSubview(doneButton)

        // Live state dot — the single signature accent shared by the capsule and logo direction.
        stateDot.frame = NSRect(x: 47, y: 24, width: 8, height: 8)
        stateDot.wantsLayer = true
        stateDot.layer?.cornerRadius = 4
        stateDot.layer?.backgroundColor = Self.accentColor.cgColor
        stateDot.layer?.shadowColor = Self.accentColor.cgColor
        stateDot.layer?.shadowOpacity = 0.45
        stateDot.layer?.shadowRadius = 4
        stateDot.layer?.shadowOffset = .zero
        containerView.addSubview(stateDot)

        // Fine, audio-reactive waveform with enough breathing room to read at a glance.
        let waveformWidth: CGFloat = 128
        let waveformHeight: CGFloat = 26
        waveformView.frame = NSRect(
            x: 64,
            y: (Self.panelHeight - waveformHeight) / 2,
            width: waveformWidth,
            height: waveformHeight
        )
        waveformView.barColor = Self.accentColor
        containerView.addSubview(waveformView)

        elapsedLabel.frame = NSRect(x: 198, y: 20, width: 32, height: 16)
        elapsedLabel.stringValue = "0:00"
        elapsedLabel.alignment = .right
        elapsedLabel.font = .monospacedDigitSystemFont(ofSize: 10, weight: .medium)
        elapsedLabel.textColor = NSColor.white.withAlphaComponent(0.56)
        elapsedLabel.isBezeled = false
        elapsedLabel.drawsBackground = false
        elapsedLabel.isEditable = false
        elapsedLabel.isSelectable = false
        containerView.addSubview(elapsedLabel)

        // Processing states trade the waveform for one short, calm status line.
        statusLabel.frame = NSRect(x: 64, y: 19, width: 160, height: 18)
        statusLabel.stringValue = ""
        statusLabel.alignment = .left
        statusLabel.font = .systemFont(ofSize: 12, weight: .medium)
        statusLabel.textColor = NSColor.white.withAlphaComponent(0.88)
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
            startElapsedTimer()
            statusLabel.isHidden = true
            elapsedLabel.isHidden = false
            stateDot.isHidden = false
            waveformView.isHidden = false
            cancelButton.isHidden = false
            doneButton.isHidden = false
            cancelButton.isEnabled = true
            doneButton.isEnabled = true
            setStateDot(color: Self.accentColor, pulsing: false)
            waveformView.barColor = Self.accentColor
            waveformView.setMode(.live)

        case .transcribing:
            stopElapsedTimer()
            statusLabel.stringValue = "正在辨識語音"
            statusLabel.isHidden = false
            elapsedLabel.isHidden = true
            stateDot.isHidden = false
            waveformView.isHidden = true
            cancelButton.isHidden = true
            doneButton.isHidden = true
            cancelButton.isEnabled = false
            doneButton.isEnabled = false
            setStateDot(color: NSColor.white.withAlphaComponent(0.64), pulsing: true)

        case .polishing:
            stopElapsedTimer()
            statusLabel.stringValue = "正在潤飾文字"
            statusLabel.isHidden = false
            elapsedLabel.isHidden = true
            stateDot.isHidden = false
            waveformView.isHidden = true
            cancelButton.isHidden = true
            doneButton.isHidden = true
            cancelButton.isEnabled = false
            doneButton.isEnabled = false
            setStateDot(color: Self.accentColor, pulsing: true)

        case .complete:
            stopElapsedTimer()
            statusLabel.stringValue = "文字已準備好"
            statusLabel.isHidden = false
            elapsedLabel.isHidden = true
            stateDot.isHidden = false
            waveformView.isHidden = true
            cancelButton.isHidden = true
            doneButton.isHidden = true
            cancelButton.isEnabled = false
            doneButton.isEnabled = false
            setStateDot(color: Self.accentColor, pulsing: false)
            // Cancellable auto-hide: if setState(.recording) is called before
            // 0.4 s elapses (second recording started quickly), cancel() prevents
            // the hide from firing on the newly-shown panel.
            let item = DispatchWorkItem { [weak self] in
                self?.hideWithAnimation()
            }
            autoHideWorkItem = item
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: item)

        case .cancelled:
            stopElapsedTimer()
            hideWithAnimation()
        }
    }

    private func setStateDot(color: NSColor, pulsing: Bool) {
        stateDot.layer?.backgroundColor = color.cgColor
        stateDot.layer?.shadowColor = color.cgColor
        stateDot.layer?.removeAnimation(forKey: "cantoFlowPulse")

        guard pulsing else {
            stateDot.layer?.opacity = 1
            return
        }

        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = 1.0
        pulse.toValue = 0.28
        pulse.duration = 0.72
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        stateDot.layer?.add(pulse, forKey: "cantoFlowPulse")
    }

    private func startElapsedTimer() {
        stopElapsedTimer()
        recordingStartedAt = Date()
        updateElapsedLabel()
        let timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            self?.updateElapsedLabel()
        }
        elapsedTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func stopElapsedTimer() {
        elapsedTimer?.invalidate()
        elapsedTimer = nil
        recordingStartedAt = nil
    }

    private func updateElapsedLabel() {
        guard let recordingStartedAt else { return }
        let elapsed = max(0, Int(Date().timeIntervalSince(recordingStartedAt)))
        elapsedLabel.stringValue = "\(elapsed / 60):\(String(format: "%02d", elapsed % 60))"
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
        stopElapsedTimer()
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
