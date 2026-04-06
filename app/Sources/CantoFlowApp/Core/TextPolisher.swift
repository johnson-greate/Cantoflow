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
            return "No API key found. Set GEMINI_API_KEY, DASHSCOPE_API_KEY/QWEN_API_KEY, or OPENAI_API_KEY."
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
        case .cantonese: return "保留香港粵語口語、常用字同語氣，避免改成書面語。"
        case .formal:    return "中國大陸標準書面語，用詞嚴謹規範。"
        }
    }

    var systemPrompt: String {
        switch self {
        case .cantonese:
            return """
            你是一位精通香港廣東話口語的資深編輯。你的工作是把 Whisper 語音轉錄粗稿輕度修正，整理成地道、自然、貼近香港人日常打字的廣東話文字。

            請嚴格遵守以下規則：
            1. 保持原意，不要擴寫，不要總結，不要自行補充資訊。
            2. 這是「廣東話口語模式」，必須優先保留口語說法，不可擅自改成正式書面語。
            3. 例如應優先保留「上落」「攞／拎」「搵日」「埋單／結帳都可但以原句習慣為先」「唔」「喺」「咗」「啦」「囉」「喎」「㗎」等香港常用口語字詞。
            4. 只修正明顯的語音識別錯字、同音字、近音字、英文音譯拼音，以及不自然的斷句與標點。
            5. 除非原文明顯有誤，否則不要把口語詞改成書面詞，例如不要隨便把「攞」改成「拿」、「搵日」改成「改天」、「唔要緊」改成「沒關係」、「飲茶」改成「喝茶」。
            6. 若用戶詞庫或香港常用詞庫中有對應詞，請優先採用詞庫內的寫法；若輸入與詞庫詞條屬同音、近音、常見誤聽，應校正為詞庫詞條。
            7. 對地名、人名、公司名、產品名等專有名詞採取保守策略：只有在高度確定，或詞庫明確提供對應寫法時，才作修正。
            8. 尤其避免把香港地名、商場名、屋苑名、公司名錯改成其他詞。
            9. 必須輸出繁體中文；若輸入出現簡體字，請轉為繁體字。
            10. 只輸出整理後文字，不要加引號、不要解釋、不要列點、不要輸出「修正後：」。
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
            8. 若發現無意義的英文音譯拼音（例如將「測試」誤認為 "Thick see"、"Chack see"、"tixy" 等），請根據上下文自動修正為合理的廣東話中文字（如「測試」）。
            9. 必須以繁體中文輸出，將所有簡體字轉換為繁體字
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
            let vocabSection = VocabularyStore.shared.generatePolishPromptSection()
            if !vocabSection.isEmpty {
                prompt += "\n" + vocabSection
            }
        }

        return prompt
    }

    private func generateUserPrompt(for rawText: String) -> String {
        let raw = UserDefaults.standard.string(forKey: "polishStyle") ?? PolishStyle.cantonese.rawValue
        let style = PolishStyle(rawValue: raw) ?? .cantonese

        switch style {
        case .cantonese:
            return """
            以下是 Whisper 轉錄粗稿。請按「香港廣東話口語模式」做最小必要修正，並優先跟從詞庫用字。

            粗稿：
            \(rawText)
            """
        case .formal:
            return rawText
        }
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
        case .gemini:
            polishedText = try await callGemini(text: rawText)
        case .qwen:
            polishedText = try await callQwen(text: rawText)
        case .openai:
            polishedText = try await callOpenAI(text: rawText)
        case .anthropic:
            polishedText = try await callAnthropic(text: rawText)
        case .local:
            polishedText = try await callLocal(text: rawText)
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
    /// Environment variables take precedence; falls back to UserDefaults.
    private func resolvedAPIKey(envVars: [String], userDefaultsKeys: [String]) -> String? {
        for envVar in envVars {
            if let envKey = ProcessInfo.processInfo.environment[envVar],
               !envKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return envKey.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        for key in userDefaultsKeys {
            if let stored = UserDefaults.standard.string(forKey: key),
               !stored.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return stored.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return nil
    }

    private func resolvedQwenAPIKey() -> String? {
        resolvedAPIKey(
            envVars: ["DASHSCOPE_API_KEY", "QWEN_API_KEY"],
            userDefaultsKeys: ["dashscopeAPIKey", "qwenAPIKey"]
        )
    }

    private func resolvedGeminiAPIKey() -> String? {
        resolvedAPIKey(
            envVars: ["GEMINI_API_KEY"],
            userDefaultsKeys: ["geminiAPIKey"]
        )
    }

    /// Resolve which provider to use based on config and available API keys.
    /// Checks both environment variables and UserDefaults (Settings UI keys).
    private func resolveProvider() -> AppConfig.PolishProvider {
        switch config.polishProvider {
        case .gemini:
            return resolvedGeminiAPIKey() != nil ? .gemini : .none
        case .qwen:
            return resolvedQwenAPIKey() != nil ? .qwen : .none
        case .openai:
            return resolvedAPIKey(envVars: ["OPENAI_API_KEY"], userDefaultsKeys: ["openaiAPIKey"]) != nil ? .openai : .none
        case .anthropic:
            return resolvedAPIKey(envVars: ["ANTHROPIC_API_KEY"], userDefaultsKeys: ["anthropicAPIKey"]) != nil ? .anthropic : .none
        case .local:
            return resolvedLocalEndpoint() != nil ? .local : .none
        case .none:
            return .none
        case .auto:
            // Priority: Gemini > Qwen > OpenAI > Anthropic > Local
            if resolvedGeminiAPIKey() != nil {
                return .gemini
            } else if resolvedQwenAPIKey() != nil {
                return .qwen
            } else if resolvedAPIKey(envVars: ["OPENAI_API_KEY"], userDefaultsKeys: ["openaiAPIKey"]) != nil {
                return .openai
            } else if resolvedAPIKey(envVars: ["ANTHROPIC_API_KEY"], userDefaultsKeys: ["anthropicAPIKey"]) != nil {
                return .anthropic
            } else if resolvedLocalEndpoint() != nil {
                return .local
            } else {
                return .none
            }
        }
    }

    /// Check if polishing is available (API key exists in env or UserDefaults)
    func isAvailable() -> Bool {
        return resolveProvider() != .none
    }

    // MARK: - Gemini API

    private func callGemini(text: String) async throws -> String {
        guard let apiKey = resolvedGeminiAPIKey() else {
            throw PolishError.noAPIKey
        }

        let model = ProcessInfo.processInfo.environment["GEMINI_MODEL"] ?? "gemini-2.5-flash"
        let systemPrompt = generateSystemPrompt()

        let requestBody: [String: Any] = [
            "system_instruction": [
                "parts": [
                    ["text": systemPrompt]
                ]
            ],
            "contents": [
                [
                    "role": "user",
                    "parts": [
                        ["text": generateUserPrompt(for: text)]
                    ]
                ]
            ],
            "generationConfig": [
                "temperature": 0.2,
                "maxOutputTokens": 1024
            ]
        ]

        let jsonData = try JSONSerialization.data(withJSONObject: requestBody)
        let encodedModel = model.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? model
        var request = URLRequest(url: URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(encodedModel):generateContent")!)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = jsonData
        request.timeoutInterval = 10

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
              let candidates = json["candidates"] as? [[String: Any]],
              let firstCandidate = candidates.first,
              let content = firstCandidate["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]] else {
            throw PolishError.invalidResponse
        }

        let polished = parts
            .compactMap { $0["text"] as? String }
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !polished.isEmpty else {
            throw PolishError.emptyResult
        }

        return polished
    }

    // MARK: - Qwen API (DashScope OpenAI-compatible)

    private func callQwen(text: String) async throws -> String {
        guard let apiKey = resolvedQwenAPIKey() else {
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
                ["role": "user", "content": generateUserPrompt(for: text)]
            ]
        ]

        let jsonData = try JSONSerialization.data(withJSONObject: requestBody)

        var request = URLRequest(url: URL(string: "https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = jsonData
        request.timeoutInterval = 10

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
        guard let apiKey = resolvedAPIKey(envVars: ["OPENAI_API_KEY"], userDefaultsKeys: ["openaiAPIKey"]) else {
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
                ["role": "user", "content": generateUserPrompt(for: text)]
            ]
        ]

        let jsonData = try JSONSerialization.data(withJSONObject: requestBody)

        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = jsonData
        request.timeoutInterval = 10

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
        guard let apiKey = resolvedAPIKey(envVars: ["ANTHROPIC_API_KEY"], userDefaultsKeys: ["anthropicAPIKey"]) else {
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
                            "text": generateUserPrompt(for: text)
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
        request.timeoutInterval = 10

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

    // MARK: - Local LLM (OpenAI-compatible: Ollama, LM Studio, llama.cpp, etc.)

    /// Resolve the local LLM endpoint URL from env var or UserDefaults.
    /// Returns nil if no endpoint is configured.
    private func resolvedLocalEndpoint() -> String? {
        if let envVal = ProcessInfo.processInfo.environment["LOCAL_LLM_ENDPOINT"],
           !envVal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return envVal.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let stored = UserDefaults.standard.string(forKey: "localLLMEndpoint"),
           !stored.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return stored.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }

    private func callLocal(text: String) async throws -> String {
        guard let endpoint = resolvedLocalEndpoint(),
              let url = URL(string: endpoint) else {
            throw PolishError.noAPIKey
        }

        let model = ProcessInfo.processInfo.environment["LOCAL_LLM_MODEL"]
            ?? UserDefaults.standard.string(forKey: "localLLMModel")
            ?? ""
        let systemPrompt = generateSystemPrompt()

        var requestBody: [String: Any] = [
            "temperature": 0.2,
            "max_tokens": 1024,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": generateUserPrompt(for: text)]
            ]
        ]
        // Only include "model" if explicitly set — Ollama requires it, but some
        // servers auto-select when omitted.
        if !model.isEmpty {
            requestBody["model"] = model
        }

        let jsonData = try JSONSerialization.data(withJSONObject: requestBody)

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = jsonData
        request.timeoutInterval = 30  // local models can be slower than cloud

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
}
