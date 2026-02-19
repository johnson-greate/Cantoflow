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

        // Set back-reference for state management
        menuBarController?.pushToTalkManager = pushToTalkManager

        // Configure vocabulary usage
        VocabularyStore.shared.hkCommonEnabled = config.useVocabulary

        // Check permissions and show ready notification
        checkPermissionsAndNotify()
    }

    func applicationWillTerminate(_ notification: Notification) {
        pushToTalkManager?.stop()
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
    private func resolveTriggerKey() -> TriggerKeyType {
        switch config.triggerKey.lowercased() {
        case "fn": return .fn
        case "f12": return .f12
        case "f13": return .f13
        case "f14": return .f14
        case "f15": return .f15
        case "auto":
            fallthrough
        default:
            let model = getHardwareModel()
            if model.contains("MacBook") {
                return .fn
            } else {
                return .f15
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
