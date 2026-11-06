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
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
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
        guard total > 0 else { return false }
        return Double(han) / Double(total) >= 0.15
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

/// 翻译在当前系统上到底能不能用（macOS 15 起才有 Translation 框架）
enum TranslationSupport {
    static var isAvailable: Bool {
        if #available(macOS 15.0, *) { return true }
        return false
    }

    /// 翻译不了时给用户看的说明（不是"错误"，是能力边界）
    static let unavailableNote = "翻译需要 macOS 15 及以上（用的系统自带离线翻译，不联网、不要密钥）"
}
