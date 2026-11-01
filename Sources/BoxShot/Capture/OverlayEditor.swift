import AppKit

// ============================================================
// 原位编辑浮层（1.0.1 按用户截图改版）
//
// 截图完成后，选区**原位置原大小**钉住显示截好的图（顶部尺寸条），
// 标注工具栏浮在框外（优先放框下方，放不下放上方）。
// 交互：
//   · 工具栏选工具后直接在图上拖拽/点按标注
//   · 复制 / 保存 / 贴图 / OCR / QR 均以"底图+标注"的合成结果为准
//   · ⌫ 撤销 ⌘Z / 重做 ⇧⌘Z；Esc 或点击框外 = 关闭浮层
//
// 复用 EditorDocument（形状/撤销栈/效果图）与 EditorRenderer.drawShapes，
// 与独立编辑器窗口共用同一套渲染语义，避免两处各写一套坐标换算。
// ============================================================

@MainActor
final class OverlayEditorController: NSObject {

    private let doc: EditorDocument
    private weak var model: AppModel?
    private let selectionFrame: CGRect   // AppKit 全局坐标（点）
    private let displayScale: CGFloat

    private var imagePanel: NSPanel!
    private var toolbarPanel: NSPanel!
    private var contentView: OverlayEditorView!
    private var toolButtons: [EditorTool: NSButton] = [:]
    private var swatchButtons: [String: NSButton] = [:]
    private var widthButtons: [CGFloat: NSButton] = [:]
    private var monitors: [Any] = []
    /// 本次截图是否已落盘（保存过 / 自动保存过就不再重复写）
    private var didPersist = false
    /// 裁剪后要"重开"：这段不许触发自动保存，否则会把裁剪前的图落盘
    private var suppressAutosave = false

    /// 关闭回调（AppModel 用来清引用）
    var onClose: (() -> Void)?

    // ── 裁剪 ────────────────────────────────────────────────

    /// 有待确认的裁剪就撤掉它并返回 true（Esc 用：先撤裁剪，再按一次才关浮层）
    @discardableResult
    func cancelCropIfPending() -> Bool {
        guard contentView?.hasPendingCrop == true else { return false }
        contentView?.cancelCrop()
        return true
    }

    /// 应用裁剪：裁好图 + 平移到新原点的标注，原位置重开一个浮层。
    ///
    /// 不原地改 document（imageRect / 手柄 / 面板尺寸都是 init 时定死的），
    /// 改成"关掉自己→按新尺寸重开"：坐标换算只有一套，不会留下半个旧状态。
    @discardableResult
    func applyCropIfPending() -> Bool {
        guard let rect = contentView?.pendingCropRect else { return false }
        guard let result = doc.croppedResult(to: rect) else {
            contentView?.cancelCrop()
            return true
        }
        let frame = croppedFrame(for: rect)
        suppressAutosave = true
        close()
        model?.openOverlayEditor(image: result.image, frame: frame, shapes: result.shapes)
        return true
    }

    /// 裁剪框（图像像素）→ 新浮层在屏幕上的位置（AppKit 全局坐标）。
    /// 图像顶边贴着 selectionFrame.maxY，y 轴方向相反，别把两个轴搞混。
    private func croppedFrame(for rect: CGRect) -> CGRect {
        let unit = 1 / displayScale
        return CGRect(x: selectionFrame.minX + rect.minX * unit,
                      y: selectionFrame.maxY - rect.maxY * unit,
                      width: rect.width * unit,
                      height: rect.height * unit)
    }

    /// 诊断专用：读浮层的文档（自检预置形状用）
    var docForDiagnostics: EditorDocument { doc }

    init(model: AppModel, image: CGImage, selectionFrameAppKit frame: CGRect,
         shapes: [AnnotationShape] = []) {
        self.model = model
        self.doc = EditorDocument(image: image, shapes: shapes)
        self.selectionFrame = frame
        self.displayScale = NSScreen.screens.first?.backingScaleFactor ?? 2
        super.init()
    }

    // ── 布局常量 ──
    private let barHeight: CGFloat = 30
    private let margin: CGFloat = 6
    private let toolbarHeight: CGFloat = 56

    func show() {
        let pointSize = CGSize(width: CGFloat(doc.baseImage.width) / displayScale,
                               height: CGFloat(doc.baseImage.height) / displayScale)
        let windowFrame = CGRect(x: selectionFrame.minX - margin,
                                 y: selectionFrame.minY - margin,
                                 width: selectionFrame.width + margin * 2,
                                 height: selectionFrame.height + barHeight + margin)

        // ── 图像浮层 ──
        let panel = NSPanel(contentRect: windowFrame,
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let view = OverlayEditorView(doc: doc, controller: self,
                                     imageRect: NSRect(origin: CGPoint(x: margin, y: barHeight),
                                                       size: pointSize),
                                     displayScale: displayScale)
        contentView = view
        panel.contentView = view
        imagePanel = panel

        // ── 工具栏 ──
        toolbarPanel = buildToolbarPanel()

        panel.makeKeyAndOrderFront(nil)
        toolbarPanel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        installMonitors()
        refresh()
    }

    func close() {
        autosaveIfNeeded()
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors.removeAll()
        imagePanel?.orderOut(nil)
        toolbarPanel?.orderOut(nil)
        imagePanel = nil
        toolbarPanel = nil
        onClose?()
    }

    /// 开了"自动保存"后，关闭浮层即落盘（标注一起合成进去）；
    /// 已经保存过的（⌘S / 保存按钮）不重复写。
    private func autosaveIfNeeded() {
        guard !didPersist, !suppressAutosave, let model else { return }
        let prefs = model.prefs.value
        guard prefs.autoSave, let dirPath = prefs.saveDirectory, !dirPath.isEmpty else { return }
        guard let image = doc.rendered() else { return }
        let url = Support.uniqueFileURL(in: URL(fileURLWithPath: dirPath, isDirectory: true),
                                        name: Support.shotFileName(ext: prefs.shotFormat.fileExtension))
        write(image: image, format: prefs.shotFormat, quality: prefs.jpgQuality, to: url)
    }

    // ── 工具栏 ──────────────────────────────────────────────

    private func buildToolbarPanel() -> NSPanel {
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.spacing = 2
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)

        for tool in EditorTool.allCases {
            let button = toolbarButton(symbol: tool.symbol, title: tool.title) { [weak self] in
                self?.selectTool(tool)
            }
            toolButtons[tool] = button
            stack.addArrangedSubview(button)
        }
        stack.addArrangedSubview(divider())

        // 颜色 / 粗细：改变后续绘制的默认值；有选中标注时直接改它
        for color in [RGBColor.red, .blue, .yellow, .green, .white, .black] {
            let dot = colorDotButton(color)
            swatchButtons[color.hexString] = dot
            stack.addArrangedSubview(dot)
        }
        for width: CGFloat in [3, 6, 12] {
            let button = lineWidthButton(width)
            widthButtons[width] = button
            stack.addArrangedSubview(button)
        }
        stack.addArrangedSubview(divider())

        stack.addArrangedSubview(toolbarButton(symbol: "arrow.uturn.backward", title: "撤销 ⌘Z") { [weak self] in self?.doc.undo(); self?.refresh() })
        stack.addArrangedSubview(toolbarButton(symbol: "arrow.uturn.forward", title: "重做 ⇧⌘Z") { [weak self] in self?.doc.redo(); self?.refresh() })
        stack.addArrangedSubview(divider())

        stack.addArrangedSubview(toolbarButton(symbol: "text.below.photo", title: "OCR 识别文字") { [weak self] in self?.ocr() })
        stack.addArrangedSubview(toolbarButton(symbol: "qrcode.viewfinder", title: "解码 QR/条形码") { [weak self] in self?.decodeQR() })
        stack.addArrangedSubview(toolbarButton(symbol: "pin", title: "贴图") { [weak self] in self?.pin() })
        stack.addArrangedSubview(toolbarButton(symbol: "doc.on.doc", title: "复制 ⌘C") { [weak self] in self?.copyToClipboard() })
        stack.addArrangedSubview(toolbarButton(symbol: "arrow.down.circle", title: "保存 ⌘S") { [weak self] in self?.save() })
        stack.addArrangedSubview(divider())

        let close = toolbarButton(symbol: "xmark", title: "关闭（丢弃未保存的标注）") { [weak self] in self?.close() }
        close.contentTintColor = .systemRed
        stack.addArrangedSubview(close)

        stack.layoutSubtreeIfNeeded()
        let size = stack.fittingSize
        let container = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        container.material = .hudWindow
        container.state = .active
        container.wantsLayer = true
        container.layer?.cornerRadius = 10
        container.addSubview(stack)
        stack.frame = container.bounds

        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = container
        positionToolbar(panel)
        return panel
    }

    private func positionToolbar(_ panel: NSPanel) {
        guard let screen = imagePanel?.screen ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        let width = panel.frame.width
        let centerX = selectionFrame.midX - width / 2

        // 优先放框下方，贴到屏幕底边不够时放上方
        let belowY = selectionFrame.minY - toolbarHeight - 8
        let y: CGFloat
        if belowY >= visible.minY + 4 {
            y = belowY
        } else {
            y = selectionFrame.maxY + barHeight + 8
        }
        let clampedX = min(max(centerX, visible.minX + 4), visible.maxX - width - 4)
        panel.setFrameOrigin(NSPoint(x: clampedX, y: y))
    }

    private func toolbarButton(symbol: String, title: String, action: @escaping () -> Void) -> NSButton {
        let button = NSButton(title: "", target: nil, action: nil)
        button.bezelStyle = .regularSquare
        button.isBordered = false
        button.wantsLayer = true
        button.layer?.cornerRadius = 5
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)?
            .withSymbolConfiguration(.init(pointSize: 16, weight: .medium))
        button.imageScaling = .scaleNone
        button.toolTip = title
        button.setButtonType(.momentaryChange)
        button.onAction = action
        button.frame = NSRect(x: 0, y: 0, width: 40, height: 34)
        return button
    }

    private func divider() -> NSView {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 1, height: 26))
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.separatorColor.cgColor
        return view
    }

    private func selectTool(_ tool: EditorTool) {
        doc.tool = tool
        refresh()
    }

    /// 工具高亮刷新
    func refresh() {
        for (tool, button) in toolButtons {
            if tool == doc.tool {
                button.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.35).cgColor
            } else {
                button.layer?.backgroundColor = NSColor.clear.cgColor
            }
        }
        for (hex, button) in swatchButtons {
            if hex == doc.color.hexString {
                button.layer?.borderWidth = 2
                button.layer?.borderColor = NSColor.controlAccentColor.cgColor
            } else {
                button.layer?.borderWidth = 0
            }
        }
        for (width, button) in widthButtons {
            if abs(doc.lineWidth - width) < 0.5 {
                button.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.35).cgColor
            } else {
                button.layer?.backgroundColor = NSColor.clear.cgColor
            }
        }
        contentView?.needsDisplay = true
    }

    // ── 颜色 / 粗细控件 ─────────────────────────────────────

    private func colorDotButton(_ color: RGBColor) -> NSButton {
        let button = NSButton(title: "", target: nil, action: nil)
        button.bezelStyle = .regularSquare
        button.isBordered = false
        button.wantsLayer = true
        button.layer?.backgroundColor = color.cgColor
        button.layer?.cornerRadius = 7
        button.toolTip = "颜色 \(color.hexString)（有选中标注时直接改它）"
        button.setButtonType(.momentaryChange)
        button.onAction = { [weak self] in
            self?.doc.applyToSelected(color: color)
            self?.refresh()
        }
        button.frame = NSRect(x: 0, y: 0, width: 18, height: 26)
        return button
    }

    private func lineWidthButton(_ width: CGFloat) -> NSButton {
        let button = NSButton(title: "", target: nil, action: nil)
        button.bezelStyle = .regularSquare
        button.isBordered = false
        button.wantsLayer = true
        button.layer?.cornerRadius = 5
        button.toolTip = "粗细 \(Int(width)) px"
        button.setButtonType(.momentaryChange)
        // 画一条对应粗细的横线示意
        let image = NSImage(size: NSSize(width: 18, height: 18))
        image.lockFocus()
        if let ctx = NSGraphicsContext.current?.cgContext {
            ctx.setStrokeColor(NSColor.white.cgColor)
            ctx.setLineWidth(min(10, max(2, width / 2)))
            ctx.setLineCap(.round)
            ctx.move(to: CGPoint(x: 2, y: 9))
            ctx.addLine(to: CGPoint(x: 16, y: 9))
            ctx.strokePath()
        }
        image.unlockFocus()
        button.image = image
        button.onAction = { [weak self] in
            self?.doc.applyToSelected(lineWidth: width)
            self?.refresh()
        }
        button.frame = NSRect(x: 0, y: 0, width: 24, height: 26)
        return button
    }

    // ── 输出动作 ────────────────────────────────────────────

    private func renderedImage() -> CGImage? {
        doc.rendered()
    }

    func copyToClipboard() {
        guard let image = renderedImage() else { return }
        Support.copyImageToClipboard(image)
        if model?.prefs.value.playSound == true { Support.playFeedbackSound() }
        contentView?.flashStatus("已复制到剪贴板")
    }

    func save() {
        guard let image = renderedImage(), let model else { return }
        let prefs = model.prefs.value
        let suggestedName = Support.shotFileName(ext: prefs.shotFormat.fileExtension)

        if prefs.autoSave, let dirPath = prefs.saveDirectory, !dirPath.isEmpty {
            let directory = URL(fileURLWithPath: dirPath, isDirectory: true)
            write(image: image, format: prefs.shotFormat,
                  quality: prefs.jpgQuality, to: Support.uniqueFileURL(in: directory, name: suggestedName))
            return
        }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName
        panel.allowedContentTypes = prefs.shotFormat == .png ? [.png] : [.jpeg]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        write(image: image, format: prefs.shotFormat, quality: prefs.jpgQuality, to: url)
    }

    private func write(image: CGImage, format: ShotFormat, quality: Double, to url: URL) {
        guard let data = ImageEncode.data(image, format: format, jpgQuality: quality) else { return }
        do {
            try data.write(to: url)
            didPersist = true
            if model?.prefs.value.playSound == true { Support.playFeedbackSound() }
            contentView?.flashStatus("已保存：\(url.lastPathComponent)")
        } catch {
            contentView?.flashStatus("保存失败：\(error.localizedDescription)")
        }
    }

    func pin() {
        guard let image = renderedImage() else { return }
        model?.pinImage(image)
        contentView?.flashStatus("已贴图")
    }

    func ocr() {
        guard let image = renderedImage() else { return }
        model?.runOCR(image: image)
    }

    func decodeQR() {
        guard let image = renderedImage() else { return }
        model?.runQR(image: image)
    }

    // ── 键盘 / 框外点击 ──────────────────────────────────────

    private func installMonitors() {
        // Esc / ⌘Z / ⌘S / ⌘C 只在浮层是焦点时生效
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.imagePanel != nil else { return event }
            guard event.window === self.imagePanel || event.window === self.toolbarPanel else { return event }
            // 文字输入中不抢键盘
            if self.contentView?.isEditingText == true { return event }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            switch event.keyCode {
            case 53: // Esc：有待确认的裁剪就只撤裁剪，不关浮层
                if self.cancelCropIfPending() { return nil }
                self.close()
                return nil
            case 36, 76: // ⏎ / 小键盘 Enter：应用裁剪
                if self.applyCropIfPending() { return nil }
                return event
            case 6 where flags.contains(.command): // Z
                if flags.contains(.shift) { self.doc.redo() } else { self.doc.undo() }
                self.refresh()
                return nil
            case 0 where flags.contains(.command): // C
                self.copyToClipboard()
                return nil
            case 1 where flags.contains(.command): // S
                self.save()
                return nil
            case 51, 117: // ⌫ / Delete：有选中删标注，否则当撤销
                if doc.selectedShape != nil {
                    doc.deleteSelected()
                } else {
                    self.doc.undo()
                }
                self.refresh()
                return nil
            default:
                return event
            }
        })

        // 点击框外 = 关闭（丢弃）。全局 + 本地各装一个：
        // 自己应用的窗口走本地监听，其他应用走全局监听（鼠标监听不需要辅助功能授权）。
        let isInside: (NSPoint) -> Bool = { [weak self] location in
            guard let self else { return true }
            let inImage = self.imagePanel?.frame.contains(location) ?? false
            let inToolbar = self.toolbarPanel?.frame.contains(location) ?? false
            return inImage || inToolbar
        }
        monitors.append(NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let self else { return }
            if !isInside(NSEvent.mouseLocation) { self.close() }
        })
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self else { return event }
            if let window = event.window, window === self.imagePanel || window === self.toolbarPanel {
                return event
            }
            // 点到本应用其他窗口（如设置）也关闭
            self.close()
            return event
        })
    }
}

// ============================================================
// 浮层内容视图：图像 + 标注 + 尺寸条
// ============================================================

final class OverlayEditorView: NSView {

    private let doc: EditorDocument
    private unowned let controller: OverlayEditorController
    private let imageRect: NSRect      // 视图坐标（点，flipped）
    private let displayScale: CGFloat

    private var pixelScale: CGFloat {
        CGFloat(doc.baseImage.width) / imageRect.width
    }

    private var draft: AnnotationShape?
    private var draftStart: CGPoint?
    private var statusMessage: String?
    private var statusUntil = Date()
    private var textField: NSTextField?
    /// 选择工具：正在拖动选中标注
    private var draggingSelection = false
    private var dragLastPoint: CGPoint?
    /// 裁剪：拖出的保留范围（图像像素坐标），⏎ 应用 / ⎋ 取消
    private var pendingCrop: CGRect?
    private var cropAnchor: CGPoint?

    /// 控制器用：当前是否有待确认的裁剪
    var hasPendingCrop: Bool { pendingCrop != nil }
    var pendingCropRect: CGRect? { pendingCrop }

    var isEditingText: Bool { textField != nil }

    init(doc: EditorDocument, controller: OverlayEditorController,
         imageRect: NSRect, displayScale: CGFloat) {
        self.doc = doc
        self.controller = controller
        self.imageRect = imageRect
        self.displayScale = displayScale
        let bounds = NSRect(origin: .zero,
                            size: NSSize(width: imageRect.maxX + imageRect.minX,
                                         height: imageRect.maxY + imageRect.minY))
        super.init(frame: bounds)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    // ── 绘制 ────────────────────────────────────────────────

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        // 尺寸条
        drawSizeBar(ctx)

        // 画布底（白底衬托透明 PNG）
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fill(imageRect)

        // 底图：翻转上下文里画 CGImage 要走标准配方，否则上下颠倒
        ctx.saveGState()
        ctx.translateBy(x: imageRect.minX, y: imageRect.maxY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.interpolationQuality = .high
        ctx.draw(doc.baseImage, in: CGRect(origin: .zero, size: imageRect.size))
        ctx.restoreGState()

        // 标注：变换到"图像像素空间（左上原点 y 向下）"后复用渲染器。
        // 🔴 这里是从像素坐标**回到视图坐标**：1 图像像素 = 1/pixelScale 个视图点
        //（pixelScale 是"每视图点对应多少像素"）。曾经写成 scaleBy(pixelScale)
        // 方向反了——标注整体放大 4 倍画到图像区域外，表现为"画了但看不见"。
        ctx.saveGState()
        ctx.translateBy(x: imageRect.minX, y: imageRect.minY)
        let viewPerPixel = imageRect.width / CGFloat(doc.baseImage.width)
        ctx.scaleBy(x: viewPerPixel, y: viewPerPixel)
        EditorRenderer.drawShapes(doc.shapes, in: ctx, effects: doc.effects,
                                  canvasHeight: CGFloat(doc.baseImage.height))
        if let draft {
            EditorRenderer.drawShapes([draft], in: ctx, effects: doc.effects,
                                      canvasHeight: CGFloat(doc.baseImage.height))
        }
        if let selected = doc.selectedShape {
            EditorRenderer.drawSelection(for: selected, in: ctx)
        }
        ctx.restoreGState()

        // 边框 + 手柄
        ctx.setStrokeColor(NSColor.controlAccentColor.cgColor)
        ctx.setLineWidth(2)
        ctx.stroke(imageRect)
        ctx.setFillColor(NSColor.white.cgColor)
        for point in Self.handlePoints(of: imageRect) {
            ctx.fillEllipse(in: CGRect(x: point.x - 4, y: point.y - 4, width: 8, height: 8))
        }

        drawCropMask(ctx)
    }

    /// 裁剪取景：范围外压暗 + 白框 + 底部提示
    private func drawCropMask(_ ctx: CGContext) {
        guard let crop = pendingCrop, crop.width > 1, crop.height > 1 else { return }
        // 像素 → 视图点
        let scale = 1 / pixelScale
        let rect = CGRect(x: imageRect.minX + crop.minX * scale,
                          y: imageRect.minY + crop.minY * scale,
                          width: crop.width * scale,
                          height: crop.height * scale)

        // 四条边围出来的"压暗区"（不用甚至奇偶填充，省得算 even-odd）
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.55).cgColor)
        let full = imageRect
        let bands = [
            CGRect(x: full.minX, y: full.minY, width: full.width, height: rect.minY - full.minY),
            CGRect(x: full.minX, y: rect.maxY, width: full.width, height: full.maxY - rect.maxY),
            CGRect(x: full.minX, y: rect.minY, width: rect.minX - full.minX, height: rect.height),
            CGRect(x: rect.maxX, y: rect.minY, width: full.maxX - rect.maxX, height: rect.height),
        ]
        for band in bands where band.width > 0 && band.height > 0 { ctx.fill(band) }

        ctx.setStrokeColor(NSColor.white.cgColor)
        ctx.setLineWidth(2)
        ctx.stroke(rect)

        // 尺寸 + 操作提示，画在裁剪框下方
        let label = "\(Int(crop.width)) × \(Int(crop.height))   ⏎ 应用 · ⎋ 取消"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: NSColor.white,
        ]
        let size = (label as NSString).size(withAttributes: attributes)
        let barRect = CGRect(x: rect.minX, y: min(rect.maxY + 6, imageRect.maxY - 26),
                             width: size.width + 16, height: 22)
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.8).cgColor)
        ctx.addPath(CGPath(roundedRect: barRect, cornerWidth: 6, cornerHeight: 6, transform: nil))
        ctx.fillPath()
        (label as NSString).draw(at: CGPoint(x: barRect.minX + 8, y: barRect.minY + 4),
                                 withAttributes: attributes)
    }

    func cancelCrop() {
        pendingCrop = nil
        cropAnchor = nil
        needsDisplay = true
    }

    private func drawSizeBar(_ ctx: CGContext) {
        let text = "\(doc.baseImage.width) × \(doc.baseImage.height)" + (statusMessage.map { "   \($0)" } ?? "")
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: NSColor.white,
        ]
        let size = (text as NSString).size(withAttributes: attributes)
        let barRect = CGRect(x: imageRect.minX, y: 4,
                             width: size.width + 20, height: imageRect.minY - 8)
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.75).cgColor)
        ctx.addPath(CGPath(roundedRect: barRect, cornerWidth: 6, cornerHeight: 6, transform: nil))
        ctx.fillPath()
        (text as NSString).draw(at: CGPoint(x: barRect.minX + 10, y: barRect.minY + 5),
                                withAttributes: attributes)
    }

    private static func handlePoints(of rect: NSRect) -> [CGPoint] {
        [
            CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.midX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
            CGPoint(x: rect.minX, y: rect.midY), CGPoint(x: rect.maxX, y: rect.midY),
            CGPoint(x: rect.minX, y: rect.maxY), CGPoint(x: rect.midX, y: rect.maxY), CGPoint(x: rect.maxX, y: rect.maxY),
        ]
    }

    func flashStatus(_ message: String) {
        statusMessage = message
        statusUntil = Date().addingTimeInterval(1.6)
        needsDisplay = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.7) { [weak self] in
            guard let self, Date() >= self.statusUntil else { return }
            self.statusMessage = nil
            self.needsDisplay = true
        }
    }

    // ── 鼠标 ────────────────────────────────────────────────

    private func pixelPoint(_ event: NSEvent) -> CGPoint {
        let p = convert(event.locationInWindow, from: nil)
        return CGPoint(x: (p.x - imageRect.minX) * pixelScale,
                       y: (p.y - imageRect.minY) * pixelScale)
    }

    private func clampToImage(_ p: CGPoint) -> CGPoint {
        CGPoint(x: min(max(0, p.x), CGFloat(doc.baseImage.width)),
                y: min(max(0, p.y), CGFloat(doc.baseImage.height)))
    }

    override func mouseDown(with event: NSEvent) {
        // 文字输入中：先提交再继续
        if let field = textField { commitTextField(field) }

        let p = clampToImage(pixelPoint(event))
        guard imageRect.contains(convert(event.locationInWindow, from: nil)) else { return }

        if doc.tool == .crop {
            // 裁剪：拖出保留范围（按下即清掉上一个草稿）
            cropAnchor = p
            pendingCrop = nil
            needsDisplay = true
            return
        }

        if doc.tool == .select {
            // 点选：命中 → 选中并进入拖动；落空 → 取消选中
            if doc.select(at: p) != nil {
                draggingSelection = true
                dragLastPoint = p
                doc.beginMoveSelected()
            }
        } else if doc.tool.isDragTool {
            doc.selectedID = nil
            draftStart = p
            draft = AnnotationShape(tool: doc.tool, points: [p],
                                    color: doc.color, lineWidth: doc.lineWidth)
        } else {
            switch doc.tool {
            case .text:
                doc.selectedID = nil
                beginTextEditing(at: p)
            case .colorPick:
                if let color = doc.pixelColor(at: p) {
                    doc.commit(AnnotationShape(tool: .colorPick, points: [p], color: color, lineWidth: 0))
                    Support.copyTextToClipboard(color.hexString)
                    flashStatus("已取色 \(color.hexString)")
                }
            default:
                break
            }
        }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let p = clampToImage(pixelPoint(event))
        if doc.tool == .crop {
            let anchor = cropAnchor ?? p
            pendingCrop = CGRect(x: min(anchor.x, p.x), y: min(anchor.y, p.y),
                                 width: abs(p.x - anchor.x), height: abs(p.y - anchor.y))
            needsDisplay = true
            return
        }
        if draggingSelection {
            if let last = dragLastPoint {
                doc.moveSelected(by: CGPoint(x: p.x - last.x, y: p.y - last.y))
            }
            dragLastPoint = p
        } else {
            guard draftStart != nil else { return }
            switch doc.tool {
            case .pen, .marker:
                draft?.points.append(p)
            default:
                // 马赛克/模糊与形状类一致：按"起点→当前点"矩形预览（渲染语义是矩形区域）
                draft?.points = [draftStart ?? p, p]
            }
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        if doc.tool == .crop {
            cropAnchor = nil
            // 太小就是误触：清掉，别留个几像素的框
            if let crop = pendingCrop, crop.width < 8 || crop.height < 8 { pendingCrop = nil }
            needsDisplay = true
            return
        }
        if draggingSelection {
            draggingSelection = false
            dragLastPoint = nil
            doc.endMoveSelected()
            needsDisplay = true
            return
        }
        guard var shape = draft else { return }
        draft = nil
        draftStart = nil
        if shape.points.count >= 2 {
            if shape.tool == .mosaic || shape.tool == .blur {
                let first = shape.points.first!
                let last = shape.points.last!
                shape.points = [first, last]
            }
            doc.commit(shape)
        }
        needsDisplay = true
    }

    // ── 文字编辑 ────────────────────────────────────────────

    private func beginTextEditing(at pixelPoint: CGPoint) {
        commitTextFieldIfAny()
        let field = NSTextField(frame: NSRect(x: imageRect.minX + pixelPoint.x / pixelScale,
                                              y: imageRect.minY + pixelPoint.y / pixelScale - 12,
                                              width: 200, height: 24))
        field.placeholderString = "输入文字，回车确认"
        field.font = .systemFont(ofSize: 14)
        field.identifier = NSUserInterfaceItemIdentifier("boxshot.textfield")
        addSubview(field)
        textField = field
        window?.makeFirstResponder(field)

        // 用闭包捕获提交：回车或失焦都提交
        field.target = self
        field.action = #selector(textFieldSubmitted(_:))
    }

    @objc private func textFieldSubmitted(_ sender: NSTextField) {
        commitTextField(sender)
    }

    private func commitTextFieldIfAny() {
        if let field = textField { commitTextField(field) }
    }

    private func commitTextField(_ field: NSTextField) {
        let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        // 从字段位置反推像素坐标
        let pixel = CGPoint(x: (field.frame.minX - imageRect.minX) * pixelScale,
                            y: (field.frame.minY - imageRect.minY) * pixelScale + 12 * pixelScale)
        field.removeFromSuperview()
        textField = nil
        guard !text.isEmpty else { return }
        doc.commit(AnnotationShape(tool: .text, points: [pixel],
                                   color: doc.color, lineWidth: 0, text: text,
                                   fontSize: 30 * pixelScale))
        needsDisplay = true
    }
}

private extension NSButton {
    // NSButton 用 target/action；这里挂闭包的小工具
    private struct Keys { static var onAction = "onAction" }
    var onAction: (() -> Void)? {
        get { objc_getAssociatedObject(self, &Keys.onAction) as? () -> Void }
        set {
            objc_setAssociatedObject(self, &Keys.onAction, newValue, .OBJC_ASSOCIATION_COPY_NONATOMIC)
            target = self
            action = #selector(dispatchAction)
        }
    }
    @objc func dispatchAction() { onAction?() }
}
