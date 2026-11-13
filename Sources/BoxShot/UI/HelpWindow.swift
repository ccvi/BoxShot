import AppKit
import SwiftUI

// ============================================================
// 应用内帮助（设置 → 关于 → 帮助文档）
//
// 用户 2026-11-13 第一版要求「把链接放在关于那里」，随后明确：
// 「帮助文档不能是 github 的文档链接，要本地的」。
// 所以不走浏览器 —— 文档打包进 .app（`Contents/Resources/help.md`），
// 关于页那个入口打开的是**应用内的这个窗口**。
//
// 为什么自己写一个小解析器，而不是把文档硬编码成 SwiftUI 视图：
//   · 正文仍然是 markdown（`docs/help.md` 是唯一来源，改文档不用改代码）；
//   · 只用系统自带的 `AttributedString(markdown:)` 处理**行内**样式（粗体 / 代码），
//     块级结构（标题 / 列表 / 引用 / 分隔线）自己切 —— 这两件事它本来就分工明确；
//   · 零第三方依赖（本仓铁律），也不引 WebKit 去渲染一份本地 HTML。
//
// 🔴 文档里不要用 Markdown 表格：这里的渲染器不认（表格会退化成一行竖线）。
//    需要列清单就用列表写，`--selftest` 有一条盯着这个约定。
// ============================================================

/// 帮助文档的一个块（块级结构；行内样式在渲染时再解析）
enum HelpBlock: Equatable {
    case heading(level: Int, text: String)
    case paragraph(String)
    case bullet(String)
    case numbered(Int, String)
    case quote(String)
    case divider
}

/// 带序号的块。`HelpBlock` 自己不做 Hashable/Identifiable ——
/// 位置就是身份，同一段文字可能出现两次（比如两个「截图」小标题）。
struct HelpItem: Identifiable, Equatable {
    let id: Int
    let block: HelpBlock
}

enum HelpMarkup {

    /// 把 markdown 正文切成块。
    ///
    /// 只认这一份文档实际用到的语法：`#`…`####` 标题、`-` 列表、`1.` 有序列表、
    /// `>` 引用、`---` 分隔线，其余按段落累积（连续行合并成一段）。
    /// 行内（`**粗体**`、`` `代码` ``）不在这里处理 —— 交给 `AttributedString(markdown:)`。
    static func parse(_ text: String) -> [HelpItem] {
        var items: [HelpItem] = []
        var paragraph: [String] = []

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            items.append(HelpItem(id: items.count,
                                  block: .paragraph(paragraph.joined(separator: " "))))
            paragraph.removeAll()
        }
        func append(_ block: HelpBlock) {
            flushParagraph()
            items.append(HelpItem(id: items.count, block: block))
        }

        for rawLine in text.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)

            if line.isEmpty {
                flushParagraph()
                continue
            }
            if line == "---" || line == "***" || line == "___" {
                append(.divider)
                continue
            }
            if let heading = headingOf(line) {
                append(.heading(level: heading.level, text: heading.text))
                continue
            }
            if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("+ ") {
                append(.bullet(String(line.dropFirst(2))))
                continue
            }
            if let numbered = numberedOf(line) {
                append(.numbered(numbered.number, numbered.text))
                continue
            }
            if line.hasPrefix("> ") {
                append(.quote(String(line.dropFirst(2))))
                continue
            }
            paragraph.append(line)
        }
        flushParagraph()
        return items
    }

    /// `## 标题` → (2, "标题")；不是标题行返回 nil。
    /// 🔴 `#` 后面必须跟空格：`#BoxShot` 是正文里的井号，不是标题。
    static func headingOf(_ line: String) -> (level: Int, text: String)? {
        guard line.hasPrefix("#") else { return nil }
        let hashes = line.prefix { $0 == "#" }
        guard (1...4).contains(hashes.count) else { return nil }
        let rest = line.dropFirst(hashes.count)
        guard rest.hasPrefix(" ") else { return nil }
        return (hashes.count, String(rest.dropFirst()).trimmingCharacters(in: .whitespaces))
    }

    /// `3. 第三步` → (3, "第三步")。数字后必须跟 `. `，否则（比如 `4.25%`）不算列表。
    static func numberedOf(_ line: String) -> (number: Int, text: String)? {
        let digits = line.prefix { $0.isNumber }
        guard !digits.isEmpty, let number = Int(digits) else { return nil }
        let rest = line.dropFirst(digits.count)
        guard rest.hasPrefix(". ") else { return nil }
        return (number, String(rest.dropFirst(2)))
    }

    /// 行内样式：`**粗体**`、`` `代码` ``、`[文字](链接)`。
    /// 解析失败就原样显示 —— 帮助文档不该因为一个星号没配对上就变成空白。
    static func inline(_ text: String) -> AttributedString {
        (try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }
}

/// 帮助正文：读 bundle 里的 `help.md`（打包时从 `docs/help.md` 复制进来）。
enum HelpText {

    /// 文档读不到时的兜底：宁可给一句人话，也不给一个空白窗口
    static let fallback = """
    # BoxShot

    帮助文档没有随应用一起安装（打包时漏了 `docs/help.md`）。

    你仍然可以从菜单栏图标里用所有功能；需要文档的话，重新安装一次完整版本即可。
    """

    static var body: String {
        guard let url = Bundle.main.url(forResource: "help", withExtension: "md"),
              let text = try? String(contentsOf: url, encoding: .utf8),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return fallback
        }
        return text
    }

    static var items: [HelpItem] { HelpMarkup.parse(body) }
}

// MARK: - 窗口

@MainActor
final class HelpWindowController: NSWindowController, NSWindowDelegate {

    var onClose: (() -> Void)?

    /// 窗口尺寸：720 × 560。帮助是"读"的界面，宽度要够一行放得下 40 来个汉字
    /// （再宽眼睛要来回扫），高度给到能一次看到两三个小节。
    static let preferredSize = NSSize(width: 720, height: 560)

    init() {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: Self.preferredSize),
                              styleMask: [.titled, .closable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "BoxShot 帮助"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 520, height: 360)
        super.init(window: window)
        window.delegate = self
        window.contentView = NSHostingView(rootView: HelpContentView(items: HelpText.items))
        window.center()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func show() {
        // 和其它窗口同一套前置逻辑（见 Support.bringToFront 的注释）
        Support.bringToFront(window)
    }

    func windowWillClose(_ notification: Notification) {
        onClose?()
    }
}

// MARK: - 渲染

struct HelpContentView: View {
    let items: [HelpItem]

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 9) {
                ForEach(items) { item in
                    block(item.block)
                }
            }
            .padding(.horizontal, 26)
            .padding(.vertical, 22)
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    @ViewBuilder
    private func block(_ block: HelpBlock) -> some View {
        switch block {
        case let .heading(level, text):
            Text(HelpMarkup.inline(text))
                .font(headingFont(level))
                .foregroundStyle(.primary)
                .padding(.top, level <= 2 ? 14 : 6)
                .frame(maxWidth: .infinity, alignment: .leading)

        case let .paragraph(text):
            Text(HelpMarkup.inline(text))
                .font(.system(size: 13))
                .lineSpacing(4)
                .frame(maxWidth: .infinity, alignment: .leading)

        case let .bullet(text):
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text("•").font(.system(size: 13)).foregroundStyle(.secondary)
                Text(HelpMarkup.inline(text))
                    .font(.system(size: 13))
                    .lineSpacing(4)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

        case let .numbered(number, text):
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text("\(number).")
                    .font(.system(size: 13).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 16, alignment: .trailing)
                Text(HelpMarkup.inline(text))
                    .font(.system(size: 13))
                    .lineSpacing(4)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

        case let .quote(text):
            HStack(alignment: .top, spacing: 9) {
                Rectangle()
                    .fill(Color.secondary.opacity(0.35))
                    .frame(width: 3)
                Text(HelpMarkup.inline(text))
                    .font(.system(size: 12.5))
                    .lineSpacing(4)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .fixedSize(horizontal: false, vertical: true)

        case .divider:
            Divider().padding(.vertical, 6)
        }
    }

    /// 标题层级：一级像"书名"，二级是小节，三/四级只是分组
    private func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: return .system(size: 21, weight: .bold)
        case 2: return .system(size: 16, weight: .bold)
        case 3: return .system(size: 13.5, weight: .semibold)
        default: return .system(size: 13, weight: .semibold)
        }
    }
}
