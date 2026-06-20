import XCTest
@testable import CantoFlowApp

final class WorkerEventParserTests: XCTestCase {

    func testParsesEachEvent() {
        XCTAssertEqual(
            WorkerEventParser.parse(#"{"v":1,"event":"worker_ready","total_files":3}"#),
            .workerReady(totalFiles: 3)
        )
        XCTAssertEqual(
            WorkerEventParser.parse(#"{"v":1,"event":"file_started","file_id":"a","file_index":1,"total_files":3}"#),
            .fileStarted(fileID: "a", index: 1, total: 3)
        )
        XCTAssertEqual(
            WorkerEventParser.parse(#"{"v":1,"event":"asr_progress","file_id":"a","progress":0.21,"chunk_index":18,"total_chunks":87,"processed_audio_sec":540.0,"audio_duration_sec":2578.2}"#),
            .asrProgress(fileID: "a", progress: 0.21, chunkIndex: 18, totalChunks: 87, processedAudioSec: 540, audioDurationSec: 2578.2)
        )
        XCTAssertEqual(
            WorkerEventParser.parse(#"{"v":1,"event":"file_completed","file_id":"a","output_txt":"/x.txt","chars":12,"language":"Cantonese","truncated":true,"duration_ms":88}"#),
            .fileCompleted(fileID: "a", outputTxt: "/x.txt", chars: 12, language: "Cantonese", truncated: true, durationMs: 88)
        )
        XCTAssertEqual(
            WorkerEventParser.parse(#"{"v":1,"event":"file_failed","file_id":"a","code":"decode_failed","message":"bad"}"#),
            .fileFailed(fileID: "a", code: "decode_failed", message: "bad")
        )
        XCTAssertEqual(
            WorkerEventParser.parse(#"{"v":1,"event":"batch_completed","succeeded":2,"failed":1,"duration_ms":190}"#),
            .batchCompleted(succeeded: 2, failed: 1, durationMs: 190)
        )
    }

    func testIgnoresMalformedAndUnknown() {
        XCTAssertNil(WorkerEventParser.parse(""))
        XCTAssertNil(WorkerEventParser.parse("   "))
        XCTAssertNil(WorkerEventParser.parse("not json at all"))
        XCTAssertNil(WorkerEventParser.parse(#"{"v":1}"#))                    // no event
        XCTAssertNil(WorkerEventParser.parse(#"{"v":1,"event":"future_thing","x":1}"#)) // unknown event
        XCTAssertNil(WorkerEventParser.parse(#"{"event":"worker_ready""#))    // truncated json
    }
}

final class FileTranscriptionRunnerTests: XCTestCase {

    private func makeFakeWorker(lines: [String]) throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cf-fakeworker-\(UUID().uuidString).sh")
        var script = "#!/bin/sh\n"
        for line in lines {
            // single-quote safe: our test lines contain no single quotes
            script += "printf '%s\\n' '\(line)'\n"
        }
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    func testStreamsEventsAndExitsZero() async throws {
        let lines = [
            #"{"v":1,"event":"worker_ready","total_files":1}"#,
            #"{"v":1,"event":"file_started","file_id":"a","file_index":1,"total_files":1}"#,
            #"{"v":1,"event":"asr_progress","file_id":"a","progress":0.5,"chunk_index":1,"total_chunks":2,"processed_audio_sec":5,"audio_duration_sec":10}"#,
            "this line is not json and must be ignored",
            #"{"v":1,"event":"file_completed","file_id":"a","output_txt":"/x.txt","chars":3,"language":"Cantonese","truncated":false,"duration_ms":10}"#,
            #"{"v":1,"event":"batch_completed","succeeded":1,"failed":0,"duration_ms":20}"#
        ]
        let worker = try makeFakeWorker(lines: lines)
        defer { try? FileManager.default.removeItem(at: worker) }

        let runner = FileTranscriptionRunner()
        let config = FileTranscriptionRunner.Config(
            pythonURL: URL(fileURLWithPath: "/bin/sh"),
            workerScriptURL: worker,
            manifestURL: URL(fileURLWithPath: "/tmp/m.json"),
            modelDirURL: URL(fileURLWithPath: "/tmp/model"),
            outputDirURL: URL(fileURLWithPath: "/tmp/out"),
            traditional: true
        )

        let collected = EventCollector()
        let code = try await runner.run(config) { collected.append($0) }

        XCTAssertEqual(code, 0)
        let events = collected.snapshot()
        XCTAssertEqual(events.first, .workerReady(totalFiles: 1))
        XCTAssertEqual(events.last, .batchCompleted(succeeded: 1, failed: 0, durationMs: 20))
        XCTAssertTrue(events.contains(.fileCompleted(fileID: "a", outputTxt: "/x.txt", chars: 3, language: "Cantonese", truncated: false, durationMs: 10)))
        // malformed line ignored → exactly 5 valid events
        XCTAssertEqual(events.count, 5)
    }

    /// Thread-safe collector since onEvent fires off-main.
    private final class EventCollector {
        private let lock = NSLock()
        private var events: [WorkerEvent] = []
        func append(_ e: WorkerEvent) { lock.lock(); events.append(e); lock.unlock() }
        func snapshot() -> [WorkerEvent] { lock.lock(); defer { lock.unlock() }; return events }
    }
}
