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

/// Polish output style
enum PolishStyle: String, CaseIterable {
    case cantonese = "cantonese"
    case formal    = "formal"

    var displayName: String {
        switch self {
        case .cantonese: return "廣東話口語"
        case .formal:    return "正式書面語"
        }
    }

    var styleDescription: String {
        switch self {
        case .cantonese: return "保留香港粵語用詞，語氣親切自然。"
        case .formal:    return "中國大陸標準書面語，用詞嚴謹規範。"
        }
    }

    var systemPrompt: String {
        switch self {
        case .cantonese:
            return """
            你是一位精通香港廣東話的資深編輯。請將用戶輸入的語音識別粗文字潤飾為地道、自然的香港口語。
            1. 保持用戶原意，不要過度改寫
            2. 修正語音識別錯字（按上下文）
            3. 去除口頭禪（即係、其實、呀、嗯、嗱咁等）
            4. 使用地道香港粵語用詞（係、唔、喺、咗、囉、架、喎等），語氣要親切自然
            5. 整理句式及標點
            6. 只輸出整理後文字，不要解釋
            7. 對地名、人名、品牌名等專有名詞採取保守策略：除非非常確定，否則保留原文
            8. 尤其避免把香港地名錯改為其他地區地名（例如銅鑼灣、維園、旺角、尖沙咀、中環等）
            9. 必須以繁體中文輸出，將所有簡體字轉換為繁體字
            """
        case .formal:
            return """
            你是一位精通中國大陸標準書面語的資深編輯。請將用戶輸入的語音識別粗文字潤飾為嚴謹、規範的正式書面語。
            1. 保持用戶原意，不要過度改寫
            2. 修正語音識別錯字（按上下文）
            3. 去除語氣詞、口頭禪及方言用詞，改為標準書面語表達
            4. 用詞準確、專業，符合中國大陸公文或正式出版物規範，避免口語化和方言用詞
            5. 整理句式及標點
            6. 只輸出整理後文字，不要解釋
            7. 對地名、人名、品牌名等專有名詞採取保守策略：除非非常確定，否則保留原文
            8. 必須以繁體中文輸出，將所有簡體字轉換為繁體字
            """
        }
    }
}

/// LLM-based text polisher supporting Qwen, Anthropic, and OpenAI
final class TextPolisher {
    private let config: AppConfig

    /// Whether to use vocabulary injection in the system prompt
    var useVocabularyInjection = true

    init(config: AppConfig) {
        self.config = config
    }

    /// Generate system prompt with the current polish style and vocabulary injection.
    /// Reads polishStyle from UserDefaults at call time so UI changes take effect
    /// on the next transcription without recreating the pipeline.
    private func generateSystemPrompt() -> String {
        let raw = UserDefaults.standard.string(forKey: "polishStyle") ?? PolishStyle.cantonese.rawValue
        let style = PolishStyle(rawValue: raw) ?? .cantonese
        var prompt = style.systemPrompt

        if useVocabularyInjection {
            let vocabSection = VocabularyStore.shared.generateClaudePromptSection()
            if !vocabSection.isEmpty {
                prompt += "\n" + vocabSection
            }
        }

        return prompt
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

    /// Resolve the API key for a given provider.
    /// Environment variable takes precedence; falls back to UserDefaults
    /// (set via Settings UI → LLM Polish API Keys section).
    private func resolvedAPIKey(envVar: String, userDefaultsKey: String) -> String? {
        if let envKey = ProcessInfo.processInfo.environment[envVar],
           !envKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return envKey.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let stored = UserDefaults.standard.string(forKey: userDefaultsKey),
           !stored.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return stored.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }

    /// Resolve which provider to use based on config and available API keys.
    /// Checks both environment variables and UserDefaults (Settings UI keys).
    private func resolveProvider() -> AppConfig.PolishProvider {
        switch config.polishProvider {
        case .qwen:
            return resolvedAPIKey(envVar: "QWEN_API_KEY", userDefaultsKey: "qwenAPIKey") != nil ? .qwen : .none
        case .openai:
            return resolvedAPIKey(envVar: "OPENAI_API_KEY", userDefaultsKey: "openaiAPIKey") != nil ? .openai : .none
        case .anthropic:
            return resolvedAPIKey(envVar: "ANTHROPIC_API_KEY", userDefaultsKey: "anthropicAPIKey") != nil ? .anthropic : .none
        case .none:
            return .none
        case .auto:
            // Priority: Qwen > OpenAI > Anthropic
            if resolvedAPIKey(envVar: "QWEN_API_KEY", userDefaultsKey: "qwenAPIKey") != nil {
                return .qwen
            } else if resolvedAPIKey(envVar: "OPENAI_API_KEY", userDefaultsKey: "openaiAPIKey") != nil {
                return .openai
            } else if resolvedAPIKey(envVar: "ANTHROPIC_API_KEY", userDefaultsKey: "anthropicAPIKey") != nil {
                return .anthropic
            } else {
                return .none
            }
        }
    }

    /// Check if polishing is available (API key exists in env or UserDefaults)
    func isAvailable() -> Bool {
        return resolveProvider() != .none
    }

    // MARK: - Qwen API (DashScope OpenAI-compatible)

    private func callQwen(text: String) async throws -> String {
        guard let apiKey = resolvedAPIKey(envVar: "QWEN_API_KEY", userDefaultsKey: "qwenAPIKey") else {
            throw PolishError.noAPIKey
        }

        let model = ProcessInfo.processInfo.environment["QWEN_MODEL"] ?? "qwen3.5-plus"

        let systemPrompt = generateSystemPrompt()

        let requestBody: [String: Any] = [
            "model": model,
            "temperature": 0.2,
            "max_tokens": 1024,
            "enable_thinking": false,   // disable CoT; qwen3.5 thinking mode is ~100s, not suitable for STT polish
            "messages": [
                ["role": "system", "content": systemPrompt],
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
        guard let apiKey = resolvedAPIKey(envVar: "OPENAI_API_KEY", userDefaultsKey: "openaiAPIKey") else {
            throw PolishError.noAPIKey
        }

        let model = ProcessInfo.processInfo.environment["OPENAI_MODEL"] ?? "gpt-4o-mini"
        let systemPrompt = generateSystemPrompt()

        let requestBody: [String: Any] = [
            "model": model,
            "temperature": 0.2,
            "max_completion_tokens": 1024,
            "messages": [
                ["role": "system", "content": systemPrompt],
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
        guard let apiKey = resolvedAPIKey(envVar: "ANTHROPIC_API_KEY", userDefaultsKey: "anthropicAPIKey") else {
            throw PolishError.noAPIKey
        }

        let model = ProcessInfo.processInfo.environment["ANTHROPIC_MODEL"] ?? "claude-sonnet-4-5-20250929"
        let systemPrompt = generateSystemPrompt()

        let requestBody: [String: Any] = [
            "model": model,
            "max_tokens": 1024,
            "temperature": 0.2,
            "system": systemPrompt,
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
