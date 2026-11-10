import AppKit
import SwiftUI

// ============================================================
// 识别结果窗口（OCR 文本 / QR 内容）
// ============================================================

@MainActor
final class ResultWindowController: NSWindowController, NSWindowDelegate {

    /// 关掉就放手（AppModel 把引用清掉）；下次识别会重新建一个
    var onClose: (() -> Void)?

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 420),
                              styleMask: [.titled, .closable],
                              backing: .buffered, defer: false)
        window.title = "识别结果"
        window.isReleasedWhenClosed = false
        // 🔴 结果窗必须**高过截图浮层的所有面板**，否则用户点完「解码」什么都看不到：
        //   · 图像面板是 `.floating`(3)，结果窗用默认 `.normal`(0) 时会被它整个盖住；
        //   · 标注工具条是 `.statusBar`(25)，只提到 4 的话工具条又会横在结果窗上面。
        // 抬到 statusBar 之上一档。它只在用户主动触发识别后才出现、读完就关，
        // 一直浮在最上层是可以接受的代价。
        window.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        super.init(window: window)
        window.delegate = self
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func windowWillClose(_ notification: Notification) {
        onClose?()
    }

    func show(kind: ResultKind, copied: Bool = true) {
        guard let window else { return }
        switch kind {
        case .text(let text, let markdown):
            window.title = copied ? "OCR 识别结果（已复制到剪贴板）" : "OCR 识别结果"
            window.contentView = NSHostingView(rootView: ResultTextView(text: text,
                                                                        showCopy: copied,
                                                                        markdown: markdown))
        case .payloads(let payloads):
            window.title = "解码结果（已复制到剪贴板）"
            window.contentView = NSHostingView(rootView: ResultPayloadView(payloads: payloads))
        }
        window.center()
        Support.bringToFront(window)
    }

    enum ResultKind {
        /// `markdown`：OCR 顺手重排出的 Markdown 表格（非表格图就是 nil）
        case text(String, markdown: String?)
        case payloads([String])
    }
}

private struct ResultTextView: View {
    let text: String
    var showCopy: Bool = true
    var markdown: String? = nil

    /// 译文（nil = 显示原文）。原文**永远留着**，所以"切回原文"不会丢东西。
    @State private var translated: String?
    /// 目标语言：记住过就用记住的，没记住过**按这段文字本身猜**
    /// （英文内容默认译成中文，中文内容默认译成英文 —— 否则会撞上"同语种翻译"失败）
    @State private var target: TranslateTarget

    private var shown: String { translated ?? text }

    init(text: String, showCopy: Bool = true, markdown: String? = nil) {
        self.text = text
        self.showCopy = showCopy
        self.markdown = markdown
        // 目标语言在这里定：`@State` 的初值只能靠 `_target` 传进去
        _target = State(initialValue: TranslateTarget.initial(for: text))
    }

    var body: some View {
        VStack(spacing: 0) {
            if translated != nil {
                HStack(spacing: 6) {
                    Image(systemName: "character.bubble")
                    Text("译文（\(target.title)）").font(.system(size: 11, weight: .medium))
                    Text("原文 \(text.count) 字").font(.system(size: 11)).opacity(0.7)
                    Spacer()
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .padding(.top, 10)
            }
            ScrollView {
                Text(shown)
                    .font(.system(size: 14))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
            }
            Divider()
            HStack(spacing: 8) {
                // 翻译（macOS 15 起才有系统离线翻译框架；14 上干脆不显示，
                // 而不是摆一个点了报错的按钮）
                #if canImport(Translation)
                if #available(macOS 15.0, *) {
                    TranslateBar(sourceText: text, translated: $translated, target: $target)
                }
                #endif
                Spacer(minLength: 12)
                if showCopy {
                    // 复制"当前看到的那份"：显示译文就复制译文，不会偷偷复制原文
                    Button("复制") { Support.copyTextToClipboard(shown) }
                        .keyboardShortcut("c", modifiers: .command)
                }
                // 图里是表格时 OCR 会顺带重排一份 Markdown（粘贴到备忘录 /
                // Typora 直接成表）；不是表格就没有这个按钮。
                // 译文没有 Markdown 版本（表格结构是原文重排出来的），只给原文。
                if let markdown, translated == nil {
                    Button("复制为 Markdown") { Support.copyTextToClipboard(markdown) }
                        .help("按表格结构重排并复制（可粘贴进支持 Markdown 的编辑器）")
                }
                Button("关闭") { NSApp.keyWindow?.close() }
                    .keyboardShortcut(.escape, modifiers: [])
            }
            .padding(12)
        }
    }
}

private struct ResultPayloadView: View {
    let payloads: [String]

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(payloads.enumerated()), id: \.offset) { _, payload in
                        HStack {
                            Image(systemName: "qrcode")
                                .foregroundStyle(.secondary)
                            Text(payload)
                                .font(.system(size: 14, design: .monospaced))
                                .textSelection(.enabled)
                            Spacer()
                            if let url = URL(string: payload),
                               url.scheme == "http" || url.scheme == "https" {
                                Button("打开") { NSWorkspace.shared.open(url) }
                            }
                        }
                        .padding(8)
                        .background(Color(nsColor: .controlBackgroundColor))
                        .cornerRadius(8)
                    }
                }
                .padding(16)
            }
            Divider()
            HStack {
                Spacer()
                Button("复制全部") { Support.copyTextToClipboard(payloads.joined(separator: "\n")) }
                Button("关闭") { NSApp.keyWindow?.close() }
            }
            .padding(12)
        }
    }
}
