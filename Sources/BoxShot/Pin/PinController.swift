import AppKit
import CoreGraphics
import Foundation

// ============================================================
// 贴图（钉图）：把图片/文本变成便签钉在桌面上
//
// 实现取舍：
//   · 文本 / HTML 贴图在**创建时渲染成位图**，之后与图片贴图走同一条
//     窗口链路（拖拽 / 滚轮缩放 / 双击 / 翻转）。代价是文字不可选中，
//     换来的是一份交互代码管所有贴图——1.0.0 先保稳定。
//   · 窗口用无边框 NSPanel + .floating 层级，永远浮在普通窗口上面。
//   · 历史贴图落盘（图片 PNG / 文本 RTF 化的 PNG + 位置索引），
//     重启后可恢复最近 N 张。
// ============================================================

@MainActor
final class PinManager {

    private var pins: [PinWindow] = []
    private var allHidden = false

    /// 贴图请求进编辑器时转给上层（AppModel 装）。贴图本身不知道编辑器在哪。
    var onRequestEdit: ((PinWindow) -> Void)?

    /// 自检用：拿当前贴图列表（新建 / 从历史恢复两条路的接线都得能验到）
    var pinsForDiagnostics: [PinWindow] { pins }

    // ── 贴图入口 ──

    @discardableResult
    func pinImage(_ image: CGImage, opacity: Double, shadow: Bool) -> Bool {
        guard let pin = PinWindow(image: image, opacity: opacity, shadow: shadow) else { return false }
        place(pin)
        return true
    }

    @discardableResult
    func pinFromClipboard(opacity: Double, shadow: Bool) -> Bool {
        let pasteboard = NSPasteboard.general
        if let image = readImage(from: pasteboard) {
            return pinImage(image, opacity: opacity, shadow: shadow)
        }
        if let text = pasteboard.string(forType: .string), !text.isEmpty {
            return pinText(text, opacity: opacity, shadow: shadow)
        }
        if let htmlData = pasteboard.data(forType: .html) {
            if let image = Self.renderHTMLToImage(htmlData) {
                return pinImage(image, opacity: opacity, shadow: shadow)
            }
        }
        return false
    }

    @discardableResult
    func pinText(_ text: String, opacity: Double, shadow: Bool) -> Bool {
        guard let image = Self.renderTextToImage(text) else { return false }
        // 同时留下原文字：内容视图会换成可选中的 NSTextView，位图只用于复制/落盘
        guard let pin = PinWindow(image: image, opacity: opacity, shadow: shadow, text: text) else {
            return false
        }
        place(pin)
        return true
    }

    @discardableResult
    func pinFile(at url: URL, opacity: Double, shadow: Bool) -> Bool {
        let ext = url.pathExtension.lowercased()
        if ["png", "jpg", "jpeg", "gif", "tiff", "bmp", "heic", "webp"].contains(ext) {
            guard let image = NSImage(contentsOf: url)?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return false }
            return pinImage(image, opacity: opacity, shadow: shadow)
        }
        if ["txt", "md", "log", "json", "csv"].contains(ext),
           let text = try? String(contentsOf: url, encoding: .utf8) {
            return pinText(text, opacity: opacity, shadow: shadow)
        }
        if ext == "html" || ext == "htm", let data = try? Data(contentsOf: url) {
            if let image = Self.renderHTMLToImage(data) {
                return pinImage(image, opacity: opacity, shadow: shadow)
            }
        }
        return false
    }

    // ── 批量 ──

    /// 内存诊断用：贴图数量 + 位图总占用（4 字节/像素的原始口径）
    func stats() -> String {
        var totalPixels = 0
        for pin in pins {
            let image = pin.pinnedImage
            totalPixels += image.width * image.height
        }
        let megabytes = Double(totalPixels) * 4 / 1_048_576
        return "\(pins.count) 张 · 位图约 \(String(format: "%.0f", megabytes)) MB"
    }

    func toggleAllVisible() {
        allHidden.toggle()
        for pin in pins {
            if allHidden { pin.hidePin() } else { pin.showPin() }
        }
    }

    func closeAll() {
        for pin in pins { pin.close() }
        pins.removeAll()
        persistIndex()
    }

    private func place(_ pin: PinWindow) {
        // 新贴图错开叠放，别精确盖住上一张
        let offset = CGFloat(pins.count % 8) * 26
        pin.place(at: offset)
        pin.showPin()
        pins.append(pin)
        wire(pin)
        persistIndex()
    }

    /// 把回调接上。新建和「从历史恢复」两条路都必须走这里 ——
    /// 以前恢复那条只接了 onClose，于是恢复出来的贴图右键「编辑贴图」会静默不响应
    /// （`onRequestEdit` 是 nil，`requestEdit()` 什么也不做）。
    private func wire(_ pin: PinWindow) {
        pin.onClose = { [weak self, weak pin] in
            self?.pins.removeAll { $0 === pin }
            self?.persistIndex()
        }
        pin.onStateChanged = { [weak self] in
            self?.persistIndex()
        }
        pin.onRequestEdit = { [weak self] pin in
            self?.onRequestEdit?(pin)
        }
    }

    // ── 剪贴板读取 ──

    private func readImage(from pasteboard: NSPasteboard) -> CGImage? {
        if let data = pasteboard.data(forType: .png) ?? pasteboard.data(forType: .tiff) {
            return NSImage(data: data)?.cgImage(forProposedRect: nil, context: nil, hints: nil)
        }
        if let fileURL = NSPasteboard.general.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])?.first as? URL,
           ["png", "jpg", "jpeg", "gif", "tiff", "bmp", "heic", "webp"].contains(fileURL.pathExtension.lowercased()),
           let image = NSImage(contentsOf: fileURL) {
            return image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        }
        return nil
    }

    // ── 文本 / HTML → 位图 ──

    static func renderTextToImage(_ text: String) -> CGImage? {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 3
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 14),
            .foregroundColor: NSColor.textColor,
            .paragraphStyle: paragraph,
        ]
        let attributed = NSAttributedString(string: text, attributes: attributes)
        return renderAttributed(attributed, backgroundColor: NSColor.textBackgroundColor)
    }

    static func renderHTMLToImage(_ htmlData: Data) -> CGImage? {
        guard let attributed = NSAttributedString(html: htmlData,
                                                  options: [:],
                                                  documentAttributes: nil) else { return nil }
        return renderAttributed(attributed, backgroundColor: .white)
    }

    private static func renderAttributed(_ attributed: NSAttributedString, backgroundColor: NSColor) -> CGImage? {
        let maxWidth: CGFloat = 600
        let margin: CGFloat = 16
        let bounds = attributed.boundingRect(with: CGSize(width: maxWidth, height: .greatestFiniteMagnitude),
                                             options: [.usesLineFragmentOrigin, .usesFontLeading])
        let contentWidth = min(ceil(bounds.width), maxWidth)
        let contentHeight = ceil(bounds.height)
        let width = Int(contentWidth + margin * 2)
        let height = Int(contentHeight + margin * 2)
        guard width > 4, height > 4 else { return nil }

        // 用 NSBitmapImageRep 建位图上下文：不依赖窗口服务器，headless（自检）也能跑
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                         pixelsWide: width * 2, pixelsHigh: height * 2,
                                         bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = NSSize(width: width, height: height)
        NSGraphicsContext.saveGraphicsState()
        guard let ctx = NSGraphicsContext(bitmapImageRep: rep) else {
            NSGraphicsContext.restoreGraphicsState()
            return nil
        }
        NSGraphicsContext.current = ctx

        backgroundColor.setFill()
        NSBezierPath(rect: NSRect(x: 0, y: 0, width: width, height: height)).fill()
        attributed.draw(with: CGRect(x: margin, y: margin,
                                     width: contentWidth, height: contentHeight),
                        options: [.usesLineFragmentOrigin, .usesFontLeading])
        NSGraphicsContext.restoreGraphicsState()
        return rep.cgImage
    }

    // ── 历史持久化 ──

    struct PinRecord: Codable {
        var file: String
        var x: Double
        var y: Double
        var scale: Double
        /// 2 = `scale` 是"相对 1:1 的倍数"（当前口径）。
        /// 旧记录没有这个字段（解码成 nil），那时的 scale 是从 0.5 起算的，
        /// 直接套用会让恢复出来的贴图小一半 —— 见 restoreHistory。
        var v: Int?
        /// 文本贴图的原文（nil = 普通图片贴图）。老记录没有这个键，解码成 nil。
        var text: String?
    }

    static var pinsDirectory: URL {
        Support.appSupportRoot.appendingPathComponent("pins", isDirectory: true)
    }
    private static var indexURL: URL {
        Support.appSupportRoot.appendingPathComponent("pins.json")
    }

    func restoreHistory(limit: Int) {
        let fm = FileManager.default
        guard let data = try? Data(contentsOf: Self.indexURL),
              let records = try? JSONDecoder().decode([PinRecord].self, from: data) else { return }
        for record in records.suffix(limit) {
            let url = Self.pinsDirectory.appendingPathComponent(record.file)
            guard let image = NSImage(contentsOf: url)?.cgImage(forProposedRect: nil, context: nil, hints: nil),
                  let pin = PinWindow(image: image, opacity: 1.0, shadow: true, text: record.text) else { continue }
            // 旧记录（无 v）按 1:1 恢复：它们的 scale 是 0.5 起算的旧口径，
            // 套用会小一半。绝大多数用户从没缩放过，1:1 就是他们看到的样子。
            let scale = record.v == nil ? 1.0 : record.scale
            pin.restore(frameOrigin: CGPoint(x: record.x, y: record.y), scale: scale)
            pins.append(pin)
            wire(pin)
        }
    }

    private func persistIndex() {
        let fm = FileManager.default
        try? fm.createDirectory(at: Self.pinsDirectory, withIntermediateDirectories: true)
        var records: [PinRecord] = []
        for pin in pins {
            guard let record = pin.exportRecord() else { continue }
            records.append(record)
        }
        if let data = try? JSONEncoder().encode(records) {
            try? data.write(to: Self.indexURL, options: .atomic)
        }
    }
}

// ============================================================
// 单张贴图窗口
// ============================================================

final class PinWindow: NSPanel {

    var onClose: (() -> Void)?
    var onStateChanged: (() -> Void)?
    /// 右键「编辑贴图」→ 交给 AppModel 开编辑器（贴图自己不知道编辑器在哪）
    var onRequestEdit: ((PinWindow) -> Void)?

    private var image: CGImage
    /// 内容视图要拿原图（复制图片 / 计算尺寸），开个只读口子
    var pinnedImage: CGImage { image }
    /// 文本贴图的原文。非 nil 时内容视图换成可选中的 NSTextView（用户要求"贴图上的文字可以选择"）
    let text: String?
    // 图片贴图的 OCR 选字层做过一版（1.0.16 中段），用户试过之后明确取消：
    // 「贴图可以选择文字的功能取消掉」—— 图片贴图恢复纯图片，不装选字层。
    private var scale: CGFloat
    var flippedH = false
    var flippedV = false
    private var archivedFile: String?

    /// Retina 适配：截图通常 2x，显示按像素 / backingScale，看起来和来源一致
    private static var baseDisplayScale: CGFloat {
        NSScreen.main?.backingScaleFactor ?? 2
    }

    init?(image: CGImage, opacity: Double, shadow: Bool, text: String? = nil) {
        self.image = image
        self.text = text
        // 🔴 `scale` 是"相对 1:1 显示的倍数"（applyScale 里 baseW × scale），
        // 所以初始值必须是 **1.0**。以前写成 1/baseDisplayScale（= 0.5），
        // 于是窗口一被 applyScale 重排（首次缩放 / 从历史恢复）就变成**一半大**
        // —— 用户看到的是"贴图恢复后变小了一圈"。
        self.scale = 1.0
        super.init(contentRect: NSRect(x: 0, y: 0,
                                       width: CGFloat(image.width) / Self.baseDisplayScale,
                                       height: CGFloat(image.height) / Self.baseDisplayScale),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        setup(opacity: opacity, shadow: shadow)
    }

    private func setup(opacity: Double, shadow: Bool) {
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = shadow
        isMovable = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        // 🔴 文本贴图**不能**套 vibrantDark：`textBackgroundColor` / `textColor` 会跟着
        // 解析成黑底白字，而落盘/复制用的位图是在应用当前外观下渲染的（浅色模式就是白底黑字）
        // —— 两张一对不上，用户看到的就是"眼睛读的和复制出来的不是同一个东西"。
        appearance = text == nil ? NSAppearance(named: .vibrantDark) : nil
        // 文本贴图用可选中的文本视图，图片贴图照旧走 draw 路径
        if let text {
            contentView = PinTextContentView(text: text, window: self)
        } else {
            contentView = PinContentView(image: image, window: self)
        }
        alphaValue = opacity
    }

    // ── 置顶 ──

    /// 贴图默认就在 `.floating`（浮在普通窗口之上）。这个按钮是"取消/恢复"它：
    /// 想让贴图沉到当前应用后面看东西时点一下，再点回来。
    var isOnTop: Bool { level == .floating }

    func toggleOnTop() {
        level = isOnTop ? .normal : .floating
        // level 变了窗口可能要重排，再 orderFront 一次才真的换层
        orderFrontRegardless()
        (contentView as? PinSurfaceView)?.refreshOnTopButton()
        onStateChanged?()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func place(at offset: CGFloat) {
        guard let screen = NSScreen.main else { return }
        let x = screen.frame.midX - frame.width / 2 + offset
        let y = screen.frame.midY - frame.height / 2 + offset
        moveTo(CGPoint(x: x, y: y))
    }

    /// 移动贴图（避免与 NSWindow.setFrameOrigin 同签名）
    func moveTo(_ origin: CGPoint) {
        setFrameOrigin(NSPoint(x: origin.x, y: origin.y))
    }

    func showPin() { makeKeyAndOrderFront(nil) }
    func hidePin() { super.orderOut(nil) }

    // ── 内容操作（内容视图转发过来） ──

    // ── 编辑贴图（右键菜单 → 编辑器 → 关窗写回） ──

    /// 右键「编辑贴图」：把请求交给上层（PinManager → AppModel → 编辑窗口）
    func requestEdit() { onRequestEdit?(self) }

    /// 编辑器关窗时把新图写回来。
    ///
    /// 换的是内容视图而不是往原视图里塞图：`PinContentView` 的尺寸是 init 里按图算的，
    /// 图一变窗口也得跟着变（`applyScale` 会保持左上角不动，符合贴图习惯）。
    /// 🔴 只支持图片贴图：文本贴图靠 `text != nil` 走可选中的 NSTextView，
    /// 换成位图就等于把"贴图上的文字可以选择"这条用户明确要的能力弄丢了。
    func replaceImage(_ newImage: CGImage) {
        guard text == nil, newImage.width > 0, newImage.height > 0 else { return }
        image = newImage
        // 归档 PNG 是按旧图写的，换图必须作废 —— 否则重启恢复出来的是编辑前的画面
        if let old = archivedFile {
            try? FileManager.default.removeItem(at: PinManager.pinsDirectory
                .appendingPathComponent(old))
            archivedFile = nil
        }
        contentView = PinContentView(image: newImage, window: self)
        applyScale()
        onStateChanged?()
    }

    func zoom(by factor: CGFloat) {
        let newScale = min(8.0, max(0.1, scale * factor))
        guard newScale != scale else { return }
        scale = newScale
        applyScale()
    }

    func toggleMirrorH() { flippedH.toggle(); contentView?.needsDisplay = true }
    func toggleMirrorV() { flippedV.toggle(); contentView?.needsDisplay = true }

    func handleDoubleClick() {
        let action = (NSApp.delegate as? AppDelegate)?.model.prefs.value.pinDoubleClick ?? .close
        switch action {
        case .close:
            close()
        case .shrink:
            zoom(by: 0.5)
        case .viewLarge:
            openLargePreview()
        }
    }

    private func openLargePreview() {
        let preview = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 200),
                               styleMask: [.titled, .closable, .resizable],
                               backing: .buffered, defer: false)
        preview.title = "贴图查看"
        let imageView = NSImageView(frame: .zero)
        imageView.image = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        imageView.autoresizingMask = [.width, .height]
        imageView.imageScaling = .scaleProportionallyUpOrDown
        preview.contentView = imageView
        // 按图比例给一个合理初始尺寸
        let ratio = CGFloat(image.height) / max(1, CGFloat(image.width))
        let w = min(1000, CGFloat(image.width) / Self.baseDisplayScale * 1.6)
        preview.setContentSize(NSSize(width: w, height: w * ratio))
        preview.center()
        preview.makeKeyAndOrderFront(nil)
    }

    private func applyScale() {
        let baseW = CGFloat(image.width) / Self.baseDisplayScale
        let baseH = CGFloat(image.height) / Self.baseDisplayScale
        var newFrame = NSRect(x: frame.origin.x, y: frame.origin.y,
                              width: baseW * scale, height: baseH * scale)
        // 缩放时保持左上角不动（贴图习惯）
        newFrame.origin.y = frame.maxY - newFrame.height
        setFrame(newFrame, display: true)
        onStateChanged?()
    }

    /// 滚轮缩放时内容视图读的镜像状态直接走公开属性（flippedH / flippedV）

    // 关闭时必须通知管理器摘掉引用 + 落盘索引，否则数组里挂着僵尸窗口
    override func close() {
        onClose?()
        super.close()
    }

    // ── 持久化 ──

    func restore(frameOrigin: CGPoint, scale savedScale: Double) {
        scale = CGFloat(savedScale)
        applyScale()
        moveTo(frameOrigin)
        showPin()
    }

    func exportRecord() -> PinManager.PinRecord? {
        let fm = FileManager.default
        let dir = PinManager.pinsDirectory
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        if archivedFile == nil {
            // 首次落盘：把图存成 PNG（重名不可能——UUID 文件名）
            archivedFile = "pin-\(UUID().uuidString).png"
            let rep = NSBitmapImageRep(cgImage: image)
            guard let data = rep.representation(using: .png, properties: [:]) else { return nil }
            try? data.write(to: dir.appendingPathComponent(archivedFile!), options: .atomic)
        }
        return PinManager.PinRecord(file: archivedFile!,
                                    x: frame.origin.x, y: frame.origin.y,
                                    scale: Double(scale), v: 2, text: text)
    }

    // 贴图不是标准可激活窗口；但文本贴图必须能成为 key window，
    // 否则 NSTextView 拿不到 first responder —— 选得出来却 ⌘C 复制不了。
    override var canBecomeKey: Bool { text != nil }
}

// ── 贴图内容视图：拖拽 / 缩放 / 双击 / 右键 / 悬停置顶按钮 ──

/// 两张内容视图（图片 / 文本）的公共部分：拖拽、滚轮缩放、双击、右键菜单、
/// 以及**鼠标悬停才露出来的置顶按钮**。悬停才显示是有意的：平时贴图要干净，
/// 按钮常驻会切掉画面右上角一块。
class PinSurfaceView: NSView {

    unowned let window_: PinWindow
    private var onTopButton: NSButton?
    private var hoverArea: NSTrackingArea?

    private var dragStartOrigin: NSPoint?
    /// 按下时的鼠标屏幕坐标（拖拽用屏幕坐标差，见 mouseDragged）
    private var dragStartMouse: NSPoint?

    init(window: PinWindow) {
        self.window_ = window
        super.init(frame: .zero)
        buildOnTopButton()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }

    /// 非 key 窗口里默认**第一下点击会被吞掉**（acceptsFirstMouse 默认 false）：
    /// 贴图点下去没反应、要拖两下才动，一半原因是这个。
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // ── 置顶按钮 ──

    private func buildOnTopButton() {
        let symbol = NSImage(systemSymbolName: "pin.fill", accessibilityDescription: "置顶")
        let button = FirstMouseButton(image: symbol ?? NSImage(),
                                      target: self,
                                      action: #selector(toggleOnTop))
        button.isBordered = false
        button.bezelStyle = .regularSquare
        button.imagePosition = .imageOnly
        button.isHidden = true
        button.wantsLayer = true
        button.layer?.cornerRadius = 11
        button.layer?.masksToBounds = true
        addSubview(button)
        onTopButton = button
        refreshOnTopButton()
    }

    override func layout() {
        super.layout()
        // 按钮钉在右上角（本视图 isFlipped，y 从上算）
        let side: CGFloat = 22
        onTopButton?.frame = NSRect(x: max(4, bounds.width - side - 6), y: 6,
                                    width: side, height: side)
    }

    /// 置顶态：白底 + accent 实心图钉；普通态：半透明黑底 + 白色空心图钉
    func refreshOnTopButton() {
        guard let button = onTopButton else { return }
        let onTop = window_.isOnTop
        button.image = NSImage(systemSymbolName: onTop ? "pin.fill" : "pin",
                               accessibilityDescription: "置顶")
        button.contentTintColor = onTop ? .controlAccentColor : .white
        button.layer?.backgroundColor = (onTop
            ? NSColor.white.withAlphaComponent(0.92)
            : NSColor.black.withAlphaComponent(0.5)).cgColor
        button.toolTip = onTop ? "已置顶（点击取消）" : "置顶显示"
    }

    @objc private func toggleOnTop() { window_.toggleOnTop() }

    // ── 悬停显示 / 隐藏按钮 ──

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area = hoverArea { removeTrackingArea(area) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseEntered(with event: NSEvent) { onTopButton?.isHidden = false }
    override func mouseExited(with event: NSEvent) { onTopButton?.isHidden = true }

    // ── 拖拽 / 缩放 / 双击 ──

    func beginWindowDrag() {
        dragStartOrigin = window_.frame.origin
        dragStartMouse = NSEvent.mouseLocation
    }

    func continueWindowDrag() {
        guard let origin = dragStartOrigin, let start = dragStartMouse else { return }
        let now = NSEvent.mouseLocation
        window_.moveTo(CGPoint(x: origin.x + (now.x - start.x),
                               y: origin.y + (now.y - start.y)))
    }

    /// 返回这一轮拖拽移动了多少点（mouseUp 用来判断"是拖动还是双击"）
    @discardableResult
    func endWindowDrag() -> CGFloat {
        let moved = dragStartOrigin.map { start in
            hypot(window_.frame.origin.x - start.x, window_.frame.origin.y - start.y)
        } ?? 0
        dragStartOrigin = nil
        dragStartMouse = nil
        return moved
    }

    override func mouseDown(with event: NSEvent) {
        beginWindowDrag()
    }

    override func mouseDragged(with event: NSEvent) {
        // 🔴 用**屏幕坐标差**，不要用 `event.deltaX/deltaY`：
        //   · delta 是增量，可 origin 是 mouseDown 时记的、之后没更新 →
        //     写成 `origin + delta` 每帧都把窗口摆回"起点 + 一点点"，看着就是**拖不动**；
        //   · 更坑的是**合成事件（CGEvent）里 delta 恒为 0**，这条路根本验不出来。
        // 屏幕坐标差对两者都成立，也不受"窗口自己在动"的影响
        // （locationInWindow 会随窗口移动而变，越拖越飘）。
        continueWindowDrag()
    }

    override func mouseUp(with event: NSEvent) {
        let moved = endWindowDrag()
        if moved < 3, event.clickCount == 2 {
            window_.handleDoubleClick()
        } else if moved >= 3 {
            window_.onStateChanged?()
        }
    }

    // 滚轮缩放（保持左上角不动；向上滚 = 放大）
    override func scrollWheel(with event: NSEvent) {
        let factor = pow(1.1, event.scrollingDeltaY / 4)
        window_.zoom(by: factor)
    }

    // 右键菜单：置顶 / 翻转 / 复制 / 关闭
    override func menu(for event: NSEvent) -> NSMenu? { buildContextMenu() }

    /// 右键菜单内容。抽出来是为了自检能直接验「图片贴图第一项是编辑贴图、
    /// 文本贴图没有这一项」—— `menu(for:)` 需要一个真鼠标事件，测试里造不出来。
    func buildContextMenu() -> NSMenu {
        let menu = NSMenu()
        // 编辑贴图（1.0.33）：进编辑器加标注，关窗时把结果写回这张贴图。
        // 文本贴图的画面是"文字渲染成的位图"，编辑它意义不大且会把可选中文字换掉，
        // 所以只给图片贴图这一项。
        if window_.text == nil {
            menu.addItem(withTitle: "编辑贴图", action: #selector(editPin), keyEquivalent: "").target = self
            menu.addItem(.separator())
        }
        menu.addItem(withTitle: window_.isOnTop ? "取消置顶" : "置顶显示",
                     action: #selector(menuToggleOnTop), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "水平翻转", action: #selector(flipH), keyEquivalent: "").target = self
        menu.addItem(withTitle: "垂直翻转", action: #selector(flipV), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "复制图片", action: #selector(copyImage), keyEquivalent: "").target = self
        if let text = window_.text, !text.isEmpty {
            menu.addItem(withTitle: "复制全部文字", action: #selector(copyAllText), keyEquivalent: "").target = self
        }
        menu.addItem(withTitle: "关闭贴图", action: #selector(closePin), keyEquivalent: "").target = self
        return menu
    }

    @objc private func menuToggleOnTop() { window_.toggleOnTop() }
    @objc private func editPin() { window_.requestEdit() }
    @objc private func flipH() { window_.toggleMirrorH() }
    @objc private func flipV() { window_.toggleMirrorV() }
    @objc private func copyImage() { Support.copyImageToClipboard(window_.pinnedImage) }
    @objc private func copyAllText() {
        if let text = window_.text { Support.copyTextToClipboard(text) }
    }
    @objc private func closePin() { window_.close() }
}

// ── 图片贴图 ──

final class PinContentView: PinSurfaceView {

    private let image: CGImage

    init(image: CGImage, window: PinWindow) {
        self.image = image
        super.init(window: window)
        frame = NSRect(origin: .zero,
                       size: NSSize(width: CGFloat(image.width) / (NSScreen.main?.backingScaleFactor ?? 2),
                                    height: CGFloat(image.height) / (NSScreen.main?.backingScaleFactor ?? 2)))
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let rect = bounds
        ctx.saveGState()
        // 🔴 本视图 isFlipped = true（左上原点、y 向下），在这个坐标系里直接
        // `ctx.draw(cgImage)` 画出来是**上下颠倒**的 —— 用户看到的就是"贴图是倒的"。
        // 和截图浮层一样要走标准配方：先翻回 y 向上的标准空间再画。
        // 注意顺序：这一步必须在镜像（flippedH / flippedV）之前，
        // 否则"垂直翻转"的含义会跟着反。
        ctx.translateBy(x: 0, y: rect.height)
        ctx.scaleBy(x: 1, y: -1)
        if window_.flippedH {
            ctx.translateBy(x: rect.width, y: 0)
            ctx.scaleBy(x: -1, y: 1)
        }
        if window_.flippedV {
            ctx.translateBy(x: 0, y: rect.height)
            ctx.scaleBy(x: 1, y: -1)
        }
        ctx.interpolationQuality = .high
        let imageRect = NSRect(origin: .zero, size: rect.size)
        ctx.draw(image, in: imageRect)
        ctx.restoreGState()
    }
}

// ── 文本贴图：可选中的文字 ──

/// 文本贴图的容器：画背景 + 装一个可选中的 NSTextView。
/// 拖拽只认**四周的留白边**（12pt），文字区域留给选字 ——
/// 想直接抓住文字拖窗口就按住 ⌘（见 PinSelectableTextView）。
final class PinTextContentView: PinSurfaceView {

    private let textView: PinSelectableTextView

    /// 和 `PinManager.renderTextToImage` 的 `margin` 保持一致：
    /// 位图和文本视图的边距必须一样，否则"选文字"和"复制出来的图"两种观感对不上。
    private static let margin: CGFloat = 12

    init(text: String, window: PinWindow) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 3
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 14),
            .foregroundColor: NSColor.textColor,
            .paragraphStyle: paragraph,
        ]
        textView = PinSelectableTextView(frame: .zero)
        super.init(window: window)
        textView.window_ = window
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.drawsBackground = false
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.textStorage?.setAttributedString(NSAttributedString(string: text, attributes: attributes))
        textView.autoresizingMask = [.width, .height]
        addSubview(textView)
        // 置顶按钮要压在最上面：addSubview 顺序在基类构造里已经加过一次，
        // 这里重新把它提上来（文本视图盖住整块，不提就会把按钮盖掉）
        if let button = subviews.first(where: { $0 is NSButton }) {
            addSubview(button, positioned: .above, relativeTo: textView)
        }
        frame = NSRect(origin: .zero,
                       size: NSSize(width: CGFloat(window.pinnedImage.width) / (NSScreen.main?.backingScaleFactor ?? 2),
                                    height: CGFloat(window.pinnedImage.height) / (NSScreen.main?.backingScaleFactor ?? 2)))
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func layout() {
        super.layout()
        textView.frame = bounds.insetBy(dx: Self.margin, dy: Self.margin)
    }

    override func draw(_ dirtyRect: NSRect) {
        // 文本贴图的背景：跟 renderTextToImage 用的 textBackgroundColor 一致
        NSColor.textBackgroundColor.setFill()
        bounds.fill()
    }
}

/// 可选中的文本视图。⌘ + 拖 = 移动整个贴图窗口；
/// 不按 ⌘ 就是正常的选字（不调 super 的话连光标都放不进去）。
final class PinSelectableTextView: NSTextView {

    weak var window_: PinWindow?
    private var dragStartOrigin: NSPoint?
    private var dragStartMouse: NSPoint?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command), let window_ {
            dragStartOrigin = window_.frame.origin
            dragStartMouse = NSEvent.mouseLocation
            return
        }
        super.mouseDown(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        if let origin = dragStartOrigin, let start = dragStartMouse, let window_ {
            let now = NSEvent.mouseLocation
            window_.moveTo(CGPoint(x: origin.x + (now.x - start.x),
                                   y: origin.y + (now.y - start.y)))
            return
        }
        super.mouseDragged(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        if dragStartOrigin != nil {
            dragStartOrigin = nil
            dragStartMouse = nil
            window_?.onStateChanged?()
            return
        }
        super.mouseUp(with: event)
    }
}
