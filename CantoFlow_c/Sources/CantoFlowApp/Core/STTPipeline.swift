import Foundation

/// Errors that can occur in the STT pipeline
enum PipelineError: Error, LocalizedError {
    case notRecording
    case recordingTooShort(Int)
    case recordingFailed(Error)
    case sttFailed(Error)
    case polishFailed(Error)

    var errorDescription: String? {
        switch self {
        case .notRecording:
            return "Not recording"
        case .recordingTooShort(let ms):
            return "Recording too short (\(ms)ms)"
        case .recordingFailed(let error):
            return "Recording failed: \(error.localizedDescription)"
        case .sttFailed(let error):
            return "STT failed: \(error.localizedDescription)"
        case .polishFailed(let error):
            return "Polish failed: \(error.localizedDescription)"
        }
    }
}

/// Result of a complete STT pipeline run
struct PipelineResult {
    let rawText: String
    let finalText: String
    let recordingMs: Int
    let sttMs: Int
    let polishMs: Int
    let provider: String
    let polishStatus: String
    let fastIMERawStatus: String
    let fastIMEReplaceStatus: String
}

/// Minimum recording duration in milliseconds
private let minRecordingMs = 1500

/// Unified STT result (compatible with both Whisper and FunASR)
struct STTResult {
    let text: String
    let rawOutputPath: URL
    let modelUsed: String
    let durationMs: Int
}

/// STT pipeline integrating audio capture, whisper/funasr, polishing, and text insertion
final class STTPipeline {
    private let config: AppConfig
    private let audioCapture = AudioCapture()
    private let whisperRunner: WhisperRunner
    private let funasrRunner: FunASRRunner
    private let textPolisher: TextPolisher
    private let textInserter = TextInserter()
    private let telemetryLogger: TelemetryLogger

    private var recordingStartTime: Date?
    private var currentRecordingURL: URL?

    /// Callback for real-time audio level updates (for waveform visualization)
    var onAudioLevelUpdate: ((Float) -> Void)? {
        didSet {
            audioCapture.onAudioLevelUpdate = onAudioLevelUpdate
        }
    }

    init(config: AppConfig) {
        self.config = config
        self.whisperRunner = WhisperRunner(config: config)
        self.funasrRunner = FunASRRunner(config: config)
        self.textPolisher = TextPolisher(config: config)
        self.telemetryLogger = TelemetryLogger(fileURL: config.telemetryFile)
    }

    /// Run STT using configured backend (whisper or funasr)
    private func runSTT(audioURL: URL, outputPrefix: URL) async throws -> STTResult {
        switch config.sttBackend {
        case .whisper:
            let result = try await whisperRunner.transcribe(audioURL: audioURL, outputPrefix: outputPrefix)
            return STTResult(
                text: result.text,
                rawOutputPath: result.rawOutputPath,
                modelUsed: result.modelUsed.lastPathComponent,
                durationMs: result.durationMs
            )
        case .funasr:
            let result = try await funasrRunner.transcribe(audioURL: audioURL, outputPrefix: outputPrefix)
            return STTResult(
                text: result.text,
                rawOutputPath: result.rawOutputPath,
                modelUsed: result.modelUsed,
                durationMs: result.durationMs
            )
        }
    }

    /// Request microphone permission
    func requestMicrophonePermission(completion: @escaping (Bool) -> Void) {
        AudioCapture.requestPermission(completion: completion)
    }

    /// Start recording
    func startRecording() throws {
        let stamp = TelemetryLogger.fileTimestamp()
        let outputURL = config.outDir.appendingPathComponent("recording_\(stamp).wav")

        try audioCapture.startRecording(to: outputURL)
        recordingStartTime = Date()
        currentRecordingURL = outputURL
    }

    /// Stop recording and process through the pipeline
    /// - Returns: PipelineResult with all timing and text data
    func stopAndProcess() async throws -> PipelineResult {
        guard let startTime = recordingStartTime,
              let recordingURL = currentRecordingURL else {
            throw PipelineError.notRecording
        }

        // Stop recording
        let stoppedAt = Date()
        let recordingMs = Int(stoppedAt.timeIntervalSince(startTime) * 1000)

        do {
            try audioCapture.stopRecording()
        } catch {
            recordingStartTime = nil
            currentRecordingURL = nil
            throw PipelineError.recordingFailed(error)
        }

        recordingStartTime = nil
        currentRecordingURL = nil

        // Check minimum duration
        if recordingMs < minRecordingMs {
            try? FileManager.default.removeItem(at: recordingURL)
            throw PipelineError.recordingTooShort(recordingMs)
        }

        // Run STT (whisper or funasr based on config)
        let stamp = TelemetryLogger.fileTimestamp()
        let outputPrefix = config.outDir.appendingPathComponent("raw_\(stamp)")

        let sttResult: STTResult
        do {
            sttResult = try await runSTT(audioURL: recordingURL, outputPrefix: outputPrefix)
        } catch {
            throw PipelineError.sttFailed(error)
        }

        let rawText = sttResult.text
        var finalText = rawText
        var polishMs = 0
        var provider = "none"
        var polishStatus = "not_run"
        var fastIMERawStatus = "not_run"
        var fastIMEReplaceStatus = "not_run"
        var rawAutoPasted = false

        // Fast IME: insert raw text first
        if config.fastIME {
            fastIMERawStatus = "copied"

            if config.autoPaste {
                let result = textInserter.insertViaClipboard(text: rawText)
                if result.success {
                    rawAutoPasted = true
                    fastIMERawStatus = "auto_pasted"
                } else {
                    fastIMERawStatus = "copy_only"
                }
            }
        }

        // Polish text if provider is available
        if textPolisher.isAvailable() {
            do {
                let polishResult = try await textPolisher.polish(rawText: rawText)
                finalText = polishResult.text
                polishMs = polishResult.durationMs
                provider = polishResult.provider.rawValue
                polishStatus = "ok"

                // Fast IME: replace raw with polished
                if config.fastIME {
                    fastIMEReplaceStatus = "copied"

                    if config.autoPaste && config.autoReplace && rawAutoPasted {
                        // Undo raw text, then paste polished
                        if textInserter.undo() {
                            try? await Task.sleep(nanoseconds: 50_000_000) // 50ms
                            let insertResult = textInserter.insertViaClipboard(text: finalText)
                            if insertResult.success {
                                fastIMEReplaceStatus = "undo_then_paste"
                            } else {
                                fastIMEReplaceStatus = "undo_only"
                            }
                        } else {
                            fastIMEReplaceStatus = "copy_only"
                        }
                    }
                }
            } catch {
                polishStatus = "failed"
                print("Polish failed: \(error)")
            }
        }

        // If not in fast IME mode, insert final text directly
        if !config.fastIME {
            let insertResult = textInserter.insertViaClipboard(text: finalText)
            if !insertResult.success {
                print("Warning: Failed to auto-insert text, copied to clipboard instead")
            }
        }

        // Log telemetry
        let entry = TelemetryEntry(
            timestamp: TelemetryLogger.isoTimestamp(),
            sttProfile: config.sttProfile.rawValue,
            sttBackend: config.sttBackend.rawValue,
            modelPath: sttResult.modelUsed,
            audioDevice: config.audioDevice,
            provider: provider,
            polishStatus: polishStatus,
            fastIME: TelemetryEntry.FastIMEStatus(
                enabled: config.fastIME,
                autoPaste: config.autoPaste,
                autoReplace: config.autoReplace,
                rawStatus: fastIMERawStatus,
                replaceStatus: fastIMEReplaceStatus
            ),
            latencyMs: TelemetryEntry.LatencyMs(
                record: recordingMs,
                stt: sttResult.durationMs,
                polish: polishMs,
                clipboard: 0,
                firstInsert: 0,
                total: recordingMs + sttResult.durationMs + polishMs
            ),
            textStats: TelemetryEntry.TextStats(
                rawChars: rawText.count,
                finalChars: finalText.count
            ),
            artifacts: TelemetryEntry.Artifacts(
                rawFile: sttResult.rawOutputPath.path,
                polishedFile: config.outDir.appendingPathComponent("polished_\(stamp).txt").path
            ),
            rawText: rawText,
            finalText: finalText
        )
        telemetryLogger.log(entry)

        // Save polished text
        if polishStatus == "ok" {
            let polishedFile = config.outDir.appendingPathComponent("polished_\(stamp).txt")
            try? finalText.write(to: polishedFile, atomically: true, encoding: .utf8)
        }

        return PipelineResult(
            rawText: rawText,
            finalText: finalText,
            recordingMs: recordingMs,
            sttMs: sttResult.durationMs,
            polishMs: polishMs,
            provider: provider,
            polishStatus: polishStatus,
            fastIMERawStatus: fastIMERawStatus,
            fastIMEReplaceStatus: fastIMEReplaceStatus
        )
    }

    /// Cancel recording without processing
    func cancelRecording() {
        audioCapture.cancelRecording()
        recordingStartTime = nil
        currentRecordingURL = nil
    }

    /// Check if currently recording
    var isRecording: Bool {
        return audioCapture.recording
    }
}
