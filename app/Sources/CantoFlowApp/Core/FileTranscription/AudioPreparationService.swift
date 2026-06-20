import AVFoundation
import Foundation

enum AudioPreparationError: Error, LocalizedError {
    case cannotOpen(String)
    case formatUnavailable
    case converterUnavailable
    case writeFailed(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .cannotOpen(let detail): return "無法讀取音頻：\(detail)"
        case .formatUnavailable: return "無法建立目標音頻格式"
        case .converterUnavailable: return "無法建立音頻轉換器"
        case .writeFailed(let detail): return "寫入暫存音頻失敗：\(detail)"
        case .cancelled: return "已取消"
        }
    }
}

/// Lightweight probe of a candidate file: size, duration, decodability — without
/// decoding the whole file. Opening via AVAudioFile also rejects DRM/corrupt
/// inputs (FR-004). Throws on undecodable input.
enum FileProbe {
    struct Result {
        let sizeBytes: Int64
        let durationSeconds: Double
        let isRegularFile: Bool
    }

    static func probe(_ url: URL) throws -> Result {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        let isRegular = values.isRegularFile ?? false
        let size = Int64(values.fileSize ?? 0)

        // Decodability + duration in one step; no full decode.
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url)
        } catch {
            throw AudioPreparationError.cannotOpen(error.localizedDescription)
        }
        let sampleRate = file.processingFormat.sampleRate
        let duration = sampleRate > 0 ? Double(file.length) / sampleRate : 0
        return Result(sizeBytes: size, durationSeconds: duration, isRegularFile: isRegular)
    }
}

/// Converts any supported input into the canonical 16 kHz / mono / 16-bit PCM WAV
/// that the Qwen worker expects, using AVFoundation only (no ffmpeg — FR-011).
/// Streams in blocks so the full decoded audio never lives in memory (FR-012).
///
/// MUST be called off the main thread.
struct AudioPreparationService {
    /// Frames read from the source per pull.
    private static let inputChunkFrames: AVAudioFrameCount = 16_384

    /// - Parameters:
    ///   - inputURL: source audio (wav/mp3/m4a).
    ///   - outputURL: destination canonical WAV (caller owns/cleans it up).
    ///   - onProgress: 0…1 conversion progress, called off-main; caller hops to main.
    func prepare(
        _ inputURL: URL,
        to outputURL: URL,
        onProgress: (Double) -> Void
    ) throws {
        let input: AVAudioFile
        do {
            input = try AVAudioFile(forReading: inputURL)
        } catch {
            throw AudioPreparationError.cannotOpen(error.localizedDescription)
        }

        let inputFormat = input.processingFormat
        let totalFrames = input.length
        guard totalFrames > 0 else { throw AudioPreparationError.cannotOpen("empty audio") }

        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: TranscribeLimits.canonicalSampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw AudioPreparationError.formatUnavailable
        }

        guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            throw AudioPreparationError.converterUnavailable
        }

        // 16 kHz / mono / 16-bit little-endian PCM WAV.
        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: TranscribeLimits.canonicalSampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false
        ]
        let output: AVAudioFile
        do {
            output = try AVAudioFile(
                forWriting: outputURL,
                settings: outputSettings,
                commonFormat: .pcmFormatFloat32,
                interleaved: false
            )
        } catch {
            throw AudioPreparationError.writeFailed(error.localizedDescription)
        }

        let ratio = targetFormat.sampleRate / inputFormat.sampleRate
        let outputCapacity = AVAudioFrameCount(Double(Self.inputChunkFrames) * ratio) + 1024

        var reachedEnd = false
        var readError: Error?

        while !reachedEnd {
            if Task.isCancelled { throw AudioPreparationError.cancelled }
            onProgress(min(Double(input.framePosition) / Double(totalFrames), 1))

            guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outputCapacity) else {
                throw AudioPreparationError.formatUnavailable
            }

            var conversionError: NSError?
            let status = converter.convert(to: outputBuffer, error: &conversionError) { _, inputStatus in
                // Detect EOF by position; reading past the end throws a generic
                // error on some macOS versions instead of returning 0 frames.
                let remaining = totalFrames - input.framePosition
                if remaining <= 0 {
                    inputStatus.pointee = .endOfStream
                    reachedEnd = true
                    return nil
                }
                let toRead = AVAudioFrameCount(min(Int64(Self.inputChunkFrames), remaining))
                guard let inputBuffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: toRead) else {
                    inputStatus.pointee = .endOfStream
                    reachedEnd = true
                    return nil
                }
                do {
                    try input.read(into: inputBuffer, frameCount: toRead)
                } catch {
                    readError = error
                    inputStatus.pointee = .endOfStream
                    reachedEnd = true
                    return nil
                }
                if inputBuffer.frameLength == 0 {
                    inputStatus.pointee = .endOfStream
                    reachedEnd = true
                    return nil
                }
                inputStatus.pointee = .haveData
                return inputBuffer
            }

            if let readError { throw AudioPreparationError.cannotOpen(readError.localizedDescription) }
            if status == .error { throw AudioPreparationError.writeFailed((conversionError ?? NSError()).localizedDescription) }

            if outputBuffer.frameLength > 0 {
                do {
                    try output.write(from: outputBuffer)
                } catch {
                    throw AudioPreparationError.writeFailed(error.localizedDescription)
                }
            }
            if status == .endOfStream { reachedEnd = true }
        }

        onProgress(1)
    }
}
