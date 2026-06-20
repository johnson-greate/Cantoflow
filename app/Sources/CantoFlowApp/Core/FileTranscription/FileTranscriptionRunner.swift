import Foundation

/// Typed worker event (docs/transcribe/spec.md §15.2).
enum WorkerEvent: Equatable {
    case workerReady(totalFiles: Int)
    case fileStarted(fileID: String, index: Int, total: Int)
    case asrProgress(fileID: String, progress: Double, chunkIndex: Int, totalChunks: Int,
                     processedAudioSec: Double, audioDurationSec: Double)
    case fileCompleted(fileID: String, outputTxt: String, chars: Int, language: String,
                       truncated: Bool, durationMs: Int)
    case fileFailed(fileID: String, code: String, message: String)
    case batchCompleted(succeeded: Int, failed: Int, durationMs: Int)
}

/// Pure JSONL line → WorkerEvent. Returns nil for blank, malformed, or
/// unknown/unsupported lines (caller logs and ignores — never crash the UI).
enum WorkerEventParser {
    static func parse(_ line: String) -> WorkerEvent? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let data = trimmed.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let event = obj["event"] as? String else {
            return nil
        }

        func int(_ key: String) -> Int { (obj[key] as? NSNumber)?.intValue ?? 0 }
        func double(_ key: String) -> Double { (obj[key] as? NSNumber)?.doubleValue ?? 0 }
        func str(_ key: String) -> String { obj[key] as? String ?? "" }
        func bool(_ key: String) -> Bool { (obj[key] as? NSNumber)?.boolValue ?? (obj[key] as? Bool ?? false) }

        switch event {
        case "worker_ready":
            return .workerReady(totalFiles: int("total_files"))
        case "file_started":
            return .fileStarted(fileID: str("file_id"), index: int("file_index"), total: int("total_files"))
        case "asr_progress":
            return .asrProgress(
                fileID: str("file_id"),
                progress: double("progress"),
                chunkIndex: int("chunk_index"),
                totalChunks: int("total_chunks"),
                processedAudioSec: double("processed_audio_sec"),
                audioDurationSec: double("audio_duration_sec")
            )
        case "file_completed":
            return .fileCompleted(
                fileID: str("file_id"), outputTxt: str("output_txt"), chars: int("chars"),
                language: str("language"), truncated: bool("truncated"), durationMs: int("duration_ms")
            )
        case "file_failed":
            return .fileFailed(fileID: str("file_id"), code: str("code"), message: str("message"))
        case "batch_completed":
            return .batchCompleted(succeeded: int("succeeded"), failed: int("failed"), durationMs: int("duration_ms"))
        default:
            return nil // unknown event — ignore
        }
    }
}

/// Buffers raw stdout bytes and emits complete lines under a lock so the
/// readability handler and the final termination drain never race.
private final class StdoutLineReader {
    private let onLine: (String) -> Void
    private var buffer = Data()
    private let lock = NSLock()

    init(onLine: @escaping (String) -> Void) { self.onLine = onLine }

    func feed(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let lineData = buffer.subdata(in: buffer.startIndex..<newline)
            buffer.removeSubrange(buffer.startIndex...newline)
            if let line = String(data: lineData, encoding: .utf8) { onLine(line) }
        }
    }

    func flush() {
        lock.lock(); defer { lock.unlock() }
        if !buffer.isEmpty, let line = String(data: buffer, encoding: .utf8) { onLine(line) }
        buffer.removeAll()
    }
}

/// Launches the Python batch worker and streams its JSONL events live.
/// All process I/O happens off the main thread; `onEvent` is invoked off-main —
/// callers hop to MainActor for UI. Cancellation terminates the worker.
final class FileTranscriptionRunner {
    struct Config {
        let pythonURL: URL
        let workerScriptURL: URL
        let manifestURL: URL
        let modelDirURL: URL
        let outputDirURL: URL
        let traditional: Bool
    }

    enum RunnerError: Error, LocalizedError {
        case launchFailed(String)
        var errorDescription: String? {
            switch self {
            case .launchFailed(let detail): return "無法啟動本機轉錄引擎：\(detail)"
            }
        }
    }

    private let lock = NSLock()
    private var process: Process?
    private var stderrTail = ""

    private func storeProcess(_ proc: Process?) {
        lock.lock(); process = proc; lock.unlock()
    }

    private func appendStderr(_ text: String) {
        lock.lock(); stderrTail = String((stderrTail + text).suffix(4000)); lock.unlock()
    }

    /// Run the worker to completion. Returns the process exit code.
    func run(_ config: Config, onEvent: @escaping (WorkerEvent) -> Void) async throws -> Int32 {
        let process = Process()
        process.executableURL = config.pythonURL
        var args = [
            config.workerScriptURL.path,
            "--manifest", config.manifestURL.path,
            "--model-dir", config.modelDirURL.path,
            "--output-dir", config.outputDirURL.path
        ]
        if config.traditional { args.append("--traditional") }
        process.arguments = args

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let reader = StdoutLineReader { line in
            if let event = WorkerEventParser.parse(line) { onEvent(event) }
        }
        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            reader.feed(handle.availableData)
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty, let self else { return }
            if let text = String(data: chunk, encoding: .utf8) { self.appendStderr(text) }
        }

        storeProcess(process)

        do {
            try process.run()
        } catch {
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            storeProcess(nil)
            throw RunnerError.launchFailed(error.localizedDescription)
        }

        let code: Int32 = await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Int32, Never>) in
                process.terminationHandler = { proc in
                    stdoutPipe.fileHandleForReading.readabilityHandler = nil
                    stderrPipe.fileHandleForReading.readabilityHandler = nil
                    reader.feed(stdoutPipe.fileHandleForReading.availableData)
                    reader.flush()
                    continuation.resume(returning: proc.terminationStatus)
                }
            }
        } onCancel: {
            self.cancel()
        }

        storeProcess(nil)
        return code
    }

    /// Terminate the worker (user "stop" and Task cancellation).
    func cancel() {
        lock.lock(); let proc = process; lock.unlock()
        proc?.terminate()
    }

    /// Last stderr output, for runtime-log diagnostics on failure.
    var diagnostics: String {
        lock.lock(); defer { lock.unlock() }
        return stderrTail
    }
}
