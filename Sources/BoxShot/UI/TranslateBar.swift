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
    /// 勾了「保留原文」→ 逐句对照（原文在上、译文在下）
    @Binding var keepOriginal: Bool
    /// 对照用的"一行原文 + 一行译文"（非对照模式为 nil）
    @Binding var pairs: [BilingualPair]?

    /// 逐行送翻时每批多少条。整篇一次塞进去在长文本上要等很久，
    /// 分批能让每一轮往返都短，出问题也只影响一批。
    private static let batchSize = 40

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

            // 保留原文：勾上就变成逐句对照（原文在上、译文在下），不勾是整段替换。
            // 状态写回 UserDefaults —— 这是使用习惯，每次重开结果窗都要重勾很烦。
            Toggle("保留原文", isOn: Binding(
                get: { keepOriginal },
                set: { value in
                    keepOriginal = value
                    TranslateTarget.rememberKeepOriginal(value)
                    errorText = nil
                    // 已经译过了：勾/取消勾都得重跑一次 —— 对照要"一行对一行"的数据，
                    // 整段译文里没有这个结构，硬拆会把行数对错。
                    if isShowingTranslation { startTranslation() }
                }))
            .toggleStyle(.checkbox)
            .controlSize(.small)
            .fixedSize()
            .help("原文在上、译文在下，逐句对照；复制时也一并带上原文")

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
            pairs = nil               // 上一次的对照数据留着会让复制串内容
        } else {
            startTranslation()
        }
    }

    private func startTranslation() {
        errorText = nil
        let plan = TranslateTarget.plan(for: sourceText, into: target)
        // 整篇已经是目标语言（一个字都不用翻）时**别去问框架**：同语种它只会抛
        // TranslationError，界面上就是一句看不懂的「翻译失败：无法翻译」。
        guard plan.hasWork, let source = plan.source else {
            errorText = "这段文字已经是\(target.title)了，换个目标语言"
            return
        }
        // 🔴 源语种**显式给**，不能让框架自己认：中英混排时它认不出来，会弹
        // 「The language could not be automatically detected」并要求用户选源语言，
        // 我们这边只收到 Unable to Translate —— 用户看到的就是「两个方向都失败」。
        if var existing = configuration {
            // 同一对语言要"再来一次"，必须 invalidate —— 直接赋等值对象不会重新触发；
            // 换了方向则要把 source / target 一起改掉。
            existing.invalidate()
            existing.source = source.language
            existing.target = target.language
            configuration = existing
        } else {
            configuration = .init(source: source.language, target: target.language)
        }
    }

    private func run(_ session: TranslationSession) async {
        await MainActor.run { isWorking = true; errorText = nil }
        let plan = TranslateTarget.plan(for: sourceText, into: target)
        guard plan.hasWork else {
            await MainActor.run {
                isWorking = false
                errorText = "这段文字已经是\(target.title)了，换个目标语言"
            }
            return
        }
        do {
            // 语言包没装时它会弹系统下载框。
            // 🔴 **但它的失败不能当致命错误**：`prepareTranslation()` 在自动识别/首次启动等
            // 情形下会抛 TranslationError/1，而紧接着的 `translations(from:)` **是成功的**。
            // 原来在这里 try 完就 catch，用户看到的是「语言包明明装了却说翻译失败」。
            try await session.prepareTranslation()
        } catch {
            let ns = error as NSError
            NSLog("[BoxShot][translate] prepare 未通过（继续翻）%@/%d", ns.domain, ns.code)
        }
        do {
            if keepOriginal {
                // 对照模式：**逐行**送翻（去重后分批），回来才能一行对一行。
                // 这里不能复用下面那套"相邻同类行合并成块"的方案：一块回来是多行，
                // 再按 \n 拆回去并不可靠 —— 框架合并/拆句时行数就对不上，配错行比不配对更糟。
                let pending = TranslateTarget.linesNeedingTranslation(sourceText, into: target)
                var byOriginal: [String: String] = [:]
                var start = 0
                while start < pending.count {
                    let slice = Array(pending[start..<min(start + Self.batchSize, pending.count)])
                    let requests = slice.map { TranslationSession.Request(sourceText: $0) }
                    let responses = try await session.translations(from: requests)
                    for response in responses { byOriginal[response.sourceText] = response.targetText }
                    start += Self.batchSize
                }
                let built = TranslateTarget.bilingualPairs(sourceText, into: target,
                                                           translations: byOriginal)
                let joined = TranslateTarget.joinedTranslation(built)
                await MainActor.run {
                    isWorking = false
                    if joined.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        errorText = "没有译出内容"
                    } else {
                        pairs = built
                        translated = joined
                    }
                }
                return
            }

            // 只把"要翻的块"送进去，一次批量。每块语种单一，不会再把混排丢给框架去猜。
            let requests = plan.pendingTexts.map { TranslationSession.Request(sourceText: $0) }
            let responses = try await session.translations(from: requests)
            // 按 sourceText 回填（不依赖返回顺序），再按原文顺序拼回去
            var byOriginal: [String: String] = [:]
            for response in responses { byOriginal[response.sourceText] = response.targetText }
            var rebuilt: [String] = []
            for (piece, need) in zip(plan.pieces, plan.needsTranslation) {
                rebuilt.append(need ? (byOriginal[piece] ?? piece) : piece)
            }
            let result = rebuilt.joined(separator: "\n")
            await MainActor.run {
                isWorking = false
                if result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    errorText = "没有译出内容"
                } else {
                    pairs = nil            // 整段模式没有逐句结构，别让上一次的对照数据留着
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
    /// 样本：优先读 `/tmp/boxshot-transmix.txt`（喂真实的中英混排文本），否则用内置英文段。
    /// 用户 2026-11-07 报「中英文混合时，翻成中文或英文都失败」，要拿他那份文本复现。
    static var sample: String {
        if let text = try? String(contentsOfFile: "/tmp/boxshot-transmix.txt", encoding: .utf8),
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return text
        }
        return """
        The Federal Reserve said on Wednesday that it would keep its benchmark interest \
        rate unchanged at a range of 4.25% to 4.5%, while signalling that two cuts may \
        still be appropriate this year if inflation continues to cool. Policymakers noted \
        that the labour market had remained resilient despite higher borrowing costs.
        """
    }

    @State private var config: TranslationSession.Configuration?
    @State private var index = 0

    /// 🔴 显式语言对放最前面：`source: nil`（自动识别）在混排文本上会卡住不返回，
    /// 排在前面会把后面几条永远挡住。
    private static let variants: [(String, Locale.Language?, Locale.Language)] = [
        ("显式中 → 英", Locale.Language(identifier: "zh-Hans"), Locale.Language(identifier: "en")),
        ("显式英 → 中", Locale.Language(identifier: "en"), Locale.Language(identifier: "zh-Hans")),
        ("自动识别 → 中文", nil, Locale.Language(identifier: "zh-Hans")),
        ("自动识别 → 英文", nil, Locale.Language(identifier: "en")),
    ]

    /// 结果同时写文件：`NSLog` 在 log show 里不一定捞得到，探针必须自己能交代清楚
    static func logLine(_ text: String) {
        NSLog("[BoxShot][transmix] %@", text)
        let url = URL(fileURLWithPath: "/tmp/boxshot-transmix.log")
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile()
            h.write("\(text)\n".data(using: .utf8)!)
            try? h.close()
        } else {
            try? text.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    var body: some View {
        Color.clear.frame(width: 1, height: 1)
            .translationTask(config) { session in
                await run(session)
            }
            .onAppear { Self.logLine("· onAppear"); next() }
    }

    private func next() {
        Self.logLine("· next() 进入 index=\(index)")
        guard index < Self.variants.count else {
            Self.logLine("· 四种全跑完，退出")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { exit(0) }
            return
        }
        let (name, source, target) = Self.variants[index]
        index += 1
        Self.logLine("── \(name) ── 文本 \(Self.sample.count) 字")
        config = TranslationSession.Configuration(source: source, target: target)
    }

    private func run(_ session: TranslationSession) async {
        let (name, _, _) = Self.variants[index - 1]
        let text = Self.sample
        do {
            try await session.prepareTranslation()
            Self.logLine("\(name)：prepare 成功")
        } catch {
            let ns = error as NSError
            Self.logLine("\(name)：prepare 失败 \(ns.domain)/\(ns.code) \(ns.localizedDescription)")
        }
        do {
            let out = try await session.translations(from: [.init(sourceText: text)])
            let got = out.first?.targetText ?? "（空）"
            Self.logLine("\(name)：翻译成功 前 40 字 → \(got.prefix(40))")
        } catch {
            let ns = error as NSError
            Self.logLine("\(name)：翻译失败 \(ns.domain)/\(ns.code) \(ns.localizedDescription) userInfo=\(ns.userInfo)")
        }
        await MainActor.run { next() }
    }
}
#endif
