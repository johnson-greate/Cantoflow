import Foundation

/// Computes CantoFlow's on-disk footprint (app bundle + Whisper + local ASR
/// models/runtime) and the current process memory, for the "運行資訊" menu item
/// shown to students. Excludes the optional local LLM (Ollama).
struct RunningInfo {
    let appBytes: UInt64
    let whisperBytes: UInt64
    let localASRBytes: UInt64
    let memoryBytes: UInt64

    var diskTotalBytes: UInt64 { appBytes + whisperBytes + localASRBytes }

    /// Collect footprint. Filesystem walks can be slow (the local-ASR venv has
    /// many small files), so call this off the main thread.
    static func collect(config: AppConfig) -> RunningInfo {
        let app = directorySize(Bundle.main.bundleURL)

        // Count only the active Whisper model + binary, not the whole models
        // directory (a dev checkout may hold many models the user never uses).
        let whisper = fileAllocatedSize(config.resolveModelPath()) + fileAllocatedSize(config.whisperCLI)

        let localASR = directorySize(ASRRuntimePaths().root)

        return RunningInfo(
            appBytes: app,
            whisperBytes: whisper,
            localASRBytes: localASR,
            memoryBytes: currentMemoryBytes()
        )
    }

    /// Human-readable multi-line summary for the alert.
    func summary() -> String {
        var lines = ["📦 應用程式：\(Self.format(appBytes))"]
        if whisperBytes > 0 {
            lines.append("🎙️ Whisper（程式＋模型）：\(Self.format(whisperBytes))")
        }
        if localASRBytes > 0 {
            lines.append("🧠 本機 ASR（模型＋環境）：\(Self.format(localASRBytes))")
        }
        lines.append("────────────")
        lines.append("💾 SSD 總用量：≈ \(Self.format(diskTotalBytes))")
        lines.append("🧮 記憶體（目前）：\(Self.format(memoryBytes))")
        lines.append("")
        lines.append("＊不含選用的本機 LLM（Ollama）")
        return lines.joined(separator: "\n")
    }

    // MARK: - Helpers

    static func format(_ bytes: UInt64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(bytes))
    }

    private static func directorySize(_ url: URL) -> UInt64 {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { return 0 }
        if !isDir.boolValue { return fileAllocatedSize(url) }

        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey]
        guard let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: keys) else { return 0 }
        var total: UInt64 = 0
        for case let file as URL in enumerator {
            total += fileAllocatedSize(file)
        }
        return total
    }

    private static func fileAllocatedSize(_ url: URL) -> UInt64 {
        let values = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey])
        return UInt64(values?.totalFileAllocatedSize ?? values?.fileAllocatedSize ?? 0)
    }

    /// Current process resident memory (phys_footprint), matching what Activity
    /// Monitor reports under "Memory".
    private static func currentMemoryBytes() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? UInt64(info.phys_footprint) : 0
    }
}
