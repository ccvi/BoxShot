import AppKit
import SwiftUI

// ============================================================
// 编辑器窗口：截好的图进来，标注完出去（复制 / 保存 / 贴图 / OCR）
//
// 每次截图新建一个文档实例（底图不同，撤销栈也不同）；
// 窗口复用同一个 NSWindowController，大小按图自适应。
// ============================================================

@MainActor
final class EditorWindowController: NSWindowController, NSWindowDelegate {

    private var doc: EditorDocument?
    private weak var appModel: AppModel?
    private var escMonitor: Any?

    init(model: AppModel) {
        self.appModel = model
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 640),
                              styleMask: [.titled, .closable, .miniaturizable],
                              backing: .buffered, defer: false)
        window.title = "BoxShot 编辑"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    var isVisible: Bool { window?.isVisible ?? false }

    func show(image: CGImage) {
        guard let window else { return }
        let document = EditorDocument(image: image)
        doc = document

        // 窗口尺寸：图像显示尺寸（适配屏幕可用区域）+ 工具条高度
        let screenFrame = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let maxW = screenFrame.width - 60
        let maxH = screenFrame.height - 130
        let scale = min(maxW / CGFloat(image.width), maxH / CGFloat(image.height), 1.0)
        let displayW = CGFloat(image.width) * scale
        let displayH = CGFloat(image.height) * scale
        let toolbarHeight: CGFloat = 62
        let contentSize = NSSize(width: max(520, displayW),
                                 height: displayH + toolbarHeight)
        window.setContentSize(contentSize)
        window.center()

        let view = EditorView(doc: document,
                              onCopy: { [weak self] in self?.copyToClipboard() },
                              onSave: { [weak self] in self?.save() },
                              onPin: { [weak self] in self?.pinCurrent() },
                              onOCR: { [weak self] in self?.ocrCurrent() },
                              onClose: { [weak self] in self?.window?.performClose(nil) })
        window.contentView = NSHostingView(rootView: view)

        installEscMonitor()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // ── 输出动作 ─────────────────────────────────────────────

    private func renderedImage() -> CGImage? {
        guard let doc else { return nil }
        return doc.rendered()
    }

    private func copyToClipboard() {
        guard let image = renderedImage() else { return }
        Support.copyImageToClipboard(image)
        if appModel?.prefs.value.playSound == true { Support.playFeedbackSound() }
    }

    private func save() {
        guard let doc, let image = renderedImage() else { return }
        let prefs = appModel?.prefs.value ?? Preferences()
        let ext = prefs.shotFormat.fileExtension
        let suggestedName = Support.shotFileName(ext: ext)

        if prefs.autoSave, let dirPath = prefs.saveDirectory, !dirPath.isEmpty {
            let directory = URL(fileURLWithPath: dirPath, isDirectory: true)
            let url = Support.uniqueFileURL(in: directory, name: suggestedName)
            write(image: image, format: prefs.shotFormat, to: url)
            return
        }

        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName
        panel.allowedContentTypes = prefs.shotFormat == .png ? [.png] : [.jpeg]
        panel.directoryURL = prefs.saveDirectory.flatMap { URL(fileURLWithPath: $0, isDirectory: true) }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        write(image: image, format: prefs.shotFormat, to: url)
    }

    private func write(image: CGImage, format: ShotFormat, to url: URL) {
        guard let data = ImageEncode.data(image, format: format, jpgQuality: appModel?.prefs.value.jpgQuality ?? 0.9) else {
            presentError("图片编码失败")
            return
        }
        do {
            try data.write(to: url)
            if appModel?.prefs.value.playSound == true { Support.playFeedbackSound() }
        } catch {
            presentError("保存失败：\(error.localizedDescription)")
        }
    }

    private func pinCurrent() {
        guard let image = renderedImage() else { return }
        appModel?.pinImage(image)
    }

    private func ocrCurrent() {
        guard let image = renderedImage() else { return }
        appModel?.runOCR(image: image)
    }

    private func presentError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.runModal()
    }

    // ── Esc 关闭 ─────────────────────────────────────────────

    private func installEscMonitor() {
        removeEscMonitor()
        escMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let window = self.window, event.window === window else { return event }
            if event.keyCode == 53 {
                window.performClose(nil)
                return nil
            }
            return event
        }
    }

    private func removeEscMonitor() {
        if let monitor = escMonitor {
            NSEvent.removeMonitor(monitor)
            escMonitor = nil
        }
    }

    func windowWillClose(_ notification: Notification) {
        removeEscMonitor()
        doc = nil
        appModel?.editorDidClose(self)
    }
}
