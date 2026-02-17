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
}

/// Runner for external whisper-cli binary
final class WhisperRunner {
    private let config: AppConfig

    /// Whether to use vocabulary injection in the prompt
    var useVocabularyInjection = true

    init(config: AppConfig) {
        self.config = config
    }

    /// Generate STT prompt with vocabulary injection
    private func generatePrompt() -> String {
        if useVocabularyInjection {
            return VocabularyStore.shared.generateWhisperPrompt(maxLength: 500)
        } else {
            // Fallback to basic prompt
            return "以下係廣東話句子，請以繁體中文輸出。"
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

        // Run whisper-cli with model fallback
        var result = try await runWhisper(
            whisperPath: whisperPath,
            modelPath: modelPath,
            audioURL: audioURL,
            outputPrefix: outputPrefix
        )

        // If turbo model failed, try fallback to large-v3
        if result == nil && modelPath == config.turboModelPath {
            let fallbackModel = config.largeModelPath
            if fm.fileExists(atPath: fallbackModel.path) {
                result = try await runWhisper(
                    whisperPath: whisperPath,
                    modelPath: fallbackModel,
                    audioURL: audioURL,
                    outputPrefix: outputPrefix
                )
            }
        }

        guard let (text, actualModel) = result else {
            throw WhisperError.emptyTranscription
        }

        let durationMs = Int(Date().timeIntervalSince(startTime) * 1000)
        let outputPath = URL(fileURLWithPath: outputPrefix.path + ".txt")

        return WhisperResult(
            text: text,
            rawOutputPath: outputPath,
            modelUsed: actualModel,
            durationMs: durationMs
        )
    }

    /// Execute whisper-cli process
    private func runWhisper(
        whisperPath: URL,
        modelPath: URL,
        audioURL: URL,
        outputPrefix: URL
    ) async throws -> (text: String, model: URL)? {
        let prompt = generatePrompt()

        let process = Process()
        process.executableURL = whisperPath
        process.arguments = [
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

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try process.run()
                    process.waitUntilExit()

                    let exitCode = process.terminationStatus
                    if exitCode != 0 {
                        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
                        let errorOutput = String(data: errorData, encoding: .utf8) ?? ""
                        continuation.resume(throwing: WhisperError.transcriptionFailed(exitCode, errorOutput))
                        return
                    }

                    // Read the output text file
                    let outputPath = URL(fileURLWithPath: outputPrefix.path + ".txt")
                    guard FileManager.default.fileExists(atPath: outputPath.path) else {
                        continuation.resume(throwing: WhisperError.outputFileNotFound)
                        return
                    }

                    let text = try String(contentsOf: outputPath, encoding: .utf8)
                        .trimmingCharacters(in: .whitespacesAndNewlines)

                    if text.isEmpty {
                        continuation.resume(returning: nil)
                    } else {
                        continuation.resume(returning: (text, modelPath))
                    }
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}
