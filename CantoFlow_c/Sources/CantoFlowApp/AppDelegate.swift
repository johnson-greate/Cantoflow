import AppKit

/// Application delegate that sets up the app as an accessory (menu bar only).
/// Config is now parsed internally so NSApplicationDelegateAdaptor can
/// instantiate the delegate with its required no-argument initialiser.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let config: AppConfig
    private var menuBarController: MenuBarController?
    private var pushToTalkManager: PushToTalkManager?
    private var pipeline: STTPipeline?

    override init() {
        self.config = AppConfig.fromArgs()
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Accessory app — no dock icon (Info.plist LSUIElement=YES is the primary
        // gate; this call ensures it is also set at runtime).
        NSApp.setActivationPolicy(.accessory)

        // Pre-warm the overlay panel singleton on the main thread.
        // RecordingOverlayPanel.shared is a static let — accessing it here guarantees
        // AppKit initialisation happens on the main thread (required for NSPanel/NSView
        // setup), and keeps the object alive for the entire process lifetime.
        // This satisfies the Red Team requirement: "keep a strong reference in the
        // App Delegate so it never gets unexpectedly deallocated."
        _ = RecordingOverlayPanel.shared

        // Create output directory
        try? FileManager.default.createDirectory(at: config.outDir, withIntermediateDirectories: true)

        // Initialize pipeline
        pipeline = STTPipeline(config: config)

        // Initialize menu bar UI
        menuBarController = MenuBarController(config: config, pipeline: pipeline!)
        menuBarController?.showOverlay = config.showOverlay

        // Initialize Push-to-Talk manager
        pushToTalkManager = PushToTalkManager()
        pushToTalkManager?.delegate = menuBarController
        pushToTalkManager?.triggerKey = resolveTriggerKey()
        pushToTalkManager?.start()
        
        if let keyName = pushToTalkManager?.triggerKey.displayName {
            menuBarController?.updateHint(keyName: keyName)
        }

        // Set back-reference for state management
        menuBarController?.pushToTalkManager = pushToTalkManager

        // Configure vocabulary usage
        VocabularyStore.shared.hkCommonEnabled = config.useVocabulary

        // Check permissions and show ready notification
        checkPermissionsAndNotify()

        // Observe customHotkey changes in UserDefaults
        UserDefaults.standard.addObserver(self, forKeyPath: "customHotkey", options: [.new], context: nil)
    }

    func applicationWillTerminate(_ notification: Notification) {
        UserDefaults.standard.removeObserver(self, forKeyPath: "customHotkey")
        pushToTalkManager?.stop()
    }

    override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey : Any]?, context: UnsafeMutableRawPointer?) {
        if keyPath == "customHotkey" {
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                let newKey = self.resolveTriggerKey()
                if self.pushToTalkManager?.triggerKey != newKey {
                    self.pushToTalkManager?.triggerKey = newKey
                    self.menuBarController?.updateHint(keyName: newKey.displayName)
                }
            }
        }
    }

    private func checkPermissionsAndNotify() {
        pipeline?.requestMicrophonePermission { granted in
            DispatchQueue.main.async {
                if granted {
                    let keyName = self.pushToTalkManager?.triggerKey.displayName ?? "Fn"
                    NotificationManager.shared.notify("CantoFlow ready. Hold \(keyName) to record.")
                } else {
                    NotificationManager.shared.notify("Microphone permission denied. Please enable in System Settings.")
                }
            }
        }
    }

    /// Resolve trigger key based on config or auto-detect
    private func resolveTriggerKey() -> CustomHotkey {
        // First try to load custom recorded hotkey
        if let string = UserDefaults.standard.string(forKey: "customHotkey"),
           let data = Data(base64Encoded: string, options: .ignoreUnknownCharacters) ?? string.data(using: .utf8),
           let decoded = try? JSONDecoder().decode(CustomHotkey.self, from: data) {
            return decoded
        } else if let data = UserDefaults.standard.data(forKey: "customHotkey"),
                  let decoded = try? JSONDecoder().decode(CustomHotkey.self, from: data) {
            return decoded
        }
        
        // Fall back to CLI config or hardware auto-detect
        switch config.triggerKey.lowercased() {
        case "fn": return .defaultFn
        case "f15": return .defaultF15
        case "auto":
            fallthrough
        default:
            let model = getHardwareModel()
            if model.contains("MacBook") {
                return .defaultFn
            } else {
                return .defaultF15
            }
        }
    }

    private func getHardwareModel() -> String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var model = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.model", &model, &size, nil, 0)
        return String(cString: model)
    }
}
