import SwiftUI

#if canImport(Translation)
import Translation

// ============================================================
// OCR 结果窗底部的「翻译 + 中/英下拉」
//
// 用户 2026-11-06 给的样张：按钮在最左（翻译），紧跟一个只显示「英 ⌄」的小下拉，
// 右边才是复制 / 关闭。这里就按这个顺序排。
//
// 为什么用 `.translationTask` 而不是"自己 new 一个 session"：
// `TranslationSession` 没有公开的初始化方法，只能由 SwiftUI 的这个修饰器发下来；
// 而它正好也负责"语言包没装 → 弹系统下载框"这件事，省掉我们自己拼 NSSheet。
// ============================================================

@available(macOS 15.0, *)
struct TranslateBar: View {
    let sourceText: String
    /// 译文；nil = 正在显示原文
    @Binding var translated: String?
    @Binding var target: TranslateTarget

    @State private var configuration: TranslationSession.Configuration?
    @State private var isWorking = false
    @State private var errorText: String?

    var body: some View {
        HStack(spacing: 8) {
            Button(isShowingTranslation ? "原文" : "翻译") { toggle() }
                .disabled(isWorking || sourceText.isEmpty)
                .help(isShowingTranslation ? "切回识别出来的原文"
                                           : "把识别到的文字翻译成\(target.title)")
            Menu {
                ForEach(TranslateTarget.allCases) { item in
                    Button {
                        target = item
                        TranslateTarget.remember(item)
                        // 换了目标语言，上一条提示说的是"上一个方向"，必须清掉
                        // （否则用户选了中文，界面上还挂着「这段文字已经是英文了」）
                        errorText = nil
                        // 已经有一份译文在显示时，换语言就当场重译一遍
                        if isShowingTranslation { startTranslation() }
                    } label: {
                        Text(item == target ? "✓ \(item.title)" : item.title)
                    }
                }
            } label: {
                HStack(spacing: 2) {
                    Text(target.short)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .semibold))
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("翻译成哪种语言")

            if isWorking {
                ProgressView().controlSize(.small).scaleEffect(0.7)
            }
            if let errorText {
                Text(errorText)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        // 配置一变就重跑；首次调用时系统会自己弹「下载语言包」
        .translationTask(configuration) { session in
            await run(session)
        }
    }

    private var isShowingTranslation: Bool { translated != nil }

    private func toggle() {
        if isShowingTranslation {
            translated = nil          // 切回原文（原文一直留着，不做破坏性覆盖）
        } else {
            startTranslation()
        }
    }

    private func startTranslation() {
        errorText = nil
        // 目标语言和原文同语种时**别去问框架**：它会抛 TranslationError，
        // 界面上就是一句看不懂的「翻译失败：Unable to Translate」。
        // 这里直说人话，用户一看就知道该换方向。
        if (target == .chinese) == TranslateTarget.looksChinese(sourceText) {
            errorText = "这段文字已经是\(target.title)了，换个目标语言"
            return
        }
        if var existing = configuration {
            // 同一份配置要"再来一次"，必须 invalidate —— 直接赋等值对象不会重新触发
            existing.invalidate()
            configuration = existing
        } else {
            configuration = .init(source: nil, target: target.language)   // source nil = 自动识别原语种
        }
    }

    private func run(_ session: TranslationSession) async {
        await MainActor.run { isWorking = true; errorText = nil }
        do {
            // 语言包没装时它会弹系统下载框。
            // 🔴 **但它的失败不能当致命错误**：`source: nil`（自动识别语种）时
            // 实测 macOS 26 上 `prepareTranslation()` 抛 TranslationError/1，
            // 而紧接着的 `translations(from:)` **是成功的**。原来在这里 try 完就 catch，
            // 用户看到的是「语言包明明装了却说翻译失败」。所以只记日志，继续往下译。
            try await session.prepareTranslation()
        } catch {
            let ns = error as NSError
            NSLog("[BoxShot][translate] prepare 未通过（继续翻）%@/%d", ns.domain, ns.code)
        }
        do {
            let batch = [TranslationSession.Request(sourceText: sourceText)]
            let responses = try await session.translations(from: batch)
            let result = responses.first?.targetText ?? ""
            await MainActor.run {
                isWorking = false
                if result.isEmpty {
                    errorText = "没有译出内容"
                } else {
                    translated = result
                }
            }
        } catch {
            // 诊断：`localizedDescription` 只有一句 "Unable to Translate"，
            // 到底是语种识别失败还是别的原因，只有把 domain/code 打出来才知道。
            let ns = error as NSError
            NSLog("[BoxShot][translate] 翻译失败 domain=%@ code=%d userInfo=%@",
                  ns.domain, ns.code, String(describing: ns.userInfo))
            await MainActor.run {
                isWorking = false
                errorText = "翻译失败：\(error.localizedDescription)"
            }
        }
    }
}
#endif

#if canImport(Translation)
// ============================================================
// 诊断：把 Translation 的每一步单独打出来
//
// 用户机器上语言包是"已安装"，但界面只显示 "Unable to Translate" ——
// 必须分清是 prepareTranslation 失败、translations 失败，还是"自动识别语种"这一步不行。
// 三种配置各试一遍：自动识别 / 显式 en→zh / 显式 zh→en。
// ============================================================

@available(macOS 15.0, *)
struct TranslationProbeView: View {
    static let sample = """
    The Federal Reserve said on Wednesday that it would keep its benchmark interest \
    rate unchanged at a range of 4.25% to 4.5%, while signalling that two cuts may \
    still be appropriate this year if inflation continues to cool. Policymakers noted \
    that the labour market had remained resilient despite higher borrowing costs.
    """

    @State private var config: TranslationSession.Configuration?
    @State private var index = 0

    private static let variants: [(String, Locale.Language?, Locale.Language)] = [
        ("自动识别 → 中文", nil, Locale.Language(identifier: "zh-Hans")),
        ("英文 → 中文", Locale.Language(identifier: "en"), Locale.Language(identifier: "zh-Hans")),
        ("中文 → 英文", Locale.Language(identifier: "zh-Hans"), Locale.Language(identifier: "en")),
    ]

    var body: some View {
        Color.clear.frame(width: 1, height: 1)
            .translationTask(config) { session in
                await run(session)
            }
            .onAppear { next() }
    }

    private func next() {
        guard index < Self.variants.count else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { exit(0) }
            return
        }
        let (name, source, target) = Self.variants[index]
        index += 1
        NSLog("[BoxShot][tprobe] ── %@ ──", name)
        config = TranslationSession.Configuration(source: source, target: target)
    }

    private func run(_ session: TranslationSession) async {
        let (name, _, _) = Self.variants[index - 1]
        let text = Self.sample
        do {
            try await session.prepareTranslation()
            NSLog("[BoxShot][tprobe] %@：prepare 成功", name)
        } catch {
            let ns = error as NSError
            NSLog("[BoxShot][tprobe] %@：prepare 失败 %@/%d", name, ns.domain, ns.code)
        }
        do {
            let out = try await session.translations(from: [.init(sourceText: text)])
            NSLog("[BoxShot][tprobe] %@：翻译成功 → %@", name, out.first?.targetText ?? "（空）")
        } catch {
            let ns = error as NSError
            NSLog("[BoxShot][tprobe] %@：翻译失败 %@/%d", name, ns.domain, ns.code)
        }
        await MainActor.run { next() }
    }
}
#endif
