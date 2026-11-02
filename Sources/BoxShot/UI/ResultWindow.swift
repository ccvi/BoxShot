import AppKit
import SwiftUI

// ============================================================
// 识别结果窗口（OCR 文本 / QR 内容）
// ============================================================

@MainActor
final class ResultWindowController: NSWindowController {

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
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func show(kind: ResultKind, copied: Bool = true) {
        guard let window else { return }
        switch kind {
        case .text(let text):
            window.title = copied ? "OCR 识别结果（已复制到剪贴板）" : "OCR 识别结果"
            window.contentView = NSHostingView(rootView: ResultTextView(text: text, showCopy: copied))
        case .payloads(let payloads):
            window.title = "解码结果（已复制到剪贴板）"
            window.contentView = NSHostingView(rootView: ResultPayloadView(payloads: payloads))
        }
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    enum ResultKind {
        case text(String)
        case payloads([String])
    }
}

private struct ResultTextView: View {
    let text: String
    var showCopy: Bool = true

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                Text(text)
                    .font(.system(size: 14))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
            }
            Divider()
            HStack {
                Spacer()
                if showCopy {
                    Button("复制") { Support.copyTextToClipboard(text) }
                        .keyboardShortcut("c", modifiers: .command)
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
