import XCTest
@testable import CantoFlowApp

private final class FakeLLMClient: LLMCompleting {
    var lastRequest: LLMCompletionRequest?
    var result: LLMCompletionResult
    var available = true
    init(text: String) { result = LLMCompletionResult(text: text, provider: .deepseek) }
    func complete(_ request: LLMCompletionRequest) async throws -> LLMCompletionResult {
        lastRequest = request
        return result
    }
    func resolvedProvider() -> AppConfig.PolishProvider { available ? .deepseek : .none }
    func isAvailable() -> Bool { available }
}

final class MeetingNotesPromptTests: XCTestCase {
    func testSystemPromptHasAntiHallucinationRules() {
        let p = MeetingNotesPrompt.systemPrompt
        XCTAssertTrue(p.contains("不可補充逐字稿沒有的事實"))
        XCTAssertTrue(p.contains("不可猜測講者身份"))
        XCTAssertTrue(p.contains("未指定"))
        XCTAssertTrue(p.contains("只有逐字稿明確要求行動時才列為「待辦事項」"))
    }

    func testHasAllHeadings() {
        let good = "# 會議記錄\n## 會議摘要\n## 主要討論\n## 決議\n## 待辦事項\n## 未決問題"
        XCTAssertTrue(MeetingNotesPrompt.hasAllHeadings(good))
        XCTAssertFalse(MeetingNotesPrompt.hasAllHeadings("## 會議摘要\n## 決議"))
    }

    func testUserPromptCarriesTranscriptAndFilename() {
        let u = MeetingNotesPrompt.userPrompt(filename: "m.m4a", recordingDate: nil, transcript: "大家好")
        XCTAssertTrue(u.contains("m.m4a"))
        XCTAssertTrue(u.contains("大家好"))
        XCTAssertTrue(u.contains("錄音日期：未知"))
    }
}

final class MeetingNotesFormatterTests: XCTestCase {
    func testStripsHeadingsTablesBullets() {
        let md = """
        # 會議記錄

        ## 待辦事項
        | 待辦事項 | 跟進人 | 截止日期 |
        |---|---|---|
        | 跟進報價 | 阿明 | 未指定 |

        ## 未決問題
        - 預算未確認
        """
        let txt = MeetingNotesFormatter.plainText(from: md)
        XCTAssertFalse(txt.contains("#"))
        XCTAssertFalse(txt.contains("|---|"))
        XCTAssertTrue(txt.contains("跟進報價\t阿明\t未指定"))
        XCTAssertTrue(txt.contains("預算未確認"))
        XCTAssertFalse(txt.contains("- 預算"))
    }
}

final class LLMDisclosureTests: XCTestCase {
    func testCloudNeedsDisclosureOnceLocalNever() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: "llmDisclosureConsent.deepseek")
        XCTAssertTrue(LLMDisclosure.needsDisclosure(.deepseek))
        XCTAssertFalse(LLMDisclosure.needsDisclosure(.local))
        LLMDisclosure.recordConsent(.deepseek)
        XCTAssertFalse(LLMDisclosure.needsDisclosure(.deepseek))
        defaults.removeObject(forKey: "llmDisclosureConsent.deepseek")
    }
}

final class MeetingNotesGeneratorTests: XCTestCase {
    func testUsesNotesPromptAnd4096Cap() async throws {
        let fake = FakeLLMClient(text: "# 會議記錄\n## 會議摘要\n摘要\n## 主要討論\n- x\n## 決議\n- y\n## 待辦事項\n| a | b | c |\n## 未決問題\n- z")
        let gen = MeetingNotesGenerator(client: fake)
        let result = try await gen.generate(transcript: "大家好，今日開會。", filename: "m.m4a", recordingDate: nil)
        XCTAssertEqual(fake.lastRequest?.maxOutputTokens, 4096)
        XCTAssertEqual(fake.lastRequest?.temperature, 0.1)
        XCTAssertEqual(fake.lastRequest?.timeout, 120)
        XCTAssertEqual(fake.lastRequest?.systemPrompt, MeetingNotesPrompt.systemPrompt)
        XCTAssertFalse(result.formatWarning)
    }

    func testFlagsFormatWarningWhenHeadingsMissing() async throws {
        let fake = FakeLLMClient(text: "隨便嘅輸出，冇 headings")
        let gen = MeetingNotesGenerator(client: fake)
        let result = try await gen.generate(transcript: "內容", filename: "m.m4a", recordingDate: nil)
        XCTAssertTrue(result.formatWarning)
    }

    func testEmptyTranscriptThrows() async {
        let gen = MeetingNotesGenerator(client: FakeLLMClient(text: "x"))
        do {
            _ = try await gen.generate(transcript: "   ", filename: "m.m4a", recordingDate: nil)
            XCTFail("should throw")
        } catch {
            // expected
        }
    }
}
