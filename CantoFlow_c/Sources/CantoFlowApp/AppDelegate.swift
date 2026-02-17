import AppKit

/// Application delegate that sets up the app as an accessory (menu bar only)
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let config: AppConfig
    private var menuBarController: MenuBarController?
    private var hotkeyManager: HotkeyManager?
    private var pipeline: STTPipeline?

    init(config: AppConfig) {
        self.config = config
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Set as accessory app (no dock icon, menu bar only)
        NSApp.setActivationPolicy(.accessory)

        // Create output directory
        try? FileManager.default.createDirectory(at: config.outDir, withIntermediateDirectories: true)

        // Initialize pipeline
        pipeline = STTPipeline(config: config)

        // Initialize menu bar UI
        menuBarController = MenuBarController(config: config, pipeline: pipeline!)

        // Initialize hotkey manager
        hotkeyManager = HotkeyManager { [weak self] in
            self?.menuBarController?.toggleRecording()
        }
        hotkeyManager?.start()

        // Check permissions and show ready notification
        checkPermissionsAndNotify()
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotkeyManager?.stop()
    }

    private func checkPermissionsAndNotify() {
        pipeline?.requestMicrophonePermission { granted in
            DispatchQueue.main.async {
                if granted {
                    NotificationManager.shared.notify("CantoFlow_c ready. Press Fn or F12 to record.")
                } else {
                    NotificationManager.shared.notify("Microphone permission denied. Please enable in System Settings.")
                }
            }
        }
    }
}
