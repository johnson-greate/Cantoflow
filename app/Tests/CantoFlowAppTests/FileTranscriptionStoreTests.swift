import AVFoundation
import XCTest
@testable import CantoFlowApp

@MainActor
final class FileTranscriptionStoreTests: XCTestCase {

    private func makeWAV(seconds: Double = 1.0) throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cf-store-\(UUID().uuidString).wav")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let frames = AVAudioFrameCount(16_000 * seconds)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames)!
        buffer.frameLength = frames
        try file.write(from: buffer)
        return url
    }

    private func makeStore() -> FileTranscriptionStore {
        FileTranscriptionStore(config: AppConfig(projectRoot: URL(fileURLWithPath: "/tmp")))
    }

    func testAddValidFileQueues() throws {
        let store = makeStore()
        let wav = try makeWAV()
        defer { try? FileManager.default.removeItem(at: wav) }
        store.addFiles([wav])
        XCTAssertEqual(store.items.count, 1)
        XCTAssertEqual(store.items.first?.status, .queued)
        XCTAssertTrue(store.hasQueuedWork)
    }

    func testDuplicateNotAddedTwice() throws {
        let store = makeStore()
        let wav = try makeWAV()
        defer { try? FileManager.default.removeItem(at: wav) }
        store.addFiles([wav])
        store.addFiles([wav])
        XCTAssertEqual(store.items.count, 1)
    }

    func testRejectsNonAudioFile() throws {
        let store = makeStore()
        let txt = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("cf-\(UUID().uuidString).txt")
        try Data("hi".utf8).write(to: txt)
        defer { try? FileManager.default.removeItem(at: txt) }
        store.addFiles([txt])
        XCTAssertEqual(store.items.count, 0)
    }

    func testRemoveQueuedItem() throws {
        let store = makeStore()
        let wav = try makeWAV()
        defer { try? FileManager.default.removeItem(at: wav) }
        store.addFiles([wav])
        let id = try XCTUnwrap(store.items.first?.id)
        store.removeItem(id)
        XCTAssertTrue(store.items.isEmpty)
    }
}
