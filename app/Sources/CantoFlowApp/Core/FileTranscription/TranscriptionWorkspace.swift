import Foundation

/// On-disk workspace for file transcription (PRD §14).
///
/// ~/Library/Application Support/CantoFlow/Transcriptions/<batch-uuid>/
/// ├── manifest.json
/// ├── temp/<file-uuid>.wav
/// ├── transcripts/<source-basename>-transcript.txt
/// └── notes/<source-basename>-meeting-notes.md
struct TranscriptionWorkspace {
    let root: URL

    init(root: URL = TranscriptionWorkspace.defaultRoot) {
        self.root = root
    }

    static var defaultRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/CantoFlow/Transcriptions", isDirectory: true)
    }

    // MARK: - Paths

    func batchDirectory(_ batchID: UUID) -> URL {
        root.appendingPathComponent(batchID.uuidString, isDirectory: true)
    }

    func tempDirectory(_ batchID: UUID) -> URL {
        batchDirectory(batchID).appendingPathComponent("temp", isDirectory: true)
    }

    func transcriptsDirectory(_ batchID: UUID) -> URL {
        batchDirectory(batchID).appendingPathComponent("transcripts", isDirectory: true)
    }

    func notesDirectory(_ batchID: UUID) -> URL {
        batchDirectory(batchID).appendingPathComponent("notes", isDirectory: true)
    }

    func manifestURL(_ batchID: UUID) -> URL {
        batchDirectory(batchID).appendingPathComponent("manifest.json")
    }

    func tempWAVURL(batchID: UUID, fileID: UUID) -> URL {
        tempDirectory(batchID).appendingPathComponent("\(fileID.uuidString).wav")
    }

    /// Create the directory tree for a batch.
    @discardableResult
    func prepareBatchDirectories(_ batchID: UUID) throws -> URL {
        let fm = FileManager.default
        for dir in [tempDirectory(batchID), transcriptsDirectory(batchID), notesDirectory(batchID)] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return batchDirectory(batchID)
    }

    // MARK: - Atomic writes (FR-028 / FR-054 / FR-069)

    func atomicWrite(_ text: String, to url: URL) throws {
        try Data(text.utf8).write(to: url, options: .atomic)
    }

    // MARK: - Collision-safe export filenames (FR-052 / FR-067)

    /// Pure: returns "base.ext", else "base-1.ext", "base-2.ext", … until `exists`
    /// returns false. Injectable predicate keeps it unit-testable.
    static func uniqueFilename(base: String, ext: String, exists: (String) -> Bool) -> String {
        let first = "\(base).\(ext)"
        if !exists(first) { return first }
        var n = 1
        while true {
            let candidate = "\(base)-\(n).\(ext)"
            if !exists(candidate) { return candidate }
            n += 1
        }
    }

    /// Default transcript filename for a source (FR-052).
    static func transcriptBasename(forSource sourceURL: URL) -> String {
        sourceURL.deletingPathExtension().lastPathComponent + "-transcript"
    }

    /// Default meeting-notes filename for a source (FR-067).
    static func notesBasename(forSource sourceURL: URL) -> String {
        sourceURL.deletingPathExtension().lastPathComponent + "-meeting-notes"
    }

    // MARK: - Temp cleanup

    func removeTempWAV(batchID: UUID, fileID: UUID) {
        try? FileManager.default.removeItem(at: tempWAVURL(batchID: batchID, fileID: fileID))
    }

    /// Purge leftover batch temp dirs older than the retention window (FR-014).
    /// Only touches `temp/` contents — never transcripts or notes.
    func purgeStaleTemp(now: Date = Date()) {
        let fm = FileManager.default
        guard let batches = try? fm.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        for batchDir in batches {
            let temp = batchDir.appendingPathComponent("temp", isDirectory: true)
            guard let entries = try? fm.contentsOfDirectory(
                at: temp,
                includingPropertiesForKeys: [.contentModificationDateKey]
            ) else { continue }
            for entry in entries {
                let modified = (try? entry.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                if let modified, now.timeIntervalSince(modified) > TranscribeLimits.tempRetentionSeconds {
                    try? fm.removeItem(at: entry)
                }
            }
        }
    }
}
