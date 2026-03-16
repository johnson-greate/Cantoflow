namespace CantoFlow.Core;

public static class PromptBuilder
{
    public static string BuildSystemPrompt(string style, string? vocabularySection)
    {
        var prompt = style == "formal" ? FormalPrompt : CantonesePrompt;
        if (!string.IsNullOrWhiteSpace(vocabularySection))
            prompt += "\n" + vocabularySection;
        return prompt;
    }

    public static string BuildUserPrompt(string rawText, string style) => style == "formal"
        ? rawText
        : $"以下是 Whisper 轉錄粗稿。請按「香港廣東話口語模式」做最小必要修正，並優先跟從詞庫用字。\n\n粗稿：\n{rawText}";

    private const string CantonesePrompt = """
        你是一位精通香港廣東話口語的資深編輯。你的工作是把 Whisper 語音轉錄粗稿輕度修正，整理成地道、自然、貼近香港人日常打字的廣東話文字。

        請嚴格遵守以下規則：
        1. 保持原意，不要擴寫，不要總結，不要自行補充資訊。
        2. 這是「廣東話口語模式」，必須優先保留口語說法，不可擅自改成正式書面語。
        3. 只修正明顯的語音識別錯字、同音字、近音字、英文音譯拼音，以及不自然的斷句與標點。
        4. 必須輸出繁體中文；若輸入出現簡體字，請轉為繁體字。
        5. 只輸出整理後文字，不要加引號、不要解釋、不要列點、不要輸出「修正後：」。
        """;

    private const string FormalPrompt = """
        你是一位精通中國大陸標準書面語的資深編輯。請將用戶輸入的語音識別粗文字潤飾為嚴謹、規範的正式書面語。
        1. 保持用戶原意，不要過度改寫
        2. 修正語音識別錯字（按上下文）
        3. 去除語氣詞、口頭禪及方言用詞，改為標準書面語表達
        4. 整理句式及標點
        5. 只輸出整理後文字，不要解釋
        6. 必須以繁體中文輸出，將所有簡體字轉換為繁體字
        """;
}
