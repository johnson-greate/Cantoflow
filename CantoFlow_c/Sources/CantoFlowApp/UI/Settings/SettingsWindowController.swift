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

    // Persistent window that is NEVER deallocated.
    //
    // Previously the window was created fresh in show() and set to nil in
    // windowWillClose(_:).  That caused the NSConcretePointerArray backing
    // @AppStorage subscriptions to be released during the CA close-animation
    // transaction on macOS 26 beta:
    //
    //   NSConcretePointerArray dealloc
    //   → _Block_release
    //   → objc_release  ← Bad pointer dereference  (crash)
    //
    // Fix: keep the NSWindow + NSHostingController alive for the app's entire
    // lifetime.  isReleasedWhenClosed = false prevents AppKit from sending an
    // extra ObjC release when the user clicks the close button.  The window
    // simply goes off-screen; its @AppStorage views are never torn down during
    // a CA transaction.
    private lazy var window: NSWindow = {
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
        win.isReleasedWhenClosed = false  // ARC owns the lifetime; prevent ObjC double-free
        win.center()
        return win
    }()

    private override init() {}

    func show() {
        // Sync backend state before opening (it may have been changed from the menu).
        if let pl = pipeline {
            let key = pl.sttBackend == .funasr ? "funasr" : "whisper"
            UserDefaults.standard.set(key, forKey: "sttBackend")
        }

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        // Intentionally empty: the window stays alive (hidden) after close.
        // Releasing it here would deallocate @AppStorage views during the
        // CA close-animation transaction → NSConcretePointerArray crash.
    }
}
