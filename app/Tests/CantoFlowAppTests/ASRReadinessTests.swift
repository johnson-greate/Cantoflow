import XCTest
@testable import CantoFlowApp

final class ASRReadinessTests: XCTestCase {
    private func makeRoot() -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cf-asr-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func testHasUsableHFSnapshotFollowsRefsAndTokenizer() throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fm = FileManager.default
        let paths = ASRRuntimePaths(root: root)
        let repo = "models--Qwen--Qwen3-ASR-0.6B"
        let repoDir = root.appendingPathComponent("cache/huggingface/hub/\(repo)", isDirectory: true)
        let sha = "5eb144179a02acc5e5ba31e748d22b0cf3e303b0"
        let snap = repoDir.appendingPathComponent("snapshots/\(sha)", isDirectory: true)
        try fm.createDirectory(at: snap, withIntermediateDirectories: true)
        func writeFile(_ name: String) throws { try Data("{}".utf8).write(to: snap.appendingPathComponent(name)) }

        // Nothing → not usable.
        XCTAssertFalse(paths.hasUsableHFSnapshot(repo: repo))

        // Orphan snapshot with full files but NO refs/main → not usable (loader
        // resolves via refs/main, which is missing).
        try writeFile("config.json"); try writeFile("vocab.json"); try writeFile("merges.txt")
        XCTAssertFalse(paths.hasUsableHFSnapshot(repo: repo))

        // refs/main present but tokenizer files missing → not usable.
        try fm.createDirectory(at: repoDir.appendingPathComponent("refs"), withIntermediateDirectories: true)
        try Data(sha.utf8).write(to: repoDir.appendingPathComponent("refs/main"))
        try fm.removeItem(at: snap.appendingPathComponent("vocab.json"))
        try fm.removeItem(at: snap.appendingPathComponent("merges.txt"))
        XCTAssertFalse(paths.hasUsableHFSnapshot(repo: repo))

        // refs/main + config + full tokenizer → usable.
        try writeFile("vocab.json"); try writeFile("merges.txt")
        XCTAssertTrue(paths.hasUsableHFSnapshot(repo: repo))

        // refs/main pointing at a non-existent snapshot → not usable.
        try Data("deadbeef".utf8).write(to: repoDir.appendingPathComponent("refs/main"))
        XCTAssertFalse(paths.hasUsableHFSnapshot(repo: repo))
    }
}
