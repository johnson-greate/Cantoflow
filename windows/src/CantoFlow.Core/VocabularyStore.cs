namespace CantoFlow.Core;

/// <summary>
/// Bundled HK vocabulary for Whisper prompt injection and LLM polish hints.
/// Ported from macOS VocabularyStore.swift (read-only starter packs only;
/// personal vocabulary UI is a future task).
/// </summary>
public static class VocabularyStore
{
    // ── Starter Pack 1: places / actions / slang / food ──────────────────────

    private static readonly string[] Pack1Places =
    [
        "新蒲崗","啟德","九龍城","土瓜灣","何文田","黃埔","紅磡","佐敦",
        "太子","旺角","深水埗","長沙灣","美孚","荃灣","葵芳","青衣",
        "沙田","大圍","馬鞍山","大埔","元朗","天水圍","屯門","將軍澳","西貢"
    ];

    private static readonly string[] Pack1Actions =
    [
        "開會","傾偈","跟進","覆核","簽收","批核","送貨","對數",
        "對稿","執貨","執房","補鐘","上堂","落堂","開工","收工",
        "返工","放工","交租","排隊","拎貨","上落","夾單","交更","埋單"
    ];

    private static readonly string[] Pack1Slang =
    [
        "唔該","唔緊要","冇問題","搞掂","得閒","等陣","遲啲","即刻",
        "頭先","而家","聽日","後日","做咩","點算","點搞","係咪",
        "真係","梗係","未必","算啦","好彩","唔錯","好正","勁正","痴線","頂唔順"
    ];

    private static readonly string[] Pack1Food =
    [
        "菠蘿油","絲襪奶茶","鴛鴦","凍檸茶","檸蜜","西多士","蛋撻","雞尾包",
        "叉燒包","餐蛋麵","公仔麵","常餐","下午茶餐","碟頭飯","雲吞麵","牛腩麵",
        "魚蛋","牛雜","雞蛋仔","格仔餅","車仔麵","燒賣","腸粉","蝦餃","馬拉糕"
    ];

    // ── Starter Pack 2: malls / estates / roads / office ─────────────────────

    private static readonly string[] Pack2Malls =
    [
        "AIRSIDE","Mikiki","K11","K11 Musea","海港城","朗豪坊","新城市廣場","apm",
        "德福廣場","又一城","時代廣場","希慎廣場","圓方","MegaBox","荷里活廣場","V Walk",
        "PopCorn","將軍澳廣場","新都城","形點","YOHO Mall","屯門市廣場","如心廣場","奧海城"
    ];

    private static readonly string[] Pack2Estates =
    [
        "太古城","美孚新邨","黃埔花園","麗港城","杏花邨","嘉湖山莊","沙田第一城",
        "將軍澳中心","維景灣畔","新港城","海怡半島","康怡花園","淘大花園","德福花園"
    ];

    private static readonly string[] Pack2Roads =
    [
        "彌敦道","亞皆老街","太子道西","太子道東","觀塘道","旺角道","廣東道",
        "窩打老道","青山公路","沙田路","大埔公路","吐露港公路","將軍澳道"
    ];

    private static readonly string[] Pack2Office =
    [
        "會議室","辦公室","前台","接待處","茶水間","會議紀錄","跟單",
        "報價單","發票","送貨單","採購單","請假","打卡","簽到","交表",
        "入數","對單","報銷","入職","離職","交接","開票","落單","出貨"
    ];

    // ── HK Common (inline, mirrors macOS createDefaultHKVocabulary) ───────────

    private static readonly string[] HKSlang =
    [
        "搞掂","得閒","唔該","冇問題","傾偈","食嘢","返工","放工",
        "好嘢","正嘢","勁","掂","冇嘢","唔緊要","等陣","遲啲",
        "即刻","而家","頭先","琴日","聽日","後日","係咪","係咁",
        "唔係","咁樣","噉","呢度","嗰度","仲有","仲係","仲未"
    ];

    private static readonly string[] HKFood =
    [
        "菠蘿油","奶茶","鴛鴦","凍檸茶","西多士","蛋撻","叉燒包","餐蛋麵",
        "公仔麵","常餐","下午茶餐","碟頭飯","雲吞麵","牛腩麵",
        "魚蛋","牛雜","雞蛋仔","格仔餅","車仔麵","腸粉","蝦餃"
    ];

    // ── Public API ────────────────────────────────────────────────────────────

    /// <summary>
    /// All starter-pack terms combined (packs 1 + 2 + HK common slang/food).
    /// Used to build the Whisper --prompt and LLM vocabulary section.
    /// </summary>
    public static IEnumerable<string> AllTerms =>
        Pack1Places.Concat(Pack1Actions).Concat(Pack1Slang).Concat(Pack1Food)
        .Concat(Pack2Malls).Concat(Pack2Estates).Concat(Pack2Roads).Concat(Pack2Office)
        .Concat(HKSlang).Concat(HKFood)
        .Distinct();

    /// <summary>
    /// Builds the Whisper --prompt string (max ~500 chars).
    /// Mirrors macOS VocabularyStore.generateWhisperPrompt().
    /// </summary>
    public static string GenerateWhisperPrompt(int maxLength = 500)
    {
        var prompt = "這是一段香港廣東話錄音，請直接輸出繁體中文字，絕對不要輸出任何英文音譯拼音。";
        foreach (var term in AllTerms)
        {
            var addition = term + "、";
            if (prompt.Length + addition.Length > maxLength) break;
            prompt += addition;
        }
        if (prompt.EndsWith('、'))
            prompt = prompt[..^1];
        return prompt;
    }

    /// <summary>
    /// Builds the vocabulary section injected into the LLM system prompt.
    /// Mirrors macOS VocabularyStore.generatePolishPromptSection().
    /// </summary>
    public static string GeneratePolishPromptSection() => """
        ---
        以下是香港常用詞彙，可用作校正參考。當粗稿出現近似詞、誤聽詞、音近詞時，優先考慮以下香港常用寫法：
        地名：新蒲崗、啟德、九龍城、土瓜灣、何文田、黃埔、紅磡、將軍澳、西貢、沙田、大圍、元朗、天水圍、屯門
        口語：搞掂、得閒、唔該、冇問題、傾偈、頂唔順、痴線、唔緊要、係咪、梗係
        食物：菠蘿油、絲襪奶茶、鴛鴦、蛋撻、餐蛋麵、公仔麵、魚蛋、牛雜、雞蛋仔、腸粉、蝦餃
        商場：海港城、朗豪坊、時代廣場、圓方、MegaBox、apm、K11
        """;
}
