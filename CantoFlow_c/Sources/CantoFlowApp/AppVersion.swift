import Foundation

/// Dynamic build stamp derived from the executable's modification timestamp.
///
/// Format: yyyyMMdd.HHmm  e.g. "20260223.2230"
///
/// Regenerates automatically on every `swift build` — no manual version bump needed.
/// CommandLine.arguments[0] is the path of the running binary, whose mtime is set
/// by the linker at the end of each compilation.
let appBuildVersion: String = {
    let rawPath = CommandLine.arguments[0]
    let path = URL(fileURLWithPath: rawPath).standardized.path
    guard
        let attrs = try? FileManager.default.attributesOfItem(atPath: path),
        let modDate = attrs[.modificationDate] as? Date
    else { return "dev" }

    let fmt = DateFormatter()
    fmt.locale = Locale(identifier: "en_US_POSIX")
    fmt.dateFormat = "yyyyMMdd.HHmm"
    return fmt.string(from: modDate)
}()

// Backward-compatible aliases used in SettingsView's About section.
var appShortVersion: String { appBuildVersion }
var appBuildNumber:  String { "" }
