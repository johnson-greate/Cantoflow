import Foundation

final class LaunchAtLoginManager {
    static let shared = LaunchAtLoginManager()

    private let label = "com.cantoflow.launchagent"
    private let legacyLabel = "com.cantoflow.c.launchagent"

    private init() {}

    var isEnabled: Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: launchAgentURL.path) || fm.fileExists(atPath: legacyLaunchAgentURL.path)
    }

    func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try installLaunchAgent(reload: true)
        } else {
            try uninstallLaunchAgent()
        }
    }

    func reconcileInstalledFilesIfNeeded() {
        guard isEnabled else { return }
        do {
            try installLaunchAgent(reload: false)
        } catch {
            RuntimeHealthMonitor.shared.record(
                "launchagent-reconcile-failed",
                details: ["error=\(error.localizedDescription)"]
            )
        }
    }

    private var homeURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
    }

    private var appSupportURL: URL {
        homeURL.appendingPathComponent("Library/Application Support/CantoFlow", isDirectory: true)
    }

    private var launchAgentURL: URL {
        homeURL
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
            .appendingPathComponent("\(label).plist")
    }

    private var legacyLaunchAgentURL: URL {
        homeURL
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
            .appendingPathComponent("\(legacyLabel).plist")
    }

    private var wrapperURL: URL {
        appSupportURL.appendingPathComponent("launchd-wrapper.sh")
    }

    private var launchdLogURL: URL {
        homeURL.appendingPathComponent("Library/Logs/CantoFlow.launchd.log")
    }

    private func installLaunchAgent(reload: Bool) throws {
        try FileManager.default.createDirectory(at: launchAgentURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: appSupportURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: launchdLogURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try cleanupLegacyLaunchAgent()

        let config = AppConfig.fromArgs()
        let wrapperContent = makeWrapperScript(projectRoot: config.projectRoot.path)
        try writeFileIfNeeded(to: wrapperURL, content: wrapperContent, executable: true)

        let plist = makeLaunchAgentPlist()
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try writeDataIfNeeded(to: launchAgentURL, data: data)

        RuntimeHealthMonitor.shared.record(
            reload ? "launchagent-install" : "launchagent-reconcile",
            details: [
                "program=\(wrapperURL.path)",
                "working_dir=\(appSupportURL.path)",
                "keepalive=successful-exit-false",
                "project_root=\(config.projectRoot.path)"
            ]
        )

        guard reload else { return }
        try runLaunchCtl(arguments: ["bootout", "gui/\(getuid())", launchAgentURL.path], allowFailure: true)
        try runLaunchCtl(arguments: ["bootstrap", "gui/\(getuid())", launchAgentURL.path], allowFailure: false)
    }

    private func uninstallLaunchAgent() throws {
        try runLaunchCtl(arguments: ["bootout", "gui/\(getuid())", launchAgentURL.path], allowFailure: true)
        if FileManager.default.fileExists(atPath: launchAgentURL.path) {
            try FileManager.default.removeItem(at: launchAgentURL)
        }
        if FileManager.default.fileExists(atPath: wrapperURL.path) {
            try FileManager.default.removeItem(at: wrapperURL)
        }
        try cleanupLegacyLaunchAgent()
        RuntimeHealthMonitor.shared.record("launchagent-uninstall", details: ["label=\(label)"])
    }

    private func makeLaunchAgentPlist() -> [String: Any] {
        [
            "Label": label,
            "ProgramArguments": [wrapperURL.path],
            "RunAtLoad": true,
            "KeepAlive": ["SuccessfulExit": false],
            "WorkingDirectory": appSupportURL.path,
            "StandardOutPath": launchdLogURL.path,
            "StandardErrorPath": launchdLogURL.path,
            "ProcessType": "Interactive"
        ]
    }

    private func makeWrapperScript(projectRoot: String) -> String {
        let home = homeURL.path
        let appBinary = "/Applications/CantoFlow.app/Contents/MacOS/cantoflow"
        return """
        #!/bin/bash
        set -euo pipefail

        timestamp() {
          /bin/date -u +"%Y-%m-%dT%H:%M:%SZ"
        }

        export HOME="\(home)"
        export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

        if [[ -f "${HOME}/.cantoflow.env" ]]; then
          set -o allexport
          source "${HOME}/.cantoflow.env"
          set +o allexport
        fi

        APP_BINARY="\(appBinary)"
        PROJECT_ROOT="\(projectRoot)"

        if [[ ! -x "${APP_BINARY}" ]]; then
          echo "[$(timestamp)] launchd-wrapper error | missing app binary at ${APP_BINARY}"
          exit 111
        fi

        echo "[$(timestamp)] launchd-wrapper start | pid=$$ | app_binary=${APP_BINARY} | project_root=${PROJECT_ROOT}"
        exec "${APP_BINARY}" \\
          --project-root "${PROJECT_ROOT}" \\
          --stt-profile fast \\
          --auto-replace
        """
    }

    private func writeFileIfNeeded(to url: URL, content: String, executable: Bool) throws {
        let data = Data(content.utf8)
        try writeDataIfNeeded(to: url, data: data)
        if executable {
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
    }

    private func writeDataIfNeeded(to url: URL, data: Data) throws {
        if let existing = try? Data(contentsOf: url), existing == data {
            return
        }
        try data.write(to: url, options: .atomic)
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

    private func cleanupLegacyLaunchAgent() throws {
        try runLaunchCtl(arguments: ["bootout", "gui/\(getuid())", legacyLaunchAgentURL.path], allowFailure: true)
        if FileManager.default.fileExists(atPath: legacyLaunchAgentURL.path) {
            try FileManager.default.removeItem(at: legacyLaunchAgentURL)
        }
    }
}
