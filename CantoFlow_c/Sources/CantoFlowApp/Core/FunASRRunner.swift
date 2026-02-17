import Foundation

/// Errors that can occur during FunASR transcription
enum FunASRError: Error, LocalizedError {
    case serverNotReady(String)
    case serverUnreachable(String)
    case inputFileNotFound(String)
    case transcriptionFailed(Int, String)
    case invalidResponse(String)
    case emptyTranscription

    var errorDescription: String? {
        switch self {
        case .serverNotReady(let detail):
            return "FunASR server not ready: \(detail)"
        case .serverUnreachable(let url):
            return "FunASR server unreachable at: \(url)"
        case .inputFileNotFound(let path):
            return "Input audio file not found: \(path)"
        case .transcriptionFailed(let code, let detail):
            return "Transcription failed (HTTP \(code)): \(detail)"
        case .invalidResponse(let detail):
            return "Invalid response from FunASR server: \(detail)"
        case .emptyTranscription:
            return "Transcription result is empty"
        }
    }
}

/// Result of FunASR transcription (compatible with WhisperResult interface)
struct FunASRResult {
    let text: String
    let rawOutputPath: URL
    let modelUsed: String
    let durationMs: Int
}

/// Chinese script preference
enum ChineseScript: String {
    case traditional = "traditional"  // 繁體字
    case simplified = "simplified"    // 简体字
}

/// Runner for FunASR HTTP server
final class FunASRRunner {
    private let config: AppConfig
    private let session: URLSession

    /// Current script preference (can be changed at runtime)
    var scriptPreference: ChineseScript = .traditional

    /// Cantonese hotwords for better accuracy
    static let hotwords = "銅鑼灣 維園 旺角 尖沙咀 中環 沙田 將軍澳 荃灣 屯門 九龍 港島 新界"

    init(config: AppConfig) {
        self.config = config

        // Configure URLSession with timeout
        let sessionConfig = URLSessionConfiguration.default
        sessionConfig.timeoutIntervalForRequest = 30  // 30 second timeout
        sessionConfig.timeoutIntervalForResource = 60  // 60 second resource timeout
        self.session = URLSession(configuration: sessionConfig)
    }

    /// Server endpoint URL
    private var serverURL: URL {
        let host = config.funasrHost
        let port = config.funasrPort
        return URL(string: "http://\(host):\(port)")!
    }

    /// Check if server is ready
    func isServerReady() async -> Bool {
        let readyURL = serverURL.appendingPathComponent("ready")
        var request = URLRequest(url: readyURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 5  // Quick check

        do {
            let (_, response) = try await session.data(for: request)
            if let httpResponse = response as? HTTPURLResponse {
                return httpResponse.statusCode == 200
            }
        } catch {
            // Server not reachable
        }
        return false
    }

    /// Transcribe audio file using FunASR server
    /// - Parameters:
    ///   - audioURL: Path to the input WAV file
    ///   - outputPrefix: Prefix for output files (for compatibility)
    /// - Returns: FunASRResult containing transcribed text
    func transcribe(audioURL: URL, outputPrefix: URL) async throws -> FunASRResult {
        let fm = FileManager.default

        // Validate input file
        guard fm.fileExists(atPath: audioURL.path) else {
            throw FunASRError.inputFileNotFound(audioURL.path)
        }

        // Check server ready
        let ready = await isServerReady()
        if !ready {
            throw FunASRError.serverNotReady("Server at \(serverURL) not responding")
        }

        let startTime = Date()

        // Build multipart form request
        let transcribeURL = serverURL.appendingPathComponent("transcribe")
        var request = URLRequest(url: transcribeURL)
        request.httpMethod = "POST"

        let boundary = UUID().uuidString
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        // Read audio file
        let audioData = try Data(contentsOf: audioURL)

        // Build multipart body
        var body = Data()

        // Add audio file
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"audio\"; filename=\"\(audioURL.lastPathComponent)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
        body.append(audioData)
        body.append("\r\n".data(using: .utf8)!)

        // Add language parameter
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"language\"\r\n\r\n".data(using: .utf8)!)
        body.append("yue\r\n".data(using: .utf8)!)

        // Add hotwords parameter
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"hotwords\"\r\n\r\n".data(using: .utf8)!)
        body.append("\(Self.hotwords)\r\n".data(using: .utf8)!)

        // Add script parameter (traditional/simplified)
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"script\"\r\n\r\n".data(using: .utf8)!)
        body.append("\(scriptPreference.rawValue)\r\n".data(using: .utf8)!)

        // End boundary
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)

        request.httpBody = body

        // Send request
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw FunASRError.serverUnreachable(serverURL.absoluteString)
        }

        // Check HTTP status
        guard let httpResponse = response as? HTTPURLResponse else {
            throw FunASRError.invalidResponse("Not an HTTP response")
        }

        if httpResponse.statusCode != 200 {
            let errorBody = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw FunASRError.transcriptionFailed(httpResponse.statusCode, errorBody)
        }

        // Parse JSON response
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = json["text"] as? String else {
            throw FunASRError.invalidResponse("Missing 'text' field in response")
        }

        if text.isEmpty {
            throw FunASRError.emptyTranscription
        }

        // Get model info from response
        let model = json["model"] as? String ?? "funasr-cantonese"

        let durationMs = Int(Date().timeIntervalSince(startTime) * 1000)

        // Save raw text to file (for compatibility with WhisperResult)
        let outputPath = URL(fileURLWithPath: outputPrefix.path + ".txt")
        try text.write(to: outputPath, atomically: true, encoding: .utf8)

        return FunASRResult(
            text: text,
            rawOutputPath: outputPath,
            modelUsed: model,
            durationMs: durationMs
        )
    }
}
