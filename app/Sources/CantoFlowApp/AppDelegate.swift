import AppKit
import ApplicationServices
import AVFoundation

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

        // Check permissions, assets, and current input device
        checkStartupHealthAndNotify()

        // Observe customHotkey changes in UserDefaults
        UserDefaults.standard.addObserver(self, forKeyPath: "customHotkey", options: [.new], context: nil)
        UserDefaults.standard.addObserver(
            self,
            forKeyPath: AudioDeviceManager.preferredInputDeviceDefaultsKey,
            options: [.new],
            context: nil
        )
    }

    func applicationWillTerminate(_ notification: Notification) {
        UserDefaults.standard.removeObserver(self, forKeyPath: "customHotkey")
        UserDefaults.standard.removeObserver(self, forKeyPath: AudioDeviceManager.preferredInputDeviceDefaultsKey)
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
        } else if keyPath == AudioDeviceManager.preferredInputDeviceDefaultsKey {
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.menuBarController?.updateInputDevice(
                    name: AudioDeviceManager.shared.currentSelectionDisplayName()
                )
            }
        }
    }

    private func checkStartupHealthAndNotify() {
        pipeline?.requestMicrophonePermission { granted in
            DispatchQueue.main.async {
                guard granted else {
                    NotificationManager.shared.notify("Microphone permission denied. Please enable in System Settings.")
                    return
                }

                let keyName = self.pushToTalkManager?.triggerKey.displayName ?? "Fn"
                let checks = self.startupHealthChecks()
                let inputDevice = AudioDeviceManager.shared.currentSelectionDisplayName()
                let summary = checks.isEmpty
                    ? "CantoFlow ready. Hold \(keyName) to record. Input: \(inputDevice)"
                    : "Startup checks: " + checks.joined(separator: " | ")

                NotificationManager.shared.notify(summary)
                print("[Startup] Input device: \(inputDevice)")
                if !checks.isEmpty {
                    for item in checks {
                        print("[Startup] \(item)")
                    }
                }
            }
        }
    }

    private func startupHealthChecks() -> [String] {
        var checks: [String] = []
        let fm = FileManager.default

        if !AXIsProcessTrusted() {
            checks.append("Accessibility not granted")
        }

        if !(pushToTalkManager?.isRunning ?? false) {
            checks.append("Hotkey listener unavailable; enable Input Monitoring")
        }

        if !fm.isExecutableFile(atPath: config.whisperCLI.path) {
            checks.append("Missing whisper-cli at \(config.whisperCLI.lastPathComponent)")
        }

        let preferredModel = config.resolveModelPath()
        if !fm.fileExists(atPath: preferredModel.path) {
            checks.append("Missing model \(preferredModel.lastPathComponent)")
        }

        if AudioDeviceManager.shared.resolvedInputDevice() == nil {
            checks.append("No audio input device detected")
        }

        return checks
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
