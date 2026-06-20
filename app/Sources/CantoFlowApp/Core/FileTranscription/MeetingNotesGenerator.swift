import Foundation

struct MeetingNotesResult {
    let markdown: String
    let formatWarning: Bool
    let provider: AppConfig.PolishProvider
}

/// Generates meeting notes from a whole transcript via the shared LLM client.
/// Uses its own prompt and a 4096 output cap — never the short polish prompt/cap.
final class MeetingNotesGenerator {
    enum GeneratorError: Error, LocalizedError {
        case emptyTranscript
        case transcriptTooLong

        var errorDescription: String? {
            switch self {
            case .emptyTranscript: return "逐字稿是空的，無法生成會議記錄"
            case .transcriptTooLong: return "逐字稿超出目前 LLM 可處理長度；請改用較大 context 的 provider。"
            }
        }
    }

    /// Rough character guard (§16.2) — not a precise token count.
    static let maxTranscriptChars = 200_000

    private let client: LLMCompleting

    init(client: LLMCompleting) {
        self.client = client
    }

    func isAvailable() -> Bool { client.isAvailable() }
    func resolvedProvider() -> AppConfig.PolishProvider { client.resolvedProvider() }

    func generate(transcript: String, filename: String, recordingDate: Date?) async throws -> MeetingNotesResult {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw GeneratorError.emptyTranscript }
        guard trimmed.count <= Self.maxTranscriptChars else { throw GeneratorError.transcriptTooLong }

        let request = LLMCompletionRequest(
            systemPrompt: MeetingNotesPrompt.systemPrompt,
            userPrompt: MeetingNotesPrompt.userPrompt(
                filename: filename, recordingDate: recordingDate, transcript: trimmed
            ),
            temperature: 0.1,
            maxOutputTokens: 4096,
            timeout: 120
        )
        let result = try await client.complete(request)
        return MeetingNotesResult(
            markdown: result.text,
            formatWarning: !MeetingNotesPrompt.hasAllHeadings(result.text),
            provider: result.provider
        )
    }
}
