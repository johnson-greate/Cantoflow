import Foundation

final class LaunchAtLoginManager {
    static let shared = LaunchAtLoginManager()

    private let label = "com.cantoflow.c.launchagent"

    private init() {}

    var isEnabled: Bool {
        FileManager.default.fileExists(atPath: launchAgentURL.path)
    }

    func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try installLaunchAgent()
        } else {
            try uninstallLaunchAgent()
        }
    }

    private var launchAgentURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
            .appendingPathComponent("\(label).plist")
    }

    private func installLaunchAgent() throws {
        let agentDir = launchAgentURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: agentDir, withIntermediateDirectories: true)

        let runScriptURL = try resolveRunScriptURL()
        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": ["/bin/bash", runScriptURL.path],
            "RunAtLoad": true,
            "KeepAlive": false,
            "WorkingDirectory": runScriptURL.deletingLastPathComponent().deletingLastPathComponent().path,
            "StandardOutPath": FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/CantoFlow.launchd.log").path,
            "StandardErrorPath": FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/CantoFlow.launchd.log").path
        ]

        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: launchAgentURL, options: .atomic)

        try runLaunchCtl(arguments: ["bootout", "gui/\(getuid())", launchAgentURL.path], allowFailure: true)
        try runLaunchCtl(arguments: ["bootstrap", "gui/\(getuid())", launchAgentURL.path], allowFailure: false)
    }

    private func uninstallLaunchAgent() throws {
        try runLaunchCtl(arguments: ["bootout", "gui/\(getuid())", launchAgentURL.path], allowFailure: true)
        if FileManager.default.fileExists(atPath: launchAgentURL.path) {
            try FileManager.default.removeItem(at: launchAgentURL)
        }
    }

    private func resolveRunScriptURL() throws -> URL {
        let executableURL = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
        let appDir = executableURL
            .deletingLastPathComponent()   // release
            .deletingLastPathComponent()   // .build
            .deletingLastPathComponent()   // CantoFlow_c
        let scriptURL = appDir.appendingPathComponent("scripts/run.sh")

        guard FileManager.default.isExecutableFile(atPath: scriptURL.path) else {
            throw NSError(
                domain: "LaunchAtLoginManager",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "run.sh not found at \(scriptURL.path)"]
            )
        }
        return scriptURL
    }

    private func runLaunchCtl(arguments: [String], allowFailure: Bool) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments

        let pipe = Pipe()
        process.standardError = pipe
        process.standardOutput = pipe

        try process.run()
        process.waitUntilExit()

        if process.terminationStatus != 0 && !allowFailure {
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            throw NSError(
                domain: "LaunchAtLoginManager",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: output?.isEmpty == false ? output! : "launchctl failed"]
            )
        }
    }
}
