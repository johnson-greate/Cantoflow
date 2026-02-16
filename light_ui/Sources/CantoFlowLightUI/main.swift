import AppKit
import Foundation

struct AppConfig {
    var projectRoot: URL
    var sttProfile: String = "fast"
    var audioDevice: String = "MacBook Air Microphone"
    var fastIME: Bool = true
    var autoPaste: Bool = true
    var autoReplace: Bool = true

    static func fromArgs() -> AppConfig {
        var config = AppConfig(projectRoot: URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
        var i = 1
        let args = CommandLine.arguments
        while i < args.count {
            let arg = args[i]
            switch arg {
            case "--project-root":
                if i + 1 < args.count {
                    config.projectRoot = URL(fileURLWithPath: args[i + 1])
                    i += 1
                }
            case "--stt-profile":
                if i + 1 < args.count {
                    config.sttProfile = args[i + 1]
                    i += 1
                }
            case "--audio-device":
                if i + 1 < args.count {
                    config.audioDevice = args[i + 1]
                    i += 1
                }
            case "--no-fast-ime":
                config.fastIME = false
            case "--no-auto-paste":
                config.autoPaste = false
            case "--no-auto-replace":
                config.autoReplace = false
            default:
                break
            }
            i += 1
        }
        return config
    }
}

enum UIState: String {
    case idle
    case recording
    case processing
}

final class CantoFlowController: NSObject {
    private let config: AppConfig
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private var toggleItem: NSMenuItem?

    private var state: UIState = .idle {
        didSet {
            DispatchQueue.main.async { [weak self] in
                self?.updateStatusUI()
            }
        }
    }

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var fnCurrentlyDown = false

    private var recordingProcess: Process?
    private var recordingFileURL: URL?
    private var recordingStartedAt: Date?

    private let outDir: URL
    private let runPOCScript: URL
    private let whisperCLI: URL
    private let uiTelemetryFile: URL
    private let minRecordingMs = 1500

    init(config: AppConfig) {
        self.config = config
        self.outDir = config.projectRoot.appendingPathComponent("poc/.out", isDirectory: true)
        self.runPOCScript = config.projectRoot.appendingPathComponent("poc/run_poc.sh")
        self.whisperCLI = config.projectRoot.appendingPathComponent("third_party/whisper.cpp/build/bin/whisper-cli")
        self.uiTelemetryFile = config.projectRoot.appendingPathComponent("poc/.out/light_ui_telemetry.jsonl")
        super.init()

        try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        setupStatusItem()
        setupMenu()
        setupFnEventTap()
    }

    deinit {
        teardownFnEventTap()
    }

    private func setupStatusItem() {
        guard let button = statusItem.button else { return }
        button.target = self
        button.action = #selector(onStatusButtonClick)
        button.sendAction(on: [.leftMouseUp])
        updateStatusUI()
    }

    private func setupMenu() {
        let hint = NSMenuItem(title: "Fn (Globe) key: Start / Stop", action: nil, keyEquivalent: "")
        hint.isEnabled = false
        menu.addItem(hint)
        menu.addItem(NSMenuItem.separator())

        let toggle = NSMenuItem(title: "Start Recording", action: #selector(toggleRecordingFromMenu), keyEquivalent: "")
        toggle.target = self
        menu.addItem(toggle)
        toggleItem = toggle

        let openOut = NSMenuItem(title: "Open Output Folder", action: #selector(openOutputFolder), keyEquivalent: "")
        openOut.target = self
        menu.addItem(openOut)

        menu.addItem(NSMenuItem.separator())
        let quit = NSMenuItem(title: "Quit CantoFlow", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    private func updateStatusUI() {
        guard let button = statusItem.button else { return }
        let title: String
        let symbolName: String
        let tint: NSColor?

        switch state {
        case .idle:
            title = " CantoFlow"
            symbolName = "mic.fill"
            tint = nil
        case .recording:
            title = " CantoFlow REC"
            symbolName = "record.circle.fill"
            tint = NSColor.systemRed
        case .processing:
            title = " CantoFlow..."
            symbolName = "hourglass.circle.fill"
            tint = NSColor.systemOrange
        }

        button.title = title
        button.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "CantoFlow")
        button.imagePosition = .imageLeading
        button.contentTintColor = tint

        switch state {
        case .idle:
            toggleItem?.title = "Start Recording"
        case .recording:
            toggleItem?.title = "Stop Recording"
        case .processing:
            toggleItem?.title = "Processing..."
        }
    }

    private func setupFnEventTap() {
        let mask = (1 << CGEventType.flagsChanged.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let controller = Unmanaged<CantoFlowController>.fromOpaque(refcon).takeUnretainedValue()
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    if let eventTap = controller.eventTap {
                        CGEvent.tapEnable(tap: eventTap, enable: true)
                    }
                    return Unmanaged.passUnretained(event)
                }
                controller.handleFlagsChanged(event: event)
                return Unmanaged.passUnretained(event)
            },
            userInfo: UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        ) else {
            print("Warning: failed to create CGEvent tap. Enable Accessibility + Input Monitoring for the app.")
            return
        }

        eventTap = tap
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else { return }
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func teardownFnEventTap() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
    }

    private func handleFlagsChanged(event: CGEvent) {
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        guard keyCode == 63 else { return } // Fn / Globe
        let fnDown = event.flags.contains(.maskSecondaryFn)
        if fnDown && !fnCurrentlyDown {
            fnCurrentlyDown = true
            onFnPressed()
        } else if !fnDown && fnCurrentlyDown {
            fnCurrentlyDown = false
        }
    }

    private func onFnPressed() {
        switch state {
        case .idle:
            startRecording()
        case .recording:
            stopRecordingAndProcess()
        case .processing:
            NSSound.beep()
        }
    }

    @objc private func onStatusButtonClick() {
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func toggleRecordingFromMenu() {
        onFnPressed()
    }

    @objc private func openOutputFolder() {
        NSWorkspace.shared.open(outDir)
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }

    private func startRecording() {
        guard state == .idle else { return }
        let stamp = Self.timestamp()
        let output = outDir.appendingPathComponent("ui_recording_\(stamp).wav")

        let process = Process()
        process.currentDirectoryURL = config.projectRoot
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [
            "ffmpeg",
            "-hide_banner",
            "-loglevel", "error",
            "-f", "avfoundation",
            "-i", ":\(config.audioDevice)",
            "-ac", "1",
            "-ar", "16000",
            "-c:a", "pcm_s16le",
            output.path
        ]
        let pipe = Pipe()
        process.standardError = pipe
        process.standardOutput = Pipe()

        do {
            try process.run()
            recordingProcess = process
            recordingStartedAt = Date()
            recordingFileURL = output
            state = .recording
            notify("Recording started")
        } catch {
            notify("Failed to start recording: \(error.localizedDescription)")
            state = .idle
        }
    }

    private func stopRecordingAndProcess() {
        guard state == .recording else { return }
        guard let process = recordingProcess, let recordingURL = recordingFileURL, let startedAt = recordingStartedAt else {
            state = .idle
            return
        }

        state = .processing
        let stoppedAt = Date()
        let recordingMs = Int(stoppedAt.timeIntervalSince(startedAt) * 1000.0)
        if recordingMs < minRecordingMs {
            state = .idle
            notify("Recording too short (\(recordingMs)ms). Please hold Fn for at least \(minRecordingMs)ms.")
            recordingProcess = nil
            recordingFileURL = nil
            recordingStartedAt = nil
            return
        }
        process.interrupt()

        DispatchQueue.global(qos: .userInitiated).async {
            process.waitUntilExit()
            let fileExists = FileManager.default.fileExists(atPath: recordingURL.path)
            if !fileExists {
                DispatchQueue.main.async {
                    self.notify("Recording file missing, aborted.")
                    self.state = .idle
                }
                return
            }
            self.runPipeline(recordingURL: recordingURL, recordingMs: recordingMs)
        }
    }

    private func runPipeline(recordingURL: URL, recordingMs: Int) {
        let runStamp = Self.timestamp()
        let pipelineTelemetry = outDir.appendingPathComponent("light_ui_pipeline_\(runStamp).jsonl")
        let process = Process()
        process.currentDirectoryURL = config.projectRoot
        process.executableURL = runPOCScript

        var args: [String] = [
            "--input-wav", recordingURL.path,
            "--stt-profile", config.sttProfile,
            "--audio-device", config.audioDevice,
            "--whisper", whisperCLI.path,
            "--telemetry-file", pipelineTelemetry.path
        ]

        if config.fastIME {
            args.append("--fast-ime")
            if config.autoPaste {
                args.append("--auto-paste")
            } else {
                args.append("--no-auto-paste")
            }
            if !config.autoReplace {
                args.append("--no-auto-replace")
            }
        }

        process.arguments = args
        process.environment = ProcessInfo.processInfo.environment

        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = outputPipe

        let pipelineStart = Date()
        do {
            try process.run()
        } catch {
            DispatchQueue.main.async {
                self.notify("Failed to run pipeline: \(error.localizedDescription)")
                self.state = .idle
            }
            return
        }

        process.waitUntilExit()
        let pipelineMs = Int(Date().timeIntervalSince(pipelineStart) * 1000.0)
        let exitCode = process.terminationStatus
        let combinedOutput = String(data: outputPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""

        let pipelineTelemetryJSON = Self.readFirstJSONLine(from: pipelineTelemetry)
        self.appendUILatency(
            recordingFile: recordingURL.path,
            recordingMs: recordingMs,
            pipelineMs: pipelineMs,
            exitCode: Int(exitCode),
            pipelineTelemetry: pipelineTelemetryJSON
        )

        DispatchQueue.main.async {
            if exitCode == 0 {
                let sttMs = Self.readNestedInt(from: pipelineTelemetryJSON, keys: ["latency_ms", "stt"]) ?? -1
                let polishMs = Self.readNestedInt(from: pipelineTelemetryJSON, keys: ["latency_ms", "polish"]) ?? -1
                self.notify("Done. record=\(recordingMs)ms stt=\(sttMs)ms polish=\(polishMs)ms")
            } else {
                let tail = combinedOutput.split(separator: "\n").suffix(3).joined(separator: " | ")
                self.notify("Pipeline failed (\(exitCode)): \(tail)")
            }
            self.state = .idle
        }
    }

    private func appendUILatency(
        recordingFile: String,
        recordingMs: Int,
        pipelineMs: Int,
        exitCode: Int,
        pipelineTelemetry: [String: Any]
    ) {
        var payload: [String: Any] = [
            "timestamp": Self.isoTimestamp(),
            "recording_file": recordingFile,
            "recording_ms": recordingMs,
            "pipeline_ms": pipelineMs,
            "exit_code": exitCode,
            "stt_profile": config.sttProfile,
            "audio_device": config.audioDevice,
            "fast_ime": config.fastIME
        ]
        if !pipelineTelemetry.isEmpty {
            payload["pipeline"] = pipelineTelemetry
        }

        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              var line = String(data: data, encoding: .utf8) else { return }
        line.append("\n")
        if let encoded = line.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: uiTelemetryFile.path) {
                if let handle = try? FileHandle(forWritingTo: uiTelemetryFile) {
                    defer { try? handle.close() }
                    try? handle.seekToEnd()
                    try? handle.write(contentsOf: encoded)
                }
            } else {
                try? encoded.write(to: uiTelemetryFile, options: .atomic)
            }
        }
    }

    private func notify(_ message: String) {
        let escaped = message.replacingOccurrences(of: "\"", with: "\\\"")
        let script = "display notification \"\(escaped)\" with title \"CantoFlow\""
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        try? process.run()
    }

    private static func readFirstJSONLine(from fileURL: URL) -> [String: Any] {
        guard let content = try? String(contentsOf: fileURL, encoding: .utf8) else { return [:] }
        guard let firstLine = content.split(separator: "\n").first else { return [:] }
        guard let data = firstLine.data(using: .utf8) else { return [:] }
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    private static func readNestedInt(from dict: [String: Any], keys: [String]) -> Int? {
        var current: Any? = dict
        for key in keys {
            current = (current as? [String: Any])?[key]
        }
        return current as? Int
    }

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        return formatter.string(from: Date())
    }

    private static func isoTimestamp() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: Date())
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let config: AppConfig
    private var controller: CantoFlowController?

    init(config: AppConfig) {
        self.config = config
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        controller = CantoFlowController(config: config)
    }
}

let config = AppConfig.fromArgs()
let app = NSApplication.shared
let delegate = AppDelegate(config: config)
app.delegate = delegate
app.run()
