import XCTest
@testable import CantoFlowApp

final class LLMProviderResolverTests: XCTestCase {
    func testAutoPriorityOrder() {
        XCTAssertEqual(LLMProviderResolver.autoOrder, [.deepseek, .gemini, .qwen, .openai, .anthropic, .local])
    }

    func testAutoPicksHighestAvailable() {
        XCTAssertEqual(LLMProviderResolver.resolve(selected: .auto, available: [.qwen, .openai, .deepseek]), .deepseek)
        XCTAssertEqual(LLMProviderResolver.resolve(selected: .auto, available: [.qwen, .openai]), .qwen)
        XCTAssertEqual(LLMProviderResolver.resolve(selected: .auto, available: [.local]), .local)
        XCTAssertEqual(LLMProviderResolver.resolve(selected: .auto, available: []), .none)
    }

    func testExplicitSelectionRespectsAvailability() {
        XCTAssertEqual(LLMProviderResolver.resolve(selected: .openai, available: [.openai]), .openai)
        XCTAssertEqual(LLMProviderResolver.resolve(selected: .openai, available: [.deepseek]), .none)
        XCTAssertEqual(LLMProviderResolver.resolve(selected: .none, available: [.deepseek]), .none)
    }
}

/// Characterization: these assert the EXACT request shape that push-to-talk
/// polish has always sent (1024 cap, DeepSeek thinking disabled, Qwen
/// enable_thinking false, per-provider params/urls). Do not relax.
final class NotesProviderResolutionTests: XCTestCase {
    func testNotesProviderFollowsOrOverridesPolish() {
        let d = UserDefaults.standard
        defer {
            d.removeObject(forKey: AppConfig.polishProviderDefaultsKey)
            d.removeObject(forKey: AppConfig.notesProviderDefaultsKey)
        }
        let config = AppConfig(projectRoot: URL(fileURLWithPath: "/tmp"))
        d.set(AppConfig.PolishProvider.deepseek.rawValue, forKey: AppConfig.polishProviderDefaultsKey)

        d.removeObject(forKey: AppConfig.notesProviderDefaultsKey)
        XCTAssertEqual(config.activeNotesProvider, .deepseek, "unset → follow polish")

        d.set("follow", forKey: AppConfig.notesProviderDefaultsKey)
        XCTAssertEqual(config.activeNotesProvider, .deepseek)

        d.set(AppConfig.PolishProvider.local.rawValue, forKey: AppConfig.notesProviderDefaultsKey)
        XCTAssertEqual(config.activeNotesProvider, .local, "explicit override")
    }
}

final class LLMRequestSpecTests: XCTestCase {
    private func polishRequest() -> LLMCompletionRequest {
        LLMCompletionRequest(systemPrompt: "SYS", userPrompt: "USR", temperature: 0.2, maxOutputTokens: 1024)
    }

    private func build(_ p: AppConfig.PolishProvider, model: String = "m", cred: String = "k", _ req: LLMCompletionRequest? = nil) -> LLMRequestSpec.Built {
        LLMRequestSpec.build(provider: p, credential: cred, model: model, request: req ?? polishRequest())!
    }

    func testDeepSeekDisablesThinkingAnd1024Cap() {
        let b = build(.deepseek)
        XCTAssertEqual(b.url.absoluteString, "https://api.deepseek.com/chat/completions")
        XCTAssertEqual(b.body["max_tokens"] as? Int, 1024)
        XCTAssertEqual(b.body["temperature"] as? Double, 0.2)
        XCTAssertEqual((b.body["thinking"] as? [String: String])?["type"], "disabled")
        XCTAssertEqual(b.headers["Authorization"], "Bearer k")
        XCTAssertEqual(b.timeout, 10)
    }

    func testQwenDisablesThinking() {
        let b = build(.qwen)
        XCTAssertEqual(b.url.host, "dashscope.aliyuncs.com")
        XCTAssertEqual(b.body["enable_thinking"] as? Bool, false)
        XCTAssertEqual(b.body["max_tokens"] as? Int, 1024)
    }

    func testOpenAIUsesMaxCompletionTokens() {
        let b = build(.openai)
        XCTAssertEqual(b.body["max_completion_tokens"] as? Int, 1024)
        XCTAssertNil(b.body["max_tokens"])
    }

    func testAnthropicHeadersAndSystem() {
        let b = build(.anthropic)
        XCTAssertEqual(b.headers["x-api-key"], "k")
        XCTAssertEqual(b.headers["anthropic-version"], "2023-06-01")
        XCTAssertEqual(b.body["system"] as? String, "SYS")
        XCTAssertEqual(b.body["max_tokens"] as? Int, 1024)
    }

    func testGeminiGenerationConfigAndKeyHeader() {
        let b = build(.gemini, model: "gemini-2.5-flash")
        XCTAssertEqual(b.headers["x-goog-api-key"], "k")
        XCTAssertTrue(b.url.absoluteString.contains("gemini-2.5-flash:generateContent"))
        let gc = b.body["generationConfig"] as? [String: Any]
        XCTAssertEqual(gc?["maxOutputTokens"] as? Int, 1024)
    }

    func testLocalOmitsModelWhenEmptyAndUses30sTimeout() {
        let withModel = build(.local, model: "llama", cred: "http://localhost:11434/v1/chat/completions")
        XCTAssertEqual(withModel.body["model"] as? String, "llama")
        XCTAssertEqual(withModel.timeout, 30)
        let noModel = build(.local, model: "", cred: "http://localhost:11434/v1/chat/completions")
        XCTAssertNil(noModel.body["model"])
    }

    func testNotesUsesOwnCapNotPolishCap() {
        let notes = LLMCompletionRequest(systemPrompt: "S", userPrompt: "U", temperature: 0.1, maxOutputTokens: 4096, timeout: 120)
        let b = LLMRequestSpec.build(provider: .deepseek, credential: "k", model: "m", request: notes)!
        XCTAssertEqual(b.body["max_tokens"] as? Int, 4096)
        XCTAssertEqual(b.body["temperature"] as? Double, 0.1)
        XCTAssertEqual(b.timeout, 120)
    }
}

final class LLMResponseParserTests: XCTestCase {
    private func data(_ s: String) -> Data { Data(s.utf8) }

    func testOpenAIStyle() throws {
        let d = data(#"{"choices":[{"message":{"content":"  hello  "}}]}"#)
        XCTAssertEqual(try LLMResponseParser.parse(provider: .deepseek, data: d), "hello")
        XCTAssertEqual(try LLMResponseParser.parse(provider: .qwen, data: d), "hello")
        XCTAssertEqual(try LLMResponseParser.parse(provider: .local, data: d), "hello")
    }

    func testGeminiStyle() throws {
        let d = data(#"{"candidates":[{"content":{"parts":[{"text":"abc"},{"text":"def"}]}}]}"#)
        XCTAssertEqual(try LLMResponseParser.parse(provider: .gemini, data: d), "abcdef")
    }

    func testAnthropicStyle() throws {
        let d = data(#"{"content":[{"type":"text","text":"hi there"}]}"#)
        XCTAssertEqual(try LLMResponseParser.parse(provider: .anthropic, data: d), "hi there")
    }

    func testEmptyThrows() {
        let d = data(#"{"choices":[{"message":{"content":"   "}}]}"#)
        XCTAssertThrowsError(try LLMResponseParser.parse(provider: .openai, data: d))
    }

    func testInvalidThrows() {
        XCTAssertThrowsError(try LLMResponseParser.parse(provider: .openai, data: data("not json")))
    }
}
