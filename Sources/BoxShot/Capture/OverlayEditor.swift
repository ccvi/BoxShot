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

    /// 整屏原图 + 它在 AppKit 坐标里的框 + 「点 → 像素」倍率。
    /// 有了它，标注阶段才能随时把截图框拉大：扩出去的那块直接从这一帧里取，
    /// 不需要重新截屏（重新截会把我们自己的浮层拍进去，内容也可能已经变了）。
    struct FullDisplay {
        var image: CGImage
        /// 这张原图覆盖的屏幕矩形（AppKit 坐标）。窗口截图时是**窗口框**，
        /// 区域截图时是整块屏。
        var frameAppKit: CGRect
        var pixelScale: CGFloat
        /// 浮层窗口要铺多大。默认跟 `frameAppKit` 一样（区域截图 = 整块屏）；
        /// 窗口截图要传**整块屏**：浮层只比窗口大一圈时，框一高就顶出屏幕，
        /// AppKit 会把窗口整体往下推（constrainFrameRect），图就跟着错位了。
        var panelFrameAppKit: CGRect? = nil
    }

    private let doc: EditorDocument
    private weak var model: AppModel?
    /// 当前截图框（AppKit 全局坐标，点）。拖手柄改尺寸后整个浮层会按新框重开，
    /// 所以这里是 var 而不是 let。
    private(set) var selectionFrame: CGRect
    private let displayScale: CGFloat
    private let fullDisplay: FullDisplay?

    private var imagePanel: NSPanel!
    private var toolbarPanel: NSPanel!
    private var contentView: OverlayEditorView!
    private var toolButtons: [EditorTool: NSButton] = [:]
    private var swatchButtons: [String: NSButton] = [:]
    private var widthButtons: [CGFloat: NSButton] = [:]
    private var colorAnchorButton: NSButton?
    private var colorPanel: NSPanel?
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
        model?.openOverlayEditor(image: result.image, frame: frame,
                                 fullDisplay: fullDisplay, shapes: result.shapes)
        return true
    }

    /// 裁剪框（图像像素）→ 新浮层在屏幕上的位置（AppKit 全局坐标）。
    /// 图像顶边贴着 selectionFrame.maxY，y 轴方向相反，别把两个轴搞混。
    private func croppedFrame(for rect: CGRect) -> CGRect {
        let unit = 1 / selectionPixelScale
        return CGRect(x: selectionFrame.minX + rect.minX * unit,
                      y: selectionFrame.maxY - rect.maxY * unit,
                      width: rect.width * unit,
                      height: rect.height * unit)
    }

    /// 这份文档里「1 个视图点 = 多少图像像素」。不要直接用屏幕 backingScaleFactor：
    /// 开了「Retina 缩小到 1x」之后文档是 1x 的，两者对不上，裁剪框会整体缩一半。
    private var selectionPixelScale: CGFloat {
        CGFloat(doc.baseImage.width) / max(1, selectionFrame.width)
    }

    /// 诊断专用：读浮层的文档（自检预置形状用）
    var docForDiagnostics: EditorDocument { doc }

    /// 诊断用：浮层窗口的实际 frame（核对有没有被 AppKit 的 constrainFrameRect 推走）
    var panelFrameForDiagnostics: CGRect { imagePanel?.frame ?? .zero }
    /// 诊断用：颜色面板的 frame / 当前颜色（验"点一下色块真的换色了"）
    var colorPanelFrameForDiagnostics: CGRect { colorPanel?.frame ?? .zero }
    var docColorForDiagnostics: String { doc.color.hexString }
    /// 诊断用：颜色面板是不是 key、某个点命中的是哪个视图
    var colorPanelIsKeyForDiagnostics: Bool { colorPanel?.isKeyWindow ?? false }
    /// 诊断用：工具条 frame / 当前工具（验"合成点击到底能不能进 .statusBar 面板"）
    var toolbarFrameForDiagnostics: CGRect { toolbarPanel?.frame ?? .zero }
    var docToolForDiagnostics: String { doc.tool.rawValue }
    func colorPanelHitTestForDiagnostics(_ p: CGPoint) -> String {
        guard let v = colorPanel?.contentView?.hitTest(p) else { return "nil" }
        return String(describing: type(of: v))
    }
    /// 诊断用：直接触发第 n 个色块的动作（排除"闭包没接上"这一种可能）
    func colorPanelPerformClickForDiagnostics(index: Int) -> Bool {
        guard let panel = colorPanel, let stack = panel.contentView?.subviews.first as? NSStackView else { return false }
        let buttons = stack.arrangedSubviews.compactMap { $0 as? NSButton }
        guard index < buttons.count else { return false }
        buttons[index].performClick(nil)
        return true
    }

    init(model: AppModel, image: CGImage, selectionFrameAppKit frame: CGRect,
         fullDisplay: FullDisplay? = nil, shapes: [AnnotationShape] = []) {
        self.model = model
        self.doc = EditorDocument(image: image, shapes: shapes)
        self.selectionFrame = frame
        self.fullDisplay = fullDisplay
        self.displayScale = fullDisplay?.pixelScale
            ?? NSScreen.screens.first?.backingScaleFactor ?? 2
        super.init()
    }

    // ── 布局常量 ──
    private let barHeight: CGFloat = 30
    private let margin: CGFloat = 6
    private let toolbarHeight: CGFloat = 64

    func show() {
        // 🔴 有整屏原图时，浮层**铺满整块屏幕**：截图框要能往任意方向拉大，
        // 窗口要是只比图大一圈，拖出去的预览框就被窗口裁掉了。
        // 窗口其余部分是透明的，看着和没窗口一样（桌面照旧可见）。
        let panelFrame: CGRect
        let imageRectInView: CGRect
        if let full = fullDisplay {
            panelFrame = full.panelFrameAppKit ?? full.frameAppKit
            // 视图是 flipped（左上原点），AppKit 是左下原点
            imageRectInView = CGRect(x: selectionFrame.minX - panelFrame.minX,
                                     y: panelFrame.maxY - selectionFrame.maxY,
                                     width: selectionFrame.width,
                                     height: selectionFrame.height)
        } else {
            panelFrame = CGRect(x: selectionFrame.minX - margin,
                                y: selectionFrame.minY - margin,
                                width: selectionFrame.width + margin * 2,
                                height: selectionFrame.height + barHeight + margin)
            imageRectInView = CGRect(x: margin, y: barHeight,
                                     width: selectionFrame.width,
                                     height: selectionFrame.height)
        }

        // KeyablePanel：无边框面板默认拿不到 key window，键盘（Esc / ⌘C / ⌘S）进不来
        let panel = KeyablePanel(contentRect: panelFrame,
                                 styleMask: [.borderless, .nonactivatingPanel],
                                 backing: .buffered, defer: false)
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = fullDisplay == nil
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let view = OverlayEditorView(doc: doc, controller: self,
                                     imageRect: imageRectInView,
                                     displayScale: displayScale,
                                     canResize: fullDisplay != nil)
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

    // MARK: 拖动截图框改尺寸

    /// AppKit 全局坐标（左下原点）→ 整屏原图的像素矩形（左上原点）。
    /// 两个轴方向相反，别把 y 算成 `frame.minY` 那一套 —— 弄反了拖框会上下镜像。
    static func pixelRect(for frame: CGRect, displayFrame: CGRect, pixelScale: CGFloat) -> CGRect {
        CGRect(x: (frame.minX - displayFrame.minX) * pixelScale,
               y: (displayFrame.maxY - frame.maxY) * pixelScale,
               width: frame.width * pixelScale,
               height: frame.height * pixelScale).integral
    }

    /// 文档像素 ÷ 整屏原图像素。正常是 1；开了「Retina 缩小到 1x」时是 0.5。
    ///
    /// 以前这里写的是 `guard 两者相等 else { return }` —— 也就是 1x 模式下
    /// **拖手柄静默没反应**。用户既开了 1x 又要改尺寸就会以为是坏功能。
    /// 现在按这个比例把裁剪结果缩到文档尺度、把标注位移换算成文档单位。
    static func documentScale(selectionPixelScale: CGFloat, fullDisplayPixelScale: CGFloat) -> CGFloat {
        guard fullDisplayPixelScale > 0 else { return 0 }
        return selectionPixelScale / fullDisplayPixelScale
    }

    /// 用户拖手柄把截图框改成了 newFrame（AppKit 全局坐标）。
    /// 做法和裁剪一致：从整屏原图里按新框重新切一份，标注跟着平移，然后
    /// "关掉自己、按新尺寸重开" —— 坐标换算永远只有一套，不会留下半个旧状态。
    func commitResize(to newFrame: CGRect) {
        guard let full = fullDisplay else { return }
        let target = newFrame.intersection(full.frameAppKit).integral
        guard target.width >= 40, target.height >= 40 else { return }

        let docScale = Self.documentScale(selectionPixelScale: selectionPixelScale,
                                          fullDisplayPixelScale: full.pixelScale)
        guard docScale > 0.05 else { return }

        func pixelRect(_ r: CGRect) -> CGRect {
            Self.pixelRect(for: r, displayFrame: full.frameAppKit, pixelScale: full.pixelScale)
        }
        let newPX = pixelRect(target)
        let oldPX = pixelRect(selectionFrame)
        guard newPX != oldPX else { return }
        guard let raw = full.image.cropping(to: newPX) else { return }
        // 1x 模式：剪出来的是 2x 像素，得再缩到文档尺度，否则重开后图会被放大一倍
        let cropped: CGImage
        if abs(docScale - 1) > 0.01 {
            let w = max(1, Int((CGFloat(newPX.width) * docScale).rounded()))
            let h = max(1, Int((CGFloat(newPX.height) * docScale).rounded()))
            guard let scaled = Support.scaled(raw, to: CGSize(width: w, height: h)) else { return }
            cropped = scaled
        } else {
            cropped = raw
        }

        // 标注在文档坐标里，位移也要按文档尺度换算
        let dx = (oldPX.minX - newPX.minX) * docScale
        let dy = (oldPX.minY - newPX.minY) * docScale
        let moved = doc.shapes.map { $0.translated(dx: dx, dy: dy) }

        // 🔴 这里会把自己连面板一起拆掉，而此刻正站在自己的 mouseUp 里。
        // 同步 close() → onClose 让 AppModel 清掉 overlayEditor，controller 就在
        // 方法执行途中被释放，下一行读 model 已经是野指针（RegionSelector 当初崩
        // 四次就是同一个形状）。所以：要用的值先全部带走，旧框当场藏起来别闪，
        // 真正的"拆 + 重开"推到下一轮 runloop，并显式持有自己活到闭包结束。
        suppressAutosave = true
        imagePanel?.orderOut(nil)
        toolbarPanel?.orderOut(nil)
        let holder = self
        DispatchQueue.main.async {
            holder.close()
            holder.model?.openOverlayEditor(image: cropped, frame: target,
                                            fullDisplay: full, shapes: moved)
            _ = holder
        }
    }

    func close() {
        autosaveIfNeeded()
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors.removeAll()
        colorPanel?.orderOut(nil)
        colorPanel = nil
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

    // ── 工具条尺寸 ─────────────────────────────────────────
    //
    // 一个倍率管全部：图标字号、圆角、间距、内边距、颜色圆点、分隔线高度
    // 全从 `toolbarScale` 推出来。以前这些数散在各处硬编码，想整体缩小只能
    // 一个一个改，漏掉一个（比如只改按钮不改内边距）就变成"按钮小了但工具条
    // 还是那么高"。
    //
    // 🔴 1.0.11 的教训：用户说「工具条那个控制颜色的小圆按钮缩小 30%」，
    // 我先把整个工具条缩了 —— 他说的是**那颗圆点**，工具条本身要原尺寸。
    // 所以倍率留在 1.0 当下手开关，真正动的是 `colorAnchorSide`。

    /// 工具条整体倍率（1.0 = 原尺寸；用户 1.0.11 口径：工具条恢复原样）
    static let toolbarScale: CGFloat = 1.0
    /// 图标字号（原 19）。
    /// 🔴 **不要给工具条按钮加显式宽高约束**：这类"空标题 + 图片"的按钮
    /// 内禀尺寸来自图片本身，只缩字号整排按钮就会按同一比例缩小。
    /// 反倒原来写的 `frame = 40×38` 从来没生效过（NSStackView 只认
    /// intrinsicContentSize）：1.0.11 实测原尺寸是 **523×32**，按 40×38 去缩放
    /// 会算错。
    static let toolbarIconPointSize: CGFloat = 19 * toolbarScale
    /// 按钮选中态底色圆角（原 6）
    static let toolbarButtonCornerRadius: CGFloat = 6 * toolbarScale
    /// 按钮之间的间距（原 2）
    static let toolbarSpacing: CGFloat = 2 * toolbarScale
    /// 工具条内边距（原 上下 9 / 左右 10）
    static let toolbarInsetV: CGFloat = 9 * toolbarScale
    static let toolbarInsetH: CGFloat = 10 * toolbarScale
    /// 工具条上那条竖分隔线的高度（原 26）
    static let toolbarDividerHeight: CGFloat = 26 * toolbarScale
    /// 工具条容器圆角（原 14）
    static let toolbarContainerCornerRadius: CGFloat = 14 * toolbarScale
    /// 「当前颜色」那颗圆点的直径：**30 的 70% = 21**。
    /// 用户 1.0.11 原话「工具条那个控制颜色的小圆按钮缩小 30%」—— 只缩这颗，
    /// 工具条别的一律不动。它只有 layer 底色、没有图片，内禀尺寸是 0，
    /// 显式约束不能省（不然会被 NSStackView 压成 0 宽、整个圆点看不见）。
    static let colorAnchorSide: CGFloat = 30 * 0.7

    private func buildToolbarPanel() -> NSPanel {
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.spacing = Self.toolbarSpacing
        stack.edgeInsets = NSEdgeInsets(top: Self.toolbarInsetV, left: Self.toolbarInsetH,
                                       bottom: Self.toolbarInsetV, right: Self.toolbarInsetH)

        // 图标顺序按用户给的参考图排：选择 → 箭头 → 画笔 → 矩形 → 椭圆 → 直线 →
        // 文字 → 马克笔 → 马赛克 → 模糊 → 测距 → 取色，然后是裁剪。
        // 颜色 / 粗细不再平铺（那是 6+3 个按钮，工具条能撑到 1300pt），
        // 收进左边那个颜色圆点的弹出层里；OCR / 贴图这类低频动作收进 ⋯。
        let toolOrder: [EditorTool] = [.select, .arrow, .pen, .rect, .ellipse, .line,
                                       .text, .marker, .mosaic, .blur, .measure, .colorPick]
        for tool in toolOrder {
            let button = toolbarButton(symbol: tool.symbol, title: tool.title) { [weak self] in
                self?.selectTool(tool)
            }
            toolButtons[tool] = button
            stack.addArrangedSubview(button)
        }
        stack.addArrangedSubview(divider(Self.toolbarDividerHeight))

        // 颜色圆点：点开是 6 色 + 3 档粗细
        let colorAnchor = colorDotAnchorButton()
        stack.addArrangedSubview(colorAnchor)
        stack.addArrangedSubview(divider(Self.toolbarDividerHeight))

        stack.addArrangedSubview(toolbarButton(symbol: "arrow.uturn.backward", title: "撤销 ⌘Z") { [weak self] in
            self?.doc.undo(); self?.refresh()
        })
        stack.addArrangedSubview(toolbarButton(symbol: "arrow.uturn.forward", title: "重做 ⇧⌘Z") { [weak self] in
            self?.doc.redo(); self?.refresh()
        })

        // 1.0.10：这个位置原来放的是「裁剪」，用户要求换成「高亮」工具。
        let highlight = toolbarButton(symbol: EditorTool.highlight.symbol,
                                      title: EditorTool.highlight.title) { [weak self] in
            self?.selectTool(.highlight)
        }
        toolButtons[.highlight] = highlight
        stack.addArrangedSubview(highlight)
        stack.addArrangedSubview(divider(Self.toolbarDividerHeight))

        // 1.0.11 用户口径：**去掉裁剪**，原来塞在 ⋯ 里的三个动作（OCR / 解码 / 贴图）
        // 全部摊到工具条上 —— ⋯ 菜单就此取消。
        // 「复制到剪贴板」本来就在工具条上有按钮（📋），菜单里那条是重复的，一并去掉。
        stack.addArrangedSubview(toolbarButton(symbol: "text.below.photo", title: "OCR 识别文字") { [weak self] in
            self?.ocr()
        })
        stack.addArrangedSubview(toolbarButton(symbol: "qrcode.viewfinder", title: "解码 QR/条形码") { [weak self] in
            self?.decodeQR()
        })
        stack.addArrangedSubview(toolbarButton(symbol: "pin", title: "贴图") { [weak self] in
            self?.pin()
        })
        stack.addArrangedSubview(divider(Self.toolbarDividerHeight))

        stack.addArrangedSubview(toolbarButton(symbol: "doc.on.doc", title: "复制 ⌘C") { [weak self] in
            self?.copyToClipboard()
        })
        stack.addArrangedSubview(toolbarButton(symbol: "arrow.down.circle", title: "保存 ⌘S") { [weak self] in
            self?.save()
        })
        stack.addArrangedSubview(divider(Self.toolbarDividerHeight))

        let close = toolbarButton(symbol: "xmark", title: "关闭（丢弃未保存的标注）") { [weak self] in self?.close() }
        close.contentTintColor = .systemRed
        stack.addArrangedSubview(close)

        stack.layoutSubtreeIfNeeded()
        let size = stack.fittingSize
        let container = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        container.material = .hudWindow
        container.state = .active
        container.wantsLayer = true
        container.layer?.cornerRadius = Self.toolbarContainerCornerRadius
        container.addSubview(stack)
        stack.frame = container.bounds

        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = container
        positionToolbar(panel)
        return panel
    }

    /// 工具条左边那个"当前颜色"圆点，点开是配色/粗细面板
    private func colorDotAnchorButton() -> NSButton {
        let button = FirstMouseButton(title: "", target: nil, action: nil)
        button.bezelStyle = .regularSquare
        button.isBordered = false
        button.wantsLayer = true
        button.layer?.cornerRadius = Self.colorAnchorSide / 2
        button.layer?.borderWidth = 1.5 * Self.toolbarScale
        button.layer?.borderColor = NSColor.white.withAlphaComponent(0.75).cgColor
        button.toolTip = "颜色与粗细"
        button.setButtonType(.momentaryChange)
        button.onAction = { [weak self] in self?.toggleColorPanel() }
        button.frame = NSRect(origin: .zero, size: NSSize(width: Self.colorAnchorSide,
                                                          height: Self.colorAnchorSide))
        // 🔴 和色块同一个坑：NSStackView 只看 intrinsicContentSize，
        // 这个按钮只有 layer 底色，没约束就被压成 0 宽 —— 工具条上
        // 那颗"当前颜色"圆点一直是**看不见**的（用户只能靠猜去点）。
        button.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: Self.colorAnchorSide),
            button.heightAnchor.constraint(equalToConstant: Self.colorAnchorSide),
        ])
        colorAnchorButton = button
        updateColorAnchor()
        return button
    }

    private func updateColorAnchor() {
        colorAnchorButton?.layer?.backgroundColor = doc.color.cgColor
    }

    // ── 颜色面板：固定在工具条下面 ──────────────────────────

    /// 1.0.10 用户口径：颜色面板显示在**工具条下面**，6 个颜色。
    /// 以前是 NSPopover，弹在颜色圆点旁边、压住截图内容，位置还跟着圆点跑；
    /// 现在是一块独立的浮层，贴在工具条下方（下面放不下就贴上方），
    /// 顺带把 3 档粗细也收在一起。
    /// 诊断用：直接把颜色面板打开（--show-overlay-color 拿它截图核对）
    func showColorPanelForDiagnostics() { toggleColorPanel() }

    private func toggleColorPanel() {
        if let panel = colorPanel, panel.isVisible {
            panel.orderOut(nil)
            toolbarPanel?.makeKey()
            return
        }
        let panel = colorPanel ?? buildColorPanel()
        colorPanel = panel
        positionColorPanel(panel)
        panel.makeKeyAndOrderFront(nil)
        refresh()
    }

    private func buildColorPanel() -> NSPanel {
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 10, bottom: 8, right: 10)
        for color in Self.colorPalette {
            let dot = colorDotButton(color)
            swatchButtons[color.hexString] = dot
            stack.addArrangedSubview(dot)
        }
        stack.addArrangedSubview(divider())
        for width: CGFloat in [3, 6, 12] {
            let button = lineWidthButton(width)
            widthButtons[width] = button
            stack.addArrangedSubview(button)
        }
        stack.layoutSubtreeIfNeeded()
        let size = stack.fittingSize

        let container = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        container.material = .hudWindow
        container.state = .active
        container.wantsLayer = true
        container.layer?.cornerRadius = 10
        container.addSubview(stack)
        stack.frame = container.bounds

        // 用 KeyablePanel：非 key 窗口里的按钮"第一下"会被吞掉，点颜色要点两次。
        // 键盘不会因此跑掉 —— keyDown 的白名单里把它算作"浮层自己"。
        let panel = KeyablePanel(contentRect: NSRect(origin: .zero, size: size),
                                 styleMask: [.borderless, .nonactivatingPanel],
                                 backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = container
        return panel
    }

    private func positionColorPanel(_ panel: NSPanel) {
        guard let screen = imagePanel?.screen ?? NSScreen.main else { return }
        panel.setFrameOrigin(Self.colorPanelOrigin(toolbar: toolbarPanel?.frame ?? .zero,
                                                   panelSize: panel.frame.size,
                                                   visible: screen.visibleFrame))
    }

    /// 色块直径（pt）：圆形，圆角取一半。
    /// 1.0.10 用户口径「颜色圆形调小一点，小 20%」：26 × 0.8。
    /// 1.0.11 又「调小 10%」：再 × 0.9 = 18.72。
    /// 写成连乘而不是直接写 18.72，是为了以后"再小 10%"能一眼看出基数是谁。
    static let swatchSide: CGFloat = 26 * 0.8 * 0.9

    /// 颜色面板里那条分隔线的高度：跟着色块一起缩，否则会顶出一截
    static let colorPanelDividerHeight: CGFloat = 18

    /// 调色板：6 个颜色（1.0.10 用户口径「颜色 6 个颜色」，顺序按他给的色卡）。
    /// 抽成常量是为了自检能盯着数量 —— 以前是散在这里的数组字面量，
    /// 加一个减一个没人会发现。
    static let colorPalette: [RGBColor] = [.yellow, .green, .blue, .red, .orange, .purple]

    /// 颜色面板与工具条的间距
    static let colorPanelGap: CGFloat = 8

    /// 颜色面板落位（AppKit 坐标，点）：**贴工具条下面**（用户口径），
    /// 下面顶到可见区底边就翻到工具条上方；横向与工具条左对齐，再夹进可见区。
    static func colorPanelOrigin(toolbar: CGRect, panelSize: CGSize, visible: CGRect) -> CGPoint {
        let x = min(max(toolbar.minX, visible.minX + 4), visible.maxX - panelSize.width - 4)
        let below = toolbar.minY - colorPanelGap - panelSize.height
        if below >= visible.minY + 4 { return CGPoint(x: x, y: below) }
        let above = toolbar.maxY + colorPanelGap
        if above + panelSize.height <= visible.maxY - 4 { return CGPoint(x: x, y: above) }
        return CGPoint(x: x, y: max(visible.minY + 4, below))
    }

    private func positionToolbar(_ panel: NSPanel) {
        guard let screen = imagePanel?.screen ?? NSScreen.main else { return }
        panel.setFrameOrigin(Self.toolbarOrigin(selection: selectionFrame,
                                               toolbarSize: panel.frame.size,
                                               visible: screen.visibleFrame))
    }

    /// 工具条与截图框之间的间距（1.0.10 用户口径：10pt）
    static let toolbarGap: CGFloat = 10

    /// 工具条落位（AppKit 坐标，点）。三步口径，**顺序不能换**：
    ///   1. **框下方**（默认）：工具条底边比框底边低 10pt；
    ///   2. 下方顶到可见区底边放不下 → **框上方**：工具条底边比框顶边高 10pt；
    ///   3. 上下都不够（框几乎占满整屏高）→ **框内底部居中**，底边距框底 10pt。
    /// 横向一律按框中线居中，再夹进可见区。
    ///
    /// 抽成静态纯函数是为了 `--selftest` 能喂数字验。这段几何有三个分支，
    /// 只靠真机肉眼试的话，第 3 条几乎不出现（要框高到顶满整屏），
    /// 而它恰恰是最容易写错、也最容易在用户那边突然冒出来的。
    static func toolbarOrigin(selection: CGRect,
                              toolbarSize: CGSize,
                              visible: CGRect) -> CGPoint {
        let x = min(max(selection.midX - toolbarSize.width / 2, visible.minX + 4),
                    visible.maxX - toolbarSize.width - 4)

        let below = selection.minY - toolbarGap - toolbarSize.height
        if below >= visible.minY + 4 { return CGPoint(x: x, y: below) }

        // 旧写法这里是 `selection.maxY + barHeight + 8`——barHeight（30）是图内那条
        // 刻度带的高度，跟工具条没关系，于是"放上方"时凭空多出 30pt 的空隙。
        let above = selection.maxY + toolbarGap
        if above + toolbarSize.height <= visible.maxY - 4 { return CGPoint(x: x, y: above) }

        var inside = selection.minY + toolbarGap
        if inside > selection.maxY - toolbarSize.height - toolbarGap {
            // 框本身比工具条还矮：竖直居中，贴底就整个跑出去了
            inside = selection.midY - toolbarSize.height / 2
        }
        return CGPoint(x: x, y: min(inside, visible.maxY - toolbarSize.height - 4))
    }

    private func toolbarButton(symbol: String, title: String, action: @escaping () -> Void) -> NSButton {
        toolbarButtonWithSender(symbol: symbol, title: title) { _ in action() }
    }

    private func toolbarButtonWithSender(symbol: String, title: String,
                                         action: @escaping (NSButton) -> Void) -> NSButton {
        let button = FirstMouseButton(title: "", target: nil, action: nil)
        button.bezelStyle = .regularSquare
        button.isBordered = false
        button.wantsLayer = true
        button.layer?.cornerRadius = Self.toolbarButtonCornerRadius
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)?
            .withSymbolConfiguration(.init(pointSize: Self.toolbarIconPointSize, weight: .medium))
        button.imageScaling = .scaleNone
        button.toolTip = title
        button.setButtonType(.momentaryChange)
        button.onAction = { [weak button] in if let button { action(button) } }
        // 不给宽高约束也不设 frame：尺寸由图标的内禀大小决定（见 toolbarIconPointSize 的说明）
        return button
    }

    private func divider(_ height: CGFloat = OverlayEditorController.colorPanelDividerHeight) -> NSView {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 1, height: height))
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.separatorColor.cgColor
        // 同上：裸 NSView 没有 intrinsicContentSize，在 NSStackView 里会被压成 0 宽
        view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            view.widthAnchor.constraint(equalToConstant: 1),
            view.heightAnchor.constraint(equalToConstant: height),
        ])
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
        updateColorAnchor()
        contentView?.needsDisplay = true
    }

    // ── 颜色 / 粗细控件 ─────────────────────────────────────

    private func colorDotButton(_ color: RGBColor) -> NSButton {
        let button = FirstMouseButton(title: "", target: nil, action: nil)
        button.bezelStyle = .regularSquare
        button.isBordered = false
        button.wantsLayer = true
        button.layer?.backgroundColor = color.cgColor
        // 圆形：圆角 = 边长的一半（1.0.10 用户口径「颜色改成圆形的」）
        button.layer?.cornerRadius = Self.swatchSide / 2
        button.toolTip = "颜色 \(color.hexString)（有选中标注时直接改它）"
        button.setButtonType(.momentaryChange)
        button.onAction = { [weak self] in
            self?.doc.applyToSelected(color: color)
            self?.refresh()
        }
        button.frame = NSRect(x: 0, y: 0, width: Self.swatchSide, height: Self.swatchSide)
        // 🔴 这几条约束不能省：NSStackView 按 intrinsicContentSize 排，
        // 而这个按钮 title 为空、只有 layer 底色 → intrinsic 是 0×0，
        // 整排色块会被压成 0 宽（表现为"颜色面板是空的"）。
        button.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: Self.swatchSide),
            button.heightAnchor.constraint(equalToConstant: Self.swatchSide),
        ])
        return button
    }

    private func lineWidthButton(_ width: CGFloat) -> NSButton {
        let button = FirstMouseButton(title: "", target: nil, action: nil)
        button.bezelStyle = .regularSquare
        button.isBordered = false
        button.wantsLayer = true
        button.layer?.cornerRadius = 3
        button.toolTip = "粗细 \(Int(width)) px"
        button.setButtonType(.momentaryChange)
        // 示意线：跟色块同高，否则这几颗比色块高，面板会被它们撑住不跟着缩
        let boxH = Self.swatchSide
        let boxW = (Self.swatchSide * 1.3).rounded()
        let image = NSImage(size: NSSize(width: boxW, height: boxH))
        image.lockFocus()
        if let ctx = NSGraphicsContext.current?.cgContext {
            ctx.setStrokeColor(NSColor.white.cgColor)
            ctx.setLineWidth(min(boxH * 0.6, max(1.5, width / 2)))
            ctx.setLineCap(.round)
            ctx.move(to: CGPoint(x: 2, y: boxH / 2))
            ctx.addLine(to: CGPoint(x: boxW - 2, y: boxH / 2))
            ctx.strokePath()
        }
        image.unlockFocus()
        button.image = image
        button.onAction = { [weak self] in
            self?.doc.applyToSelected(lineWidth: width)
            self?.refresh()
        }
        button.frame = NSRect(x: 0, y: 0, width: boxW, height: boxH)
        button.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: boxW),
            button.heightAnchor.constraint(equalToConstant: boxH),
        ])
        return button
    }

    // ── 输出动作 ────────────────────────────────────────────

    private func renderedImage() -> CGImage? {
        doc.rendered()
    }

    func copyToClipboard() {
        guard let image = renderedImage() else { return }
        Support.copyImageToClipboard(image)
        model?.playFeedbackSound()
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
        // 编码失败以前是静默 return：用户点「保存」什么都不发生，也看不到任何提示，
        // 看起来就像"保存格式这个设置没用"。宁可报一句，也别当无事发生。
        guard let data = ImageEncode.data(image, format: format, jpgQuality: quality) else {
            contentView?.flashStatus("\(format.title) 编码失败，换 PNG 再试")
            return
        }
        do {
            try data.write(to: url)
            didPersist = true
            model?.playFeedbackSound()
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
            guard event.window === self.imagePanel
                || event.window === self.toolbarPanel
                || event.window === self.colorPanel else { return event }
            // 文字输入中不抢键盘
            if self.contentView?.isEditingText == true { return event }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            switch event.keyCode {
            case 53: // Esc：强制结束截屏（用户 1.0.9 要求「全局 Esc 都能结束」）
                // 分两步是为了别把"手一抖"变成"白干"：先撤掉正在进行的动作
                // （待确认的裁剪 / 正在画的那一笔），再按一次才关浮层。
                // 关的时候走 close()：自动保存开着就照常落盘，不算丢图。
                if self.cancelCropIfPending() { return nil }
                if self.contentView?.cancelDraft() == true { return nil }
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

        // 🔴 这里**故意不监听框外点击**。
        // 点一下浮层外面就关掉并丢标注，用户只是切个窗口辛苦标的就没了 ——
        // 那属于"没主动取消却被结束"。出口只留两个：✕ 按钮、Esc（一次撤动作、
        // 一次关浮层），都是明确意图。
    }
}

// ============================================================
// 浮层内容视图：图像 + 标注 + 尺寸条
// ============================================================

final class OverlayEditorView: NSView {

    private let doc: EditorDocument
    private unowned let controller: OverlayEditorController
    /// 底图在视图里的位置（flipped 视图坐标）。拖手柄改尺寸时以它为准。
    private var imageRect: NSRect
    private let displayScale: CGFloat
    /// 能不能拖手柄改截图框（要有整屏原图才做得到）
    private let canResize: Bool

    private var pixelScale: CGFloat {
        CGFloat(doc.baseImage.width) / imageRect.width
    }

    // ── 改截图框尺寸 ────────────────────────────────────────
    enum ResizeHandle: CaseIterable {
        case topLeft, top, topRight, left, right, bottomLeft, bottom, bottomRight
        func point(in rect: CGRect) -> CGPoint {
            switch self {
            case .topLeft:     return CGPoint(x: rect.minX, y: rect.minY)
            case .top:         return CGPoint(x: rect.midX, y: rect.minY)
            case .topRight:    return CGPoint(x: rect.maxX, y: rect.minY)
            case .left:        return CGPoint(x: rect.minX, y: rect.midY)
            case .right:       return CGPoint(x: rect.maxX, y: rect.midY)
            case .bottomLeft:  return CGPoint(x: rect.minX, y: rect.maxY)
            case .bottom:      return CGPoint(x: rect.midX, y: rect.maxY)
            case .bottomRight: return CGPoint(x: rect.maxX, y: rect.maxY)
            }
        }
        var cursor: NSCursor {
            switch self {
            case .topLeft, .bottomRight: return .crosshair
            case .topRight, .bottomLeft: return .crosshair
            case .left, .right: return .resizeLeftRight
            case .top, .bottom: return .resizeUpDown
            }
        }
    }
    private var resizeHandle: ResizeHandle?
    private var resizeStartRect: CGRect?
    private var resizeStartPoint: CGPoint?
    /// 拖动中的新框（视图坐标），松手才提交
    private(set) var previewRect: CGRect?

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
         imageRect: NSRect, displayScale: CGFloat, canResize: Bool = false) {
        self.doc = doc
        self.controller = controller
        self.imageRect = imageRect
        self.displayScale = displayScale
        self.canResize = canResize
        // 真正的尺寸由 AppKit 按窗口内容区设（设置为 contentView 时会重设 frame），
        // 这里给个不小于底图的初值就行
        super.init(frame: NSRect(origin: .zero,
                                 size: NSSize(width: max(imageRect.maxX, 320),
                                              height: max(imageRect.maxY, 240))))
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    // ── 绘制 ────────────────────────────────────────────────

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

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
        drawHandleDots(ctx, on: imageRect)

        drawCropMask(ctx)

        // 拖手柄改尺寸中的新框：框外压暗 + 白虚线 + 手柄，尺寸条跟着走
        if let preview = previewRect {
            fillOutside(preview, ctx: ctx)
            ctx.setStrokeColor(NSColor.white.cgColor)
            ctx.setLineWidth(1.5)
            ctx.setLineDash(phase: 0, lengths: [6, 4])
            ctx.stroke(preview)
            ctx.setLineDash(phase: 0, lengths: [])
            drawHandleDots(ctx, on: preview)
        }

        // 尺寸条：贴在当前框的正上方（跟着框走，用户要的"工具条跟着框"）
        drawSizeBar(ctx, above: previewRect ?? imageRect)
    }

    /// 八个手柄：白底 + 蓝环，跟系统截图那个观感一致
    private func drawHandleDots(_ ctx: CGContext, on rect: CGRect) {
        let points = canResize
            ? ResizeHandle.allCases.map { $0.point(in: rect) }
            : [
                CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.midX, y: rect.minY),
                CGPoint(x: rect.maxX, y: rect.minY), CGPoint(x: rect.minX, y: rect.midY),
                CGPoint(x: rect.maxX, y: rect.midY), CGPoint(x: rect.minX, y: rect.maxY),
                CGPoint(x: rect.midX, y: rect.maxY), CGPoint(x: rect.maxX, y: rect.maxY),
            ]
        for point in points {
            let dot = CGRect(x: point.x - 4.5, y: point.y - 4.5, width: 9, height: 9)
            ctx.setFillColor(NSColor.white.cgColor)
            ctx.fillEllipse(in: dot)
            ctx.setStrokeColor(NSColor.controlAccentColor.cgColor)
            ctx.setLineWidth(1.6)
            ctx.strokeEllipse(in: dot)
        }
    }

    /// 把 rect 以外全部压暗（四条带拼起来，不用 even-odd 填充）
    private func fillOutside(_ rect: CGRect, ctx: CGContext) {
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.45).cgColor)
        let bands = [
            CGRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: rect.minY - bounds.minY),
            CGRect(x: bounds.minX, y: rect.maxY, width: bounds.width, height: bounds.maxY - rect.maxY),
            CGRect(x: bounds.minX, y: rect.minY, width: rect.minX - bounds.minX, height: rect.height),
            CGRect(x: rect.maxX, y: rect.minY, width: bounds.maxX - rect.maxX, height: rect.height),
        ]
        for band in bands where band.width > 0 && band.height > 0 { ctx.fill(band) }
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

    /// Esc 用：丢掉正在拖/正在画的那一笔（没有正在进行的就返回 false）。
    /// 返回 false 时调用方**不要**顺手把浮层关掉 —— 用户要求只有主动点 ✕ 才结束。
    @discardableResult
    func cancelDraft() -> Bool {
        if resizeHandle != nil {
            resizeHandle = nil
            resizeStartRect = nil
            resizeStartPoint = nil
            previewRect = nil
            needsDisplay = true
            return true
        }
        guard draft != nil || draftStart != nil || draggingSelection else { return false }
        draft = nil
        draftStart = nil
        draggingSelection = false
        dragLastPoint = nil
        needsDisplay = true
        return true
    }

    /// 尺寸条：贴在框的正上方，框一动它就动（框贴到屏幕顶边时改放框内侧）
    private func drawSizeBar(_ ctx: CGContext, above rect: CGRect) {
        var text = "\(Int(rect.width * pixelScale)) × \(Int(rect.height * pixelScale))"
        if let statusMessage { text += "   \(statusMessage)" }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: NSColor.white,
        ]
        let size = (text as NSString).size(withAttributes: attributes)
        let barSize = CGSize(width: size.width + 22, height: size.height + 10)
        var origin = CGPoint(x: rect.minX, y: rect.minY - barSize.height - 8)
        if origin.y < bounds.minY + 2 {
            // 框贴到屏幕顶边：有整屏原图就挪到框内侧；小窗模式放回顶部预留条
            origin.y = canResize ? rect.minY + 8 : bounds.minY + 3
        }
        if origin.x + barSize.width > bounds.maxX - 2 {
            origin.x = max(bounds.minX + 2, bounds.maxX - barSize.width - 2)
        }
        let barRect = CGRect(origin: origin, size: barSize)
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.72).cgColor)
        ctx.addPath(CGPath(roundedRect: barRect, cornerWidth: 7, cornerHeight: 7, transform: nil))
        ctx.fillPath()
        (text as NSString).draw(at: CGPoint(x: barRect.minX + 11, y: barRect.minY + 5),
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

    /// 拖手柄改尺寸：命中判据（先角、再边线中段）
    private func resizeHandleHit(at point: CGPoint) -> ResizeHandle? {
        let tolerance: CGFloat = 9
        for handle in ResizeHandle.allCases {
            let hp = handle.point(in: imageRect)
            if abs(point.x - hp.x) <= tolerance && abs(point.y - hp.y) <= tolerance { return handle }
        }
        guard imageRect.insetBy(dx: -3, dy: -3).contains(point) else { return nil }
        if abs(point.x - imageRect.minX) <= 3 { return .left }
        if abs(point.x - imageRect.maxX) <= 3 { return .right }
        if abs(point.y - imageRect.minY) <= 3 { return .top }
        if abs(point.y - imageRect.maxY) <= 3 { return .bottom }
        return nil
    }

    /// 按手柄 + 位移算新框，夹在屏幕内，最小 40×40。
    /// 抽成静态是为了自检能测 —— 这里错了就是"一拖手柄截图框乱飞"。
    static func resizedRect(_ origin: CGRect, handle: ResizeHandle, delta: CGPoint,
                            bounds: CGRect) -> CGRect {
        var minX = origin.minX, maxX = origin.maxX
        var minY = origin.minY, maxY = origin.maxY
        switch handle {
        case .topLeft:     minX += delta.x; minY += delta.y
        case .top:         minY += delta.y
        case .topRight:    maxX += delta.x; minY += delta.y
        case .left:        minX += delta.x
        case .right:       maxX += delta.x
        case .bottomLeft:  minX += delta.x; maxY += delta.y
        case .bottom:      maxY += delta.y
        case .bottomRight: maxX += delta.x; maxY += delta.y
        }
        var rect = CGRect(x: min(minX, maxX), y: min(minY, maxY),
                          width: abs(maxX - minX), height: abs(maxY - minY)).integral
        rect.origin.x = min(max(bounds.minX, rect.origin.x), max(bounds.minX, bounds.maxX - 40))
        rect.origin.y = min(max(bounds.minY, rect.origin.y), max(bounds.minY, bounds.maxY - 40))
        rect.size.width = min(rect.width, bounds.maxX - rect.minX)
        rect.size.height = min(rect.height, bounds.maxY - rect.minY)
        return rect
    }

    /// 视图坐标（flipped，窗口内）→ AppKit 全局坐标（左下原点）
    private func appKitRect(fromView rect: CGRect) -> CGRect {
        let origin = window?.frame.origin ?? .zero
        return CGRect(x: rect.minX + origin.x,
                      y: origin.y + (bounds.height - rect.maxY),
                      width: rect.width, height: rect.height)
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        guard canResize else { return }
        for handle in ResizeHandle.allCases {
            let point = handle.point(in: imageRect)
            addCursorRect(CGRect(x: point.x - 8, y: point.y - 8, width: 16, height: 16),
                          cursor: handle.cursor)
        }
    }

    override func mouseDown(with event: NSEvent) {
        // 文字输入中：先提交再继续
        if let field = textField { commitTextField(field) }

        let viewPoint = convert(event.locationInWindow, from: nil)

        // 🔴 拖手柄改截图框优先于一切绘制工具：手柄就压在图边缘上，
        // 不让它优先的话，想调尺寸永远会先画出一条线。
        if canResize, let handle = resizeHandleHit(at: viewPoint) {
            resizeHandle = handle
            resizeStartRect = imageRect
            resizeStartPoint = viewPoint
            previewRect = nil
            needsDisplay = true
            return
        }

        let p = clampToImage(pixelPoint(event))
        guard imageRect.contains(viewPoint) else { return }

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
        let viewPoint = convert(event.locationInWindow, from: nil)
        if let handle = resizeHandle, let startRect = resizeStartRect, let start = resizeStartPoint {
            previewRect = Self.resizedRect(startRect, handle: handle,
                                           delta: CGPoint(x: viewPoint.x - start.x, y: viewPoint.y - start.y),
                                           bounds: bounds)
            needsDisplay = true
            return
        }
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
        if resizeHandle != nil {
            let target = previewRect
            resizeHandle = nil
            resizeStartRect = nil
            resizeStartPoint = nil
            previewRect = nil
            needsDisplay = true
            if let target { controller.commitResize(to: appKitRect(fromView: target)) }
            return
        }
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

/// 非 key 窗口里的 NSButton 默认 **第一下点击会被吞掉**（acceptsFirstMouse = false）：
/// 面板一旦失去焦点（点了工具条、点了截图），再点颜色就要连点两次才有反应，
/// 表现就是"颜色面板点了没反应"。这个子类一律接受首击。
final class FirstMouseButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
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
