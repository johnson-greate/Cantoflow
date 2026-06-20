import Foundation

enum LocalASRError: Error, LocalizedError {
    case runtimeNotFound(String)
    case bridgeNotFound(String)
    case modelNotFound(String)
    case inputFileNotFound(String)
    case transcriptionFailed(Int32, String)
    case outputFileNotFound
    case emptyTranscription

    var errorDescription: String? {
        switch self {
        case .runtimeNotFound(let path): return "Local ASR runtime not found: \(path). Open Settings > Models to install it."
        case .bridgeNotFound(let path): return "Local ASR bridge not found: \(path)"
        case .modelNotFound(let path): return "Local ASR model not found: \(path). Open Settings > Models to install it."
        case .inputFileNotFound(let path): return "Input audio file not found: \(path)"
        case .transcriptionFailed(let code, let output): return "Local ASR failed (exit \(code)): \(output)"
        case .outputFileNotFound: return "Local ASR output file was not created"
        case .emptyTranscription: return "Local ASR returned an empty transcription"
        }
    }
}

struct LocalASRResult {
    let text: String
    let rawOutputPath: URL
    let modelUsed: String
    let durationMs: Int
    let launchMs: Int
    let inferenceMs: Int
    let outputReadMs: Int
    let metalEnabled: Bool
}

/// Runs the Python bridge used by the SenseVoice and Qwen3-ASR experiments.
/// The bridge is deliberately process-based for this first quality-comparison
/// build. Once a model wins, it can move to a persistent worker to remove cold
/// start and model-loading time.
final class LocalASRRunner {
    private let config: AppConfig
    private let paths: ASRRuntimePaths

    init(config: AppConfig, paths: ASRRuntimePaths = ASRRuntimePaths()) {
        self.config = config
        self.paths = paths
    }

    func transcribe(
        engine: STTEngine,
        audioURL: URL,
        outputPrefix: URL
    ) async throws -> LocalASRResult {
        precondition(engine != .whisper)

        let fm = FileManager.default
        let bridge = config.localASRBridge
        guard fm.isExecutableFile(atPath: paths.python.path) else {
            throw LocalASRError.runtimeNotFound(paths.python.path)
        }
        guard fm.fileExists(atPath: bridge.path) else {
            throw LocalASRError.bridgeNotFound(bridge.path)
        }
        guard fm.fileExists(atPath: audioURL.path) else {
            throw LocalASRError.inputFileNotFound(audioURL.path)
        }

        let modelPath: URL
        switch engine {
        case .senseVoice:
            modelPath = paths.senseVoiceDirectory
            guard fm.fileExists(atPath: paths.senseVoiceModel.path),
                  fm.fileExists(atPath: paths.senseVoiceTokens.path) else {
                throw LocalASRError.modelNotFound(modelPath.path)
            }
        case .qwen3ASR:
            modelPath = paths.qwenModelDirectory
            guard fm.fileExists(atPath: modelPath.appendingPathComponent("config.json").path) else {
                throw LocalASRError.modelNotFound(modelPath.path)
            }
        case .whisper:
            preconditionFailure("Whisper must use WhisperRunner")
        }

        let outputPath = URL(fileURLWithPath: outputPrefix.path + ".txt")
        var arguments = [
            bridge.path,
            "--engine", engine.rawValue,
            "--audio", audioURL.path,
            "--model-dir", modelPath.path,
            "--output", outputPath.path,
            "--traditional"
        ]

        if engine == .qwen3ASR && config.useVocabulary {
            let context = VocabularyStore.shared.generateWhisperPrompt(maxLength: 500)
            if !context.isEmpty {
                arguments += ["--context", context]
            }
        }

        let startedAt = Date()
        let processResult = try await runProcess(
            executable: paths.python,
            arguments: arguments
        )
        let inferenceFinishedAt = Date()

        guard processResult.exitCode == 0 else {
            let diagnostic = String(processResult.output.suffix(4000))
            throw LocalASRError.transcriptionFailed(processResult.exitCode, diagnostic)
        }
        guard fm.fileExists(atPath: outputPath.path) else {
            throw LocalASRError.outputFileNotFound
        }

        let readStartedAt = Date()
        let text = try String(contentsOf: outputPath, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let outputReadMs = Int(Date().timeIntervalSince(readStartedAt) * 1000)
        guard !text.isEmpty else { throw LocalASRError.emptyTranscription }

        return LocalASRResult(
            text: text,
            rawOutputPath: outputPath,
            modelUsed: engine.displayName,
            durationMs: Int(Date().timeIntervalSince(startedAt) * 1000),
            launchMs: processResult.launchMs,
            inferenceMs: Int(inferenceFinishedAt.timeIntervalSince(startedAt) * 1000) - processResult.launchMs,
            outputReadMs: outputReadMs,
            metalEnabled: engine == .qwen3ASR
        )
    }

    private struct ProcessResult {
        let exitCode: Int32
        let output: String
        let launchMs: Int
    }

    private func runProcess(executable: URL, arguments: [String]) async throws -> ProcessResult {
        let environment = paths.offlineModelEnvironment
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = executable
                process.arguments = arguments
                // Avoid inheriting a restricted-volume CWD (e.g. /Volumes/JTDev),
                // which makes Python abort on os.getcwd() with a permission error.
                process.currentDirectoryURL = FileManager.default.temporaryDirectory
                // Force fully-local model loading (no HF Hub access / cache on an
                // unplugged external volume; also skips the slow first-run fetch).
                process.environment = environment

                let outputPipe = Pipe()
                process.standardOutput = outputPipe
                process.standardError = outputPipe

                do {
                    let launchStartedAt = Date()
                    try process.run()
                    let launchMs = Int(Date().timeIntervalSince(launchStartedAt) * 1000)

                    // Drain while the process runs so verbose native runtimes cannot
                    // fill the pipe buffer and deadlock the app.
                    let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit()
                    let output = String(data: data, encoding: .utf8) ?? ""
                    continuation.resume(returning: ProcessResult(
                        exitCode: process.terminationStatus,
                        output: output,
                        launchMs: launchMs
                    ))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}
