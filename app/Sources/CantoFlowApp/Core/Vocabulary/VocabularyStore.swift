import Foundation

/// Category of vocabulary entry
enum VocabCategory: String, Codable, CaseIterable {
    case place = "place"           // 地名
    case action = "action"         // 動作
    case person = "person"         // 人名
    case slang = "slang"           // 口語/俗語
    case food = "food"             // 食物
    case transport = "transport"   // 交通
    case company = "company"       // 公司
    case product = "product"       // 產品
    case tech = "tech"             // 技術
    case other = "other"           // 其他

    var displayName: String {
        switch self {
        case .place: return "地名"
        case .action: return "動作"
        case .person: return "人名"
        case .slang: return "口語/俗語"
        case .food: return "食物"
        case .transport: return "交通"
        case .company: return "公司"
        case .product: return "產品"
        case .tech: return "技術"
        case .other: return "其他"
        }
    }
}

/// A vocabulary entry
struct VocabEntry: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var term: String
    var pronunciationHint: String?
    var category: VocabCategory
    var notes: String?

    enum CodingKeys: String, CodingKey {
        case id, term
        case pronunciationHint = "pronunciation_hint"
        case category, notes
    }
}

/// Personal vocabulary storage
struct PersonalVocabulary: Codable {
    var entries: [VocabEntry]
    var maxCapacity: Int = 500

    init(entries: [VocabEntry] = []) {
        self.entries = entries
    }

    var isFull: Bool {
        return entries.count >= maxCapacity
    }

    mutating func add(_ entry: VocabEntry) -> Bool {
        guard entries.count < maxCapacity else { return false }
        entries.append(entry)
        return true
    }

    mutating func remove(id: UUID) {
        entries.removeAll { $0.id == id }
    }

    mutating func update(_ entry: VocabEntry) {
        if let index = entries.firstIndex(where: { $0.id == entry.id }) {
            entries[index] = entry
        }
    }

    func search(query: String) -> [VocabEntry] {
        guard !query.isEmpty else { return entries }
        let lowercased = query.lowercased()
        return entries.filter {
            $0.term.lowercased().contains(lowercased) ||
            ($0.notes?.lowercased().contains(lowercased) ?? false) ||
            ($0.pronunciationHint?.lowercased().contains(lowercased) ?? false)
        }
    }

    /// Get all terms as a list for prompt injection
    var terms: [String] {
        return entries.map { $0.term }
    }
}

struct VocabularyImportPreview: Identifiable {
    let id = UUID()
    let sourceURL: URL
    let totalEntries: Int
    let importableEntries: [VocabEntry]
    let duplicateTerms: [String]
    let blankTerms: Int
    let capacityRemaining: Int

    var importableCount: Int { importableEntries.count }
    var duplicateCount: Int { duplicateTerms.count }
    var willFillToCapacity: Bool { importableCount < totalEntries - duplicateCount - blankTerms }
}

/// Hong Kong common vocabulary (read-only, bundled with app)
struct HKCommonVocabulary: Codable {
    var places: [String]       // 地名
    var mtrStations: [String]  // 港鐵站
    var surnames: [String]     // 姓氏
    var slang: [String]        // 口語/俗語
    var food: [String]         // 食物
    var transport: [String]    // 交通

    /// Get all terms as a flat list
    var allTerms: [String] {
        return places + mtrStations + surnames + slang + food + transport
    }

    /// Get terms by category with enable flags
    func getTerms(
        includePlaces: Bool = true,
        includeMTR: Bool = true,
        includeSurnames: Bool = true,
        includeSlang: Bool = true,
        includeFood: Bool = true,
        includeTransport: Bool = true
    ) -> [String] {
        var result: [String] = []
        if includePlaces { result.append(contentsOf: places) }
        if includeMTR { result.append(contentsOf: mtrStations) }
        if includeSurnames { result.append(contentsOf: surnames) }
        if includeSlang { result.append(contentsOf: slang) }
        if includeFood { result.append(contentsOf: food) }
        if includeTransport { result.append(contentsOf: transport) }
        return result
    }
}

/// Manages vocabulary loading, saving, and injection
final class VocabularyStore {
    static let shared = VocabularyStore()

    /// Personal vocabulary
    private(set) var personal = PersonalVocabulary()

    /// Hong Kong common vocabulary
    private(set) var hkCommon: HKCommonVocabulary?

    /// Whether HK common vocabulary is enabled
    var hkCommonEnabled = true

    /// HK vocab category toggles
    var hkPlacesEnabled = true
    var hkMTREnabled = true
    var hkSurnamesEnabled = true
    var hkSlangEnabled = true
    var hkFoodEnabled = true
    var hkTransportEnabled = true

    /// Personal vocabulary file path
    private var personalVocabURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let cantoFlow = appSupport.appendingPathComponent("CantoFlow", isDirectory: true)
        try? FileManager.default.createDirectory(at: cantoFlow, withIntermediateDirectories: true)
        return cantoFlow.appendingPathComponent("personal_vocab.json")
    }

    private init() {
        loadPersonalVocabulary()
        loadHKCommonVocabulary()
    }

    // MARK: - Personal Vocabulary

    func loadPersonalVocabulary() {
        guard FileManager.default.fileExists(atPath: personalVocabURL.path) else { return }

        do {
            let data = try Data(contentsOf: personalVocabURL)
            personal = try JSONDecoder().decode(PersonalVocabulary.self, from: data)
            print("Loaded \(personal.entries.count) personal vocabulary entries")
        } catch {
            print("Failed to load personal vocabulary: \(error)")
        }
    }

    func savePersonalVocabulary() {
        do {
            let data = try JSONEncoder().encode(personal)
            try data.write(to: personalVocabURL)
        } catch {
            print("Failed to save personal vocabulary: \(error)")
        }
    }

    func exportPersonalVocabulary(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(personal)
        try data.write(to: url, options: .atomic)
    }

    func previewImportPersonalVocabulary(from url: URL) throws -> VocabularyImportPreview {
        let data = try Data(contentsOf: url)
        let imported = try JSONDecoder().decode(PersonalVocabulary.self, from: data)

        var existingTerms = Set(personal.entries.map {
            $0.term.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        })
        var importableEntries: [VocabEntry] = []
        var duplicateTerms: [String] = []
        var blankTerms = 0
        let capacityRemaining = max(0, personal.maxCapacity - personal.entries.count)

        for entry in imported.entries {
            let normalized = entry.term.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if normalized.isEmpty {
                blankTerms += 1
                continue
            }
            if existingTerms.contains(normalized) {
                duplicateTerms.append(entry.term)
                continue
            }
            if importableEntries.count < capacityRemaining {
                importableEntries.append(entry)
                existingTerms.insert(normalized)
            }
        }

        return VocabularyImportPreview(
            sourceURL: url,
            totalEntries: imported.entries.count,
            importableEntries: importableEntries,
            duplicateTerms: duplicateTerms,
            blankTerms: blankTerms,
            capacityRemaining: capacityRemaining
        )
    }

    @discardableResult
    func importPersonalVocabulary(from url: URL) throws -> Int {
        let preview = try previewImportPersonalVocabulary(from: url)
        var addedCount = 0

        for entry in preview.importableEntries {
            if personal.add(entry) {
                addedCount += 1
            }
        }

        if addedCount > 0 {
            savePersonalVocabulary()
        }

        return addedCount
    }

    func addPersonalEntry(_ entry: VocabEntry) -> Bool {
        guard !containsPersonalTerm(entry.term) else { return false }
        let success = personal.add(entry)
        if success {
            savePersonalVocabulary()
        }
        return success
    }

    @discardableResult
    func importHKStarterPack(limit: Int = 100) -> Int {
        importEntries(hkStarterPackEntries, limit: limit)
    }

    @discardableResult
    func importHKStarterPack2(limit: Int = 100) -> Int {
        importEntries(hkStarterPackEntries2, limit: limit)
    }

    @discardableResult
    private func importEntries(_ source: [VocabEntry], limit: Int) -> Int {
        var existingTerms = Set(personal.entries.map(\.term))
        var addedCount = 0

        for entry in source.prefix(limit) {
            if personal.isFull {
                break
            }
            if existingTerms.contains(entry.term) {
                continue
            }
            if personal.add(entry) {
                existingTerms.insert(entry.term)
                addedCount += 1
            }
        }

        if addedCount > 0 {
            savePersonalVocabulary()
        }

        return addedCount
    }

    func removePersonalEntry(id: UUID) {
        personal.remove(id: id)
        savePersonalVocabulary()
    }

    func updatePersonalEntry(_ entry: VocabEntry) {
        guard !containsPersonalTerm(entry.term, excluding: entry.id) else { return }
        personal.update(entry)
        savePersonalVocabulary()
    }

    func containsPersonalTerm(_ term: String, excluding id: UUID? = nil) -> Bool {
        let normalized = term.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return false }

        return personal.entries.contains { entry in
            if let id, entry.id == id { return false }
            return entry.term.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == normalized
        }
    }

    // MARK: - HK Common Vocabulary

    func loadHKCommonVocabulary() {
        // Try to load from bundled JSON file
        // In a real app, this would be in the app bundle
        // For now, we'll use embedded data

        hkCommon = createDefaultHKVocabulary()
        print("Loaded HK common vocabulary: \(hkCommon?.allTerms.count ?? 0) terms")
    }

    /// Create default HK vocabulary (embedded)
    private func createDefaultHKVocabulary() -> HKCommonVocabulary {
        return HKCommonVocabulary(
            places: [
                // 地區
                "西環", "上環", "中環", "金鐘", "灣仔", "銅鑼灣", "天后", "炮台山", "北角",
                "鰂魚涌", "太古", "西灣河", "筲箕灣", "杏花邨", "柴灣",
                "尖沙咀", "佐敦", "油麻地", "旺角", "太子", "深水埗", "長沙灣", "荔枝角",
                "美孚", "荔景", "葵芳", "葵興", "大窩口", "荃灣",
                "觀塘", "藍田", "油塘", "調景嶺", "將軍澳", "坑口", "寶琳", "康城",
                "九龍灣", "牛頭角", "彩虹", "鑽石山", "黃大仙", "樂富", "九龍塘",
                "沙田", "大圍", "火炭", "馬鞍山", "大埔", "粉嶺", "上水",
                "元朗", "天水圍", "屯門", "荃灣西", "南昌", "柯士甸", "九龍",
                "石硤尾", "慈雲山", "秀茂坪", "東涌", "赤鱲角",
                // 地標
                "維多利亞港", "維港", "太平山頂", "山頂", "獅子山", "大澳", "赤柱",
                "金紫荊廣場", "海洋公園", "迪士尼樂園", "迪士尼", "淺水灣",
                "星光大道", "天壇大佛", "昂坪", "西貢", "南丫島", "長洲", "坪洲",
                "石澳", "大浪灣", "清水灣", "愉景灣"
            ],
            mtrStations: [
                // 港島線
                "堅尼地城", "香港大學", "西營盤", "上環", "中環", "金鐘", "灣仔", "銅鑼灣",
                "天后", "炮台山", "北角", "鰂魚涌", "太古", "西灣河", "筲箕灣", "杏花邨", "柴灣",
                // 荃灣線
                "荃灣", "大窩口", "葵興", "葵芳", "荔景", "美孚", "荔枝角", "長沙灣",
                "深水埗", "太子", "旺角", "油麻地", "佐敦", "尖沙咀", "金鐘", "中環",
                // 觀塘線
                "黃埔", "何文田", "油麻地", "旺角", "太子", "石硤尾", "九龍塘", "樂富",
                "黃大仙", "鑽石山", "彩虹", "九龍灣", "牛頭角", "觀塘", "藍田", "油塘", "調景嶺",
                // 將軍澳線
                "北角", "鰂魚涌", "油塘", "調景嶺", "將軍澳", "坑口", "寶琳", "康城",
                // 東鐵線
                "金鐘", "會展", "紅磡", "旺角東", "九龍塘", "大圍", "沙田", "火炭",
                "大學", "大埔墟", "太和", "粉嶺", "上水", "落馬洲", "羅湖",
                // 屯馬線
                "屯門", "兆康", "天水圍", "朗屏", "元朗", "錦上路", "荃灣西", "美孚",
                "南昌", "柯士甸", "尖東", "紅磡", "何文田", "土瓜灣", "宋皇臺", "啟德",
                "鑽石山", "顯徑", "大圍", "車公廟", "沙田圍", "第一城", "石門", "大水坑",
                "恆安", "馬鞍山", "烏溪沙",
                // 東涌線
                "香港", "九龍", "奧運", "南昌", "荔景", "青衣", "欣澳", "東涌",
                // 機場快線
                "香港", "九龍", "青衣", "機場", "博覽館",
                // 南港島線
                "金鐘", "海洋公園", "黃竹坑", "利東", "海怡半島"
            ],
            surnames: [
                "陳", "黃", "李", "張", "梁", "王", "劉", "林", "吳", "鄭",
                "何", "周", "楊", "蔡", "曾", "謝", "徐", "朱", "馬", "蕭",
                "郭", "趙", "鄧", "羅", "許", "余", "葉", "潘", "胡", "方"
            ],
            slang: [
                // 常用口語
                "搞掂", "得閒", "收皮", "嬲", "攰", "唔該", "冇問題", "揸主意",
                "傾偈", "食嘢", "飲嘢", "瞓覺", "返工", "放工", "收工", "OT",
                "好嘢", "正嘢", "勁", "掂", "OK", "冇嘢", "唔緊要", "唔使客氣",
                "等陣", "遲啲", "即刻", "而家", "頭先", "琴日", "聽日", "後日",
                "點解", "點樣", "邊度", "邊個", "乜嘢", "幾時", "幾多", "幾耐",
                "係咪", "係咁", "唔係", "咁樣", "噉", "呢度", "嗰度", "嗰邊",
                "仲有", "仲係", "仲未", "已經", "快啲", "慢慢", "小心",
                // 俚語
                "屈機", "串爆", "HEA", "Hea", "Chur", "chur", "爆肝",
                "躺平", "擺爛", "伏", "中伏", "老笠", "打工仔", "老細",
                "放飛機", "甩底", "食檸檬", "派膠", "好L", "好撚",
                "on9", "ON9", "on nine", "傻仔", "痴線", "黐線", "癲",
                "嘈", "嘈喧巴閉", "好煩", "煩到死", "頂唔順",
                "醒目", "叻", "好叻", "勁叻", "醒", "蠢", "懵", "懵豬"
            ],
            food: [
                // 茶餐廳
                "菠蘿油", "奶茶", "鴛鴦", "凍檸茶", "熱檸茶", "檸水", "檸蜜",
                "西多士", "蛋撻", "雞批", "叉燒包", "叉燒飯", "燒味飯",
                "公仔麵", "出前一丁", "即食麵", "腸仔麵", "餐蛋麵",
                "常餐", "快餐", "下午茶餐", "特餐", "碟頭飯",
                // 點心
                "蝦餃", "燒賣", "叉燒腸粉", "腸粉", "粉果", "鳳爪",
                "豉汁蒸排骨", "山竹牛肉", "馬拉糕", "蓮蓉包", "奶黃包",
                // 小食
                "魚蛋", "牛雜", "雞蛋仔", "碗仔翅", "格仔餅", "煎釀三寶",
                "咖喱魚蛋", "燒賣", "腸粉", "臭豆腐", "車仔麵",
                // 其他
                "燒鵝", "燒鴨", "白切雞", "油雞", "叉燒", "燒肉",
                "雲吞麵", "牛腩麵", "河粉", "瀨粉", "米粉"
            ],
            transport: [
                // 交通工具
                "港鐵", "MTR", "地鐵", "火車", "東鐵", "西鐵", "屯馬線", "東涌線",
                "巴士", "小巴", "紅Van", "綠Van", "的士", "Taxi", "Uber",
                "電車", "叮叮", "渡輪", "天星小輪", "港外線碼頭",
                "機場快線", "機鐵", "輕鐵", "纜車", "山頂纜車",
                // 道路
                "隧道", "海底隧道", "紅隧", "西隧", "東隧", "獅隧", "大欖隧道",
                "青馬大橋", "汀九橋", "昂船洲大橋", "大橋"
            ]
        )
    }

    private var hkStarterPackEntries: [VocabEntry] {
        let placeTerms = [
            "新蒲崗", "啟德", "九龍城", "土瓜灣", "何文田", "黃埔", "紅磡", "佐敦",
            "太子", "旺角", "深水埗", "長沙灣", "美孚", "荃灣", "葵芳", "青衣",
            "沙田", "大圍", "馬鞍山", "大埔", "元朗", "天水圍", "屯門", "將軍澳", "西貢"
        ].map {
            VocabEntry(term: $0, pronunciationHint: nil, category: .place, notes: "香港常用地名")
        }

        let actionTerms = [
            "開會", "傾偈", "跟進", "覆核", "簽收", "批核", "送貨", "對數",
            "對稿", "執貨", "執房", "補鐘", "上堂", "落堂", "開工", "收工",
            "返工", "放工", "交租", "排隊", "拎貨", "上落", "夾單", "交更", "埋單"
        ].map {
            VocabEntry(term: $0, pronunciationHint: nil, category: .action, notes: "香港常用動作")
        }

        let slangTerms = [
            "唔該", "唔緊要", "冇問題", "搞掂", "得閒", "等陣", "遲啲", "即刻",
            "頭先", "而家", "聽日", "後日", "做咩", "點算", "點搞", "係咪",
            "真係", "梗係", "未必", "算啦", "好彩", "唔錯", "好正", "勁正", "痴線", "頂唔順"
        ].map {
            VocabEntry(term: $0, pronunciationHint: nil, category: .slang, notes: "香港常用口頭禪")
        }

        let foodTerms = [
            "菠蘿油", "絲襪奶茶", "鴛鴦", "凍檸茶", "檸蜜", "西多士", "蛋撻", "雞尾包",
            "叉燒包", "餐蛋麵", "公仔麵", "常餐", "下午茶餐", "碟頭飯", "雲吞麵", "牛腩麵",
            "魚蛋", "牛雜", "雞蛋仔", "格仔餅", "車仔麵", "燒賣", "腸粉", "蝦餃", "馬拉糕"
        ].map {
            VocabEntry(term: $0, pronunciationHint: nil, category: .food, notes: "香港常用食物")
        }

        return placeTerms + actionTerms + slangTerms + foodTerms
    }

    private var hkStarterPackEntries2: [VocabEntry] {
        let mallTerms = [
            "AIRSIDE", "Mikiki", "K11", "K11 Musea", "海港城", "朗豪坊", "新城市廣場", "apm",
            "德福廣場", "又一城", "時代廣場", "希慎廣場", "圓方", "MegaBox", "荷里活廣場", "V Walk",
            "PopCorn", "將軍澳廣場", "新都城", "形點", "YOHO Mall", "屯門市廣場", "如心廣場", "新世紀廣場", "奧海城"
        ].map {
            VocabEntry(term: $0, pronunciationHint: nil, category: .place, notes: "香港常用商場")
        }

        let estateTerms = [
            "太古城", "美孚新邨", "黃埔花園", "麗港城", "杏花邨", "嘉湖山莊", "沙田第一城", "新都城",
            "將軍澳中心", "維景灣畔", "新港城", "海怡半島", "康怡花園", "匯景花園", "淘大花園", "德福花園",
            "譽港灣", "翔龍灣", "港灣豪庭", "泓景臺", "君匯港", "昇悅居", "宇晴軒", "柏景灣", "浪澄灣"
        ].map {
            VocabEntry(term: $0, pronunciationHint: nil, category: .place, notes: "香港常用屋苑")
        }

        let roadTerms = [
            "彌敦道", "亞皆老街", "太子道西", "太子道東", "觀塘道", "旺角道", "上海街", "廣東道",
            "窩打老道", "公主道", "獅子山隧道公路", "龍翔道", "青山公路", "沙田路", "大埔公路", "吐露港公路",
            "將軍澳道", "寶琳北路", "康城路", "宏基街", "五芳街", "大有街", "爵祿街", "彩虹道", "協調道"
        ].map {
            VocabEntry(term: $0, pronunciationHint: nil, category: .place, notes: "香港常用街道")
        }

        let officeTerms = [
            "會議室", "辦公室", "前台", "接待處", "茶水間", "影印機", "會議紀錄", "跟單",
            "報價單", "發票", "送貨單", "採購單", "請假", "打卡", "簽到", "交表",
            "入數", "對單", "報銷", "入職", "離職", "交接", "開票", "落單", "出貨"
        ].map {
            VocabEntry(term: $0, pronunciationHint: nil, category: .action, notes: "香港辦公室常用詞")
        }

        return mallTerms + estateTerms + roadTerms + officeTerms
    }

    // MARK: - Prompt Generation

    /// Generate vocabulary terms for Whisper initial_prompt
    /// Maximum ~224 tokens, prioritize personal vocabulary
    func generateWhisperPrompt(maxLength: Int = 500) -> String {
        var terms: [String] = []

        // Add personal vocabulary first (highest priority)
        terms.append(contentsOf: personal.terms)

        // Add HK common vocabulary if enabled
        if hkCommonEnabled, let hk = hkCommon {
            let hkTerms = hk.getTerms(
                includePlaces: hkPlacesEnabled,
                includeMTR: hkMTREnabled,
                includeSurnames: hkSurnamesEnabled,
                includeSlang: hkSlangEnabled,
                includeFood: hkFoodEnabled,
                includeTransport: hkTransportEnabled
            )
            terms.append(contentsOf: hkTerms)
        }

        // Remove duplicates while preserving order
        var seen = Set<String>()
        terms = terms.filter { seen.insert($0).inserted }

        // Build prompt string, respecting max length
        var prompt = "這是一段香港廣東話錄音，請直接輸出繁體中文字，絕對不要輸出任何英文音譯拼音，例如「測試」絕對不要寫成「Thick see」。"
        var currentLength = prompt.count

        for term in terms {
            let addition = term + "、"
            if currentLength + addition.count > maxLength {
                break
            }
            prompt += addition
            currentLength += addition.count
        }

        // Remove trailing separator
        if prompt.hasSuffix("、") {
            prompt = String(prompt.dropLast())
        }

        return prompt
    }

    /// Generate vocabulary section for polish LLM system prompts.
    func generatePolishPromptSection() -> String {
        var sections: [String] = []

        if !personal.entries.isEmpty {
            let grouped = Dictionary(grouping: personal.entries, by: \.category)
            let orderedCategories = VocabCategory.allCases.filter { grouped[$0] != nil }
            var categoryLines: [String] = []

            for category in orderedCategories {
                let terms = grouped[category, default: []]
                    .map { entry -> String in
                        if let notes = entry.notes, !notes.isEmpty {
                            return "\(entry.term)（\(notes)）"
                        }
                        return entry.term
                    }
                    .joined(separator: "、")
                categoryLines.append("- \(category.displayName)：\(terms)")
            }

            sections.append("""
            ---
            以下是用戶的個人詞庫。這些詞的優先級最高：
            1. 若粗稿與詞庫詞條相同、近似、同音、近音，優先修正為詞庫內寫法。
            2. 不要把詞庫中的口語詞改成書面語。
            3. 若詞庫詞條屬專有名詞，除非明顯錯誤，否則應保留該寫法。
            \(categoryLines.joined(separator: "\n"))
            """)
        }

        if hkCommonEnabled, let hk = hkCommon {
            var hkTerms: [String] = []
            if hkPlacesEnabled { hkTerms.append(contentsOf: hk.places.prefix(20)) }
            if hkMTREnabled { hkTerms.append(contentsOf: hk.mtrStations.prefix(20)) }
            if hkSlangEnabled { hkTerms.append(contentsOf: hk.slang.prefix(20)) }

            if !hkTerms.isEmpty {
                sections.append("""
                ---
                以下是香港常用詞彙，可用作校正參考。當粗稿出現近似詞、誤聽詞、音近詞時，優先考慮以下香港常用寫法：
                \(hkTerms.joined(separator: "、"))
                """)
            }
        }

        return sections.joined(separator: "\n")
    }

    /// Backward-compatible alias for older callers.
    func generateClaudePromptSection() -> String {
        generatePolishPromptSection()
    }
}
