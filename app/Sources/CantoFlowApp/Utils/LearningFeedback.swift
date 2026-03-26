import Foundation

extension Notification.Name {
    static let cantoFlowLearningStatusDidChange = Notification.Name("CantoFlowLearningStatusDidChange")
}

final class LearningFeedback {
    static let shared = LearningFeedback()

    private let queue = DispatchQueue(label: "com.cantoflow.learning-feedback", qos: .utility)

    private init() {}

    private var logFileURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let cantoFlow = appSupport.appendingPathComponent("CantoFlow", isDirectory: true)
        try? FileManager.default.createDirectory(at: cantoFlow, withIntermediateDirectories: true)
        return cantoFlow.appendingPathComponent("learning.log")
    }

    func record(_ summary: String, detail: String? = nil) {
        let timestamp = TelemetryLogger.isoTimestamp()
        let line = if let detail, !detail.isEmpty {
            "[\(timestamp)] \(summary) | \(detail)\n"
        } else {
            "[\(timestamp)] \(summary)\n"
        }

        queue.async { [weak self] in
            self?.append(line)
        }

        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: .cantoFlowLearningStatusDidChange,
                object: nil,
                userInfo: ["summary": summary]
            )
        }
    }

    private func append(_ line: String) {
        guard let data = line.data(using: .utf8) else { return }
        let fileURL = logFileURL
        let fm = FileManager.default

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
}
