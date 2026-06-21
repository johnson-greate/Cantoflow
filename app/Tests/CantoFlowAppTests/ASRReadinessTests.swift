import XCTest
@testable import CantoFlowApp

final class ASRReadinessTests: XCTestCase {
    private func makeRoot() -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cf-asr-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func testHasUsableHFSnapshotRequiresConfigInSnapshot() throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ASRRuntimePaths(root: root)
        let repo = "models--Qwen--Qwen3-ASR-0.6B"

        // Nothing → not usable.
        XCTAssertFalse(paths.hasUsableHFSnapshot(repo: repo))

        // Empty snapshot dir (partial cache) → still not usable.
        let snap = root.appendingPathComponent("cache/huggingface/hub/\(repo)/snapshots/abc123", isDirectory: true)
        try FileManager.default.createDirectory(at: snap, withIntermediateDirectories: true)
        XCTAssertFalse(paths.hasUsableHFSnapshot(repo: repo))

        // With config.json present → usable.
        try Data("{}".utf8).write(to: snap.appendingPathComponent("config.json"))
        XCTAssertTrue(paths.hasUsableHFSnapshot(repo: repo))
    }
}
