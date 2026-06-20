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
            return "No API key found. Set DEEPSEEK_API_KEY, GEMINI_API_KEY, DASHSCOPE_API_KEY/QWEN_API_KEY, OPENAI_API_KEY, or ANTHROPIC_API_KEY."
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
    case mandarin  = "mandarin"

    var displayName: String {
        switch self {
        case .cantonese: return "粵語口語"
        case .formal:    return "繁體中文書面語"
        case .mandarin:  return "簡體普通話"
        }
    }

    var styleDescription: String {
        switch self {
        case .cantonese: return "保留香港粵語口語、常用字同語氣，避免改成書面語。"
        case .formal:    return "繁體中文標準書面語，用詞嚴謹規範。"
        case .mandarin:  return "簡體字輸出，普通話自然口語（大陸講法）。"
        }
    }

    var systemPrompt: String {
        switch self {
        case .cantonese:
            return """
            你是一位精通香港廣東話口語的資深編輯。你的工作是把 ASR 語音轉錄粗稿輕度修正，整理成地道、自然、貼近香港人日常打字的廣東話文字。

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
            10. 刪去說話時的猶豫語、停頓助語詞，例如「誒」「呃」「嗯」「唉」「呢個呢個」，以及無意義的重複（如連續的「即係即係」「嗰個嗰個」）；但必須保留有意義的句末語氣詞，例如「啦」「囉」「喎」「㗎」「呀」「吖」。
            11. 只輸出整理後文字，不要加引號、不要解釋、不要列點、不要輸出「修正後：」。
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
        case .mandarin:
            return """
            你是一位精通中國大陸普通話的資深編輯。請把語音識別粗稿整理成自然、口語化的普通話文字。

            請嚴格遵守以下規則：
            1. 保持原意，不要擴寫，不要總結，不要自行補充資訊。
            2. 用大陸普通話的自然口語表達（例如「的、了、這個、那個、然後、就是、可以」），把粵語字詞改成對應普通話說法，例如「嘅」→「的」、「喺」→「在」、「咗」→「了」、「唔」→「不」、「攞／拎」→「拿」、「搵」→「找」、「係」→「是」、「畀」→「給」。
            3. 保留自然口語語氣，不要改成生硬書面語；這是口語模式，不是公文。
            4. 刪去說話時的猶豫語、停頓助語詞，例如「誒」「呃」「嗯」「唉」，以及無意義的重複（如「就是就是」「那個那個」）。
            5. 修正明顯的語音識別錯字、同音字、近音字、英文音譯拼音，以及不自然的斷句與標點。
            6. 若用戶詞庫或常用詞庫中有對應詞，請優先採用詞庫內的寫法。
            7. 對地名、人名、公司名、產品名等專有名詞採取保守策略：只有在高度確定時才作修正。
            8. 必須輸出簡體中文；若輸入出現繁體字，請轉為簡體字。
            9. 只輸出整理後文字，不要加引號、不要解釋、不要列點、不要輸出「修正後：」。
            """
        }
    }
}

/// LLM-based text polisher supporting DeepSeek, Gemini, Qwen, Anthropic, OpenAI, and local models.
final class TextPolisher {
    private let config: AppConfig

    /// Whether to use vocabulary injection in the system prompt
    var useVocabularyInjection = true

    /// Shared completion transport (provider resolution + HTTP). Polish keeps its
    /// short prompt + 1024 cap; meeting notes uses the same client with its own.
    private lazy var client = LLMCompletionClient(config: config)

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
            以下是 ASR 轉錄粗稿。請按「香港廣東話口語模式」做最小必要修正，並優先跟從詞庫用字。

            粗稿：
            \(rawText)
            """
        case .formal:
            return rawText
        case .mandarin:
            return """
            以下是 ASR 轉錄粗稿。請按「簡體普通話口語模式」整理成自然的普通話，並輸出簡體字。

            粗稿：
            \(rawText)
            """
        }
    }

    /// Polish raw transcribed text using LLM
    /// - Parameter rawText: Raw text from speech recognition
    /// - Returns: PolishResult containing polished text
    func polish(rawText: String) async throws -> PolishResult {
        let startTime = Date()
        let result = try await client.complete(LLMCompletionRequest(
            systemPrompt: generateSystemPrompt(),
            userPrompt: generateUserPrompt(for: rawText),
            temperature: 0.2,
            maxOutputTokens: 1024
        ))
        let durationMs = Int(Date().timeIntervalSince(startTime) * 1000)
        return PolishResult(text: result.text, provider: result.provider, durationMs: durationMs)
    }

    /// Whether any LLM provider is configured (delegates to the shared client).
    func isAvailable() -> Bool {
        return client.isAvailable()
    }
}
