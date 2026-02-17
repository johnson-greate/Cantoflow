import AppKit
import Accelerate

/// A view that displays real-time audio waveform bars
final class WaveformView: NSView {
    /// Number of bars in the waveform
    private let barCount: Int = 40

    /// Spacing between bars
    private let barSpacing: CGFloat = 2

    /// Minimum bar height
    private let minBarHeight: CGFloat = 4

    /// Maximum bar height (as fraction of view height)
    private let maxBarHeightFraction: CGFloat = 0.9

    /// Color of the bars
    var barColor: NSColor = NSColor.systemBlue {
        didSet { needsDisplay = true }
    }

    /// Corner radius for each bar
    private let barCornerRadius: CGFloat = 2

    /// Current audio levels (0.0 to 1.0)
    private var levels: [CGFloat] = []

    /// Display link for smooth animation
    private var displayLink: CVDisplayLink?

    /// Target levels for smooth animation
    private var targetLevels: [CGFloat] = []

    /// Animation decay factor
    private let decayFactor: CGFloat = 0.85

    /// Animation smoothing factor
    private let smoothingFactor: CGFloat = 0.3

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

    /// Start the animation
    func startAnimation() {
        guard displayLink == nil else { return }

        CVDisplayLinkCreateWithActiveCGDisplays(&displayLink)
        guard let displayLink = displayLink else { return }

        CVDisplayLinkSetOutputCallback(displayLink, { _, _, _, _, _, userInfo -> CVReturn in
            guard let userInfo = userInfo else { return kCVReturnSuccess }
            let view = Unmanaged<WaveformView>.fromOpaque(userInfo).takeUnretainedValue()
            DispatchQueue.main.async {
                view.updateAnimation()
            }
            return kCVReturnSuccess
        }, Unmanaged.passUnretained(self).toOpaque())

        CVDisplayLinkStart(displayLink)
    }

    /// Stop the animation
    func stopAnimation() {
        guard let displayLink = displayLink else { return }
        CVDisplayLinkStop(displayLink)
        self.displayLink = nil
    }

    /// Update with new audio level (RMS value, 0.0 to 1.0)
    func updateLevel(_ level: Float) {
        // Shift levels to the right and add new level at the beginning
        let normalizedLevel = CGFloat(min(1.0, max(0.0, level * 3))) // Amplify for visibility

        targetLevels.removeLast()
        targetLevels.insert(normalizedLevel, at: 0)
    }

    /// Update animation frame
    private func updateAnimation() {
        var needsRedraw = false

        for i in 0..<barCount {
            // Smooth towards target
            let diff = targetLevels[i] - levels[i]
            if abs(diff) > 0.001 {
                levels[i] += diff * smoothingFactor
                needsRedraw = true
            }

            // Apply decay to target levels
            targetLevels[i] *= decayFactor
        }

        if needsRedraw {
            needsDisplay = true
        }
    }

    /// Set all bars to idle state
    func setIdle() {
        for i in 0..<barCount {
            targetLevels[i] = 0
        }
    }

    /// Set a pulsing animation (for processing state)
    func setPulsing() {
        let time = Date().timeIntervalSinceReferenceDate
        for i in 0..<barCount {
            let phase = Double(i) / Double(barCount) * .pi * 2
            let wave = (sin(time * 3 + phase) + 1) / 2 * 0.3
            targetLevels[i] = CGFloat(wave)
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

            // Gradient based on level
            let alpha = 0.5 + level * 0.5
            barColor.withAlphaComponent(alpha).setFill()
            path.fill()
        }
    }
}
