import Foundation

/// Centralized v1 guardrails / canonical-audio constants for file transcription.
/// Kept in one place so they can be tuned after real-world testing (PRD §6, §15).
enum TranscribeLimits {
    /// Input container formats accepted in v1 (audio-only). Lowercased extensions.
    static let supportedExtensions: Set<String> = ["wav", "mp3", "m4a"]

    /// Max files queued in a single batch.
    static let maxFilesPerBatch = 20

    /// Reject anything longer than 120 minutes in v1.
    static let maxDurationSeconds: Double = 120 * 60

    /// Reject anything larger than 2 GB in v1.
    static let maxFileSizeBytes: Int64 = 2 * 1024 * 1024 * 1024

    /// Canonical WAV: 16 kHz, mono, 16-bit → 32,000 bytes/sec.
    static let canonicalSampleRate: Double = 16_000
    static let canonicalBytesPerSecond: Double = 32_000

    /// Temp-WAV space estimate with 20% headroom (FR-015).
    static func estimatedTempBytes(forAudioSeconds seconds: Double) -> Int64 {
        Int64((seconds * canonicalBytesPerSecond * 1.2).rounded(.up))
    }

    /// Leftover temp directories older than this are purged on launch (FR-014).
    static let tempRetentionSeconds: TimeInterval = 24 * 60 * 60
}

/// Why a candidate file was rejected at intake (FR-004/005). Pure value type so
/// the validation rules can be unit-tested without touching the filesystem.
enum FileIntakeRejection: Equatable {
    case unsupportedType(ext: String)
    case notARegularFile
    case empty
    case tooLarge(bytes: Int64)
    case tooLong(seconds: Double)
    case duplicate

    /// Human-readable, Traditional-Chinese reason for the UI (PRD §18).
    var message: String {
        switch self {
        case .unsupportedType:
            return "暫時只支援 WAV、MP3、M4A"
        case .notARegularFile:
            return "請選擇音頻檔案，不支援資料夾或捷徑"
        case .empty:
            return "檔案是空的，無法轉錄"
        case .tooLarge:
            return "檔案超過 2 GB 上限"
        case .tooLong:
            return "錄音超過 120 分鐘上限"
        case .duplicate:
            return "已在佇列中"
        }
    }
}

/// Per-file lifecycle state (PRD §13 / §8.3).
enum FileTranscriptionStatus: Equatable {
    case queued
    case validating
    case preparing(progress: Double)
    case transcribing(progress: Double, chunk: Int, totalChunks: Int)
    case transcriptReady
    case generatingNotes
    case complete
    case completedWithWarning(String)
    case failed(String)
    case cancelled

    /// Stable kind label used for transition rules, persistence and tests —
    /// independent of associated progress/message payloads.
    var kind: String {
        switch self {
        case .queued: return "queued"
        case .validating: return "validating"
        case .preparing: return "preparing"
        case .transcribing: return "transcribing"
        case .transcriptReady: return "transcriptReady"
        case .generatingNotes: return "generatingNotes"
        case .complete: return "complete"
        case .completedWithWarning: return "completedWithWarning"
        case .failed: return "failed"
        case .cancelled: return "cancelled"
        }
    }

    /// Traditional-Chinese status label for the queue (PRD §8.3).
    var displayText: String {
        switch self {
        case .queued: return "等候中"
        case .validating: return "檢查檔案…"
        case .preparing(let p): return "準備音訊… \(Int(p * 100))%"
        case .transcribing(_, let chunk, let total):
            return total > 0 ? "正在轉錄 · Chunk \(chunk)/\(total)" : "正在轉錄…"
        case .transcriptReady: return "逐字稿已完成"
        case .generatingNotes: return "正在生成會議記錄…"
        case .complete: return "會議記錄已完成"
        case .completedWithWarning: return "已完成，但部分內容可能不完整"
        case .failed(let reason): return "失敗：\(reason)"
        case .cancelled: return "已停止"
        }
    }

    /// A transcript exists and can be copied / exported / turned into notes.
    var hasTranscript: Bool {
        switch self {
        case .transcriptReady, .generatingNotes, .complete, .completedWithWarning:
            return true
        default:
            return false
        }
    }

    /// Whether a state machine edge is allowed. Keeps the queue from showing
    /// impossible transitions (e.g. a completed file going back to transcribing).
    static func isLegalTransition(from: FileTranscriptionStatus, to: FileTranscriptionStatus) -> Bool {
        if from.kind == to.kind { return true } // progress updates within a state
        switch (from.kind, to.kind) {
        case ("queued", "validating"),
             ("queued", "failed"),
             ("queued", "cancelled"),
             ("validating", "preparing"),
             ("validating", "failed"),
             ("validating", "cancelled"),
             ("preparing", "transcribing"),
             ("preparing", "failed"),
             ("preparing", "cancelled"),
             ("transcribing", "transcriptReady"),
             ("transcribing", "completedWithWarning"),
             ("transcribing", "failed"),
             ("transcribing", "cancelled"),
             ("transcriptReady", "generatingNotes"),
             ("completedWithWarning", "generatingNotes"),
             ("generatingNotes", "complete"),
             ("generatingNotes", "transcriptReady"),       // notes failed → back to ready
             ("generatingNotes", "completedWithWarning"),
             ("complete", "generatingNotes"),               // regenerate notes
             ("failed", "queued"),                          // retry
             ("cancelled", "queued"):                       // retry
            return true
        default:
            return false
        }
    }
}

struct FileTranscriptionItem: Identifiable, Equatable {
    let id: UUID
    let sourceURL: URL
    let displayName: String
    let fileSizeBytes: Int64
    let durationSeconds: Double
    var status: FileTranscriptionStatus
    var transcriptURL: URL?
    var meetingNotesURL: URL?
    var language: String?
    var truncated: Bool = false
    var createdAt: Date

    init(
        id: UUID = UUID(),
        sourceURL: URL,
        fileSizeBytes: Int64,
        durationSeconds: Double,
        status: FileTranscriptionStatus = .queued,
        createdAt: Date
    ) {
        self.id = id
        self.sourceURL = sourceURL
        self.displayName = sourceURL.lastPathComponent
        self.fileSizeBytes = fileSizeBytes
        self.durationSeconds = durationSeconds
        self.status = status
        self.createdAt = createdAt
    }
}

/// Pure intake validation — no filesystem access, so it is fully unit-testable.
/// Callers gather `ext`, `sizeBytes`, `durationSeconds`, `isRegularFile` and the
/// set of already-queued source URLs, then ask here for a rejection (or nil).
enum FileIntakeValidator {
    static func isSupportedExtension(_ ext: String) -> Bool {
        TranscribeLimits.supportedExtensions.contains(ext.lowercased())
    }

    static func rejection(
        ext: String,
        isRegularFile: Bool,
        sizeBytes: Int64,
        durationSeconds: Double,
        url: URL,
        alreadyQueued: Set<URL>
    ) -> FileIntakeRejection? {
        if alreadyQueued.contains(url.standardizedFileURL) { return .duplicate }
        guard isRegularFile else { return .notARegularFile }
        guard isSupportedExtension(ext) else { return .unsupportedType(ext: ext.lowercased()) }
        guard sizeBytes > 0 else { return .empty }
        guard sizeBytes <= TranscribeLimits.maxFileSizeBytes else { return .tooLarge(bytes: sizeBytes) }
        guard durationSeconds <= TranscribeLimits.maxDurationSeconds else { return .tooLong(seconds: durationSeconds) }
        return nil
    }
}

/// Batch-wide weighted progress (PRD §8.5). Pure + monotonic-friendly.
enum BatchProgress {
    /// (sum completed file seconds + current file seconds × current progress) ÷ total seconds.
    static func overall(
        completedDurations: [Double],
        currentDuration: Double,
        currentProgress: Double,
        totalDuration: Double
    ) -> Double {
        guard totalDuration > 0 else { return 0 }
        let done = completedDurations.reduce(0, +)
        let current = currentDuration * min(max(currentProgress, 0), 1)
        return min(max((done + current) / totalDuration, 0), 1)
    }
}
