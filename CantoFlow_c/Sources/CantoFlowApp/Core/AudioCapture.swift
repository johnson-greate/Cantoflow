import AVFoundation
import Foundation

/// Errors that can occur during audio capture
enum AudioCaptureError: Error, LocalizedError {
    case engineNotReady
    case recordingInProgress
    case notRecording
    case fileCreationFailed
    case permissionDenied

    var errorDescription: String? {
        switch self {
        case .engineNotReady: return "Audio engine is not ready"
        case .recordingInProgress: return "Recording is already in progress"
        case .notRecording: return "Not currently recording"
        case .fileCreationFailed: return "Failed to create audio file"
        case .permissionDenied: return "Microphone permission denied"
        }
    }
}

/// Audio capture using AVAudioEngine (native macOS, no ffmpeg dependency)
final class AudioCapture {
    private let audioEngine = AVAudioEngine()
    private var audioFile: AVAudioFile?
    private var isRecording = false
    private var recordingURL: URL?

    /// Callback for real-time audio level updates (normalized 0.0 to 1.0)
    var onAudioLevelUpdate: ((Float) -> Void)?

    /// Target format for whisper: 16kHz mono PCM
    static let targetSampleRate: Double = 16000
    static let targetChannels: AVAudioChannelCount = 1

    /// Check microphone permission status
    static func checkPermission() -> AVAuthorizationStatus {
        return AVCaptureDevice.authorizationStatus(for: .audio)
    }

    /// Request microphone permission
    static func requestPermission(completion: @escaping (Bool) -> Void) {
        switch checkPermission() {
        case .authorized:
            completion(true)
        case .denied, .restricted:
            completion(false)
        case .notDetermined:
            // Trigger permission dialog by briefly starting audio engine
            let engine = AVAudioEngine()
            let inputNode = engine.inputNode
            let format = inputNode.outputFormat(forBus: 0)

            inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { _, _ in }

            do {
                try engine.start()
                engine.stop()
                inputNode.removeTap(onBus: 0)
                completion(true)
            } catch {
                completion(false)
            }
        @unknown default:
            completion(false)
        }
    }

    /// Start recording to the specified URL
    /// - Parameter outputURL: URL to save the WAV file
    func startRecording(to outputURL: URL) throws {
        guard !isRecording else {
            throw AudioCaptureError.recordingInProgress
        }

        let inputNode = audioEngine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)

        // Create target format: 16kHz mono PCM
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Self.targetSampleRate,
            channels: Self.targetChannels,
            interleaved: false
        ) else {
            throw AudioCaptureError.engineNotReady
        }

        // Create audio file for writing
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: Self.targetSampleRate,
            AVNumberOfChannelsKey: Self.targetChannels,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false
        ]

        do {
            audioFile = try AVAudioFile(forWriting: outputURL, settings: settings)
        } catch {
            throw AudioCaptureError.fileCreationFailed
        }

        // Create converter for sample rate conversion
        guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            throw AudioCaptureError.engineNotReady
        }

        // Install tap on input node
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            guard let self = self, let audioFile = self.audioFile else { return }

            // Calculate audio level for waveform visualization
            if let channelData = buffer.floatChannelData?[0] {
                let frameLength = Int(buffer.frameLength)
                var sum: Float = 0
                for i in 0..<frameLength {
                    sum += channelData[i] * channelData[i]
                }
                let rms = sqrt(sum / Float(frameLength))

                // Apply sensitivity boost and non-linear scaling for better UI response
                // Normal speech should fill 60-80% of the bar
                let boosted = pow(rms * 8.0, 0.5)  // Boost and apply sqrt for better dynamic range
                let normalized = min(1.0, max(0.0, boosted))

                DispatchQueue.main.async { [weak self] in
                    self?.onAudioLevelUpdate?(normalized)
                }
            }

            // Convert buffer to target format
            let frameCount = AVAudioFrameCount(
                Double(buffer.frameLength) * Self.targetSampleRate / inputFormat.sampleRate
            )

            guard let convertedBuffer = AVAudioPCMBuffer(
                pcmFormat: targetFormat,
                frameCapacity: frameCount
            ) else { return }

            var error: NSError?
            let status = converter.convert(to: convertedBuffer, error: &error) { inNumPackets, outStatus in
                outStatus.pointee = .haveData
                return buffer
            }

            guard status != .error else { return }

            // Write to file
            do {
                try audioFile.write(from: convertedBuffer)
            } catch {
                print("AudioCapture: Failed to write buffer: \(error)")
            }
        }

        // Start the engine
        try audioEngine.start()

        isRecording = true
        recordingURL = outputURL
    }

    /// Stop recording and return the recorded file URL
    /// - Returns: URL of the recorded WAV file
    @discardableResult
    func stopRecording() throws -> URL {
        guard isRecording else {
            throw AudioCaptureError.notRecording
        }

        // Stop engine and remove tap
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)

        // Close the audio file
        audioFile = nil
        isRecording = false

        guard let url = recordingURL else {
            throw AudioCaptureError.notRecording
        }

        recordingURL = nil
        return url
    }

    /// Cancel recording without saving
    func cancelRecording() {
        if isRecording {
            audioEngine.stop()
            audioEngine.inputNode.removeTap(onBus: 0)
            isRecording = false

            // Delete the partial file
            if let url = recordingURL {
                try? FileManager.default.removeItem(at: url)
            }
            recordingURL = nil
            audioFile = nil
        }
    }

    /// Check if currently recording
    var recording: Bool {
        return isRecording
    }
}
