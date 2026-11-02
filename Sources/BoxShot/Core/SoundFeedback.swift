import AppKit

// ============================================================
// 反馈：提示音
//
// 和 BoxPaste 用同一套系统音效、同一份名字/中文标题，两个应用的
// 设置页看起来才是一家的。用系统音效而不是打包音频文件：每台 Mac 上
// 都有，包也不用变大，更不用处理版权。
// ============================================================

enum SoundFeedback {

    /// 可选的提示音（与 BoxPaste 完全一致，2026-10-22 试听后圈定这 8 个）。
    /// name 是系统音效文件名（/System/Library/Sounds/*.aiff 去扩展名）。
    static let options: [(name: String, title: String)] = [
        ("Blow", "气声轻吹"),
        ("Bottle", "空瓶脆响"),
        ("Funk", "节奏拨弦"),
        ("Glass", "玻璃轻响"),
        ("Hero", "英雄上扬"),
        ("Morse", "电报脉冲"),
        ("Ping", "清脆叮声"),
        ("Purr", "轻柔低鸣"),
    ]

    static let defaultName = "Glass"

    /// 当前可用的音效名集合。读到不在这个集合里的旧值要落回默认，
    /// 否则 Picker 会显示空白。
    static var availableNames: Set<String> { Set(options.map(\.name)) }

    /// 每档音效各自缓存：来回试听不重复加载（NSSound(named:) 有几十毫秒延迟）
    private static var cache: [String: NSSound] = [:]

    private static func sound(named name: String) -> NSSound? {
        if let cached = cache[name] { return cached }
        let created = NSSound(named: NSSound.Name(name))
            ?? NSSound(named: NSSound.Name(defaultName))
        cache[name] = created
        return created
    }

    /// 播一次。名字不认识就走默认音效，实在没有就静默 —— 声音绝不该把主流程搞挂。
    static func play(name: String) {
        guard let sound = sound(named: name) else { return }
        // 连着操作时上一声还没播完，先停再播，避免叠成一团噪音
        if sound.isPlaying { sound.stop() }
        sound.play()
    }

    /// 设置页的「试听」
    static func preview(name: String) {
        play(name: name)
    }
}
