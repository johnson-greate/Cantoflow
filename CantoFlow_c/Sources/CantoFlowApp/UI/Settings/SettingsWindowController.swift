import AppKit
import SwiftUI

/// Manages the Settings window for the CantoFlow menu bar app.
///
/// Why manual NSWindow instead of the SwiftUI Settings scene's showSettingsWindow: action:
/// This app runs as an LSUIElement accessory (no dock icon, no standard menu bar).
/// In that configuration SwiftUI does not register showSettingsWindow: in the responder
/// chain, so NSApp.sendAction fires silently and nothing opens.
///
/// The Settings scene in CantoFlowApp.body is kept only to satisfy SwiftUI's
/// requirement that every App have at least one scene. The actual window shown to
/// the user is the one created here.
final class SettingsWindowController: NSObject, NSWindowDelegate {
    static let shared = SettingsWindowController()

    /// Callback wired by MenuBarController so ModelsTab's picker can switch
    /// backends at runtime.  ModelsTab calls this via .onChange(of: sttBackend).
    var onSttBackendChange: ((String) -> Void)?

    private var window: NSWindow?

    /// Set by MenuBarController so the Models tab can switch backends at runtime.
    weak var pipeline: STTPipeline? {
        didSet {
            // Sync pipeline state → UserDefaults so @AppStorage("sttBackend") in
            // ModelsTab immediately reflects the live backend.
            let key = pipeline?.sttBackend == .funasr ? "funasr" : "whisper"
            UserDefaults.standard.set(key, forKey: "sttBackend")

            onSttBackendChange = { [weak self] newBackend in
                self?.pipeline?.sttBackend = newBackend == "funasr" ? .funasr : .whisper
            }
        }
    }

    private override init() {}

    func show() {
        // Sync backend state before opening (it may have been changed from the menu).
        if let pl = pipeline {
            let key = pl.sttBackend == .funasr ? "funasr" : "whisper"
            UserDefaults.standard.set(key, forKey: "sttBackend")
        }

        // Bring existing window to front if already visible.
        if let existing = window, existing.isVisible {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        // Embed the SwiftUI view in an NSWindow via NSHostingController.
        // No environmentObject needed: ModelsTab uses @AppStorage directly;
        // SettingsStore is no longer ObservableObject.
        let hosting = NSHostingController(rootView: SettingsView())

        let win = NSWindow(
            contentRect: .zero,
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        win.title = "CantoFlow Settings"
        win.contentViewController = hosting
        win.delegate = self
        win.setFrameAutosaveName("CantoFlow.SettingsWindow")
        win.setContentSize(NSSize(width: 560, height: 440))
        win.center()

        self.window = win
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        window = nil
    }
}
