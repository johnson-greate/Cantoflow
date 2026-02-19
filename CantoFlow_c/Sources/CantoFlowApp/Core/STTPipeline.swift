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
    let sttBackend: AppConfig.STTBackend
}

/// Minimum recording duration in milliseconds
private let minRecordingMs = 1500

/// Unified STT result (compatible with both Whisper and FunASR)
struct STTResult {
    let text: String
    let rawOutputPath: URL
    let modelUsed: String
    let durationMs: Int
    /// Sub-timing for whisper runs; nil for FunASR
    let sttBreakdown: TelemetryEntry.LatencyMs.SttBreakdown?
}

/// STT pipeline integrating audio capture, whisper/funasr, polishing, and text insertion
final class STTPipeline {
    private var config: AppConfig

    /// Runtime backend switching for A/B testing
    var sttBackend: AppConfig.STTBackend {
        get { config.sttBackend }
        set { config.sttBackend = newValue }
    }
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
                durationMs: result.durationMs,
                sttBreakdown: TelemetryEntry.LatencyMs.SttBreakdown(
                    launchMs: result.breakdown.launchMs,
                    inferenceMs: result.breakdown.inferenceMs,
                    outputReadMs: result.breakdown.outputReadMs,
                    metalEnabled: result.breakdown.metalEnabled
                )
            )
        case .funasr:
            let result = try await funasrRunner.transcribe(audioURL: audioURL, outputPrefix: outputPrefix)
            return STTResult(
                text: result.text,
                rawOutputPath: result.rawOutputPath,
                modelUsed: result.modelUsed,
                durationMs: result.durationMs,
                sttBreakdown: nil
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

        // Capture backend at the moment recording stops (for telemetry accuracy)
        let backendUsed = config.sttBackend

        // Stop recording — measure both recording duration and flush time
        let stoppedAt = Date()
        let recordingMs = Int(stoppedAt.timeIntervalSince(startTime) * 1000)

        do {
            try audioCapture.stopRecording()
        } catch {
            recordingStartTime = nil
            currentRecordingURL = nil
            throw PipelineError.recordingFailed(error)
        }
        // audioFlushMs: time for stopRecording() to fully flush WAV to disk
        let audioFlushMs = Int(Date().timeIntervalSince(stoppedAt) * 1000)

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

        // Detect terminal once before STT delay changes frontmost app context
        let isTerminal = textInserter.isFrontmostAppTerminal()

        // Fast IME: insert raw text first.
        // Skip in terminal apps — Cmd+Z won't undo text and pasted newlines execute as commands.
        if config.fastIME {
            fastIMERawStatus = "copied"

            if config.autoPaste && !isTerminal {
                let result = textInserter.insertViaClipboard(text: rawText)
                if result.success {
                    rawAutoPasted = true
                    fastIMERawStatus = "auto_pasted"
                } else {
                    fastIMERawStatus = "copy_only"
                }
            } else if isTerminal {
                fastIMERawStatus = "skipped_terminal"
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

                // Fast IME: replace raw with polished (regular apps only).
                // Terminal is handled separately below so it works even without polish.
                if config.fastIME && config.autoPaste && config.autoReplace && rawAutoPasted {
                    fastIMEReplaceStatus = "copied"
                    if textInserter.undo() {
                        try? await Task.sleep(nanoseconds: 50_000_000) // 50ms
                        let insertResult = textInserter.insertViaClipboard(text: finalText)
                        fastIMEReplaceStatus = insertResult.success ? "undo_then_paste" : "undo_only"
                    } else {
                        fastIMEReplaceStatus = "copy_only"
                    }
                }
            } catch {
                polishStatus = "failed"
                print("Polish failed: \(error)")
            }
        }

        // Terminal paste — intentionally outside the polish block so it runs
        // regardless of whether an LLM key is configured or polish succeeded.
        // Raw paste was suppressed earlier to prevent newlines executing as shell
        // commands; paste the final text (raw or polished) here instead.
        if config.fastIME && config.autoPaste && isTerminal {
            fastIMEReplaceStatus = "copied"
            let insertResult = textInserter.insertViaClipboard(text: finalText)
            fastIMEReplaceStatus = insertResult.success ? "terminal_paste" : "copy_only"
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
                audioFlushMs: audioFlushMs,
                stt: sttResult.durationMs,
                sttBreakdown: sttResult.sttBreakdown,
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
            fastIMEReplaceStatus: fastIMEReplaceStatus,
            sttBackend: backendUsed
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
