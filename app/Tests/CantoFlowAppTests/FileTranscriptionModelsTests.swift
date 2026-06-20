import XCTest
@testable import CantoFlowApp

final class FileTranscriptionModelsTests: XCTestCase {

    // MARK: - Supported type validation (FR-001)

    func testSupportedExtensionsCaseInsensitive() {
        XCTAssertTrue(FileIntakeValidator.isSupportedExtension("wav"))
        XCTAssertTrue(FileIntakeValidator.isSupportedExtension("MP3"))
        XCTAssertTrue(FileIntakeValidator.isSupportedExtension("M4a"))
        XCTAssertFalse(FileIntakeValidator.isSupportedExtension("flac"))
        XCTAssertFalse(FileIntakeValidator.isSupportedExtension("mp4"))
        XCTAssertFalse(FileIntakeValidator.isSupportedExtension(""))
    }

    // MARK: - Intake rejection rules (FR-004)

    private func url(_ name: String) -> URL { URL(fileURLWithPath: "/tmp/\(name)") }

    func testRejectsUnsupportedType() {
        let r = FileIntakeValidator.rejection(
            ext: "flac", isRegularFile: true, sizeBytes: 1000, durationSeconds: 60,
            url: url("a.flac"), alreadyQueued: []
        )
        XCTAssertEqual(r, .unsupportedType(ext: "flac"))
    }

    func testRejectsFolder() {
        let r = FileIntakeValidator.rejection(
            ext: "wav", isRegularFile: false, sizeBytes: 1000, durationSeconds: 60,
            url: url("dir"), alreadyQueued: []
        )
        XCTAssertEqual(r, .notARegularFile)
    }

    func testRejectsEmpty() {
        let r = FileIntakeValidator.rejection(
            ext: "wav", isRegularFile: true, sizeBytes: 0, durationSeconds: 0,
            url: url("a.wav"), alreadyQueued: []
        )
        XCTAssertEqual(r, .empty)
    }

    func testRejectsTooLarge() {
        let big = TranscribeLimits.maxFileSizeBytes + 1
        let r = FileIntakeValidator.rejection(
            ext: "wav", isRegularFile: true, sizeBytes: big, durationSeconds: 60,
            url: url("a.wav"), alreadyQueued: []
        )
        XCTAssertEqual(r, .tooLarge(bytes: big))
    }

    func testRejectsTooLong() {
        let long = TranscribeLimits.maxDurationSeconds + 1
        let r = FileIntakeValidator.rejection(
            ext: "wav", isRegularFile: true, sizeBytes: 1000, durationSeconds: long,
            url: url("a.wav"), alreadyQueued: []
        )
        XCTAssertEqual(r, .tooLong(seconds: long))
    }

    func testDuplicateDetection() {
        let u = url("a.wav")
        let r = FileIntakeValidator.rejection(
            ext: "wav", isRegularFile: true, sizeBytes: 1000, durationSeconds: 60,
            url: u, alreadyQueued: [u.standardizedFileURL]
        )
        XCTAssertEqual(r, .duplicate)
    }

    func testAcceptsValidFile() {
        let r = FileIntakeValidator.rejection(
            ext: "m4a", isRegularFile: true, sizeBytes: 5_000_000, durationSeconds: 2700,
            url: url("meeting.m4a"), alreadyQueued: []
        )
        XCTAssertNil(r)
    }

    // MARK: - State transition legality

    func testLegalTransitions() {
        XCTAssertTrue(FileTranscriptionStatus.isLegalTransition(from: .queued, to: .validating))
        XCTAssertTrue(FileTranscriptionStatus.isLegalTransition(from: .preparing(progress: 0.2), to: .transcribing(progress: 0, chunk: 0, totalChunks: 10)))
        XCTAssertTrue(FileTranscriptionStatus.isLegalTransition(from: .transcribing(progress: 1, chunk: 10, totalChunks: 10), to: .transcriptReady))
        XCTAssertTrue(FileTranscriptionStatus.isLegalTransition(from: .transcriptReady, to: .generatingNotes))
        XCTAssertTrue(FileTranscriptionStatus.isLegalTransition(from: .generatingNotes, to: .complete))
        XCTAssertTrue(FileTranscriptionStatus.isLegalTransition(from: .complete, to: .generatingNotes)) // regenerate
        XCTAssertTrue(FileTranscriptionStatus.isLegalTransition(from: .failed("x"), to: .queued))       // retry
        // progress update within the same kind
        XCTAssertTrue(FileTranscriptionStatus.isLegalTransition(from: .transcribing(progress: 0.1, chunk: 1, totalChunks: 9), to: .transcribing(progress: 0.5, chunk: 5, totalChunks: 9)))
    }

    func testIllegalTransitions() {
        XCTAssertFalse(FileTranscriptionStatus.isLegalTransition(from: .complete, to: .transcribing(progress: 0, chunk: 0, totalChunks: 1)))
        XCTAssertFalse(FileTranscriptionStatus.isLegalTransition(from: .queued, to: .complete))
        XCTAssertFalse(FileTranscriptionStatus.isLegalTransition(from: .transcriptReady, to: .preparing(progress: 0)))
    }

    func testHasTranscript() {
        XCTAssertTrue(FileTranscriptionStatus.transcriptReady.hasTranscript)
        XCTAssertTrue(FileTranscriptionStatus.complete.hasTranscript)
        XCTAssertTrue(FileTranscriptionStatus.completedWithWarning("x").hasTranscript)
        XCTAssertFalse(FileTranscriptionStatus.queued.hasTranscript)
        XCTAssertFalse(FileTranscriptionStatus.failed("x").hasTranscript)
    }

    // MARK: - Weighted progress (§8.5)

    func testOverallProgressMonotonicAndBounded() {
        // batch: 60s done, currently in a 120s file at 50%, total 300s
        let p = BatchProgress.overall(completedDurations: [60], currentDuration: 120, currentProgress: 0.5, totalDuration: 300)
        XCTAssertEqual(p, (60 + 60) / 300, accuracy: 0.0001)

        // clamps progress and result
        XCTAssertEqual(BatchProgress.overall(completedDurations: [], currentDuration: 100, currentProgress: 2, totalDuration: 100), 1, accuracy: 0.0001)
        XCTAssertEqual(BatchProgress.overall(completedDurations: [], currentDuration: 100, currentProgress: -1, totalDuration: 100), 0, accuracy: 0.0001)
        XCTAssertEqual(BatchProgress.overall(completedDurations: [], currentDuration: 0, currentProgress: 0, totalDuration: 0), 0, accuracy: 0.0001)
    }

    func testOverallProgressNeverDecreasesAcrossUpdates() {
        let total = 300.0
        let p1 = BatchProgress.overall(completedDurations: [], currentDuration: 100, currentProgress: 0.2, totalDuration: total)
        let p2 = BatchProgress.overall(completedDurations: [], currentDuration: 100, currentProgress: 0.9, totalDuration: total)
        let p3 = BatchProgress.overall(completedDurations: [100], currentDuration: 100, currentProgress: 0.0, totalDuration: total)
        XCTAssertLessThanOrEqual(p1, p2)
        XCTAssertLessThanOrEqual(p2, p3)
    }

    // MARK: - Temp estimate (FR-015)

    func testEstimatedTempBytes() {
        // 60 min = 3600s × 32000 × 1.2 = 138,240,000
        XCTAssertEqual(TranscribeLimits.estimatedTempBytes(forAudioSeconds: 3600), 138_240_000)
    }
}
