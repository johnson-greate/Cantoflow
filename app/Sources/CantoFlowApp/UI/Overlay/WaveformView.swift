import AppKit

/// Waveform display mode
enum WaveformMode {
    case live       // React to real-time audio input
    case processing // Knight Rider style scanning animation
    case idle       // Static flat line
}

/// A view that displays real-time audio waveform bars (compact version - 25% smaller)
final class WaveformView: NSView {
    /// Number of bars in the waveform (fewer for ultra-compact mode)
    private let barCount: Int = 18

    /// Spacing between bars
    private let barSpacing: CGFloat = 1.5

    /// Minimum bar height
    private let minBarHeight: CGFloat = 2

    /// Maximum bar height (as fraction of view height)
    private let maxBarHeightFraction: CGFloat = 0.85

    /// Color of the bars
    var barColor: NSColor = NSColor.systemBlue {
        didSet { needsDisplay = true }
    }

    /// Corner radius for each bar (smaller for compact)
    private let barCornerRadius: CGFloat = 1

    /// Current audio levels (0.0 to 1.0)
    private var levels: [CGFloat] = []

    /// Display link timer
    private var displayTimer: Timer?

    /// Target levels for smooth animation
    private var targetLevels: [CGFloat] = []

    /// Animation smoothing factor (higher = faster response)
    private let smoothingFactor: CGFloat = 0.4

    /// Decay factor for levels
    private let decayFactor: CGFloat = 0.92

    /// Current display mode
    private var mode: WaveformMode = .idle

    /// Processing animation phase
    private var processingPhase: CGFloat = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        wantsLayer = true
        levels = Array(repeating: 0, count: barCount)
        targetLevels = Array(repeating: 0, count: barCount)
    }

    deinit {
        stopAnimation()
    }

    /// Set the display mode
    func setMode(_ newMode: WaveformMode) {
        mode = newMode
        if mode == .processing {
            processingPhase = 0
        }
    }

    /// Start the animation timer
    func startAnimation() {
        guard displayTimer == nil else { return }

        // Use a timer at 60fps
        displayTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            self?.updateAnimation()
        }
        RunLoop.main.add(displayTimer!, forMode: .common)
    }

    /// Stop the animation
    func stopAnimation() {
        displayTimer?.invalidate()
        displayTimer = nil
    }

    /// Update with new audio level (RMS value, 0.0 to 1.0)
    func updateLevel(_ level: Float) {
        guard mode == .live else { return }

        let normalizedLevel = CGFloat(min(1.0, max(0.0, level)))

        // Shift levels to the right and add new level at the beginning
        // This creates a "rolling" effect
        targetLevels.removeLast()
        targetLevels.insert(normalizedLevel, at: 0)
    }

    /// Update animation frame
    private func updateAnimation() {
        var needsRedraw = false

        switch mode {
        case .live:
            // Smooth interpolation towards target levels with decay
            for i in 0..<barCount {
                let diff = targetLevels[i] - levels[i]
                if abs(diff) > 0.001 {
                    levels[i] += diff * smoothingFactor
                    needsRedraw = true
                }
                // Apply decay to target levels
                targetLevels[i] *= decayFactor
            }

        case .processing:
            // Knight Rider style scanning effect
            processingPhase += 0.05
            if processingPhase > CGFloat.pi * 2 {
                processingPhase -= CGFloat.pi * 2
            }

            for i in 0..<barCount {
                let normalizedPos = CGFloat(i) / CGFloat(barCount - 1)
                // Create a moving wave
                let wave = sin(normalizedPos * CGFloat.pi * 2 - processingPhase)
                let envelope = exp(-pow((normalizedPos - 0.5) * 2, 2) * 2) // Gaussian envelope
                levels[i] = (wave + 1) / 2 * 0.6 * envelope + 0.1
            }
            needsRedraw = true

        case .idle:
            // Fade all levels to minimum
            for i in 0..<barCount {
                if levels[i] > 0.01 {
                    levels[i] *= 0.9
                    needsRedraw = true
                }
            }
        }

        if needsRedraw {
            needsDisplay = true
        }
    }

    /// Set all bars to idle state
    func setIdle() {
        mode = .idle
        for i in 0..<barCount {
            targetLevels[i] = 0
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        guard NSGraphicsContext.current?.cgContext != nil else { return }

        let totalSpacing = barSpacing * CGFloat(barCount - 1)
        let barWidth = (bounds.width - totalSpacing) / CGFloat(barCount)
        let maxBarHeight = bounds.height * maxBarHeightFraction

        for i in 0..<barCount {
            let level = levels[i]
            let barHeight = max(minBarHeight, minBarHeight + (maxBarHeight - minBarHeight) * level)

            let x = CGFloat(i) * (barWidth + barSpacing)
            let y = (bounds.height - barHeight) / 2

            let rect = CGRect(x: x, y: y, width: barWidth, height: barHeight)
            let path = NSBezierPath(roundedRect: rect, xRadius: barCornerRadius, yRadius: barCornerRadius)

            // Alpha based on level for more visual feedback
            let alpha = 0.4 + level * 0.6
            barColor.withAlphaComponent(alpha).setFill()
            path.fill()
        }
    }
}
