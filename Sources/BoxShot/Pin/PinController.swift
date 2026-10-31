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
        return pinImage(image, opacity: opacity, shadow: shadow)
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
        pin.onClose = { [weak self, weak pin] in
            self?.pins.removeAll { $0 === pin }
            self?.persistIndex()
        }
        pin.onStateChanged = { [weak self] in
            self?.persistIndex()
        }
        persistIndex()
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
                  let pin = PinWindow(image: image, opacity: 1.0, shadow: true) else { continue }
            pin.onClose = { [weak self, weak pin] in
                self?.pins.removeAll { $0 === pin }
                self?.persistIndex()
            }
            pin.restore(frameOrigin: CGPoint(x: record.x, y: record.y), scale: record.scale)
            pins.append(pin)
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

    private let image: CGImage
    private var scale: CGFloat
    var flippedH = false
    var flippedV = false
    private var archivedFile: String?

    /// Retina 适配：截图通常 2x，显示按像素 / backingScale，看起来和来源一致
    private static var baseDisplayScale: CGFloat {
        NSScreen.main?.backingScaleFactor ?? 2
    }

    init?(image: CGImage, opacity: Double, shadow: Bool) {
        self.image = image
        self.scale = 1.0 / Self.baseDisplayScale
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
        appearance = NSAppearance(named: .vibrantDark)
        contentView = PinContentView(image: image, window: self)
        alphaValue = opacity
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
                                    scale: Double(scale))
    }

    // 贴图不是标准可激活窗口；双击/滚轮交互全在内容视图里
    override var canBecomeKey: Bool { false }
}

// ── 贴图内容视图：拖拽 / 缩放 / 双击 / 右键 ──

final class PinContentView: NSView {

    private let image: CGImage
    private unowned let window_: PinWindow
    private var dragStartOrigin: NSPoint?

    init(image: CGImage, window: PinWindow) {
        self.image = image
        self.window_ = window
        super.init(frame: NSRect(origin: .zero,
                                 size: NSSize(width: CGFloat(image.width) / (NSScreen.main?.backingScaleFactor ?? 2),
                                              height: CGFloat(image.height) / (NSScreen.main?.backingScaleFactor ?? 2))))
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let rect = bounds
        ctx.saveGState()
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

    // 拖拽移动
    override func mouseDown(with event: NSEvent) {
        dragStartOrigin = window_.frame.origin
    }

    override func mouseDragged(with event: NSEvent) {
        guard let origin = dragStartOrigin else { return }
        let dx = event.deltaX, dy = event.deltaY
        window_.moveTo(CGPoint(x: origin.x + dx, y: origin.y - dy))
    }

    override func mouseUp(with event: NSEvent) {
        let moved = dragStartOrigin.map { start in
            hypot(window_.frame.origin.x - start.x, window_.frame.origin.y - start.y)
        } ?? 0
        dragStartOrigin = nil
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

    // 右键菜单：翻转 / 复制 / 关闭
    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        menu.addItem(withTitle: "水平翻转", action: #selector(flipH), keyEquivalent: "").target = self
        menu.addItem(withTitle: "垂直翻转", action: #selector(flipV), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "复制图片", action: #selector(copyImage), keyEquivalent: "").target = self
        menu.addItem(withTitle: "关闭贴图", action: #selector(closePin), keyEquivalent: "").target = self
        return menu
    }

    @objc private func flipH() { window_.toggleMirrorH() }
    @objc private func flipV() { window_.toggleMirrorV() }
    @objc private func copyImage() { Support.copyImageToClipboard(image) }
    @objc private func closePin() { window_.close() }
}
