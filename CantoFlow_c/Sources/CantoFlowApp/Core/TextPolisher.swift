import Foundation

/// Errors that can occur during text polishing
enum PolishError: Error, LocalizedError {
    case noAPIKey
    case networkError(Error)
    case apiError(String)
    case invalidResponse
    case emptyResult

    var errorDescription: String? {
        switch self {
        case .noAPIKey:
            return "No API key found. Set QWEN_API_KEY, OPENAI_API_KEY, or ANTHROPIC_API_KEY."
        case .networkError(let error):
            return "Network error: \(error.localizedDescription)"
        case .apiError(let message):
            return "API error: \(message)"
        case .invalidResponse:
            return "Invalid API response"
        case .emptyResult:
            return "Empty result from API"
        }
    }
}

/// Result of text polishing
struct PolishResult {
    let text: String
    let provider: AppConfig.PolishProvider
    let durationMs: Int
}

/// LLM-based text polisher supporting Qwen, Anthropic, and OpenAI
final class TextPolisher {
    private let config: AppConfig

    /// System prompt for polishing Cantonese text
    static let systemPrompt = """
    你是一個廣東話語音輸入助手。你會收到一段由語音識別系統轉錄的廣東話粗文字，你的任務是：
    1. 保持用戶原意，不要過度改寫
    2. 修正語音識別錯字（按上下文）
    3. 去除口頭禪（即係、其實、呀、嗯、嗱咁等）
    4. 將廣東話口語轉成自然書面語（保留香港用語）
    5. 整理句式及標點
    6. 只輸出整理後文字，不要解釋
    7. 對地名、人名、品牌名等專有名詞採取保守策略：除非非常確定，否則保留原文，不要自行替換成其他地名
    8. 尤其避免把香港地名錯改為其他地區地名（例如銅鑼灣、維園、旺角、尖沙咀、中環等）
    """

    init(config: AppConfig) {
        self.config = config
    }

    /// Polish raw transcribed text using LLM
    /// - Parameter rawText: Raw text from speech recognition
    /// - Returns: PolishResult containing polished text
    func polish(rawText: String) async throws -> PolishResult {
        let provider = resolveProvider()

        guard provider != .none else {
            throw PolishError.noAPIKey
        }

        let startTime = Date()

        let polishedText: String
        switch provider {
        case .qwen:
            polishedText = try await callQwen(text: rawText)
        case .openai:
            polishedText = try await callOpenAI(text: rawText)
        case .anthropic:
            polishedText = try await callAnthropic(text: rawText)
        case .auto, .none:
            throw PolishError.noAPIKey
        }

        let durationMs = Int(Date().timeIntervalSince(startTime) * 1000)

        return PolishResult(
            text: polishedText,
            provider: provider,
            durationMs: durationMs
        )
    }

    /// Resolve which provider to use based on config and available API keys
    private func resolveProvider() -> AppConfig.PolishProvider {
        switch config.polishProvider {
        case .qwen:
            return .qwen
        case .openai:
            return .openai
        case .anthropic:
            return .anthropic
        case .none:
            return .none
        case .auto:
            // Priority: Qwen > OpenAI > Anthropic
            if ProcessInfo.processInfo.environment["QWEN_API_KEY"] != nil {
                return .qwen
            } else if ProcessInfo.processInfo.environment["OPENAI_API_KEY"] != nil {
                return .openai
            } else if ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"] != nil {
                return .anthropic
            } else {
                return .none
            }
        }
    }

    /// Check if polishing is available (API key exists)
    func isAvailable() -> Bool {
        return resolveProvider() != .none
    }

    // MARK: - Qwen API (DashScope OpenAI-compatible)

    private func callQwen(text: String) async throws -> String {
        guard let rawKey = ProcessInfo.processInfo.environment["QWEN_API_KEY"] else {
            throw PolishError.noAPIKey
        }
        let apiKey = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)

        let model = ProcessInfo.processInfo.environment["QWEN_MODEL"] ?? "qwen-turbo"

        let requestBody: [String: Any] = [
            "model": model,
            "temperature": 0.2,
            "max_tokens": 1024,
            "messages": [
                ["role": "system", "content": Self.systemPrompt],
                ["role": "user", "content": text]
            ]
        ]

        let jsonData = try JSONSerialization.data(withJSONObject: requestBody)

        var request = URLRequest(url: URL(string: "https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = jsonData

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw PolishError.invalidResponse
        }

        guard httpResponse.statusCode == 200 else {
            if let errorJson = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let error = errorJson["error"] as? [String: Any],
               let message = error["message"] as? String {
                throw PolishError.apiError(message)
            }
            throw PolishError.apiError("HTTP \(httpResponse.statusCode)")
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let firstChoice = choices.first,
              let message = firstChoice["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw PolishError.invalidResponse
        }

        let polished = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !polished.isEmpty else {
            throw PolishError.emptyResult
        }

        return polished
    }

    // MARK: - OpenAI API

    private func callOpenAI(text: String) async throws -> String {
        guard let rawKey = ProcessInfo.processInfo.environment["OPENAI_API_KEY"] else {
            throw PolishError.noAPIKey
        }
        let apiKey = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)

        let model = ProcessInfo.processInfo.environment["OPENAI_MODEL"] ?? "gpt-4o-mini"

        let requestBody: [String: Any] = [
            "model": model,
            "temperature": 0.2,
            "max_completion_tokens": 1024,
            "messages": [
                ["role": "system", "content": Self.systemPrompt],
                ["role": "user", "content": text]
            ]
        ]

        let jsonData = try JSONSerialization.data(withJSONObject: requestBody)

        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = jsonData

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw PolishError.invalidResponse
        }

        guard httpResponse.statusCode == 200 else {
            if let errorJson = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let error = errorJson["error"] as? [String: Any],
               let message = error["message"] as? String {
                throw PolishError.apiError(message)
            }
            throw PolishError.apiError("HTTP \(httpResponse.statusCode)")
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let firstChoice = choices.first,
              let message = firstChoice["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw PolishError.invalidResponse
        }

        let polished = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !polished.isEmpty else {
            throw PolishError.emptyResult
        }

        return polished
    }

    // MARK: - Anthropic API

    private func callAnthropic(text: String) async throws -> String {
        guard let rawKey = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"] else {
            throw PolishError.noAPIKey
        }
        let apiKey = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)

        let model = ProcessInfo.processInfo.environment["ANTHROPIC_MODEL"] ?? "claude-sonnet-4-5-20250929"

        let requestBody: [String: Any] = [
            "model": model,
            "max_tokens": 1024,
            "temperature": 0.2,
            "system": Self.systemPrompt,
            "messages": [
                [
                    "role": "user",
                    "content": [
                        [
                            "type": "text",
                            "text": text
                        ]
                    ]
                ]
            ]
        ]

        let jsonData = try JSONSerialization.data(withJSONObject: requestBody)

        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = jsonData

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw PolishError.invalidResponse
        }

        guard httpResponse.statusCode == 200 else {
            if let errorJson = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let error = errorJson["error"] as? [String: Any],
               let message = error["message"] as? String {
                throw PolishError.apiError(message)
            }
            throw PolishError.apiError("HTTP \(httpResponse.statusCode)")
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = json["content"] as? [[String: Any]] else {
            throw PolishError.invalidResponse
        }

        // Find text content
        var polished = ""
        for item in content {
            if item["type"] as? String == "text",
               let text = item["text"] as? String {
                polished = text.trimmingCharacters(in: .whitespacesAndNewlines)
                break
            }
        }

        guard !polished.isEmpty else {
            throw PolishError.emptyResult
        }

        return polished
    }
}
