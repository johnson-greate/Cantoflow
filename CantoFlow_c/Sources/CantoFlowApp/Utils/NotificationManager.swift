import Foundation

/// Notification manager using osascript for system notifications
final class NotificationManager {
    static let shared = NotificationManager()

    private init() {}

    /// Show a system notification
    /// - Parameters:
    ///   - message: Notification message
    ///   - title: Notification title (default: "CantoFlow_c")
    func notify(_ message: String, title: String = "CantoFlow_c") {
        let escaped = message
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let escapedTitle = title
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")

        let script = "display notification \"\(escaped)\" with title \"\(escapedTitle)\""

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        try? process.run()
    }

    /// Show an error notification
    func notifyError(_ message: String) {
        notify("Error: \(message)")
    }

    /// Show a success notification with latency info
    func notifySuccess(recordMs: Int, sttMs: Int, polishMs: Int) {
        notify("Done. record=\(recordMs)ms stt=\(sttMs)ms polish=\(polishMs)ms")
    }
}
