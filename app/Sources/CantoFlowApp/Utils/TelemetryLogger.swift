import Foundation

/// Telemetry entry for a single STT pipeline run
struct TelemetryEntry: Encodable {
    let timestamp: String
    let sttProfile: String
    let modelPath: String
    let audioDevice: String
    let provider: String
    let polishStatus: String
    let fastIME: FastIMEStatus
    let latencyMs: LatencyMs
    let textStats: TextStats
    let artifacts: Artifacts
    let rawText: String
    let finalText: String

    struct FastIMEStatus: Encodable {
        let enabled: Bool
        let autoPaste: Bool
        let autoReplace: Bool
        let rawStatus: String
        let replaceStatus: String
    }

    struct LatencyMs: Encodable {
        let record: Int
        /// Time from stopRecording() completing to whisper-cli being launched
        let audioFlushMs: Int
        let stt: Int
        /// Breakdown of where time went inside the stt stage
        let sttBreakdown: SttBreakdown?
        let polish: Int
        let clipboard: Int
        let firstInsert: Int
        let total: Int

        /// Sub-timing within the whisper-cli execution
        struct SttBreakdown: Encodable {
            /// OS process spawn overhead (before first byte of inference)
            let launchMs: Int
            /// Actual model load + decode + inference time
            let inferenceMs: Int
            /// Reading transcription output file from disk
            let outputReadMs: Int
            /// Whether Metal GPU acceleration was active for this run
            let metalEnabled: Bool
        }
    }

    struct TextStats: Encodable {
        let rawChars: Int
        let finalChars: Int
    }

    struct Artifacts: Encodable {
        let rawFile: String
        let polishedFile: String
    }
}

/// JSONL telemetry logger
final class TelemetryLogger {
    private let fileURL: URL
    private let queue = DispatchQueue(label: "com.cantoflow.telemetry", qos: .utility)

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// Log a telemetry entry
    func log(_ entry: TelemetryEntry) {
        queue.async { [weak self] in
            self?.writeEntry(entry)
        }
    }

    /// Log a raw dictionary as JSON
    func logRaw(_ dictionary: [String: Any]) {
        queue.async { [weak self] in
            self?.writeDictionary(dictionary)
        }
    }

    private func writeEntry(_ entry: TelemetryEntry) {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase

        guard let data = try? encoder.encode(entry),
              var line = String(data: data, encoding: .utf8) else {
            return
        }

        line.append("\n\n")  // Double newline for readability
        appendToFile(line)
    }

    private func writeDictionary(_ dictionary: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: dictionary),
              var line = String(data: data, encoding: .utf8) else {
            return
        }

        line.append("\n")
        appendToFile(line)
    }

    private func appendToFile(_ line: String) {
        guard let data = line.data(using: .utf8) else { return }

        let fm = FileManager.default

        // Ensure parent directory exists
        let parentDir = fileURL.deletingLastPathComponent()
        try? fm.createDirectory(at: parentDir, withIntermediateDirectories: true)

        if fm.fileExists(atPath: fileURL.path) {
            if let handle = try? FileHandle(forWritingTo: fileURL) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            }
        } else {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    // MARK: - Utility Methods

    /// Get current ISO8601 timestamp
    static func isoTimestamp() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: Date())
    }

    /// Get timestamp for file naming
    static func fileTimestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        return formatter.string(from: Date())
    }
}
