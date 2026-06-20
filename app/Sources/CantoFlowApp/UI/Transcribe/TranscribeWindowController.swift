import AppKit
import SwiftUI

/// Persistent controller for the Transcribe window. Strong-holds the window,
/// hosting controller and store so closing the window never tears down an
/// in-flight batch or the Combine graph (PRD §11.2). Reused across opens.
@MainActor
final class TranscribeWindowController {
    static private(set) var shared: TranscribeWindowController?

    let store: FileTranscriptionStore
    private let window: NSWindow
    private let hosting: NSHostingController<TranscribeView>

    static func showShared(config: AppConfig) {
        if shared == nil {
            shared = TranscribeWindowController(config: config)
        }
        shared?.show()
    }

    init(config: AppConfig) {
        let store = FileTranscriptionStore(config: config)
        self.store = store
        self.hosting = NSHostingController(rootView: TranscribeView(store: store))

        let window = NSWindow(contentViewController: hosting)
        window.title = "檔案轉錄"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 960, height: 680))
        window.minSize = NSSize(width: 760, height: 520)
        window.isReleasedWhenClosed = false
        window.center()
        self.window = window
    }

    var isBatchActive: Bool { store.isBatchActive }

    func show() {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
