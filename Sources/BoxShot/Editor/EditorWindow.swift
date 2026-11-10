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
    /// 关窗写回（贴图编辑用）。nil = 普通编辑窗口，关掉就完事。
    private var finishHandler: ((CGImage) -> Void)?

    /// 内容区最小尺寸。工具条本身 ~1100pt 宽，低于 640 横向滚起来太难受；
    /// 高度给画布留 ~350（工具条 62 + 画布 358），再小就只剩一条缝。
    static let minContentSize = NSSize(width: 640, height: 420)

    init(model: AppModel) {
        self.appModel = model
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 640),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "BoxShot 编辑"
        window.isReleasedWhenClosed = false
        // 用户 2026-11-04：「编辑标注窗口能不能拖拉边框改变窗口大小」——
        // 之前 styleMask 里没有 .resizable，四边都拖不动。
        window.contentMinSize = Self.minContentSize
        // 不要全屏：这个窗口是"改完就走"的临时工作区，进全屏既不常见也会把
        // 工具条的横向布局撑得很怪。绿灯保留缩放（zoom）语义就够。
        window.collectionBehavior = [.fullScreenNone]
        super.init(window: window)
        window.delegate = self
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    var isVisible: Bool { window?.isVisible ?? false }

    func show(image: CGImage, shapes: [AnnotationShape] = [],
              diagnostics: (select: UUID, tool: EditorTool)? = nil,
              onFinish: ((CGImage) -> Void)? = nil) {
        guard let window else { return }
        finishHandler = onFinish
        let document = EditorDocument(image: image, shapes: shapes)
        // 诊断入口（--editorbar-handles）用：指定初始工具和选中的形状。
        // 正路上没有这个需求（工具和选中都是用户点出来的），所以只在诊断时传。
        if let diagnostics {
            document.tool = diagnostics.tool
            document.selectedID = diagnostics.select
        }
        doc = document

        // 窗口尺寸：图像显示尺寸（适配屏幕可用区域）+ 工具条高度
        let screenFrame = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let maxW = screenFrame.width - 60
        let maxH = screenFrame.height - 130
        let scale = min(maxW / CGFloat(image.width), maxH / CGFloat(image.height), 1.0)
        let displayW = CGFloat(image.width) * scale
        let displayH = CGFloat(image.height) * scale
        let toolbarHeight: CGFloat = 62
        // 最小宽度 640：工具条本身就占 ~1100pt（13 个工具 + 6 色 + 取色器 + 粗细/字号
        // + 撤销 + 输出组），520 会把「文字工具 + 字号下拉」那一排压到互相挤。
        let contentSize = NSSize(width: max(640, displayW),
                                 height: displayH + toolbarHeight)
        window.setContentSize(contentSize)
        window.center()

        let view = EditorView(doc: document,
                              onCopy: { [weak self] in self?.copyToClipboard() },
                              onSave: { [weak self] in self?.save() },
                              onPin: { [weak self] in self?.pinCurrent() },
                              onOCR: { [weak self] in self?.ocrCurrent() },
                              onClose: { [weak self] in self?.window?.performClose(nil) },
                              // 裁剪后按新尺寸重开文档：坐标、手柄、窗口大小全按新图来
                              onCrop: { [weak self] image, shapes in
                                  // 写回回调要跟着带过去：不然"裁剪完直接关窗"贴图就不更新
                                  self?.show(image: image, shapes: shapes,
                                             onFinish: self?.finishHandler)
                              })
        window.contentView = NSHostingView(rootView: view)
        // 🔴 装在 contentView 之后**再设一次**：换 contentView 会让 SwiftUI 重算容器
        // 约束，前面 init 里那份 contentMinSize 会被盖掉（绿灯缩放也会因此失效）。
        window.contentMinSize = Self.minContentSize

        installEscMonitor()
        // 同历史窗口：macOS 14+ 上旧 activate 不顶事，窗口会落在别的应用后面
        Support.bringToFront(window)
    }

    // ── 输出动作 ─────────────────────────────────────────────

    private func renderedImage() -> CGImage? {
        guard let doc else { return nil }
        return doc.rendered()
    }

    private func copyToClipboard() {
        guard let image = renderedImage() else { return }
        Support.copyImageToClipboard(image)
        appModel?.playFeedbackSound()
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
            appModel?.playFeedbackSound()
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
            // 焦点在"还在窗口里的"文本视图上 = 正在输入文字。
            // 🔴 必须连 `tv.window === window` 一起判：文字框被拆掉后，窗口的
            // firstResponder 可能还指着那个已经脱离层级的 NSTextView，
            // 只看类型会把 ⌫ / Esc 全部误判成"在打字"而放行。
            let editingText = (window.firstResponder as? NSTextView).map { $0.window === window } ?? false
            if event.keyCode == 53 {
                // 🔴 正在输入文字时 Esc 是"取消这段文字"，不是"关窗口"。
                // 文本视图自己会处理 cancelOperation:（并回调 Viewer 的取消），
                // 这里放行就对了 —— 抢掉的话用户打一半按 Esc 整个窗口就没了。
                if editingText { return event }
                window.performClose(nil)
                return nil
            }
            // ⌫ / Delete：删选中标注。
            // 工具条上那个"删除"按钮已按用户要求去掉（"一直显示，去掉"），
            // 但删除能力不能跟着丢 —— 挪到这里，选中标注照样 ⌫ 一下就没。
            if event.keyCode == 51 || event.keyCode == 117 {
                // 焦点在文字框里时 ⌫ 是删字符，别把整条标注吃了
                if editingText { return event }
                let handled = MainActor.assumeIsolated { self.deleteSelectedShape() }
                if handled { return nil }
            }
            return event
        }
    }

    /// 有选中标注就删掉（⌫）。返回是否吃掉这次按键。
    @MainActor
    private func deleteSelectedShape() -> Bool {
        guard let doc, doc.selectedShape != nil else { return false }
        doc.deleteSelected()
        return true
    }

    private func removeEscMonitor() {
        if let monitor = escMonitor {
            NSEvent.removeMonitor(monitor)
            escMonitor = nil
        }
    }

    func windowWillClose(_ notification: Notification) {
        removeEscMonitor()
        // 贴图编辑：关窗就把当前渲染结果写回去。
        // 「完成」/ Esc / 点红点 三条路都会走到这里 —— 对用户来说它们的语义
        // 都是"我看完了"，不该只有点「完成」才写回（那会让 Esc 变成静默丢弃）。
        if let handler = finishHandler, let image = doc?.rendered() {
            handler(image)
        }
        finishHandler = nil
        doc = nil
        appModel?.editorDidClose(self)
    }

    /// 拖边框的下限在这里兜住。
    ///
    /// 🔴 光设 `window.contentMinSize` 不管用：`contentView` 换成 `NSHostingView` 之后，
    /// SwiftUI 会把窗口的最小尺寸按自己的 fitting 尺寸重算，实测能一路拖到 596×286
    /// （工具条被压成一团）。delegate 这一层是最后一道，一定拦得住。
    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        let minFrame = sender.frameRect(forContentRect:
            NSRect(origin: .zero, size: Self.minContentSize)).size
        return NSSize(width: max(frameSize.width, minFrame.width),
                      height: max(frameSize.height, minFrame.height))
    }
}
