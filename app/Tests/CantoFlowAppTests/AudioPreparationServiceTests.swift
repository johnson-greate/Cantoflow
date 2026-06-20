import AVFoundation
import XCTest
@testable import CantoFlowApp

final class AudioPreparationServiceTests: XCTestCase {

    /// Write a synthetic sine-tone source so we never commit real audio.
    private func makeSourceWAV(sampleRate: Double, channels: AVAudioChannelCount, seconds: Double) throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cf-src-\(UUID().uuidString).wav")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let format = file.processingFormat
        let frames = AVAudioFrameCount(sampleRate * seconds)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for ch in 0..<Int(format.channelCount) {
            let p = buffer.floatChannelData![ch]
            for i in 0..<Int(frames) {
                p[i] = 0.3 * sinf(2 * .pi * 440 * Float(i) / Float(sampleRate))
            }
        }
        try file.write(from: buffer)
        return url
    }

    func testConvertsToCanonical16kMono() async throws {
        let source = try makeSourceWAV(sampleRate: 44_100, channels: 2, seconds: 1.0)
        defer { try? FileManager.default.removeItem(at: source) }
        let output = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cf-out-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: output) }

        var lastProgress = -1.0
        var monotonic = true
        let service = AudioPreparationService()
        try service.prepare(source, to: output) { p in
            if p < lastProgress { monotonic = false }
            lastProgress = p
        }

        XCTAssertTrue(monotonic, "progress must be monotonic")
        XCTAssertEqual(lastProgress, 1.0, accuracy: 0.0001)

        let result = try AVAudioFile(forReading: output)
        XCTAssertEqual(result.processingFormat.sampleRate, 16_000)
        XCTAssertEqual(result.processingFormat.channelCount, 1)
        // ~1 second at 16 kHz, allow generous slack for converter priming.
        XCTAssertGreaterThan(result.length, 14_000)
        XCTAssertLessThan(result.length, 18_000)
    }

    func testProbeReportsDurationAndSize() throws {
        let source = try makeSourceWAV(sampleRate: 16_000, channels: 1, seconds: 2.0)
        defer { try? FileManager.default.removeItem(at: source) }
        let probe = try FileProbe.probe(source)
        XCTAssertTrue(probe.isRegularFile)
        XCTAssertGreaterThan(probe.sizeBytes, 0)
        XCTAssertEqual(probe.durationSeconds, 2.0, accuracy: 0.05)
    }

    func testProbeRejectsUndecodable() throws {
        let bogus = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cf-bogus-\(UUID().uuidString).wav")
        try Data("not audio".utf8).write(to: bogus)
        defer { try? FileManager.default.removeItem(at: bogus) }
        XCTAssertThrowsError(try FileProbe.probe(bogus))
    }
}
