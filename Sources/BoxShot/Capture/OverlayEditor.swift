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
    private var fontSizePopup: NSPopUpButton?
    private var colorAnchorButton: NSButton?
    private var colorPanel: NSPanel?
    private var monitors: [Any] = []
    /// 本次截图是否已落盘（保存过 / 自动保存过就不再重复写）
    private var didPersist = false
    /// close() 只走一遍：动作后的延迟关 + 用户手点关闭可能撞车，第二遍直接跳过
    private var didClose = false
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

    // ── 文字编辑诊断（`--textedit`）──
    // 用户要的是"打字时看到的就是最终效果"，这件事只有端到端截图能证：
    // 编辑器框和渲染框即使数值一样，CoreText 与 NSTextView 的行基线也可能差
    // 一两像素 —— 那就是确认瞬间"文字跳一下"。
    func textEditForDiagnostics(at pixelPoint: CGPoint, typing text: String) -> Bool {
        guard let view = contentView else { return false }
        doc.tool = .text
        view.beginTextEditingForDiagnostics(at: pixelPoint)
        guard let editor = view.editorForDiagnostics else { return false }
        let all = NSRange(location: 0, length: (editor.string as NSString).length)
        editor.insertText(text, replacementRange: all)
        return true
    }
    func commitTextForDiagnostics() { contentView?.commitTextEditing() }
    /// 诊断用：编辑器里当前的文字
    var editorTextForDiagnostics: String? { contentView?.editorForDiagnostics?.string }
    /// 诊断用：模拟"双击已有文字接着改"（走和真实双击同一条命中逻辑）
    func reeditTextForDiagnostics(at pixelPoint: CGPoint) -> String? {
        guard let view = contentView,
              let hit = view.textShapeForDiagnostics(at: pixelPoint) else { return nil }
        view.beginTextEditingForDiagnostics(at: hit.points.first ?? pixelPoint, existing: hit)
        return view.editorForDiagnostics?.string
    }
    /// 诊断用：清空编辑器里的文字（随后确认应该把这条空文字删掉）
    func clearEditorForDiagnostics() { contentView?.clearEditorForDiagnostics() }
    /// 诊断用：把插入光标染成透明。
    /// 光标不属于"最终效果"，留着会在截图里多出一整根黑竖条 —— 包围盒高度
    /// 会被它撑大 17px 左右，看起来像"确认后文字变小了"。
    func hideEditorCaretForDiagnostics() {
        contentView?.editorForDiagnostics?.insertionPointColor = .clear
    }
    var editorFrameForDiagnostics: NSRect? { contentView?.editorFrameForDiagnostics }
    var isEditingTextForDiagnostics: Bool { contentView?.isEditingText ?? false }
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
        guard !didClose else { return }
        didClose = true
        // 关闭前把没确认的文字收下：自动保存开着的话，那行字要进落盘的图
        contentView?.commitTextEditing()
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
    /// 工具条容器圆角。2026-11-02 用户口径「工具条 1 改成工具条 2 的圆角矩形」：
    /// 以前工具条是 14、颜色面板是 10，两条摆在一起圆角对不上；
    /// 现在共用这一个常量（10），改圆角只动这里。
    static let toolbarContainerCornerRadius: CGFloat = 10
    /// 工具条 / 颜色面板容器底色：**不透明灰黑**。
    /// 2026-11-02 用户口径「两个工具条变成圆角矩形框，底色为不透明的灰黑色」——
    /// 以前是 NSVisualEffectView(.hudWindow) 毛玻璃，截图内容（晚霞之类的暖色）
    /// 会从底下透出来，图标看着发脏。改成实心 NSView + layer 底色，
    /// 圆角不变。工具条和颜色面板必须用同一个值，别一处实心一处毛玻璃。
    static let toolbarBackgroundColor = ToolbarTheme.background
    /// 🔴 工具条容器**强制深色外观**。
    ///
    /// 底色是写死的深灰，但如果容器不切外观，里面的 `NSImage(systemSymbolName:)`
    /// 模板图和 `.labelColor` 仍按系统外观解析 —— 系统是浅色时图标 / 文字全部
    /// 渲染成黑色，压在 0.13 的深底上等于隐形（2026-11-03 用户截图反馈）。
    /// 之前那版是毛玻璃 `.hudWindow`，材质本身就把前景衬成浅色，所以没暴露；
    /// 换成实心 NSView 之后这个问题才浮出来。
    ///
    /// 切外观比逐个手写前景色更彻底：分隔线（separatorColor）、禁用态、以后
    /// 加进来的控件都跟着对，不会漏一个。
    static let toolbarAppearance = ToolbarTheme.appearance
    /// 工具条前景色（图标 + 文字）：**纯白，写死**。
    /// 底色是写死的深灰，前景就不能用随外观翻转的颜色。
    /// 也不能只靠切 `.darkAqua`：深色外观下的 `.labelColor` 是带透明度的白，
    /// 图标看起来是浅灰（2026-11-03 用户指着截图说"这些灰色图标改白色"）。
    static let toolbarForegroundColor = ToolbarTheme.foreground
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
            let button: NSButton
            if let label = tool.toolbarLabel {
                // 文字工具：图标位显示「文字」两个字（textformat 字形
                // 在中文环境渲染成「格式」，用户口径 2026-11-02 改掉）
                button = toolbarTextButton(label, title: tool.title) { [weak self] in
                    self?.selectTool(tool)
                }
            } else {
                button = toolbarButton(symbol: tool.symbol, title: tool.title) { [weak self] in
                    self?.selectTool(tool)
                }
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

        // 1.0.27 用户口径「在工具条加上 编辑 按钮，点击进入编辑器，同时关闭截图窗」
        // 位置按他给的截图：高亮与 OCR 之间。图标用 square.and.pencil（系统里"编辑/
        // 撰写"的通用符号），别跟画笔 pencil.tip、马克笔 highlighter 撞。
        stack.addArrangedSubview(toolbarButton(symbol: "square.and.pencil",
                                               title: "在编辑窗口中打开 ⌘E") { [weak self] in
            self?.openInEditorWindow()
        })

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
        // 不透明灰黑实底（2026-11-02 用户口径）。以前是 NSVisualEffectView(.hudWindow)
        // 毛玻璃，截图内容从底下透出来；NSVisualEffectView 无论 state 怎么调都会画
        // 一层材质，要实底就得换成普通 NSView + layer 底色。
        // 容器用可拖的子类：按住按钮间隙 / 内边距能挪工具条（用户 1.0.27 口径）。
        // 注意只有**工具条**这个容器是它；下面颜色面板那个仍是普通 NSView。
        let container = DraggableToolbarContainer(frame: NSRect(origin: .zero, size: size))
        container.wantsLayer = true
        container.appearance = Self.toolbarAppearance
        container.layer?.cornerRadius = Self.toolbarContainerCornerRadius
        container.layer?.backgroundColor = Self.toolbarBackgroundColor.cgColor
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
        button.layer?.borderColor = ToolbarTheme.swatchBorder.cgColor
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
    /// 诊断用：字号下拉本体（验菜单项与 target/action 有没有接上）
    var fontSizePopupForDiagnostics: NSPopUpButton? { fontSizePopup }
    /// 诊断用：当前默认字号（点）
    var docFontSizeForDiagnostics: CGFloat { doc.fontSize }

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
        for width in Self.lineWidthOptions {
            let button = lineWidthButton(width)
            widthButtons[width] = button
            stack.addArrangedSubview(button)
        }
        // 字号：跟颜色 / 粗细同一条面板（用户 2026-11-03 口径「在颜色控制工具条那里加上
        // 字号控制，下拉，分 6 个档」）。放最右边，中间隔一条竖线 —— 左边三组是"笔画长什么样"，
        // 右边这个是"文字多大"，语义上本来就不是一类。
        stack.addArrangedSubview(divider())
        let popup = fontSizePopUp()
        fontSizePopup = popup
        stack.addArrangedSubview(popup)
        stack.layoutSubtreeIfNeeded()
        let size = stack.fittingSize

        // 同工具条：不透明灰黑实底 + 圆角（圆角共用 toolbarContainerCornerRadius）
        let container = NSView(frame: NSRect(origin: .zero, size: size))
        container.wantsLayer = true
        container.appearance = Self.toolbarAppearance
        container.layer?.cornerRadius = Self.toolbarContainerCornerRadius
        container.layer?.backgroundColor = Self.toolbarBackgroundColor.cgColor
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

    /// 6 档字号（**点**）。默认 30 落在正中间 —— 加控件之前浮层里写死的就是
    /// `30 * pixelScale`，档位必须包含它，否则老用户的第一段字会突然变大变小。
    /// 20→68 大约是 3.4 倍，够覆盖「一行小注」到「整屏大字标题」。
    static let fontSizeOptions: [CGFloat] = [20, 24, 30, 40, 52, 68]

    /// 字号 → 档位序号：取**最近**的一档。
    /// 为什么要"最近"而不是精确相等：形状里的字号是图像像素，换成点再换回来会带
    /// 浮点误差（2x 屏 60px → 30.0000001pt），精确匹配会一个都对不上 → 下拉永远
    /// 显示第 1 档，用户改完字号看着像没生效。
    static func fontSizeIndex(for points: CGFloat) -> Int {
        var best = 0
        var bestDelta = CGFloat.greatestFiniteMagnitude
        for (index, option) in fontSizeOptions.enumerated() {
            let delta = abs(option - points)
            if delta < bestDelta {
                bestDelta = delta
                best = index
            }
        }
        return best
    }

    /// 色块直径（pt）：圆形，圆角取一半。
    /// 1.0.10 用户口径「颜色圆形调小一点，小 20%」：26 × 0.8。
    /// 1.0.11 又「调小 10%」：再 × 0.9 = 18.72。
    /// 写成连乘而不是直接写 18.72，是为了以后"再小 10%"能一眼看出基数是谁。
    static let swatchSide: CGFloat = 26 * 0.8 * 0.9

    /// 颜色面板里那条分隔线的高度：跟着色块一起缩，否则会顶出一截
    static let colorPanelDividerHeight: CGFloat = 18

    /// 3 档粗细（**图像像素**）。
    ///
    /// 用户 2026-11-04 口径「粗细增加 9 px」：原档位 `3 / 6 / 12` 各 +9 → `12 / 15 / 21`。
    /// 这里的 px 就是 tooltip 上写的那个（`AnnotationShape.lineWidth` 存的是**图像像素**，
    /// 不是点 —— 2x 截图上 21px = 屏幕上 10.5pt）。
    static let lineWidthOptions: [CGFloat] = [12, 15, 21]

    /// 档位示意线的粗细（pt，画在面板里那颗小按钮上）。
    ///
    /// 封顶 `boxHeight * 0.6`：按钮高 = 色块直径（18.72），不封顶的话最粗一档会顶满整个按钮；
    /// 下限 1.5 是"再细也得看得见"。抽成纯函数是为了自检能验"三档画出来还得有区别、且不溢出"。
    static func lineWidthSampleWidth(for width: CGFloat, boxHeight: CGFloat) -> CGFloat {
        min(boxHeight * 0.6, max(1.5, width / 2))
    }

    /// 调色板：6 个颜色（1.0.10 用户口径「颜色 6 个颜色」，顺序按他给的色卡）。
    /// 真身在 RGBColor.palette（编辑窗口共用同一份）；这里留常量别名，
    /// 自检盯着数量 —— 以前是散在这里的数组字面量，加一个减一个没人会发现。
    static let colorPalette: [RGBColor] = RGBColor.palette

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

    /// 文字标签按钮（文字工具用）：图标位放两个字。选中高亮与其他按钮
    /// 同一套 layer 底色（refresh() 只认 toolButtons 里的 layer）。
    private func toolbarTextButton(_ text: String, title: String, action: @escaping () -> Void) -> NSButton {
        let button = FirstMouseButton(title: text, target: nil, action: nil)
        button.bezelStyle = .regularSquare
        button.isBordered = false
        button.wantsLayer = true
        button.layer?.cornerRadius = Self.toolbarButtonCornerRadius
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: Self.toolbarIconPointSize * 0.62, weight: .medium),
            .foregroundColor: Self.toolbarForegroundColor,
        ]
        button.attributedTitle = NSAttributedString(string: text, attributes: attributes)
        button.toolTip = title
        button.setButtonType(.momentaryChange)
        button.onAction = { [weak button] in if let button { action() } }
        return button
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
        // 纯白：模板图默认按 `.labelColor` 着色，深色外观下那是"带透明度的白"，
        // 摆在 0.13 的深灰底上看着是灰的（用户要的是白色）。
        // 这个工具条没有禁用态按钮，不必担心 tint 固定后看不出 disabled。
        button.contentTintColor = Self.toolbarForegroundColor
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
        view.layer?.backgroundColor = ToolbarTheme.divider.cgColor
        // 同上：裸 NSView 没有 intrinsicContentSize，在 NSStackView 里会被压成 0 宽
        view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            view.widthAnchor.constraint(equalToConstant: 1),
            view.heightAnchor.constraint(equalToConstant: height),
        ])
        return view
    }

    private func selectTool(_ tool: EditorTool) {
        // 换工具 = 结束当前文字编辑（工具条是另一个面板，点它不会走 contentView 的
        // mouseDown，不在这里收口的话，切到矩形工具后那段文字还留在编辑态）
        contentView?.commitTextEditing()
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
        syncFontSizePopup()
        updateColorAnchor()
        contentView?.needsDisplay = true
    }

    /// 下拉显示哪一档：选中了文字就看**那条文字**的字号，否则看默认值。
    /// 不这么做的话，双击一条 52pt 的旧文字接着改，下拉还显示 30 —— 用户以为
    /// 字号没记住，一改又从 30 开始。
    private func syncFontSizePopup() {
        guard let popup = fontSizePopup else { return }
        let points: CGFloat
        if let selected = doc.selectedShape, selected.tool == .text, selected.fontSize > 0 {
            points = selected.fontSize / max(0.001, selectionPixelScale)
        } else {
            points = doc.fontSize
        }
        let index = Self.fontSizeIndex(for: points)
        if popup.indexOfSelectedItem != index {
            popup.selectItem(at: index)
        }
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
            // 改颜色前先收掉正在输入的文字：不然文字视图还按旧色画，
            // 确认那一刻颜色才跳变（另一半是"改色没生效"的错觉）
            self?.contentView?.commitTextEditing()
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

    // ── 字号下拉（6 档）──────────────────────────────────

    /// 下拉宽度。🔴 AppKit 控件的自然宽度要**进窗口后**才准，初始化时量出来偏窄：
    /// 按测量值定宽会把「30 pt」挤成「30 p…」。所以显式给一个宁宽勿窄的值。
    static let fontSizePopupWidth: CGFloat = 68

    private func fontSizePopUp() -> NSPopUpButton {
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0,
                                                width: Self.fontSizePopupWidth, height: 22),
                                  pullsDown: false)
        popup.isBordered = false
        popup.controlSize = .small
        popup.font = .systemFont(ofSize: 12 * Self.toolbarScale, weight: .medium)
        // 底色是写死的深灰，前景也得写死：深色外观下 `.labelColor` 是带透明度的白，
        // 看着发灰（工具条图标那次已经被这条坑过一次）。
        popup.contentTintColor = Self.toolbarForegroundColor
        popup.addItems(withTitles: Self.fontSizeOptions.map { "\(Int($0)) pt" })
        popup.toolTip = "字号（只作用于文字）：20 / 24 / 30 / 40 / 52 / 68 pt"
        popup.target = self
        popup.action = #selector(fontSizeChanged(_:))
        popup.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            popup.widthAnchor.constraint(equalToConstant: Self.fontSizePopupWidth),
            popup.heightAnchor.constraint(equalToConstant: 22),
        ])
        popup.selectItem(at: Self.fontSizeIndex(for: doc.fontSize))
        return popup
    }

    @objc private func fontSizeChanged(_ sender: NSPopUpButton) {
        let index = sender.indexOfSelectedItem
        guard Self.fontSizeOptions.indices.contains(index) else { return }
        changeFontSize(Self.fontSizeOptions[index])
    }

    /// 改字号（点）。三条路各走各的，别一股脑先 commit：
    ///   - **正在输入**：实时改（连编辑器一起换），不压撤销点 —— 落盘时随整段编辑一起算一个点；
    ///   - 选中了一条文字：改它（进撤销栈），同时把默认值也改掉，下一段字沿用；
    ///   - 别的工具 / 没选中：只改默认值。
    private func changeFontSize(_ points: CGFloat) {
        doc.fontSize = points
        if contentView?.isEditingText == true {
            contentView?.setLiveFontSize(points)
        } else {
            doc.applyToSelected(fontSize: points * selectionPixelScale)
        }
        refresh()
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
            ctx.setLineWidth(Self.lineWidthSampleWidth(for: width, boxHeight: boxH))
            ctx.setLineCap(.round)
            ctx.move(to: CGPoint(x: 2, y: boxH / 2))
            ctx.addLine(to: CGPoint(x: boxW - 2, y: boxH / 2))
            ctx.strokePath()
        }
        image.unlockFocus()
        button.image = image
        button.onAction = { [weak self] in
            self?.contentView?.commitTextEditing()
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
        // 正在输入的文字先落盘：用户打完字不按回车、直接点「复制」，最后那行
        // 字必须进图。所有输出动作（保存 / 复制 / 贴图 / OCR / 二维码）都走这里，
        // 在这一个地方收口，比在五个按钮里各写一遍靠谱。
        contentView?.commitTextEditing()
        return doc.rendered()
    }

    // ── 完成即关（用户 1.0.24）─────────────────────────────
    //
    // 设置里的「完成后直接关闭截图窗口」：OCR / 解码 QR / 贴图 / 复制 / 下载
    // 任一动作**成功**后就地把浮层收掉。三处细节：
    // · 延迟 0.5s 再关 —— flashStatus 那句"已复制 / 已保存"得来得及看；
    // · 延迟还顺手绕开老坑：不能在自己的按钮事件回调里同步拆自己的窗口
    //   （asyncAfter 闭包强持有 self，close() 全程引用都活着）；
    // · 失败不关：QR 没认出来、保存编码失败、保存面板点了取消，浮层都留着。

    /// 动作成功后的统一出口：开了开关才关，没开就保持原行为
    private func finishAfterAction() {
        guard let model, model.prefs.value.closeAfterAction else { return }
        let holder = self
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { holder.close() }
    }

    /// 自检用：给定开关状态，动作成功后应不应该关（纯函数，不碰 UI）
    static func shouldCloseAfterAction(enabled: Bool) -> Bool { enabled }

    func copyToClipboard() {
        guard let image = renderedImage() else { return }
        Support.copyImageToClipboard(image)
        model?.playFeedbackSound()
        contentView?.flashStatus("已复制到剪贴板")
        finishAfterAction()
    }

    func save() {
        guard let image = renderedImage(), let model else { return }
        let prefs = model.prefs.value
        let suggestedName = Support.shotFileName(ext: prefs.shotFormat.fileExtension)

        if prefs.autoSave, let dirPath = prefs.saveDirectory, !dirPath.isEmpty {
            let directory = URL(fileURLWithPath: dirPath, isDirectory: true)
            if write(image: image, format: prefs.shotFormat,
                     quality: prefs.jpgQuality, to: Support.uniqueFileURL(in: directory, name: suggestedName)) {
                finishAfterAction()
            }
            return
        }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName
        panel.allowedContentTypes = prefs.shotFormat == .png ? [.png] : [.jpeg]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if write(image: image, format: prefs.shotFormat, quality: prefs.jpgQuality, to: url) {
            finishAfterAction()
        }
    }

    @discardableResult
    private func write(image: CGImage, format: ShotFormat, quality: Double, to url: URL) -> Bool {
        // 编码失败以前是静默 return：用户点「保存」什么都不发生，也看不到任何提示，
        // 看起来就像"保存格式这个设置没用"。宁可报一句，也别当无事发生。
        guard let data = ImageEncode.data(image, format: format, jpgQuality: quality) else {
            contentView?.flashStatus("\(format.title) 编码失败，换 PNG 再试")
            return false
        }
        do {
            try data.write(to: url)
            didPersist = true
            model?.playFeedbackSound()
            contentView?.flashStatus("已保存：\(url.lastPathComponent)")
            return true
        } catch {
            contentView?.flashStatus("保存失败：\(error.localizedDescription)")
            return false
        }
    }

    func pin() {
        guard let image = renderedImage() else { return }
        model?.pinImage(image)
        contentView?.flashStatus("已贴图")
        finishAfterAction()
    }

    /// 把当前截图（连同已经画好的标注）送进独立编辑窗口，并把原位浮层收掉。
    ///
    /// 用户 1.0.27 口径：「点击进入编辑器，同时关闭截图窗」——所以这里**无条件**
    /// 关浮层，跟「完成后直接关闭截图窗口」那个开关无关（那个管 OCR / 解码 /
    /// 贴图 / 复制 / 下载）。内容已经整份交给编辑窗口，浮层再留着就是两张一样的图。
    ///
    /// 🔴 交的是 `baseImage + shapes`，**不是**压平后的 rendered()：编辑器本来就
    /// 收 shapes（`EditorWindowController.show(image:shapes:)`），两边坐标都是图像
    /// 像素坐标。压平了就变成"撕不下来的成品"，进去连撤销都回不去。
    /// 唯一要手工补的是正在输入的那行字 —— 它还是 contentView 里的草稿，
    /// 不 commit 就不在 shapes 里。
    func openInEditorWindow() {
        guard let model else { return }
        contentView?.commitTextEditing()
        let image = doc.baseImage
        let shapes = doc.shapes
        model.openEditor(image: image, shapes: shapes)
        // 🔴 别在这条按钮/按键回调里同步 close()：onClose 会把 AppModel 的
        // overlayEditors 里这条摘掉，controller 当场释放，而我们还站在这条
        // controller 的方法里（裁剪重开那次踩过一模一样的坑）。下一轮再拆自己。
        let holder = self
        DispatchQueue.main.async { holder.close() }
    }

    func ocr() {
        guard let image = renderedImage() else { return }
        model?.runOCR(image: image)
        // OCR 没有回调可等：结果窗稍后自己弹出来。识别失败走的是全局报错，
        // 浮层在这里就算"已交出去"，照样按完成关。
        finishAfterAction()
    }

    func decodeQR() {
        guard let image = renderedImage() else { return }
        // 先给一句"在识别"：整屏图上 Vision 要几百毫秒，中间没有一点反馈，
        // 用户会认定按钮是坏的（"扫码功能扫不了"里有这一半）。
        contentView?.flashStatus("正在识别二维码…")
        model?.runQR(image: image) { [weak self] payloads in
            guard let self else { return }
            if let first = payloads.first {
                self.contentView?.flashStatus("已复制：\(first)")
                // 只在真认出来时才算"完成"：没认出来浮层留着，用户还得再试
                self.finishAfterAction()
            } else {
                self.contentView?.flashStatus("没有识别到 QR / 条形码")
            }
        }
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
            case 14 where flags.contains(.command): // E：进独立编辑窗口
                self.openInEditorWindow()
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
    /// 选择工具：正在拖动选中标注
    private var draggingSelection = false
    private var dragLastPoint: CGPoint?
    /// 裁剪：拖出的保留范围（图像像素坐标），⏎ 应用 / ⎋ 取消
    private var pendingCrop: CGRect?
    private var cropAnchor: CGPoint?

    /// 控制器用：当前是否有待确认的裁剪
    var hasPendingCrop: Bool { pendingCrop != nil }
    var pendingCropRect: CGRect? { pendingCrop }

    var isEditingText: Bool { editingTextView != nil }

    /// 诊断用：从外面进入文字编辑（`--textedit` 验"输入时就等于最终效果"）
    func beginTextEditingForDiagnostics(at pixelPoint: CGPoint, existing: AnnotationShape? = nil) {
        beginTextEditing(at: pixelPoint, existing: existing)
    }
    /// 诊断用：正在用的那个文本视图（往里 insertText 就等于用户打字）
    var editorForDiagnostics: NSTextView? { editingTextView }
    /// 诊断用：编辑器框（视图坐标），和 `displayBounds` 换算后应当重合
    var editorFrameForDiagnostics: NSRect? { editingTextView?.frame }
    /// 诊断用：命中的已有文字（双击那条路径）
    func textShapeForDiagnostics(at pixelPoint: CGPoint) -> AnnotationShape? {
        editableTextShape(at: pixelPoint)
    }
    /// 诊断用：把编辑器清空（模拟全选删除）
    func clearEditorForDiagnostics() {
        guard let editor = editingTextView else { return }
        let all = NSRange(location: 0, length: (editor.string as NSString).length)
        editor.insertText("", replacementRange: all)
    }

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
        // 正在编辑的那条文字**跳过绘制**：字由上面的 NSTextView 画，
        // 两边都画会叠出一层更粗更脏的重影（而且位置差半个像素会发虚）。
        // 选中框仍然由下面的 drawSelection 画，所以编辑时框跟着文字实时变长。
        let painted = editingShapeID.map { id in doc.shapes.filter { $0.id != id } } ?? doc.shapes
        EditorRenderer.drawShapes(painted, in: ctx, effects: doc.effects,
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
        // 文字输入中：先确认再继续（点到别处 = 确认，这是截图工具的惯例）
        commitTextEditing()

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
            // 双击文字 = 接着改（单击仍然是选中/拖动）
            if event.clickCount >= 2, let hit = editableTextShape(at: p) {
                beginTextEditing(at: hit.points.first ?? p, existing: hit)
                return
            }
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
                // 点在已有文字上 = 接着改；点空地 = 新建
                if let hit = editableTextShape(at: p) {
                    beginTextEditing(at: hit.points.first ?? p, existing: hit)
                } else {
                    doc.selectedID = nil
                    beginTextEditing(at: p)
                }
            case .colorPick:
                if let color = doc.pixelColor(at: p) {
                    doc.commit(AnnotationShape(tool: .colorPick, points: [p], color: color, lineWidth: 0))
                    Support.copyTextToClipboard(color.hexString)
                    flashStatus("已取色 \(color.hexString)")
                }
            case .step:
                // 步骤标注：点一下放一个编号气泡，序号渲染时按顺序自动递增
                let shape = AnnotationShape(tool: .step, points: [p], color: doc.color, lineWidth: 0)
                doc.commit(shape)
                flashStatus("步骤 \(EditorRenderer.stepNumber(of: shape, in: doc.shapes))")
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

    // ── 文字编辑（原地所见即所得）──────────────────────────
    //
    // 用户口径：输入时就直接看到最终效果，输完确认，之后还能点回来改。
    // 所以不是"弹个输入框、确定后再画字"，而是在文字落下的位置放一个**透明的
    // NSTextView**：字号、颜色、起点都跟渲染器同一套（`displayBounds` 算框），
    // 打字时屏幕上看到的就是成图里的样子，IME 候选窗也自然跟在光标旁边。
    //
    // 🔴 `textContainerInset = .zero`、`lineFragmentPadding = 0` 必须显式设：
    // NSTextView 默认带 0/5pt 的缩进，不关掉的话确认一瞬间文字会往左上"跳一下"。

    private var editingTextView: NSTextView?
    private var editingShapeID: UUID?
    /// 编辑前那份 shapes：确认时压成**一个**撤销点，取消时整体回滚
    private var editSnapshot: [AnnotationShape]?

    /// 视图点 / 图像像素
    private var viewPerPixel: CGFloat {
        imageRect.width / CGFloat(max(1, doc.baseImage.width))
    }

    /// 渲染器用的是 systemFont(medium)，编辑器必须同款，否则打字时会换字重
    private static func textFont(size: CGFloat) -> NSFont {
        .systemFont(ofSize: max(9, size), weight: .medium)
    }

    private func beginTextEditing(at pixelPoint: CGPoint, existing: AnnotationShape? = nil) {
        commitTextEditing()

        let snapshot = doc.shapes
        let shape: AnnotationShape
        if let existing, let hit = doc.shapes.first(where: { $0.id == existing.id }) {
            shape = hit
        } else {
            // 新文字先挂进 shapes（不打撤销点）：这样选中框和包围盒跟着实时长。
            // 字号 = 下拉选的**点** × pixelScale → 图像像素（渲染器按像素画）。
            // 以前这里写死 30 * pixelScale，现在 30 只是下拉的默认档。
            let fresh = AnnotationShape(tool: .text, points: [pixelPoint],
                                        color: doc.color, lineWidth: 0, text: "",
                                        fontSize: doc.fontSize * pixelScale)
            doc.shapes.append(fresh)
            shape = fresh
        }
        editSnapshot = snapshot
        editingShapeID = shape.id
        doc.selectedID = shape.id

        let editor = NSTextView(frame: .zero)
        editor.delegate = self
        editor.drawsBackground = false
        editor.isRichText = false
        editor.isEditable = true
        editor.isSelectable = true
        editor.allowsUndo = true
        editor.font = Self.textFont(size: shape.fontSize * viewPerPixel)
        editor.textColor = shape.color.nsColor
        editor.insertionPointColor = shape.color.nsColor
        editor.textContainerInset = .zero
        editor.textContainer?.lineFragmentPadding = 0
        editor.textContainer?.widthTracksTextView = false
        // 🔴 关掉全部"智能"替换：截图里写的 `--flag`、`a"b`、`it's` 都是要
        // 原样进图的，被换成弯引号 / 破折号就不是用户打的那句话了。
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false
        editor.isAutomaticSpellingCorrectionEnabled = false
        editor.isContinuousSpellCheckingEnabled = false
        editor.isGrammarCheckingEnabled = false
        editor.smartInsertDeleteEnabled = false
        editor.string = shape.text
        addSubview(editor)
        editingTextView = editor
        layoutTextEditor()
        window?.makeFirstResponder(editor)
        // 修改已有文字：全选，直接打字就替换；接着往末尾补也行
        if !shape.text.isEmpty { editor.selectAll(nil) }
        needsDisplay = true
    }

    /// 编辑器位置 = 渲染器给这个文字算出来的框（同一套 displayBounds，不许另写一份）
    private func layoutTextEditor() {
        guard let editor = editingTextView, let id = editingShapeID,
              let shape = doc.shapes.first(where: { $0.id == id }),
              let box = shape.displayBounds else { return }
        let vpp = viewPerPixel
        editor.frame = NSRect(x: imageRect.minX + box.minX * vpp,
                              y: imageRect.minY + box.minY * vpp,
                              // 空文字时框只有 40 像素宽，换算成点太小，给个下限好看见光标
                              width: max(60, box.width * vpp),
                              height: max(20, box.height * vpp))
        // 文字变长后框要比视图宽，否则会横向滚动、看着像截断了
        editor.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                                     height: CGFloat.greatestFiniteMagnitude)
    }

    /// 改正在输入的那段文字的字号（实时，不压撤销点）
    ///
    /// 视图坐标是点，形状字号是图像像素：`shape.fontSize = points * pixelScale`
    /// 之后编辑器字号正好就是 `points`（= `fontSize × viewPerPixel`），不用再换算一次。
    func setLiveFontSize(_ points: CGFloat) {
        guard let id = editingShapeID,
              let idx = doc.shapes.firstIndex(where: { $0.id == id }) else { return }
        doc.shapes[idx].fontSize = points * pixelScale
        editingTextView?.font = Self.textFont(size: points)
        layoutTextEditor()
        needsDisplay = true
    }

    /// 确认：落盘成标注（整段编辑只压一个撤销点）
    /// internal 而不是 private：控制器在「保存 / 复制 / 贴图 / OCR / 关闭」之前
    /// 必须先把它落盘，否则用户在输入框里还没按回车就去点保存，最后那几行字会丢。
    func commitTextEditing() {
        guard let editor = editingTextView else { return }
        let text = editor.string.trimmingCharacters(in: .whitespacesAndNewlines)
        let id = editingShapeID
        let snapshot = editSnapshot
        teardownTextEditor()
        guard let id, let snapshot else { return }
        if let idx = doc.shapes.firstIndex(where: { $0.id == id }) {
            if text.isEmpty {
                // 空文字不留空框（点一下什么都没输 = 什么都没发生）
                doc.shapes.remove(at: idx)
            } else {
                doc.shapes[idx].text = text
            }
        }
        doc.commitEdit(from: snapshot)
        needsDisplay = true
    }

    /// 取消（Esc）：回到编辑前的样子
    private func cancelTextEditing() {
        guard editingTextView != nil else { return }
        let snapshot = editSnapshot
        teardownTextEditor()
        if let snapshot { doc.rollback(to: snapshot) }
        needsDisplay = true
    }

    private func teardownTextEditor() {
        editingTextView?.removeFromSuperview()
        editingTextView = nil
        editingShapeID = nil
        editSnapshot = nil
        window?.makeFirstResponder(self)
    }

    /// 点某个已有的文字 → 接着改
    private func editableTextShape(at pixelPoint: CGPoint) -> AnnotationShape? {
        doc.shapes.last { $0.tool == .text && $0.hitTest(pixelPoint) }
    }
}

// ── 文字原位编辑：打字实时同步 + 确认 / 取消 ──────────────
//
// 三条铁律：
// 1. 打字时**不许**调 `doc.commit(...)`。每敲一个字压一个撤销点的话，一次输入
//    就能把 50 步的栈刷满，还会把之前画的标注挤出栈外（用户按 ⌘Z 发现标注
//    全没了）。所以走 `setLiveText`（只改不压栈），确认时才压**一个**。
// 2. 确认 / 取消都以 `editSnapshot` 为基准，跟"改了几次"无关 —— 双击进去改、
//    改成空、再换成别的字，撤销一次应当直接回到"动手之前"。
// 3. Esc 归 `cancelOperation:`（文本视图自己的命令链），不要在这里判断 keyCode：
//    输入法组字过程中的 Esc 是"取消候选"，抢掉会把人正在打的拼音弄丢。
extension OverlayEditorView: NSTextViewDelegate {

    func textDidChange(_ notification: Notification) {
        guard let editor = editingTextView, let id = editingShapeID,
              notification.object as? NSTextView === editor else { return }
        doc.setLiveText(editor.string, for: id)
        // 文字变长 → 框跟着长（否则光标跑出可视区被裁掉，看着像打不进去字）
        layoutTextEditor()
        needsDisplay = true
    }

    func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            // ⏎ = 确认（截图工具惯例）。文本框只支持单行，换行没有意义。
            commitTextEditing()
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            cancelTextEditing()
            return true
        case #selector(NSResponder.insertTab(_:)):
            // Tab 也当确认：不然焦点会被吞在一个没有下一个控件的面板里
            commitTextEditing()
            return true
        default:
            return false
        }
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
