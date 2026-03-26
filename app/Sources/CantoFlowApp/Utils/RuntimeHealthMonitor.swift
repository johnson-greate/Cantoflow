import Foundation

struct RuntimeLaunchSummary {
    let launchesToday: Int
    let restartsToday: Int
    let previousExitWasUnexpected: Bool
    let previousExitSummary: String
}

final class RuntimeHealthMonitor {
    static let shared = RuntimeHealthMonitor()

    private struct SessionState: Codable {
        let pid: Int32
        let startedAt: String
        let buildVersion: String
        var gracefulTermination: Bool
        var terminationReason: String?
    }

    private struct DailyStats: Codable {
        var launchesByDay: [String: Int] = [:]
    }

    private let queue = DispatchQueue(label: "com.cantoflow.runtime-health", qos: .utility)

    private init() {}

    private var appSupportDir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("CantoFlow", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private var sessionStateURL: URL { appSupportDir.appendingPathComponent("runtime_session.json") }
    private var statsURL: URL { appSupportDir.appendingPathComponent("runtime_stats.json") }
    private var logURL: URL { appSupportDir.appendingPathComponent("runtime_health.log") }
    private var launchdLogURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/CantoFlow.launchd.log")
    }
    private var diagnosticReportsDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/DiagnosticReports", isDirectory: true)
    }

    func startup(buildVersion: String) -> RuntimeLaunchSummary {
        let now = Date()
        let previous = loadSessionState()
        let previousExitWasUnexpected = previous.map { !$0.gracefulTermination } ?? false

        let stats = incrementLaunchCount(for: now)
        let clues = previousExitWasUnexpected ? collectCrashClues(sinceISO8601: previous?.startedAt) : []
        let previousExitSummary = summarizePreviousExit(previous: previous, clues: clues)

        let state = SessionState(
            pid: ProcessInfo.processInfo.processIdentifier,
            startedAt: TelemetryLogger.isoTimestamp(),
            buildVersion: buildVersion,
            gracefulTermination: false,
            terminationReason: nil
        )
        saveSessionState(state)

        let summary = RuntimeLaunchSummary(
            launchesToday: stats.launchesToday,
            restartsToday: max(0, stats.launchesToday - 1),
            previousExitWasUnexpected: previousExitWasUnexpected,
            previousExitSummary: previousExitSummary
        )

        log("startup", details: [
            "pid=\(state.pid)",
            "build=\(buildVersion)",
            "launches_today=\(summary.launchesToday)",
            "restarts_today=\(summary.restartsToday)",
            "previous_exit=\(summary.previousExitSummary)"
        ])

        if !clues.isEmpty {
            for clue in clues {
                log("crash-clue", details: [clue])
            }
        }

        return summary
    }

    func markGracefulTermination(reason: String) {
        guard var state = loadSessionState() else { return }
        if state.gracefulTermination, state.terminationReason?.isEmpty == false {
            return
        }
        state.gracefulTermination = true
        state.terminationReason = reason
        saveSessionState(state)
        log("shutdown", details: ["pid=\(state.pid)", "reason=\(reason)"])
    }

    func runtimeLogURL() -> URL { logURL }

    func record(_ event: String, details: [String]) {
        log(event, details: details)
    }

    private func incrementLaunchCount(for date: Date) -> RuntimeLaunchSummary {
        var stats = loadStats()
        let day = dayKey(for: date)
        stats.launchesByDay[day, default: 0] += 1
        saveStats(stats)
        let launches = stats.launchesByDay[day, default: 0]
        return RuntimeLaunchSummary(
            launchesToday: launches,
            restartsToday: max(0, launches - 1),
            previousExitWasUnexpected: false,
            previousExitSummary: "unknown"
        )
    }

    private func summarizePreviousExit(previous: SessionState?, clues: [String]) -> String {
        guard let previous else { return "first launch" }
        if previous.gracefulTermination {
            return "graceful (\(previous.terminationReason ?? "normal"))"
        }
        if let firstClue = clues.first {
            return "unexpected; \(firstClue)"
        }
        return "unexpected; no direct clue"
    }

    private func collectCrashClues(sinceISO8601 startedAt: String?) -> [String] {
        var clues: [String] = []
        let fm = FileManager.default
        let sinceDate = startedAt.flatMap(Self.parseISO8601) ?? Date().addingTimeInterval(-86400)
        let threshold = sinceDate.addingTimeInterval(-300)

        if let files = try? fm.contentsOfDirectory(
            at: diagnosticReportsDir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) {
            let reportNames = ["cantoflow", "whisper-cli"]
            let matched = files
                .filter { url in
                    let name = url.lastPathComponent.lowercased()
                    return reportNames.contains { name.hasPrefix($0) }
                }
                .filter { url in
                    let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                    return modified >= threshold
                }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }

            if !matched.isEmpty {
                clues.append("diagnostic reports: " + matched.map(\.lastPathComponent).joined(separator: ", "))
            }
        }

        if let launchdTail = readLastLines(from: launchdLogURL, maxLines: 8), !launchdTail.isEmpty {
            let compact = launchdTail.joined(separator: " | ")
            clues.append("launchd tail: \(compact)")
        }

        return clues
    }

    private func loadSessionState() -> SessionState? {
        guard let data = try? Data(contentsOf: sessionStateURL) else { return nil }
        return try? JSONDecoder().decode(SessionState.self, from: data)
    }

    private func saveSessionState(_ state: SessionState) {
        if let data = try? JSONEncoder().encode(state) {
            try? data.write(to: sessionStateURL, options: .atomic)
        }
    }

    private func loadStats() -> DailyStats {
        guard let data = try? Data(contentsOf: statsURL),
              let stats = try? JSONDecoder().decode(DailyStats.self, from: data) else {
            return DailyStats()
        }
        return stats
    }

    private func saveStats(_ stats: DailyStats) {
        if let data = try? JSONEncoder().encode(stats) {
            try? data.write(to: statsURL, options: .atomic)
        }
    }

    private func log(_ event: String, details: [String]) {
        let line = "[\(TelemetryLogger.isoTimestamp())] \(event) | " + details.joined(separator: " | ") + "\n"
        queue.async { [weak self] in
            self?.append(line)
        }
    }

    private func append(_ line: String) {
        guard let data = line.data(using: .utf8) else { return }
        let fm = FileManager.default
        if fm.fileExists(atPath: logURL.path) {
            if let handle = try? FileHandle(forWritingTo: logURL) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            }
        } else {
            try? data.write(to: logURL, options: .atomic)
        }
    }

    private func readLastLines(from url: URL, maxLines: Int) -> [String]? {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let lines = content
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .suffix(maxLines)
        return Array(lines)
    }

    private func dayKey(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private static func parseISO8601(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }
}
