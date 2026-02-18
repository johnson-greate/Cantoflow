import Foundation

/// Errors that can occur during whisper transcription
enum WhisperError: Error, LocalizedError {
    case binaryNotFound(String)
    case modelNotFound(String)
    case inputFileNotFound(String)
    case transcriptionFailed(Int32, String)
    case outputFileNotFound
    case emptyTranscription

    var errorDescription: String? {
        switch self {
        case .binaryNotFound(let path):
            return "whisper-cli not found at: \(path)"
        case .modelNotFound(let path):
            return "Whisper model not found at: \(path)"
        case .inputFileNotFound(let path):
            return "Input audio file not found: \(path)"
        case .transcriptionFailed(let code, let output):
            return "Transcription failed (exit \(code)): \(output)"
        case .outputFileNotFound:
            return "Transcription output file not found"
        case .emptyTranscription:
            return "Transcription result is empty"
        }
    }
}

/// Result of whisper transcription
struct WhisperResult {
    let text: String
    let rawOutputPath: URL
    let modelUsed: URL
    let durationMs: Int
    let breakdown: SttBreakdown

    /// Sub-timing breakdown of the whisper-cli process
    struct SttBreakdown {
        /// Time for the OS to spawn the whisper-cli process (before first token)
        let launchMs: Int
        /// Time whisper-cli spent running inference (waitUntilExit)
        let inferenceMs: Int
        /// Time to read the output .txt file from disk
        let outputReadMs: Int
        /// Whether Metal GPU acceleration was requested for this run
        let metalEnabled: Bool
    }
}

/// Runner for external whisper-cli binary
final class WhisperRunner {
    private let config: AppConfig

    /// Whether to use vocabulary injection in the prompt
    var useVocabularyInjection = true

    /// Cached Metal support detection result (nil = not yet checked)
    private static var _metalSupported: Bool? = nil

    init(config: AppConfig) {
        self.config = config
    }

    /// Detect whether the whisper-cli binary was compiled with Metal GPU support.
    /// Result is cached after the first call to avoid repeated process spawns.
    static func detectMetalSupport(whisperPath: URL) -> Bool {
        if let cached = _metalSupported {
            return cached
        }

        let process = Process()
        process.executableURL = whisperPath
        process.arguments = ["--help"]

        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = outputPipe  // whisper-cli prints help to stderr

        do {
            try process.run()
            process.waitUntilExit()
            let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
            let helpText = String(data: data, encoding: .utf8) ?? ""
            // The binary has Metal/GPU support if --no-gpu or --device flags appear in help
            let supported = helpText.contains("--no-gpu") || helpText.contains("--device")
            _metalSupported = supported
            return supported
        } catch {
            _metalSupported = false
            return false
        }
    }

    /// Generate STT prompt with vocabulary injection
    private func generatePrompt() -> String {
        if useVocabularyInjection {
            return VocabularyStore.shared.generateWhisperPrompt(maxLength: 500)
        } else {
            // Fallback to basic prompt
            return "以下係廣東話句子，必須以繁體中文輸出。"
        }
    }

    /// Transcribe audio file using whisper-cli
    /// - Parameters:
    ///   - audioURL: Path to the input WAV file
    ///   - outputPrefix: Prefix for output files (whisper adds .txt extension)
    /// - Returns: WhisperResult containing transcribed text
    func transcribe(audioURL: URL, outputPrefix: URL) async throws -> WhisperResult {
        let whisperPath = config.whisperCLI
        let modelPath = config.resolveModelPath()

        // Validate paths
        let fm = FileManager.default
        guard fm.isExecutableFile(atPath: whisperPath.path) else {
            throw WhisperError.binaryNotFound(whisperPath.path)
        }
        guard fm.fileExists(atPath: modelPath.path) else {
            throw WhisperError.modelNotFound(modelPath.path)
        }
        guard fm.fileExists(atPath: audioURL.path) else {
            throw WhisperError.inputFileNotFound(audioURL.path)
        }

        let startTime = Date()

        // Detect Metal GPU support once (cached after first call)
        let metalSupported = WhisperRunner.detectMetalSupport(whisperPath: whisperPath)
        let metalEnabled = metalSupported && config.useMetalGPU

        if metalSupported && !config.useMetalGPU {
            print("[WhisperRunner] Metal GPU available but disabled via --no-metal")
        } else if !metalSupported {
            print("[WhisperRunner] Metal GPU not available in this whisper-cli build")
        } else {
            print("[WhisperRunner] Metal GPU enabled (device 0)")
        }

        // Run whisper-cli with model fallback
        var runResult = try await runWhisper(
            whisperPath: whisperPath,
            modelPath: modelPath,
            audioURL: audioURL,
            outputPrefix: outputPrefix,
            metalEnabled: metalEnabled
        )

        // If turbo model failed, try fallback to large-v3
        if runResult == nil && modelPath == config.turboModelPath {
            let fallbackModel = config.largeModelPath
            if fm.fileExists(atPath: fallbackModel.path) {
                runResult = try await runWhisper(
                    whisperPath: whisperPath,
                    modelPath: fallbackModel,
                    audioURL: audioURL,
                    outputPrefix: outputPrefix,
                    metalEnabled: metalEnabled
                )
            }
        }

        guard let run = runResult else {
            throw WhisperError.emptyTranscription
        }

        let durationMs = Int(Date().timeIntervalSince(startTime) * 1000)
        let outputPath = URL(fileURLWithPath: outputPrefix.path + ".txt")

        return WhisperResult(
            text: run.text,
            rawOutputPath: outputPath,
            modelUsed: run.model,
            durationMs: durationMs,
            breakdown: WhisperResult.SttBreakdown(
                launchMs: run.launchMs,
                inferenceMs: run.inferenceMs,
                outputReadMs: run.outputReadMs,
                metalEnabled: run.metalEnabled
            )
        )
    }

    /// Internal result type carrying timing alongside transcribed content
    private struct RunResult {
        let text: String
        let model: URL
        let launchMs: Int
        let inferenceMs: Int
        let outputReadMs: Int
        let metalEnabled: Bool
    }

    /// Execute whisper-cli process, returning text + sub-timing
    private func runWhisper(
        whisperPath: URL,
        modelPath: URL,
        audioURL: URL,
        outputPrefix: URL,
        metalEnabled: Bool
    ) async throws -> RunResult? {
        let prompt = generatePrompt()

        let process = Process()
        process.executableURL = whisperPath

        var args: [String] = [
            "-m", modelPath.path,
            "-f", audioURL.path,
            "-l", "yue",  // Cantonese
            "--prompt", prompt,
            "-sns",  // Suppress non-speech tokens
            "-nth", "0.35",  // No-speech threshold
            "-otxt",  // Output as text file
            "-of", outputPrefix.path,  // Output file prefix
            "-np"  // No progress
        ]

        if metalEnabled {
            // Explicitly select GPU device 0 (Metal on Apple Silicon)
            args += ["-dev", "0"]
        } else {
            // Disable GPU, fall back to CPU
            args += ["-ng"]
        }

        // Profile-specific decode parameters: trade accuracy for speed
        switch config.sttProfile {
        case .fast:
            // Greedy search (beam-size 1): skips beam search, ~3-5x faster inference
            args += ["--beam-size", "1", "--best-of", "1"]
        case .balanced:
            // Reduced beam search
            args += ["--beam-size", "3"]
        case .accurate:
            break  // whisper-cli defaults: beam-size 5, best-of 5
        }

        process.arguments = args

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    // T1: process launch (OS fork+exec overhead)
                    let t1 = Date()
                    try process.run()
                    let t2 = Date()
                    let launchMs = Int(t2.timeIntervalSince(t1) * 1000)

                    // T2: model load + inference (waitUntilExit)
                    process.waitUntilExit()
                    let t3 = Date()
                    let inferenceMs = Int(t3.timeIntervalSince(t2) * 1000)

                    let exitCode = process.terminationStatus
                    if exitCode != 0 {
                        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
                        let errorOutput = String(data: errorData, encoding: .utf8) ?? ""
                        continuation.resume(throwing: WhisperError.transcriptionFailed(exitCode, errorOutput))
                        return
                    }

                    // T3: output file read
                    let outputPath = URL(fileURLWithPath: outputPrefix.path + ".txt")
                    guard FileManager.default.fileExists(atPath: outputPath.path) else {
                        continuation.resume(throwing: WhisperError.outputFileNotFound)
                        return
                    }

                    let text = try String(contentsOf: outputPath, encoding: .utf8)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    let outputReadMs = Int(Date().timeIntervalSince(t3) * 1000)

                    if text.isEmpty {
                        continuation.resume(returning: nil)
                    } else {
                        continuation.resume(returning: RunResult(
                            text: text,
                            model: modelPath,
                            launchMs: launchMs,
                            inferenceMs: inferenceMs,
                            outputReadMs: outputReadMs,
                            metalEnabled: metalEnabled
                        ))
                    }
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}
