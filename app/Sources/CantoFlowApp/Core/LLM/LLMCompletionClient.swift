import Foundation

/// Shared LLM completion request. Polish uses a short prompt + low token cap;
/// meeting notes uses its own prompt + larger cap. `timeout == nil` keeps the
/// provider default (cloud 10s, local 30s) so push-to-talk polish is unchanged.
struct LLMCompletionRequest {
    let systemPrompt: String
    let userPrompt: String
    let temperature: Double
    let maxOutputTokens: Int
    var timeout: TimeInterval? = nil
}

struct LLMCompletionResult {
    let text: String
    let provider: AppConfig.PolishProvider
}

protocol LLMCompleting {
    func complete(_ request: LLMCompletionRequest) async throws -> LLMCompletionResult
    func resolvedProvider() -> AppConfig.PolishProvider
    func isAvailable() -> Bool
}

/// Pure Auto-priority resolution so the order can be unit-tested without env/keys.
enum LLMProviderResolver {
    /// Auto fallback order: DeepSeek → Gemini → Qwen → OpenAI → Anthropic → Local.
    static let autoOrder: [AppConfig.PolishProvider] = [.deepseek, .gemini, .qwen, .openai, .anthropic, .local]

    static func resolve(selected: AppConfig.PolishProvider, available: Set<AppConfig.PolishProvider>) -> AppConfig.PolishProvider {
        switch selected {
        case .none:
            return .none
        case .auto:
            return autoOrder.first(where: { available.contains($0) }) ?? .none
        default:
            return available.contains(selected) ? selected : .none
        }
    }
}

/// Pure builder for the provider HTTP request. Mirrors the original TextPolisher
/// bodies exactly so polish behavior is preserved; characterization-tested.
enum LLMRequestSpec {
    struct Built {
        let url: URL
        let headers: [String: String]
        let body: [String: Any]
        let timeout: TimeInterval
    }

    /// - Parameters:
    ///   - credential: API key for cloud providers; the endpoint URL string for `.local`.
    ///   - model: already-resolved model name (may be empty for local auto-select).
    static func build(
        provider: AppConfig.PolishProvider,
        credential: String,
        model: String,
        request: LLMCompletionRequest
    ) -> Built? {
        let messages: [[String: Any]] = [
            ["role": "system", "content": request.systemPrompt],
            ["role": "user", "content": request.userPrompt]
        ]
        let cloudTimeout = request.timeout ?? 10
        let localTimeout = request.timeout ?? 30

        switch provider {
        case .deepseek:
            return Built(
                url: URL(string: "https://api.deepseek.com/chat/completions")!,
                headers: ["Authorization": "Bearer \(credential)", "Content-Type": "application/json"],
                body: [
                    "model": model,
                    "temperature": request.temperature,
                    "max_tokens": request.maxOutputTokens,
                    "thinking": ["type": "disabled"],
                    "messages": messages
                ],
                timeout: cloudTimeout
            )
        case .qwen:
            return Built(
                url: URL(string: "https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions")!,
                headers: ["Authorization": "Bearer \(credential)", "Content-Type": "application/json"],
                body: [
                    "model": model,
                    "temperature": request.temperature,
                    "max_tokens": request.maxOutputTokens,
                    "enable_thinking": false,
                    "messages": messages
                ],
                timeout: cloudTimeout
            )
        case .openai:
            return Built(
                url: URL(string: "https://api.openai.com/v1/chat/completions")!,
                headers: ["Authorization": "Bearer \(credential)", "Content-Type": "application/json"],
                body: [
                    "model": model,
                    "temperature": request.temperature,
                    "max_completion_tokens": request.maxOutputTokens,
                    "messages": messages
                ],
                timeout: cloudTimeout
            )
        case .anthropic:
            return Built(
                url: URL(string: "https://api.anthropic.com/v1/messages")!,
                headers: [
                    "x-api-key": credential,
                    "anthropic-version": "2023-06-01",
                    "Content-Type": "application/json"
                ],
                body: [
                    "model": model,
                    "max_tokens": request.maxOutputTokens,
                    "temperature": request.temperature,
                    "system": request.systemPrompt,
                    "messages": [
                        ["role": "user", "content": [["type": "text", "text": request.userPrompt]]]
                    ]
                ],
                timeout: cloudTimeout
            )
        case .gemini:
            let encoded = model.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? model
            return Built(
                url: URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(encoded):generateContent")!,
                headers: ["x-goog-api-key": credential, "Content-Type": "application/json"],
                body: [
                    "system_instruction": ["parts": [["text": request.systemPrompt]]],
                    "contents": [["role": "user", "parts": [["text": request.userPrompt]]]],
                    "generationConfig": [
                        "temperature": request.temperature,
                        "maxOutputTokens": request.maxOutputTokens
                    ]
                ],
                timeout: cloudTimeout
            )
        case .local:
            guard let url = URL(string: credential) else { return nil }
            var body: [String: Any] = [
                "temperature": request.temperature,
                "max_tokens": request.maxOutputTokens,
                "messages": messages
            ]
            if !model.isEmpty { body["model"] = model }
            return Built(
                url: url,
                headers: ["Content-Type": "application/json"],
                body: body,
                timeout: localTimeout
            )
        case .auto, .none:
            return nil
        }
    }
}

/// Pure response parser per provider family. Throws PolishError on shape/empty.
enum LLMResponseParser {
    static func parse(provider: AppConfig.PolishProvider, data: Data) throws -> String {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw PolishError.invalidResponse
        }
        let text: String
        switch provider {
        case .deepseek, .qwen, .openai, .local:
            guard let choices = json["choices"] as? [[String: Any]],
                  let message = choices.first?["message"] as? [String: Any],
                  let content = message["content"] as? String else {
                throw PolishError.invalidResponse
            }
            text = content
        case .gemini:
            guard let candidates = json["candidates"] as? [[String: Any]],
                  let content = candidates.first?["content"] as? [String: Any],
                  let parts = content["parts"] as? [[String: Any]] else {
                throw PolishError.invalidResponse
            }
            text = parts.compactMap { $0["text"] as? String }.joined()
        case .anthropic:
            guard let content = json["content"] as? [[String: Any]] else {
                throw PolishError.invalidResponse
            }
            text = content.first(where: { $0["type"] as? String == "text" })?["text"] as? String ?? ""
        case .auto, .none:
            throw PolishError.invalidResponse
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw PolishError.emptyResult }
        return trimmed
    }

    /// Extract a provider error message for non-200s (used for PolishError.apiError).
    static func errorMessage(data: Data, status: Int) -> String {
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let error = json["error"] as? [String: Any],
           let message = error["message"] as? String {
            return message
        }
        return "HTTP \(status)"
    }
}

/// Shared completion client: provider/key resolution + HTTP + parse.
/// Replaces the per-provider request code that used to live in TextPolisher;
/// behavior for polish requests is preserved byte-for-byte.
final class LLMCompletionClient: LLMCompleting {
    private let config: AppConfig

    init(config: AppConfig) {
        self.config = config
    }

    // MARK: - Credential resolution (env precedence, then UserDefaults)

    private func resolvedKey(env: [String], defaults: [String]) -> String? {
        for name in env {
            if let value = ProcessInfo.processInfo.environment[name]?.trimmingCharacters(in: .whitespacesAndNewlines),
               !value.isEmpty { return value }
        }
        for key in defaults {
            if let value = UserDefaults.standard.string(forKey: key)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !value.isEmpty { return value }
        }
        return nil
    }

    private func credential(for provider: AppConfig.PolishProvider) -> String? {
        switch provider {
        case .deepseek: return resolvedKey(env: ["DEEPSEEK_API_KEY"], defaults: ["deepseekAPIKey"])
        case .gemini: return resolvedKey(env: ["GEMINI_API_KEY"], defaults: ["geminiAPIKey"])
        case .qwen: return resolvedKey(env: ["DASHSCOPE_API_KEY", "QWEN_API_KEY"], defaults: ["dashscopeAPIKey", "qwenAPIKey"])
        case .openai: return resolvedKey(env: ["OPENAI_API_KEY"], defaults: ["openaiAPIKey"])
        case .anthropic: return resolvedKey(env: ["ANTHROPIC_API_KEY"], defaults: ["anthropicAPIKey"])
        case .local: return resolvedKey(env: ["LOCAL_LLM_ENDPOINT"], defaults: ["localLLMEndpoint"])
        case .auto, .none: return nil
        }
    }

    private func model(for provider: AppConfig.PolishProvider) -> String {
        let env = ProcessInfo.processInfo.environment
        switch provider {
        case .deepseek: return env["DEEPSEEK_MODEL"] ?? "deepseek-v4-flash"
        case .gemini: return env["GEMINI_MODEL"] ?? "gemini-2.5-flash"
        case .qwen: return env["QWEN_MODEL"] ?? "qwen3.5-plus"
        case .openai: return env["OPENAI_MODEL"] ?? "gpt-4o-mini"
        case .anthropic: return env["ANTHROPIC_MODEL"] ?? "claude-sonnet-4-5-20250929"
        case .local: return env["LOCAL_LLM_MODEL"] ?? UserDefaults.standard.string(forKey: "localLLMModel") ?? ""
        case .auto, .none: return ""
        }
    }

    private func availableProviders() -> Set<AppConfig.PolishProvider> {
        var set: Set<AppConfig.PolishProvider> = []
        for p in LLMProviderResolver.autoOrder where credential(for: p) != nil { set.insert(p) }
        return set
    }

    func resolvedProvider() -> AppConfig.PolishProvider {
        LLMProviderResolver.resolve(selected: config.activePolishProvider, available: availableProviders())
    }

    func isAvailable() -> Bool { resolvedProvider() != .none }

    func complete(_ request: LLMCompletionRequest) async throws -> LLMCompletionResult {
        let provider = resolvedProvider()
        guard provider != .none, let credential = credential(for: provider) else {
            throw PolishError.noAPIKey
        }
        guard let built = LLMRequestSpec.build(
            provider: provider, credential: credential, model: model(for: provider), request: request
        ) else {
            throw PolishError.invalidResponse
        }

        var urlRequest = URLRequest(url: built.url)
        urlRequest.httpMethod = "POST"
        for (key, value) in built.headers { urlRequest.setValue(value, forHTTPHeaderField: key) }
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: built.body)
        urlRequest.timeoutInterval = built.timeout

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: urlRequest)
        } catch {
            throw PolishError.networkError(error)
        }
        guard let http = response as? HTTPURLResponse else { throw PolishError.invalidResponse }
        guard http.statusCode == 200 else {
            throw PolishError.apiError(LLMResponseParser.errorMessage(data: data, status: http.statusCode))
        }
        let text = try LLMResponseParser.parse(provider: provider, data: data)
        return LLMCompletionResult(text: text, provider: provider)
    }
}
