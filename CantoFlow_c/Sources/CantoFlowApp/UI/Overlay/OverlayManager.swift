import AppKit

/// Overlay display mode
enum OverlayDisplayMode: String, CaseIterable {
    case full = "full"           // Full floating panel with waveform
    case minimal = "minimal"     // Menu bar only, no panel
    case off = "off"             // No visual feedback

    var displayName: String {
        switch self {
        case .full: return "Full"
        case .minimal: return "Minimal"
        case .off: return "Off"
        }
    }
}

/// Manages the recording overlay panel lifecycle
final class OverlayManager {
    static let shared = OverlayManager()

    /// Current display mode
    var displayMode: OverlayDisplayMode = .full

    /// Callbacks (forwarded to RecordingOverlayPanel.shared)
    var onCancel: (() -> Void)? {
        didSet { RecordingOverlayPanel.shared.onCancel = onCancel }
    }
    var onDone: (() -> Void)? {
        didSet { RecordingOverlayPanel.shared.onDone = onDone }
    }

    private init() {}

    // MARK: - Overlay Control

    /// Show the recording overlay
    func showRecordingOverlay() {
        guard displayMode == .full else { return }
        DispatchQueue.main.async {
            RecordingOverlayPanel.shared.setState(.recording)
            RecordingOverlayPanel.shared.showWithAnimation()
        }
    }

    /// Update overlay to transcribing state
    func setTranscribing() {
        DispatchQueue.main.async {
            RecordingOverlayPanel.shared.setState(.transcribing)
        }
    }

    /// Update overlay to polishing state
    func setPolishing() {
        DispatchQueue.main.async {
            RecordingOverlayPanel.shared.setState(.polishing)
        }
    }

    /// Update overlay to complete state
    func setComplete() {
        DispatchQueue.main.async {
            RecordingOverlayPanel.shared.setState(.complete)
        }
    }

    /// Hide the recording overlay
    func hideOverlay() {
        DispatchQueue.main.async {
            RecordingOverlayPanel.shared.hideWithAnimation()
        }
    }

    /// Cancel and hide the overlay
    func cancelOverlay() {
        DispatchQueue.main.async {
            RecordingOverlayPanel.shared.setState(.cancelled)
        }
    }

    /// Update waveform with audio level
    func updateAudioLevel(_ level: Float) {
        DispatchQueue.main.async {
            RecordingOverlayPanel.shared.updateAudioLevel(level)
        }
    }
}
