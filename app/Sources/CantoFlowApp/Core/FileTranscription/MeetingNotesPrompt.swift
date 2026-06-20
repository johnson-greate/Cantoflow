import Foundation

/// Meeting-notes prompt + output contract (docs/transcribe/spec.md §10).
/// Kept separate from UI and from the short polish prompt so the two never mix.
enum MeetingNotesPrompt {
    /// Anti-hallucination system prompt (§10.1).
    static let systemPrompt = """
    你是一位嚴謹的香港繁體中文會議記錄員。請只根據逐字稿整理會議記錄，不可補充逐字稿沒有的事實，不可猜測講者身份、跟進人或期限。

    要求：
    1. 保留重要專有名詞、數字、日期和英文產品名。
    2. 刪除重複語氣詞，但不得扭曲原意。
    3. 只有逐字稿明確形成共識時才列為「決議」。
    4. 只有逐字稿明確要求行動時才列為「待辦事項」。
    5. 跟進人或截止日期沒有明確提及時，填「未指定」，不可自行分配。
    6. 若某部分沒有資料，明確寫「未有明確記錄」，不可省略 section。
    7. 只輸出以下 Markdown，不要加前言、解釋或 code fence。

    # 會議記錄

    ## 會議摘要
    <3–8 點或短段落>

    ## 主要討論
    - <重點>

    ## 決議
    - <決議；若沒有則寫「未有明確決議」>

    ## 待辦事項
    | 待辦事項 | 跟進人 | 截止日期 |
    |---|---|---|
    | <行動> | <明確姓名或未指定> | <明確日期或未指定> |

    ## 未決問題
    - <尚待確認事項；若沒有則寫「未有明確記錄」>
    """

    /// User prompt carrying the transcript (§10.3).
    static func userPrompt(filename: String, recordingDate: Date?, transcript: String) -> String {
        let dateText: String
        if let recordingDate {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd"
            dateText = formatter.string(from: recordingDate)
        } else {
            dateText = "未知"
        }
        return """
        來源檔案：\(filename)
        錄音日期：\(dateText)

        以下是完整逐字稿：

        \(transcript)
        """
    }

    /// The five required `##` sections (§10.4).
    static let requiredHeadings = ["會議摘要", "主要討論", "決議", "待辦事項", "未決問題"]

    /// True if all five sections are present (used to flag a format warning;
    /// content is never discarded when a heading is missing).
    static func hasAllHeadings(_ markdown: String) -> Bool {
        requiredHeadings.allSatisfy { markdown.contains("## \($0)") }
    }
}

/// Converts meeting-notes Markdown to readable plain text for TXT export (FR-068).
enum MeetingNotesFormatter {
    static func plainText(from markdown: String) -> String {
        var lines: [String] = []
        for raw in markdown.components(separatedBy: "\n") {
            var line = raw
            // Drop markdown table separator rows like |---|---|.
            let compact = line.replacingOccurrences(of: " ", with: "")
            if compact.hasPrefix("|"), compact.allSatisfy({ $0 == "|" || $0 == "-" || $0 == ":" }) {
                continue
            }
            // Strip heading markers.
            while line.hasPrefix("#") { line.removeFirst() }
            // Table row → tab-separated cells.
            if line.contains("|") {
                let cells = line.split(separator: "|", omittingEmptySubsequences: true)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                line = cells.joined(separator: "\t")
            }
            // Strip leading bullet markers.
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("- ") {
                line = String(trimmed.dropFirst(2))
            } else {
                line = trimmed
            }
            lines.append(line)
        }
        // Collapse 3+ blank lines.
        return lines.joined(separator: "\n")
            .replacingOccurrences(of: "\n\n\n", with: "\n\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Per-provider one-time cloud disclosure consent (§19.4 / FR-066).
enum LLMDisclosure {
    private static func key(_ provider: AppConfig.PolishProvider) -> String {
        "llmDisclosureConsent.\(provider.rawValue)"
    }

    /// Local provider runs on-device → never needs disclosure.
    static func needsDisclosure(_ provider: AppConfig.PolishProvider) -> Bool {
        guard provider != .local, provider != .none, provider != .auto else { return false }
        return !UserDefaults.standard.bool(forKey: key(provider))
    }

    static func recordConsent(_ provider: AppConfig.PolishProvider) {
        UserDefaults.standard.set(true, forKey: key(provider))
    }
}
