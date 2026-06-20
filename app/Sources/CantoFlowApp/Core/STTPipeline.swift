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
    let metalEnabled: Bool
    let sttModel: String
}

/// Minimum recording duration in milliseconds
private let minRecordingMs = 1500

/// Unified STT result wrapping WhisperResult for the pipeline
struct STTResult {
    let text: String
    let rawOutputPath: URL
    let modelUsed: String
    let durationMs: Int
    let sttBreakdown: TelemetryEntry.LatencyMs.SttBreakdown?
}

/// STT pipeline integrating audio capture, whisper, polishing, and text insertion
final class STTPipeline {
    private var config: AppConfig

    private let audioCapture = AudioCapture()
    private let whisperRunner: WhisperRunner
    private let localASRRunner: LocalASRRunner
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
        self.localASRRunner = LocalASRRunner(config: config)
        self.textPolisher = TextPolisher(config: config)
        self.telemetryLogger = TelemetryLogger(fileURL: config.telemetryFile)
    }

    /// Run STT using the engine currently selected in Settings.
    private func runSTT(audioURL: URL, outputPrefix: URL) async throws -> STTResult {
        switch config.activeSTTEngine {
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

        case .senseVoice, .qwen3ASR:
            let result = try await localASRRunner.transcribe(
                engine: config.activeSTTEngine,
                audioURL: audioURL,
                outputPrefix: outputPrefix
            )
            return STTResult(
                text: result.text,
                rawOutputPath: result.rawOutputPath,
                modelUsed: result.modelUsed,
                durationMs: result.durationMs,
                sttBreakdown: TelemetryEntry.LatencyMs.SttBreakdown(
                    launchMs: result.launchMs,
                    inferenceMs: result.inferenceMs,
                    outputReadMs: result.outputReadMs,
                    metalEnabled: result.metalEnabled
                )
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

        // Run STT
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

        // Flush any pending correction session from the previous recording,
        // and capture the focused element + terminal status while the user's
        // cursor is still on the target field (before STT begins).
        let (isTerminal, watchElement) = await MainActor.run {
            CorrectionWatcher.shared.flush()
            return (
                textInserter.isFrontmostAppTerminal(),
                textInserter.captureCurrentElement()
            )
        }

        // Whether an LLM polish pass will run and replace the raw text.
        let willPolish = textPolisher.isAvailable()
        // When polish will replace raw anyway, skip the raw paste entirely and paste
        // the polished text once. The old "paste raw → Cmd+Z undo → paste polished"
        // dance relied on the target app treating one Cmd+Z as undoing exactly the
        // raw paste — unreliable, and when undo silently failed the user saw BOTH
        // raw and polished text.
        let deferRawForPolish = config.fastIME && config.autoPaste && config.autoReplace
            && willPolish && !isTerminal

        // Fast IME: insert raw text first (unless deferred for polish).
        // Skip in terminal apps — Cmd+Z won't undo text and pasted newlines execute as commands.
        // All insertViaClipboard calls hop to @MainActor (NSPasteboard + CGEvent require main thread).
        if config.fastIME {
            fastIMERawStatus = "copied"

            if config.autoPaste && !isTerminal {
                if deferRawForPolish {
                    fastIMERawStatus = "deferred_for_polish"
                } else {
                    let result = await textInserter.insertViaClipboard(text: rawText)
                    fastIMERawStatus = result.success ? "auto_pasted" : "copy_only"
                }
            } else if isTerminal {
                fastIMERawStatus = "skipped_terminal"
            }
        }

        // Polish text if provider is available
        if willPolish {
            do {
                let polishResult = try await textPolisher.polish(rawText: rawText)
                finalText = polishResult.text
                polishMs = polishResult.durationMs
                provider = polishResult.provider.rawValue
                polishStatus = "ok"

                // Fast IME: paste polished (regular apps only). Raw was deferred above,
                // so this is the single paste the user sees — no undo needed.
                // Terminal is handled separately below.
                if deferRawForPolish {
                    let insertResult = await textInserter.insertViaClipboard(text: finalText)
                    fastIMEReplaceStatus = insertResult.success ? "polished_paste" : "copy_only"
                }
            } catch {
                polishStatus = "failed"
                print("Polish failed: \(error)")
                // Polish failed after we deferred the raw paste — paste raw now so the
                // user still gets their text.
                if deferRawForPolish {
                    let insertResult = await textInserter.insertViaClipboard(text: rawText)
                    fastIMEReplaceStatus = insertResult.success ? "raw_fallback" : "copy_only"
                }
            }
        }

        // Terminal paste — intentionally outside the polish block so it runs
        // regardless of whether an LLM key is configured or polish succeeded.
        // Raw paste was suppressed earlier to prevent newlines executing as shell
        // commands; paste the final text (raw or polished) here instead.
        if config.fastIME && config.autoPaste && isTerminal {
            fastIMEReplaceStatus = "copied"
            let insertResult = await textInserter.insertViaClipboard(text: finalText)
            fastIMEReplaceStatus = insertResult.success ? "terminal_paste" : "copy_only"
        }

        // If not in fast IME mode, insert final text directly
        if !config.fastIME {
            let insertResult = await textInserter.insertViaClipboard(text: finalText)
            if !insertResult.success {
                print("Warning: Failed to auto-insert text, copied to clipboard instead")
            }
        }

        // Start correction watcher on the final text so user edits can be learned
        // as personal vocabulary. Skipped for terminals (no persistent text field).
        // Capture immutable copies to satisfy Swift concurrency (finalText is a var).
        let watchText = finalText
        if let element = watchElement, !isTerminal, config.autoPaste {
            await MainActor.run {
                CorrectionWatcher.shared.start(element: element, insertedText: watchText)
            }
        }

        // Log telemetry
        let entry = TelemetryEntry(
            timestamp: TelemetryLogger.isoTimestamp(),
            sttEngine: config.activeSTTEngine.rawValue,
            sttProfile: config.sttProfile.rawValue,
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
            metalEnabled: sttResult.sttBreakdown?.metalEnabled ?? false,
            sttModel: sttResult.modelUsed
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
