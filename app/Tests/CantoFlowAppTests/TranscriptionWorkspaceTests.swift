import XCTest
@testable import CantoFlowApp

final class TranscriptionWorkspaceTests: XCTestCase {

    func testCollisionSafeFilename() {
        var taken: Set<String> = []
        XCTAssertEqual(
            TranscriptionWorkspace.uniqueFilename(base: "meeting-transcript", ext: "txt") { taken.contains($0) },
            "meeting-transcript.txt"
        )
        taken = ["meeting-transcript.txt"]
        XCTAssertEqual(
            TranscriptionWorkspace.uniqueFilename(base: "meeting-transcript", ext: "txt") { taken.contains($0) },
            "meeting-transcript-1.txt"
        )
        taken = ["meeting-transcript.txt", "meeting-transcript-1.txt"]
        XCTAssertEqual(
            TranscriptionWorkspace.uniqueFilename(base: "meeting-transcript", ext: "txt") { taken.contains($0) },
            "meeting-transcript-2.txt"
        )
    }

    func testDefaultBasenames() {
        let src = URL(fileURLWithPath: "/x/meeting-01.m4a")
        XCTAssertEqual(TranscriptionWorkspace.transcriptBasename(forSource: src), "meeting-01-transcript")
        XCTAssertEqual(TranscriptionWorkspace.notesBasename(forSource: src), "meeting-01-meeting-notes")
    }

    func testPathLayout() {
        let ws = TranscriptionWorkspace(root: URL(fileURLWithPath: "/tmp/cf-test-root"))
        let batch = UUID()
        let file = UUID()
        XCTAssertTrue(ws.tempWAVURL(batchID: batch, fileID: file).path.hasSuffix("\(batch.uuidString)/temp/\(file.uuidString).wav"))
        XCTAssertTrue(ws.manifestURL(batch).path.hasSuffix("\(batch.uuidString)/manifest.json"))
        XCTAssertTrue(ws.transcriptsDirectory(batch).path.hasSuffix("\(batch.uuidString)/transcripts"))
    }

    func testAtomicWriteAndPrepareDirectories() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cf-ws-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let ws = TranscriptionWorkspace(root: root)
        let batch = UUID()
        try ws.prepareBatchDirectories(batch)

        XCTAssertTrue(FileManager.default.fileExists(atPath: ws.transcriptsDirectory(batch).path))
        let target = ws.transcriptsDirectory(batch).appendingPathComponent("t.txt")
        try ws.atomicWrite("廣東話內容", to: target)
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "廣東話內容")
    }

    func testPurgeStaleTempLeavesTranscripts() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cf-ws-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let ws = TranscriptionWorkspace(root: root)
        let batch = UUID()
        try ws.prepareBatchDirectories(batch)

        let stale = ws.tempDirectory(batch).appendingPathComponent("old.wav")
        try Data([0]).write(to: stale)
        // Backdate the temp file beyond the retention window.
        let old = Date().addingTimeInterval(-(TranscribeLimits.tempRetentionSeconds + 3600))
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: stale.path)

        let transcript = ws.transcriptsDirectory(batch).appendingPathComponent("keep-transcript.txt")
        try ws.atomicWrite("keep", to: transcript)

        ws.purgeStaleTemp()

        XCTAssertFalse(FileManager.default.fileExists(atPath: stale.path), "stale temp wav should be purged")
        XCTAssertTrue(FileManager.default.fileExists(atPath: transcript.path), "transcripts must never be purged")
    }
}
