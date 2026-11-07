import Foundation

// ============================================================
// OCR 译文的目标语言
//
// 用户口径（2026-11-06）：「给 ocr 增加翻译功能，可以选择翻译成中文或英文（下拉选择）」。
//
// 引擎是**系统自带的 Translation 框架**（macOS 15+，纯离线、免密钥、不联网）：
// 这是唯一符合本仓「零第三方依赖」的翻译途径 —— Google / DeepL 那类都要 key 和网络，
// 打包机与用户机器都得配一遍，等于把这个功能变成"要配置才能用"。
// 代价：macOS 14 上根本没有这个框架，那个版本上不显示翻译控件（不留一个点了没反应的按钮）。
// ============================================================

enum TranslateTarget: String, CaseIterable, Identifiable {
    case chinese
    case english

    var id: String { rawValue }

    /// 下拉菜单里的全名
    var title: String {
        switch self {
        case .chinese: return "中文"
        case .english: return "英文"
        }
    }

    /// 收起状态只显示一个字（样张里就是「英 ⌄」），省工具条宽度
    var short: String {
        switch self {
        case .chinese: return "中"
        case .english: return "英"
        }
    }

    /// 传给 Translation 框架的语言标识。
    /// 中文必须写 `zh-Hans`（简体）：写 `zh` 会被当成"中文"整体，繁体图会译成繁体。
    var languageIdentifier: String {
        switch self {
        case .chinese: return "zh-Hans"
        case .english: return "en"
        }
    }

    var language: Locale.Language { Locale.Language(identifier: languageIdentifier) }

    /// 记住上次选的目标语言（下次识别还是它）
    static let lastTargetKey = "boxshot.lastTranslateTarget"

    static func remembered(_ defaults: UserDefaults = .standard) -> TranslateTarget {
        guard let raw = defaults.string(forKey: lastTargetKey),
              let saved = TranslateTarget(rawValue: raw) else { return .chinese }
        return saved
    }

    /// 首次使用（还没记住过任何选择）时按内容猜一个目标语言。
    ///
    /// 🔴 不能写死一个方向：用户拿 OCR 截英文网页是常态，截中文菜单也是常态。
    /// 一律默认「英文」的话，英文文本翻译成英文 —— 系统框架直接抛
    /// `TranslationError`（实测就是界面上的「翻译失败：Unable to Translate」），
    /// 用户会以为翻译坏了。所以按"文字本身像不像中文"来定反向。
    static func defaultFor(_ text: String) -> TranslateTarget {
        looksChinese(text) ? .english : .chinese
    }

    /// 这段文字是不是中文为主。
    /// 判据：CJK 汉字占比 ≥ 15%（中英混排的技术文章里汉字占比通常也远超这个数，
    /// 而纯英文里偶尔出现的几个汉字达不到）。
    static func looksChinese(_ text: String) -> Bool {
        cjkRatio(text) >= 0.15
    }

    /// 汉字 + 中文标点占"非空白字符"的比例（0…1）
    static func cjkRatio(_ text: String) -> Double {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return 0 }
        var han = 0
        var total = 0
        for scalar in trimmed.unicodeScalars {
            guard !CharacterSet.whitespacesAndNewlines.contains(scalar) else { continue }
            total += 1
            switch scalar.value {
            case 0x4E00...0x9FFF,   // CJK 统一汉字
                 0x3400...0x4DBF,   // 扩展 A
                 0xF900...0xFAFF,   // 兼容汉字
                 0x3000...0x303F:   // 中文标点（，。「」等）
                han += 1
            default:
                break
            }
        }
        guard total > 0 else { return 0 }
        return Double(han) / Double(total)
    }

    /// 源语种：显式给，**不要交给框架自动识别**。
    ///
    /// 🔴 事故（2026-11-07，用户：「OCR 中英文混合时，翻译成中文或英文都失败」）：
    /// `TranslationSession.Configuration(source: nil, …)` 让框架自己认语种，
    /// 纯英文 / 纯中文都还好，**中英混排它认不出来**，直接弹出系统面板
    /// 「The language could not be automatically detected. Select a language to translate from.」，
    /// 我们这边收到的就是 `TranslationError/1 Unable to Translate`（界面上一句「无法翻译」）。
    /// 界面上也没有"选源语言"的地方 —— 用户只看到两个方向都失败。
    /// 自己按字符占比判一下就有确定答案，框架不需要猜。
    static func sourceLanguage(for text: String) -> TranslateTarget {
        looksChinese(text) ? .chinese : .english
    }

    /// 一段（或一行）文字该不该被翻。
    ///
    /// 🔴 原来的判据是 `(target == .chinese) == looksChinese(text)` —— 对**中英混排**是错的：
    /// 中文占多数的技术文档被判成"已经是中文了"，用户想把它整篇变成英文却被告知不用翻。
    /// 现在按"这一行里还有没有目标语言之外的成分"判断：
    /// · 目标中文：这一行几乎没有汉字（< 15%）才值得翻；
    /// · 目标英文：这一行还有汉字就要翻。
    /// 整篇都是目标语言时，`plan` 会给不出可翻块 → 直接提示用户换方向，不惊动框架。
    static func needsTranslation(_ piece: String, into target: TranslateTarget) -> Bool {
        if piece.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return false }
        switch target {
        case .chinese: return cjkRatio(piece) < 0.15
        case .english: return cjkRatio(piece) > 0
        }
    }

    /// 把文本切成"要翻的块"和"原样保留的块"，相邻同类合并。
    ///
    /// 为什么要按行分流而不是整段丢给框架：OCR 出来的中英混排文档，整段翻会出现两种毛病 ——
    /// 要么框架按中文处理、英文句子原样吐回来（等于没翻），要么把中文部分再"翻"一遍。
    /// 按行判断、把连续同类行合成一块，既保住原来的行结构，又只把该翻的送进框架；
    /// 而且每块语种单一，源语言显式给出去就不会再"认不出语种"。
    static func plan(for text: String, into target: TranslateTarget) -> TranslationPlan {
        let lines = text.components(separatedBy: "\n")
        var pieces: [String] = []
        var flags: [Bool] = []
        for line in lines {
            let need = needsTranslation(line, into: target)
            if var last = pieces.last, flags.last == need {
                last += "\n" + line
                pieces[pieces.count - 1] = last
            } else {
                pieces.append(line)
                flags.append(need)
            }
        }
        let needs = zip(pieces, flags).filter { $0.1 }.map { $0.0 }
        return TranslationPlan(pieces: pieces, needsTranslation: flags,
                               source: needs.isEmpty ? nil : sourceLanguage(for: needs.joined(separator: "\n")))
    }

    /// 已经记住过就用记住的；没记住过按内容猜
    static func initial(for text: String, _ defaults: UserDefaults = .standard) -> TranslateTarget {
        guard let raw = defaults.string(forKey: lastTargetKey),
              let saved = TranslateTarget(rawValue: raw) else { return defaultFor(text) }
        return saved
    }

    static func remember(_ target: TranslateTarget, _ defaults: UserDefaults = .standard) {
        defaults.set(target.rawValue, forKey: lastTargetKey)
    }
}

/// 一段文本的翻译方案：哪些块要送进框架、那些块合起来的源语种是什么。
///
/// `source == nil` 表示"整篇已经是目标语言了，没什么可翻" —— 调用方据此直接提示用户，
/// 而不是把同语种的活派给框架（框架只会抛一句看不懂的 Unable to Translate）。
struct TranslationPlan: Equatable {
    /// 按原文顺序切好的块（相邻同类已合并，块内用 \n 连接）
    var pieces: [String]
    /// 与 pieces 一一对应：true = 这一块要翻译，false = 原样保留
    var needsTranslation: [Bool]
    /// 要翻的那批文字的源语种；nil = 没有要翻的
    var source: TranslateTarget?

    var hasWork: Bool { source != nil }
    var pendingTexts: [String] {
        zip(pieces, needsTranslation).filter { $0.1 }.map { $0.0 }
    }
}

/// 翻译在当前系统上到底能不能用（macOS 15 起才有 Translation 框架）
enum TranslationSupport {
    static var isAvailable: Bool {
        if #available(macOS 15.0, *) { return true }
        return false
    }

    /// 翻译不了时给用户看的说明（不是"错误"，是能力边界）
    static let unavailableNote = "翻译需要 macOS 15 及以上（用的系统自带离线翻译，不联网、不要密钥）"
}
