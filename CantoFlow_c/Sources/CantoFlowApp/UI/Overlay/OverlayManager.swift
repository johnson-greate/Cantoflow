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

    /// The current overlay panel (if any)
    private var overlayPanel: RecordingOverlayPanel?

    /// Callbacks
    var onCancel: (() -> Void)?
    var onDone: (() -> Void)?

    private init() {}

    // MARK: - Overlay Control

    /// Show the recording overlay
    func showRecordingOverlay() {
        guard displayMode == .full else { return }

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }

            // Create new panel if needed
            if self.overlayPanel == nil {
                self.overlayPanel = RecordingOverlayPanel.create()
                self.overlayPanel?.onCancel = { [weak self] in
                    self?.onCancel?()
                }
                self.overlayPanel?.onDone = { [weak self] in
                    self?.onDone?()
                }
            }

            self.overlayPanel?.setState(.recording)
            self.overlayPanel?.showWithAnimation()
        }
    }

    /// Update overlay to transcribing state
    func setTranscribing() {
        DispatchQueue.main.async { [weak self] in
            self?.overlayPanel?.setState(.transcribing)
        }
    }

    /// Update overlay to polishing state
    func setPolishing() {
        DispatchQueue.main.async { [weak self] in
            self?.overlayPanel?.setState(.polishing)
        }
    }

    /// Update overlay to complete state
    func setComplete() {
        DispatchQueue.main.async { [weak self] in
            self?.overlayPanel?.setState(.complete)
        }
    }

    /// Hide the recording overlay
    func hideOverlay() {
        DispatchQueue.main.async { [weak self] in
            self?.overlayPanel?.hideWithAnimation()
        }
    }

    /// Cancel and hide the overlay
    func cancelOverlay() {
        DispatchQueue.main.async { [weak self] in
            self?.overlayPanel?.setState(.cancelled)
        }
    }
}
