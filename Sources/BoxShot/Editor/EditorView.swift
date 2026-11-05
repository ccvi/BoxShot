import AppKit
import SwiftUI


// ============================================================
// 编辑器文档：底图 + 标注 + 撤销栈
// ============================================================

@MainActor
final class EditorDocument: ObservableObject {
    let baseImage: CGImage
    let effects: EffectImages

    @Published var shapes: [AnnotationShape] = []
    /// 打开就是箭头（用户口径）：截图十次有九次是拿箭头指一下，
    /// 默认落在「矩形」上等于每次都要先点一次工具条。
    @Published var tool: EditorTool = .arrow
    @Published var color: RGBColor = .red
    @Published var lineWidth: CGFloat = 4
    /// 新建文字的字号，**单位是点**（视图点），落成形状时 × `pixelScale` 换成图像像素。
    ///
    /// 为什么默认值是 30：加字号控件之前，浮层里写死的就是 `30 * pixelScale`。
    /// 沿用这个数，用户加完控件写出来的第一段字跟以前一模一样 —— 新增控件不该
    /// 顺手把既有观感改了。6 个档位里也正好包含 30，下拉不会显示成"未选中"。
    @Published var fontSize: CGFloat = 30
    /// 放大倍数（只对放大镜生效）：用户 2026-11-05 口径「放大倍数 2 倍和 3 倍」。
    /// 跟线宽 / 字号一样存 UserDefaults —— 下一张图打开还是这一档。
    @Published var loupeZoom: CGFloat = EditorDocument.rememberedLoupeZoom()
    /// 放大镜镜面形状（矩形 / 圆形）。用户当天追加：「矩形 2X，矩形 3X，圆形 2X，圆形 3X」。
    @Published var loupeStyle: LoupeStyle = EditorDocument.rememberedLoupeStyle()
    /// 当前选中的标注（"选择"工具点选；⌫ 删除；拖动移动）
    @Published var selectedID: UUID?
    /// 截图美化（Xnapper 式套壳）；nil = 关闭。底图不动，渲染时往外套
    @Published var beautify: BeautifyOptions?

    private var undoStack: [[AnnotationShape]] = []
    private var redoStack: [[AnnotationShape]] = []
    /// 拖动中的原始形状（endMove 时用它生成撤销点）
    private var moveOrigin: AnnotationShape?

    init(image: CGImage, shapes: [AnnotationShape] = []) {
        self.baseImage = image
        self.effects = EffectImages(base: image)
        self.shapes = shapes
    }

    var imageSize: CGSize {
        CGSize(width: baseImage.width, height: baseImage.height)
    }

    /// 画布尺寸：美化开启时 = 底图 + 四周 padding（画背景的那块）
    var canvasSize: CGSize {
        guard let beautify else { return imageSize }
        return CGSize(width: imageSize.width + beautify.padding * 2,
                      height: imageSize.height + beautify.padding * 2)
    }

    // ── 撤销 / 重做 ──

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    /// 撤销栈上限。每步存的是一整份 `[AnnotationShape]`（结构体数组，不含位图），
    /// 单份通常几 KB，但编辑一小时、反复改颜色粗细能到几百步 —— 没有上限就是
    /// 一条悄悄往上爬的曲线。50 步够用（再往回也没人记得清）。
    static let undoLimit = 50

    /// 6 档字号（**点**）—— 直接引用截图浮层那一份，别在这里另抄一个数组。
    ///
    /// 用户 1.0.27 一眼看出「编辑工具的输入文字功能跟截图工具条的输入文字功能
    /// 不一致」：其中一条就是编辑窗口**没有字号控件**，落字时还写死 `(22, 30)`。
    /// 档位必须同源，`--selftest` 里有断言盯着两边是不是同一个数组。
    static let fontSizeOptions: [CGFloat] = OverlayEditorController.fontSizeOptions

    /// 放大镜两档（**倍数**，不是像素）。档位只有两档，用户点名要的就是 2 和 3。
    static let loupeZoomOptions: [CGFloat] = AnnotationShape.loupeZoomOptions
    static let lastLoupeZoomKey = "boxshot.lastLoupeZoom"

    /// 上次选的倍数；没选过 → 默认 2×；存的数不在档位表里 → 取最近的一档。
    /// 跟字号 / 粗细下拉同一个口径（不做精确相等，浮点存回来会差一丁点）。
    static func rememberedLoupeZoom(_ defaults: UserDefaults = .standard) -> CGFloat {
        let raw = defaults.object(forKey: lastLoupeZoomKey) != nil
            ? CGFloat(defaults.double(forKey: lastLoupeZoomKey))
            : AnnotationShape.loupeDefaultZoom
        return loupeZoomOptions.min { abs($0 - raw) < abs($1 - raw) }
            ?? AnnotationShape.loupeDefaultZoom
    }

    static func rememberLoupeZoom(_ zoom: CGFloat, _ defaults: UserDefaults = .standard) {
        defaults.set(Double(zoom), forKey: lastLoupeZoomKey)
    }

    /// 镜面形状的粘性状态（矩形 / 圆形）。存字符串原始值，别存枚举序号 ——
    /// 以后枚举里插一项，序号就全错位了。
    static let lastLoupeStyleKey = "boxshot.lastLoupeStyle"

    static func rememberedLoupeStyle(_ defaults: UserDefaults = .standard) -> LoupeStyle {
        guard let raw = defaults.string(forKey: lastLoupeStyleKey),
              let style = LoupeStyle(rawValue: raw) else { return .rect }
        return style
    }

    static func rememberLoupeStyle(_ style: LoupeStyle, _ defaults: UserDefaults = .standard) {
        defaults.set(style.rawValue, forKey: lastLoupeStyleKey)
    }

    /// 字号换算：下拉给的是**视图点**，形状里存的是**图像像素**。
    ///
    /// `fitScale` = 视图点 / 图像像素（显示缩放），所以 像素 = 点 ÷ fitScale。
    /// 2x 屏（fitScale 0.5）下 30pt → 60px，跟浮层 `doc.fontSize * pixelScale`
    /// 完全同一个口径 —— 两边算出来的字号必须能互相看懂，否则"同一张图在两个地方
    /// 编辑，字大小不一样"。下限 9 是渲染器的字号下限（见 AnnotationModels）。
    static func pixelFontSize(points: CGFloat, fitScale: CGFloat) -> CGFloat {
        max(9, points / max(fitScale, 0.05))
    }

    /// 反向：图像像素 → 视图点（下拉要显示"现在是多少 pt"）
    static func pointFontSize(pixels: CGFloat, fitScale: CGFloat) -> CGFloat {
        max(9, pixels * max(fitScale, 0.05))
    }

    /// 压撤销点：统一从这里走，别各处 `undoStack.append` —— 那样迟早有人漏了截断。
    private func pushUndo(_ snapshot: [AnnotationShape]) {
        undoStack.append(snapshot)
        if undoStack.count > Self.undoLimit {
            undoStack.removeFirst(undoStack.count - Self.undoLimit)
        }
        redoStack.removeAll()
    }

    func commit(_ shape: AnnotationShape) {
        pushUndo(shapes)
        shapes.append(shape)
    }

    func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(shapes)
        shapes = previous
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(shapes)
        shapes = next
    }

    // ── 选中 / 移动 / 删除 ──

    var selectedShape: AnnotationShape? {
        guard let selectedID else { return nil }
        return shapes.first { $0.id == selectedID }
    }

    /// 点选：命中最上层标注并选中；没命中则取消选中。返回命中的形状。
    @discardableResult
    func select(at point: CGPoint) -> AnnotationShape? {
        let hit = shapes.reversed().first { $0.hitTest(point) }
        selectedID = hit?.id
        return hit
    }

    /// 拖动开始（记录原始形状，结束时生成一个撤销点）
    func beginMoveSelected() {
        moveOrigin = selectedShape
    }

    /// 拖动中：把选中形状平移 delta
    func moveSelected(by delta: CGPoint) {
        guard let selectedID, let idx = shapes.firstIndex(where: { $0.id == selectedID }) else { return }
        shapes[idx] = shapes[idx].translated(dx: delta.x, dy: delta.y)
    }

    /// 拖动中：把选中形状的第 `index` 个节点拖到 `point`。
    ///
    /// 🔴 必须以**按下时**那份 `origin` 为基准算，不能拿"上一帧的结果"当基准：
    /// 拖过一次对角之后点序会被规范化，再按当前形状算，边中点会跟着跳到另一条边，
    /// 表现为"拖着上面那条边，下面那条边也跟着动"。
    func adjustSelected(handle index: Int, to point: CGPoint, from origin: AnnotationShape) {
        guard let idx = shapes.firstIndex(where: { $0.id == origin.id }) else { return }
        shapes[idx] = origin.adjusting(handle: index, to: point)
    }

    /// 拖动结束：压一个撤销点（撤销 = 回到拖动前位置）
    func endMoveSelected() {        defer { moveOrigin = nil }
        guard let origin = moveOrigin,
              let idx = shapes.firstIndex(where: { $0.id == origin.id }) else { return }
        var previous = shapes
        previous[idx] = origin
        pushUndo(previous)
    }

    /// 删除选中标注（⌫ / Delete）
    func deleteSelected() {
        guard let selectedID, let idx = shapes.firstIndex(where: { $0.id == selectedID }) else { return }
        pushUndo(shapes)
        shapes.remove(at: idx)
        self.selectedID = nil
    }

    /// 改选中标注的颜色 / 粗细 / 字号（进撤销栈）；没有选中时只改默认值
    ///
    /// 字号只对文字生效：选中一个矩形时改字号，既不该动它、也不该白压一个撤销点。
    /// 所以这里先算出"改完长什么样"，跟原来一模一样就直接返回。
    func applyToSelected(color: RGBColor? = nil, lineWidth: CGFloat? = nil,
                         fontSize: CGFloat? = nil, zoom: CGFloat? = nil,
                         loupeStyle: LoupeStyle? = nil) {
        if color != nil { self.color = color! }
        if let lineWidth { self.lineWidth = lineWidth }
        if let zoom {
            self.loupeZoom = zoom
            Self.rememberLoupeZoom(zoom)
        }
        if let loupeStyle {
            self.loupeStyle = loupeStyle
            Self.rememberLoupeStyle(loupeStyle)
        }
        guard let selectedID, let idx = shapes.firstIndex(where: { $0.id == selectedID }) else { return }
        var updated = shapes[idx]
        if let color { updated.color = color }
        if let lineWidth { updated.lineWidth = lineWidth }
        if let fontSize, updated.tool == .text { updated.fontSize = fontSize }
        if let zoom, updated.tool == .loupe { updated.zoom = zoom }
        if let loupeStyle, updated.tool == .loupe { updated.loupeStyle = loupeStyle }
        guard updated != shapes[idx] else { return }
        pushUndo(shapes)
        shapes[idx] = updated
    }

    // ── 文字原地编辑（所见即所得）───────────────────────────
    //
    // 用户要的是"边打字边看到最终效果，确认后还能点回来改"。所以打字期间
    // 文字真实存在于 shapes 里（选中框 / 包围盒 / 渲染都跟着走），只是画字的
    // 那一步交给浮层上的 NSTextView，渲染器跳过这一条（见 OverlayEditor 的 draw）。
    //
    // 🔴 打字时**绝不能**走 commit()：每敲一个字压一个撤销点，两行字能把栈刷满，
    // 而且 undoLimit 一截断，之前所有的编辑历史就全丢了。所以拆成三步：
    // setLiveText（不压栈）→ commitEdit（整段编辑只压一个点）/ rollback（取消）。

    /// 实时改文字（不压撤销点）
    func setLiveText(_ text: String, for id: UUID) {
        guard let idx = shapes.firstIndex(where: { $0.id == id }) else { return }
        shapes[idx].text = text
    }

    /// 编辑结束：把「编辑前那份」压成一个撤销点。
    /// 只有真的变了才压 —— 点进去又原样退出来不该留下一步空撤销。
    func commitEdit(from snapshot: [AnnotationShape]) {
        guard snapshot != shapes else { return }
        pushUndo(snapshot)
    }

    /// 取消编辑：整体回滚到编辑前（连"刚新建的那条空文字"一起撤掉）
    func rollback(to snapshot: [AnnotationShape]) {
        shapes = snapshot
        redoStack.removeAll()
    }

    // ── 裁剪 ────────────────────────────────────────────────

    /// 裁剪结果：裁好的底图 + 平移到新原点的标注。
    ///
    /// 裁剪不做成"改文档状态"，而是产出一份新文档的原料 ——
    /// 两个编辑器（浮层 / 独立窗口）都用"关掉自己、按新尺寸重开"来落地，
    /// 这样窗口尺寸、手柄、坐标换算全都不用改，也不会有半个状态留在旧尺寸里。
    func croppedResult(to rect: CGRect) -> (image: CGImage, shapes: [AnnotationShape])? {
        let bounds = CGRect(origin: .zero, size: imageSize)
        let target = rect.intersection(bounds).integral
        guard target.width >= 8, target.height >= 8 else { return nil }
        guard let cropped = baseImage.cropping(to: target) else { return nil }

        // 只留还在画面里的标注（整条都被裁掉的没有意义）
        let kept = shapes.filter { shape in
            guard let box = shape.displayBounds else { return false }
            return box.intersects(target)
        }.map { $0.translated(dx: -target.minX, dy: -target.minY) }
        return (cropped, kept)
    }

    // ── 成品输出 ──

    func rendered() -> CGImage? {
        EditorRenderer.render(base: baseImage, shapes: shapes, effects: effects,
                              beautify: beautify)
    }

    /// 取色：读底图指定像素的颜色
    func pixelColor(at point: CGPoint) -> RGBColor? {
        let x = Int(point.x), y = Int(point.y)
        guard x >= 0, y >= 0, x < Int(imageSize.width), y < Int(imageSize.height) else { return nil }
        guard let data = baseImage.dataProvider?.data,
              let ptr = CFDataGetBytePtr(data) else { return nil }
        let bytesPerRow = baseImage.bytesPerRow
        let bytesPerPixel = baseImage.bitsPerPixel / 8
        let offset = y * bytesPerRow + x * bytesPerPixel
        // 1.0.0 统一按 BGRA(小端) 解；SCScreenshotManager 输出就是它
        let b = Double(ptr[offset]) / 255
        let g = Double(ptr[offset + 1]) / 255
        let r = Double(ptr[offset + 2]) / 255
        return RGBColor(red: r, green: g, blue: b)
    }
}

// ============================================================
// 编辑器视图
// ============================================================

struct EditorView: View {
    @ObservedObject var doc: EditorDocument
    var onCopy: () -> Void
    var onSave: () -> Void
    var onPin: () -> Void
    var onOCR: () -> Void
    var onClose: () -> Void
    /// 裁剪完成：窗口控制器按新图重开一个编辑器
    var onCrop: ((CGImage, [AnnotationShape]) -> Void)? = nil

    /// 显示缩放：视图点 → 图像像素
    @State private var fitScale: CGFloat = 1
    @State private var draft: AnnotationShape?
    @State private var draftStart: CGPoint?
    /// 正在输入的文字形状 id（值类型快照从 doc.shapes 里取，见 `editingShape`）
    ///
    /// 🔴 1.0.27 改的：以前是 `(point, text)` 元组 —— 文字只活在视图状态里，
    /// 画布上根本没有这个字，所以"边打边看到最终效果"根本做不到，用户只能盯着
    /// 一个 240pt 的圆角小框。现在跟浮层一样：先把空文字挂进 shapes（不压撤销点），
    /// 边打边 `setLiveText`，确认时才 `commitEdit` 压一个点。
    @State private var editingID: UUID?
    /// 开始编辑前的 shapes 快照（取消时回滚 / 确认时压成撤销点）
    @State private var editSnapshot: [AnnotationShape]?
    @State private var statusMessage: String = ""
    /// 选择工具拖动中的上一次像素坐标
    @State private var selectDragLast: CGPoint?
    /// 正在拖标注的节点（矩形 / 椭圆 / 直线 / 箭头）。
    /// 存**按下时**那份形状：拖动全程以它为基准，见 `EditorDocument.adjustSelected`。
    @State private var handleDrag: (index: Int, origin: AnnotationShape)?
    /// 颜色圆点的弹出面板（配色 + 粗细）
    @State private var showColorPanel = false
    /// 裁剪：拖出的保留范围（图像像素坐标）
    @State private var cropRect: CGRect?
    @State private var cropAnchor: CGPoint?

    var body: some View {
        VStack(spacing: 0) {
            canvas
            toolbar
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(alignment: .top) {
            if !statusMessage.isEmpty {
                Text(statusMessage)
                    .font(.callout)
                    .padding(.horizontal, 14).padding(.vertical, 7)
                    .background(.thickMaterial, in: Capsule())
                    .padding(.top, 10)
                    .transition(.opacity)
                    .onAppear {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
                            withAnimation { statusMessage = "" }
                        }
                    }
                }
        }
        .onAppear { measureFit() }
        .overlay(alignment: .bottom) {
            if cropRect != nil {
                cropBar
            } else if doc.beautify != nil {
                beautifyBar
            }
        }
    }

    /// 裁剪确认条：⏎ 应用 / ⎋ 取消（键盘快捷键挂在按钮上，SwiftUI 会自动接管）
    private var cropBar: some View {
        HStack(spacing: 10) {
            Text(cropRect.map { "裁剪为 \(Int($0.width)) × \(Int($0.height)) px" } ?? "")
                .font(.callout)
                .monospacedDigit()
            Button("应用（⏎）") { applyCrop() }
                .keyboardShortcut(.return, modifiers: [])
                .buttonStyle(.borderedProminent)
            Button("取消") { cropRect = nil; cropAnchor = nil }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(.thickMaterial, in: Capsule())
        .padding(.bottom, 12)
    }

    private func applyCrop() {
        guard let rect = cropRect, let result = doc.croppedResult(to: rect) else {
            cropRect = nil
            cropAnchor = nil
            return
        }
        cropRect = nil
        cropAnchor = nil
        onCrop?(result.image, result.shapes)
    }

    // ── 截图美化（Xnapper 式：背景 / 圆角 / 阴影 / 边距）──

    /// 分两行：上面色板 + 收起，下面滑杆 + 阴影。挤成一行在窄窗口放不下。
    private var beautifyBar: some View {
        VStack(spacing: 8) {
            HStack(spacing: 5) {
                ForEach(BeautifyOptions.solidPresets, id: \.hexString) { c in
                    beautifySolidSwatch(c)
                }
                ForEach(Array(BeautifyOptions.gradientPresets.enumerated()), id: \.offset) { _, pair in
                    beautifyGradientSwatch(pair.0, pair.1)
                }
                Spacer()
                Button("收起") { withAnimation { doc.beautify = nil } }
            }
            HStack(spacing: 10) {
                Text("边距").font(.caption).foregroundStyle(.secondary)
                Slider(value: Binding(get: { doc.beautify?.padding ?? 48 },
                                      set: { doc.beautify?.padding = $0 }),
                       in: 0...160, step: 8)
                    .frame(width: 110)
                Text("圆角").font(.caption).foregroundStyle(.secondary)
                Slider(value: Binding(get: { doc.beautify?.cornerRadius ?? 16 },
                                      set: { doc.beautify?.cornerRadius = $0 }),
                       in: 0...64, step: 4)
                    .frame(width: 90)
                Toggle("阴影", isOn: Binding(get: { doc.beautify?.shadow ?? true },
                                            set: { doc.beautify?.shadow = $0 }))
                    .toggleStyle(.checkbox)
                    .font(.caption)
                Spacer()
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.thickMaterial, in: RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal, 14)
        .padding(.bottom, 12)
    }

    private func beautifySolidSwatch(_ c: RGBColor) -> some View {
        let selected = doc.beautify?.background == .color(c)
        return Circle()
            .fill(Color(nsColor: c.nsColor))
            .frame(width: 16, height: 16)
            .overlay(Circle().strokeBorder(selected ? Color.accentColor : Color.gray.opacity(0.4),
                                           lineWidth: 2))
            .onTapGesture { doc.beautify?.background = .color(c) }
            .help("背景 \(c.hexString)")
    }

    private func beautifyGradientSwatch(_ a: RGBColor, _ b: RGBColor) -> some View {
        let selected = doc.beautify?.background == .gradient(a, b)
        return Circle()
            .fill(LinearGradient(colors: [Color(nsColor: a.nsColor), Color(nsColor: b.nsColor)],
                                 startPoint: .topLeading, endPoint: .bottomTrailing))
            .frame(width: 16, height: 16)
            .overlay(Circle().strokeBorder(selected ? Color.accentColor : Color.gray.opacity(0.4),
                                           lineWidth: 2))
            .onTapGesture { doc.beautify?.background = .gradient(a, b) }
            .help("渐变 \(a.hexString) → \(b.hexString)")
    }

    private var displaySize: CGSize {
        CGSize(width: doc.canvasSize.width * fitScale, height: doc.canvasSize.height * fitScale)
    }

    private var canvas: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                // 画布：棋盘底（透出 PNG 透明区）+ 图像 + 已提交标注 + 草稿
                CheckerboardView()
                    .frame(width: displaySize.width, height: displaySize.height)

                Canvas { context, _ in
                    context.scaleBy(x: fitScale, y: fitScale)
                    let pad = doc.beautify?.padding ?? 0

                    if let b = doc.beautify {
                        // 美化壳：背景铺满 → 圆角底图（+ 阴影）→ 标注画在底图坐标里
                        let full = CGRect(origin: .zero, size: doc.canvasSize)
                        switch b.background {
                        case .color(let c):
                            context.fill(Path(full), with: .color(Color(nsColor: c.nsColor)))
                        case .gradient(let from, let to):
                            context.fill(Path(full), with: .linearGradient(
                                Gradient(colors: [Color(nsColor: from.nsColor),
                                                  Color(nsColor: to.nsColor)]),
                                startPoint: CGPoint(x: full.minX, y: full.minY),
                                endPoint: CGPoint(x: full.maxX, y: full.maxY)))
                        }
                        let imgRect = CGRect(x: pad, y: pad,
                                             width: doc.imageSize.width, height: doc.imageSize.height)
                        let rounded = Path(roundedRect: imgRect, cornerRadius: b.cornerRadius)
                        if b.shadow {
                            context.drawLayer { layer in
                                layer.addFilter(.shadow(color: .black.opacity(0.28),
                                                        radius: BeautifyOptions.shadowBlur / 2,
                                                        x: 0, y: BeautifyOptions.shadowOffsetY / 2))
                                layer.fill(rounded, with: .color(.white))
                            }
                        } else {
                            context.fill(rounded, with: .color(.white))
                        }
                        context.drawLayer { layer in
                            layer.clip(to: rounded)
                            layer.draw(Image(decorative: doc.baseImage, scale: 1), in: imgRect)
                        }
                    } else {
                        context.draw(Image(decorative: doc.baseImage, scale: 1),
                                     in: CGRect(origin: .zero, size: doc.imageSize))
                    }

                    // 之后的标注一律画在"底图坐标"空间（美化时 = 平移 padding）
                    context.translateBy(x: pad, y: pad)

                    // 🔴 跳过"正在输入的那条文字"：它由上面的 NSTextView 实时画着，
                    // 这里再画一遍就是重影（用户 1.0.27 截图："输入文字时显示重影"——
                    // 渲染的字跟文本视图的字差半个像素，看着像描了一层边）。
                    // 浮层那边早就是这个做法（draw 里 filter { $0.id != editingShapeID }）。
                    for shape in doc.shapes where shape.id != editingID {
                        drawShape(shape, in: &context)
                    }
                    if let draft {
                        drawShape(draft, in: &context)
                    }
                    // 选中标注的虚线框
                    if let selected = doc.selectedShape, let bounds = selected.displayBounds {
                        let dash: CGFloat = 5 / max(fitScale, 0.05)
                        context.stroke(Path(bounds),
                                       with: .color(.accentColor),
                                       style: StrokeStyle(lineWidth: 1.5 / max(fitScale, 0.05),
                                                          dash: [dash, dash * 0.8]))
                    }
                    // 选中标注的可拖节点（用户 2026-11-04 口径）。
                    // 尺寸按 fitScale 换算回图像像素 —— 屏幕上永远是 9pt 的方块，
                    // 不跟着缩放变大变小。只在选择工具下显示：拿别的工具时它拖不动，
                    // 画出来只会让人以为坏了。
                    if doc.tool == .select, let selected = doc.selectedShape {
                        let handles = selected.handlePoints
                        if !handles.isEmpty {
                            let side = 9 / max(fitScale, 0.05)
                            let strokeWidth = 1.5 / max(fitScale, 0.05)
                            for handle in handles {
                                let box = CGRect(x: handle.x - side / 2, y: handle.y - side / 2,
                                                 width: side, height: side)
                                context.fill(Path(box), with: .color(.white))
                                context.stroke(Path(box),
                                               with: .color(Color(nsColor: selected.color.nsColor)),
                                               lineWidth: strokeWidth)
                            }
                        }
                    }
                    // 裁剪取景：范围外压暗（even-odd 填充做"挖洞"）
                    if let crop = cropRect, crop.width > 1, crop.height > 1 {
                        var mask = Path()
                        mask.addRect(CGRect(origin: .zero, size: doc.imageSize))
                        mask.addRect(crop)
                        context.fill(mask, with: .color(.black.opacity(0.5)),
                                     style: FillStyle(eoFill: true))
                        context.stroke(Path(crop), with: .color(.white),
                                       lineWidth: 1.5 / max(fitScale, 0.05))
                    }
                }
                .frame(width: displaySize.width, height: displaySize.height)
                // 🔴 文字输入框必须挂在 `.overlay` 里，不能当 ZStack 的兄弟视图。
                // NSTextView 有 intrinsicContentSize（宽度跟着文本长），放进 ZStack
                // 会参与尺寸计算 → 容器被撑宽 → 画布右边多出一块空白（用户 1.0.27
                // 截图红框："一输入文字，布局变形了"）。overlay 不参与父视图布局，
                // 位置交给 offset，跟画布同一个坐标原点。
                .overlay(alignment: .topLeading) {
                    if let shape = editingShape {
                        textEditorOverlay(for: shape)
                    }
                }
            }
            // 手势直接挂在画布容器上：坐标就是画布局部坐标（点），
            // 除以 fitScale 得图像像素坐标，不需要再做居中偏移换算。
            .contentShape(Rectangle())
            .gesture(dragGesture)
            .onTapGesture { location in
                let pad = doc.beautify?.padding ?? 0
                handleTap(clampToImage(CGPoint(x: location.x / fitScale - pad,
                                               y: location.y / fitScale - pad)))
            }
            .onChange(of: geo.size) { _ in measureFit(with: geo.size) }
            // 美化 padding 变了画布尺寸跟着变，适配缩放要重算
            .onChange(of: doc.canvasSize) { _ in measureFit(with: geo.size) }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background {
                // 视图尺寸进入 GeometryReader 后先量一次适配缩放
                Color.clear.onAppear { measureFit(with: geo.size) }
            }
        }
        .clipped()
    }

    // ── 手势 ──

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                guard doc.imageSize.width > 0 else { return }
                // 开始在画布上画别的东西 = 这段文字写完了，先落盘
                if editingID != nil { commitEditingText() }
                let pad = doc.beautify?.padding ?? 0
                let p = clampToImage(CGPoint(x: value.location.x / fitScale - pad,
                                             y: value.location.y / fitScale - pad))
                if doc.tool == .crop {
                    let anchor = cropAnchor ?? p
                    cropAnchor = anchor
                    cropRect = CGRect(from: anchor, to: p)
                    return
                }
                if doc.tool == .select {
                    // 拖节点改形状优先于平移：手柄压在形状边缘 / 角上，
                    // 先走 `select(at:)` 就会变成"拖着整个形状跑"，节点抓不住。
                    if let drag = handleDrag {
                        doc.adjustSelected(handle: drag.index, to: p, from: drag.origin)
                        return
                    }
                    // 拖动选中标注：按下起点命中并锁定，之后按位移平移
                    if selectDragLast == nil {
                        // 11pt 换算成图像像素当容差（手柄压在边缘上，点偏一点也得抓住）
                        let tolerance = 11 / max(fitScale, 0.05)
                        if let selected = doc.selectedShape,
                           let index = selected.handleIndex(near: p, tolerance: tolerance) {
                            handleDrag = (index, selected)
                            doc.beginMoveSelected()
                            return
                        }
                        if doc.select(at: p) != nil { doc.beginMoveSelected() }
                        selectDragLast = p
                    } else if doc.selectedID != nil {
                        doc.moveSelected(by: CGPoint(x: p.x - selectDragLast!.x,
                                                     y: p.y - selectDragLast!.y))
                        selectDragLast = p
                    }
                    return
                }
                guard doc.tool.isDragTool else { return }
                if let start = draftStart {
                    switch doc.tool {
                    case .pen, .marker:
                        draft?.points.append(p)
                    default:
                        draft?.points = [start, p]
                    }
                } else {
                    doc.selectedID = nil
                    draftStart = p
                    draft = AnnotationShape(tool: doc.tool, points: [p],
                                            color: doc.color, lineWidth: doc.lineWidth)
                    // 放大镜：落笔时就定下当前镜面与倍数（之后还能在工具条上改）
                    if doc.tool == .loupe {
                        draft?.zoom = doc.loupeZoom
                        draft?.loupeStyle = doc.loupeStyle
                    }
                }
            }
            .onEnded { _ in
                if doc.tool == .crop {
                    cropAnchor = nil
                    // 太小就是误触：直接清掉，别留一个 2×3 的裁剪框
                    if let rect = cropRect, rect.width < 8 || rect.height < 8 { cropRect = nil }
                    return
                }
                if doc.tool == .select {
                    if handleDrag != nil {
                        handleDrag = nil
                        doc.endMoveSelected()
                        return
                    }
                    if selectDragLast != nil { doc.endMoveSelected() }
                    selectDragLast = nil
                    return
                }
                guard var shape = draft else { return }
                draft = nil
                draftStart = nil
                if shape.points.count >= 2 {
                    if shape.tool == .mosaic || shape.tool == .blur || shape.tool == .loupe {
                        // 矩形语义：把点列收缩成 [起点, 终点] 方框
                        let first = shape.points.first!
                        let last = shape.points.last!
                        shape.points = [first, last]
                    }
                    doc.commit(shape)
                }
            }
    }

    private func handleTap(_ p: CGPoint) {
        // 点别处先把正在打的字落盘：不然换工具 / 换颜色之后那行字停在草稿里，
        // 画布上看不见（它只在 shapes 里"半挂"着），用户会以为白打了。
        commitEditingText()
        switch doc.tool {
        case .select:
            doc.select(at: p)
        case .text:
            doc.selectedID = nil
            beginTextEditing(at: p)
        case .colorPick:
            doc.selectedID = nil
            if let color = doc.pixelColor(at: p) {
                let shape = AnnotationShape(tool: .colorPick, points: [p],
                                            color: color, lineWidth: 0)
                doc.commit(shape)
                Support.copyTextToClipboard(color.hexString)
                flash("已取色 \(color.hexString)，色值复制到剪贴板")
            }
        case .step:
            // 点一下放一个编号气泡，序号渲染时按数组顺序数（自动递增）；
            // 删掉中间一步，后面的自动往前补号
            doc.selectedID = nil
            let shape = AnnotationShape(tool: .step, points: [p],
                                        color: doc.color, lineWidth: 0)
            doc.commit(shape)
            flash("步骤 \(EditorRenderer.stepNumber(of: shape, in: doc.shapes))")
        default:
            break
        }
    }

    /// 正在编辑的那条文字（值快照；doc.shapes 一变这里就跟着新，输入框尺寸也随之长）
    private var editingShape: AnnotationShape? {
        guard let editingID else { return nil }
        return doc.shapes.first { $0.id == editingID }
    }

    /// 开一段新文字：先把它挂进 shapes（**不压撤销点**），边打边看。
    /// 字号 = 下拉的**点** ÷ fitScale → 图像像素；以前这里写死 30 像素，
    /// 在大图上小得像颗芝麻，也是"跟浮层不一致"的一部分。
    private func beginTextEditing(at p: CGPoint) {
        let snapshot = doc.shapes
        let shape = AnnotationShape(tool: .text, points: [p], color: doc.color, lineWidth: 0,
                                    text: "",
                                    fontSize: EditorDocument.pixelFontSize(points: doc.fontSize,
                                                                           fitScale: fitScale))
        doc.shapes.append(shape)
        editSnapshot = snapshot
        editingID = shape.id
        doc.selectedID = shape.id
    }

    private func commitEditingText() {
        guard let id = editingID else { return }
        let snapshot = editSnapshot
        editingID = nil
        editSnapshot = nil
        defer { doc.selectedID = nil }
        guard let idx = doc.shapes.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = doc.shapes[idx].text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            // 点一下什么都没输 = 什么都没发生：连空框一起撤掉
            doc.shapes.remove(at: idx)
        } else {
            doc.shapes[idx].text = trimmed
        }
        // 整段编辑只压一个撤销点；一个字都没改（含"空框被删回原样"）就不压
        if let snapshot { doc.commitEdit(from: snapshot) }
    }

    /// 取消（Esc）：回到开始编辑前的样子
    private func cancelEditingText() {
        guard let snapshot = editSnapshot else {
            editingID = nil
            return
        }
        editingID = nil
        editSnapshot = nil
        doc.rollback(to: snapshot)
        doc.selectedID = nil
    }

    /// 画布上的输入框：位置与字号全按**渲染器算出来的框**走（同一套 `displayBounds`），
    /// 这样打出来的字跟最终成图在同一处、同样大 —— 这就是"跟截图工具条一致"的含义。
    @ViewBuilder
    private func textEditorOverlay(for shape: AnnotationShape) -> some View {
        let pad = doc.beautify?.padding ?? 0
        let box = shape.displayBounds ?? CGRect(origin: shape.points.first ?? .zero,
                                               size: CGSize(width: 40, height: shape.fontSize))
        // 空文字时渲染框只有 40 像素宽，换算成点放不下光标 → 给下限
        let width = max(80, box.width * fitScale + 6)
        let height = max(22, max(shape.fontSize, 20) * fitScale * 1.35)
        let originX = (box.minX + pad) * fitScale
        let originY = (box.minY + pad) * fitScale
        CanvasTextEditor(
            text: Binding(get: { editingShape?.text ?? "" },
                          set: { doc.setLiveText($0, for: shape.id) }),
            fontSize: EditorDocument.pointFontSize(pixels: shape.fontSize, fitScale: fitScale),
            color: shape.color.nsColor,
            onCommit: { commitEditingText() },
            onCancel: { cancelEditingText() }
        )
        .frame(width: width, height: height)
        .fixedSize()
        .offset(x: originX, y: originY)
    }

    // ── 坐标换算 ──

    private func clampToImage(_ p: CGPoint) -> CGPoint {
        CGPoint(x: min(max(0, p.x), doc.imageSize.width),
                y: min(max(0, p.y), doc.imageSize.height))
    }

    private func measureFit(with size: CGSize? = nil) {
        let availW = (size?.width ?? 1200) - 24
        let availH = (size?.height ?? 800) - 24
        guard doc.canvasSize.width > 0, doc.canvasSize.height > 0 else { return }
        let scale = min(availW / doc.canvasSize.width, availH / doc.canvasSize.height, 1.0)
        fitScale = max(0.05, scale)
    }

    private func flash(_ message: String) {
        withAnimation { statusMessage = message }
    }

    // ── 画布绘制（视图缩放已在 ctx 上做） ──

    private func drawShape(_ shape: AnnotationShape, in context: inout GraphicsContext) {
        let color = Color(nsColor: shape.color.nsColor)
        let width = max(1, shape.lineWidth)

        switch shape.tool {
        case .select, .crop:
            return
        case .pen, .marker:
            guard shape.points.count >= 2 else { return }
            var path = Path()
            path.addLines(shape.points)
            if shape.tool == .marker {
                context.stroke(path, with: .color(color.opacity(0.45)), style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round))
            } else {
                context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round))
            }

        case .rect:
            guard let a = shape.points.first, let b = shape.points.last else { return }
            context.stroke(Path(CGRect(from: a, to: b)), with: .color(color), lineWidth: width)

        case .highlight:
            // 聚光点亮，跟截图浮层那边的 CG 渲染同一口径：块内一个像素不动，块外压暗。
            // 🔴 必须包一层 drawLayer：GraphicsContext 是值类型，直接在 context 上
            // clip 会把**后面所有标注**一起裁掉（症状是"画了高亮，别的标注都不见了"）。
            guard let a = shape.points.first, let b = shape.points.last else { return }
            let canvas = Path(CGRect(origin: .zero, size: doc.imageSize))
            context.drawLayer { layer in
                layer.clip(to: Path(CGRect(from: a, to: b)), options: .inverse)
                layer.fill(canvas, with: .color(.black.opacity(Double(EditorRenderer.highlightDimAlpha))))
            }

        case .ellipse:
            guard let a = shape.points.first, let b = shape.points.last else { return }
            context.stroke(Path(ellipseIn: CGRect(from: a, to: b)), with: .color(color), lineWidth: width)

        case .line:
            guard let a = shape.points.first, let b = shape.points.last else { return }
            var path = Path()
            path.move(to: a); path.addLine(to: b)
            context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: width, lineCap: .round))

        case .arrow:
            guard let a = shape.points.first, let b = shape.points.last else { return }
            // 箭杆收在头部里侧（不然 round cap 会在尖端顶出个圆头），
            // 几何全部来自 EditorRenderer，和导出渲染共用一份
            let stem = EditorRenderer.arrowStemEnd(from: a, to: b, width: width)
            var path = Path()
            path.move(to: a); path.addLine(to: stem)
            context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: width, lineCap: .round))
            let pts = EditorRenderer.arrowHeadPoints(from: a, to: b, width: width)
            var head = Path()
            head.move(to: pts[0])
            for p in pts.dropFirst() { head.addLine(to: p) }
            head.closeSubpath()
            context.fill(head, with: .color(color))

        case .text:
            if let p = shape.points.first, !shape.text.isEmpty {
                context.draw(Text(shape.text)
                    .font(.system(size: (shape.fontSize > 0 ? shape.fontSize : 30) * fitScale, weight: .medium))
                    .foregroundColor(color),
                             at: CGPoint(x: p.x * fitScale, y: p.y * fitScale + 10),
                             anchor: .topLeading)
            }

        case .mosaic, .blur:
            // 与渲染器同一套区域口径：同类效果的并集外接矩形，只铺这一块
            let cover = EditorRenderer.unionRect(of: shape.tool, in: doc.shapes)
            guard let effect = (shape.tool == .mosaic ? doc.effects.pixelated(covering: cover)
                                                      : doc.effects.blurred(covering: cover)) else { return }
            var clip: Path
            if shape.points.count == 2, shape.tool == .mosaic || shape.tool == .blur {
                // 矩形 / 椭圆语义（渲染器同款判断）
                let a = shape.points[0], b = shape.points[1]
                clip = Path(CGRect(from: a, to: b))
            } else if shape.points.count >= 2 {
                var path = Path()
                path.addLines(shape.points)
                clip = path
            } else {
                return
            }
            // GraphicsContext 没有 saveGState：裁剪进一个透明图层再合成回来，
            // 效果等价且不会污染后续形状的绘制状态
            context.drawLayer { layer in
                layer.clip(to: clip, style: FillStyle(eoFill: false))
                layer.draw(Image(decorative: effect.image, scale: 1), in: effect.rect)
            }

        case .loupe:
            // 与 CG 渲染器同一套几何（`loupeSampleRect` / `loupeOutputRect` / `loupeStyle`）：
            // 取样区域裁出来，放大画进"放大后的框"，再描一圈边框（矩形圆角 / 圆形椭圆）。
            guard let out = shape.loupeOutputRect,
                  let sampleRect = shape.loupeSampleRect else { return }
            let bounds = CGRect(origin: .zero, size: doc.imageSize)
            let sample = sampleRect.intersection(bounds).integral
            guard sample.width >= 1, sample.height >= 1,
                  let cropped = doc.baseImage.cropping(to: sample) else { return }
            let lens: Path
            if shape.loupeStyle == .circle {
                lens = Path(ellipseIn: out)
            } else {
                lens = Path(roundedRect: out, cornerRadius: min(12, min(out.width, out.height) / 6))
            }
            context.drawLayer { layer in
                layer.clip(to: lens)
                layer.draw(Image(decorative: cropped, scale: 1), in: out)
            }
            context.stroke(lens, with: .color(color), lineWidth: max(2, width))

        case .measure:
            guard let a = shape.points.first, let b = shape.points.last else { return }
            var path = Path()
            path.move(to: a); path.addLine(to: b)
            context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: 2, lineCap: .round))
            for p in [a, b] {
                context.fill(Path(ellipseIn: CGRect(x: p.x - 4, y: p.y - 4, width: 8, height: 8)), with: .color(color))
            }
            let distance = Int(hypot(a.x - b.x, a.y - b.y))
            let distanceLabel = Text("\(distance) px")
                .font(.system(size: 16 * fitScale, weight: .semibold))
                .foregroundColor(.white)
            context.draw(distanceLabel,
                         at: CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2 - 14 * fitScale),
                         anchor: .bottom)

        case .step:
            // 圆底数字。序号走 EditorRenderer.stepNumber（与导出共用一份几何与编号）
            guard let p = shape.points.first else { return }
            let r = EditorRenderer.stepBubbleRadius
            let n = EditorRenderer.stepNumber(of: shape, in: doc.shapes)
            context.fill(Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r,
                                                width: r * 2, height: r * 2)),
                         with: .color(color))
            let label = Text("\(n)")
                .font(.system(size: EditorRenderer.stepFontSize * fitScale, weight: .bold))
                .foregroundColor(.white)
            context.draw(label, at: CGPoint(x: p.x, y: p.y), anchor: .center)

        case .colorPick:
            guard let p = shape.points.first else { return }
            let rect = CGRect(x: p.x - 12, y: p.y - 12, width: 24, height: 24)
            context.fill(Path(ellipseIn: rect), with: .color(color))
            context.stroke(Path(ellipseIn: rect), with: .color(.white), lineWidth: 2.5)
            let hexLabel = Text(shape.color.hexString)
                .font(.system(size: 14 * fitScale, weight: .semibold))
                .foregroundColor(.white)
            context.draw(hexLabel,
                         at: CGPoint(x: (p.x + 16) * fitScale, y: p.y * fitScale),
                         anchor: .leading)
        }
    }

    // ── 工具条 ──

    private var toolbar: some View {
        // 🔴 1.0.27：外面套一层横向 ScrollView。
        //
        // 工具条的自然宽度（14 个工具 + 6 色 + 取色器 + 字号 + 撤销 + 6 个输出按钮）
        // 已经超过 1000pt，而编辑窗口宽度是**按图片自适应**的（小图只有 640）。
        // 以前直接摆 HStack，空间不够 SwiftUI 只能压缩 —— 压的正是 `Label` 里的文字，
        // 于是"OCR"剩个"C"、"保存"剩半个字（用户截图："按钮变形了"）。
        // ScrollView 里的子视图按自然宽度排版，压不动；窗口窄了就横向滚，按钮永远是完整的。
        HStack(spacing: 0) {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
            // 工具
            HStack(spacing: 2) {
                ForEach(EditorTool.allCases) { tool in
                    Button {
                        // 换工具前先把正在打的字落盘，不然它停在"半挂"状态
                        commitEditingText()
                        doc.tool = tool
                    } label: {
                        Group {
                            // 文字工具直接显示「文字」两个字（textformat 字形
                            // 在中文环境渲染成「格式」，用户口径改掉）
                            if let label = tool.toolbarLabel {
                                Text(label)
                                    .font(.system(size: 11, weight: .medium))
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.7)
                            } else {
                                Image(systemName: tool.symbol)
                                    .font(.system(size: 14))
                            }
                        }
                        .frame(width: 28, height: 28)
                        .background(doc.tool == tool ? Color.accentColor.opacity(0.18) : .clear)
                        .cornerRadius(6)
                    }
                    .buttonStyle(.plain)
                    .help(tool.title)
                }
            }
            .padding(4)
            .background(Color(nsColor: .controlBackgroundColor))
            .cornerRadius(8)

            Divider().frame(height: 22)

            // 颜色 + 粗细收进一个圆点（点开是弹出面板）—— 跟截图浮层同一个交互。
            //
            // 🔴 1.0.27 改的：以前 6 个色块 + 取色器 + 粗细滑杆平铺在工具条上，
            // 一共占 260pt 左右；加上 14 个工具和 5 个输出按钮，自然宽度超过 1100，
            // 而编辑窗口宽度是按图片自适应的 —— 结果就是按钮被压变形（用户截图）。
            // 收进弹出层后工具条窄了 230pt，1000 宽的窗口里所有按钮都放得下。
            colorAnchor

            // 文字上下文给字号（只在文字工具 / 选中文字时出现，不占常驻宽度）
            if doc.tool == .text || doc.selectedShape?.tool == .text {
                fontSizeMenu
            }

            // 放大镜上下文给倍数（只在放大镜工具 / 选中放大镜时出现）
            if doc.tool == .loupe || doc.selectedShape?.tool == .loupe {
                loupeZoomMenu
            }

            Divider().frame(height: 22)

            // 撤销重做
            HStack(spacing: 4) {
                Button { doc.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                    .disabled(!doc.canUndo)
                    .keyboardShortcut("z", modifiers: .command)
                    .help("撤销 ⌘Z")
                Button { doc.redo() } label: { Image(systemName: "arrow.uturn.forward") }
                    .disabled(!doc.canRedo)
                    .keyboardShortcut("z", modifiers: [.command, .shift])
                    .help("重做 ⇧⌘Z")
            }
            .buttonStyle(.plain)

            Divider().frame(height: 22)

            // 输出
            //
            // 🔴 1.0.27：除了「完成」，全部改成**图标 + tooltip**。
            // 原因：窗口宽度是按图片自适应的，而工具条的自然宽度早就超过 1000pt，
            // 摆满"OCR / 美化 / 贴图 / 保存 / 复制 / 完成"六个带文字的按钮，窄窗口里
            // SwiftUI 只能压缩文字 → "OCR"剩个"C"、"保存"剩半个字（用户截图
            // "按钮变形了"）。去掉标签能省 200pt 左右，常见宽度（≥900）就不必滚动。
            // 「完成」保留文字：它是主操作，也是唯一带强调色的按钮。
            //
            // 用户 1.0.27 还要求去掉常驻的"删除"按钮（"一直显示，去掉"）——
            // 删除能力保留在 ⌫ / Delete 上（见 EditorWindowController 的按键监听）。
            HStack(spacing: 6) {
                Button { onOCR() } label: { Image(systemName: "text.below.photo") }
                    .help("识别图中文字并复制")
                Button {
                    withAnimation { doc.beautify = doc.beautify == nil ? BeautifyOptions() : nil }
                } label: { Image(systemName: "wand.and.stars") }
                    .help("截图美化（背景 / 圆角 / 阴影 / 边距）")
                Button { onPin() } label: { Image(systemName: "pin") }
                    .help("把当前图钉到桌面")
                Button { onSave() } label: { Image(systemName: "square.and.arrow.down") }
                    .keyboardShortcut("s", modifiers: .command)
                    .help("保存 ⌘S")
                Button { onCopy() } label: { Image(systemName: "doc.on.doc") }
                    .keyboardShortcut("c", modifiers: .command)
                    .help("复制 ⌘C")
            }
            }
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .fixedSize(horizontal: false, vertical: true)

        // 「完成」钉在最右边，**不跟着滚动**。
        // 它是主操作、也是唯一带强调色的按钮，滚到看不见就等于没有。
        // 左边那堆窄了可以横向滚，这个永远在原地。
        Divider().frame(height: 22)
        Button { onClose() } label: { Label("完成", systemImage: "checkmark") }
            .buttonStyle(.borderedProminent)
            .help("完成并关闭 ⎋")
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
    }

    // ── 颜色圆点 + 弹出面板 ──────────────────────────────

    /// 工具条上那颗"当前颜色"圆点，点开是 6 色调色板 + 自选色 + 粗细。
    /// 口径与截图浮层一致（那边是 `colorDotAnchorButton` + `colorPanel`）。
    private var colorAnchor: some View {
        Button {
            showColorPanel.toggle()
        } label: {
            Circle()
                .fill(Color(nsColor: doc.color.nsColor))
                .frame(width: 21, height: 21)
                .overlay(Circle().strokeBorder(Color.white.opacity(0.75), lineWidth: 1.5))
        }
        .buttonStyle(.plain)
        .help("颜色与粗细")
        .popover(isPresented: $showColorPanel, arrowEdge: .bottom) {
            colorPanel
        }
    }

    private var colorPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                ForEach(RGBColor.palette, id: \.hexString) { c in
                    Circle()
                        .fill(Color(nsColor: c.nsColor))
                        .frame(width: 18, height: 18)
                        .overlay(Circle().strokeBorder(doc.color == c ? Color.accentColor
                                                                   : Color.gray.opacity(0.4),
                                                       lineWidth: 2))
                        .onTapGesture { doc.applyToSelected(color: c) }
                        .help(c.hexString)
                }
                ColorPicker("", selection: Binding(
                    get: { Color(nsColor: doc.color.nsColor) },
                    set: { new in
                        let ns = NSColor(new).usingColorSpace(.sRGB) ?? .red
                        doc.color = RGBColor(red: ns.redComponent,
                                             green: ns.greenComponent,
                                             blue: ns.blueComponent)
                    }), supportsOpacity: false)
                    .labelsHidden()
                    .frame(width: 44, height: 22)
            }
            Divider()
            HStack(spacing: 8) {
                Text("粗细").font(.caption).foregroundStyle(.secondary)
                Slider(value: $doc.lineWidth, in: 2...24, step: 1)
                    .frame(width: 120)
                Text("\(Int(doc.lineWidth))").font(.caption)
                    .monospacedDigit().foregroundStyle(.secondary)
                    .frame(width: 18, alignment: .trailing)
            }
        }
        .padding(12)
        .frame(width: 240)
    }

    // ── 字号（与截图浮层同一份 6 档）────────────────────────

    private var fontSizeMenu: some View {
        Menu {
            ForEach(Array(EditorDocument.fontSizeOptions.enumerated()), id: \.offset) { _, points in
                Button {
                    setFontSize(points)
                } label: {
                    Text("\(Int(points)) pt")
                }
            }
        } label: {
            Text("\(Int(currentFontSizePoints.rounded())) pt")
                .font(.system(size: 11, weight: .medium))
                .monospacedDigit()
                .frame(width: 40, alignment: .leading)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("字号（只作用于文字）：20 / 24 / 30 / 40 / 52 / 68 pt")
    }

    /// 下拉该显示哪一档：正在输入 / 选中文字 → 看**那条文字**；否则看默认值。
    /// 浮层那边是同一套口径（`OverlayEditorController.currentFontSizeIndex`）。
    private var currentFontSizePoints: CGFloat {
        if let shape = editingShape ?? doc.selectedShape, shape.tool == .text, shape.fontSize > 0 {
            return EditorDocument.pointFontSize(pixels: shape.fontSize, fitScale: fitScale)
        }
        return doc.fontSize
    }

    /// 改字号（点）。三条路跟浮层一样：
    /// 正在输入 → 实时改（不压撤销点）；选中文字 → 改它并记住默认值；否则只改默认值。
    private func setFontSize(_ points: CGFloat) {
        doc.fontSize = points
        let pixels = EditorDocument.pixelFontSize(points: points, fitScale: fitScale)
        if let id = editingID, let idx = doc.shapes.firstIndex(where: { $0.id == id }) {
            doc.shapes[idx].fontSize = pixels
        } else {
            doc.applyToSelected(fontSize: pixels)
        }
    }

    // ── 放大倍数（2× / 3×）───────────────────────────────

    /// 倍数下拉。跟字号同一个思路：**只在用得上时出现**，不占常驻宽度
    /// （工具条早就超过 1000pt，常驻一个只在放大镜时才有意义的控件不值）。
    /// 一档一项、四个组合（矩形 2× / 矩形 3× / 圆形 2× / 圆形 3×）——
    /// 用户 2026-11-05 追加口径，别拆成两个下拉（形状一个、倍数一个），
    /// 那样每次换镜面要点两下。
    private var loupeZoomMenu: some View {
        Menu {
            ForEach(LoupeStyle.allCases) { style in
                ForEach(Array(EditorDocument.loupeZoomOptions.enumerated()), id: \.offset) { _, zoom in
                    Button {
                        setLoupe(style: style, zoom: zoom)
                    } label: {
                        Text("\(style.title) \(Int(zoom))×")
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: currentLoupeStyle.symbol)
                    .font(.system(size: 11))
                Text("\(Int(currentLoupeZoom))×")
                    .font(.system(size: 11, weight: .medium))
                    .monospacedDigit()
            }
            .frame(width: 48, alignment: .leading)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("放大镜：矩形 2× / 矩形 3× / 圆形 2× / 圆形 3×")
    }

    /// 下拉显示哪一档：选中放大镜就看**那条标注**，否则看默认值。
    /// 不这么做的话，选中一个 3× 的旧放大镜再想改，下拉还显示 2×，一改又回到 2×。
    private var currentLoupeZoom: CGFloat {
        if let shape = doc.selectedShape, shape.tool == .loupe { return shape.loupeZoom }
        return doc.loupeZoom
    }

    /// 镜面形状跟倍数同一个口径：选中放大镜看它自己的，否则看默认值
    private var currentLoupeStyle: LoupeStyle {
        if let shape = doc.selectedShape, shape.tool == .loupe { return shape.loupeStyle }
        return doc.loupeStyle
    }

    /// 换镜面 / 倍数：有选中的放大镜就改它并记成默认档，否则只改默认档
    /// （`applyToSelected` 里两件事一起做，包括写 UserDefaults）。
    private func setLoupe(style: LoupeStyle, zoom: CGFloat) {
        doc.applyToSelected(zoom: zoom, loupeStyle: style)
    }
}

// ============================================================
// 画布上的文字输入框
// ============================================================

/// 编辑器里的"输入文字"—— **跟截图浮层用同一种东西：NSTextView**。
///
/// 用户 1.0.27 口径：「编辑工具的输入文字功能跟截图工具条的输入文字功能不一致」。
/// 编辑器这边原来是一个 240pt 宽的 `TextField("输入文字，回车确认")`：圆角边框、
/// 15pt 固定字号、跟画布上的字毫无关系，看着就是两个功能。浮层那边是"点一下就地
/// 出现、字号颜色跟最终渲染一模一样、边打边看"。
///
/// 所以这里照抄浮层那套配置（`OverlayEditorView.beginTextEditing`）：透明背景、
/// 无边框、`systemFont(medium)`、关掉全部智能替换 —— 截图里写的 `--flag`、`a"b`、
/// `it's` 都必须原样进图，被换成弯引号/破折号就不是用户打的那句话。
///
/// 交互也照抄：⏎ / Tab = 确认，Esc = 取消。🔴 Esc 走 `cancelOperation:`，
/// **不要**在 keyCode 里判 53 —— 输入法组字过程中的 Esc 是"取消候选"，
/// 抢掉会把用户正在打的拼音弄丢。
struct CanvasTextEditor: NSViewRepresentable {

    @Binding var text: String
    /// 字号（**视图点**，调用方已经换算过）
    var fontSize: CGFloat
    var color: NSColor
    var onCommit: () -> Void
    var onCancel: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSTextView {
        let view = AutoFocusTextView(frame: .zero)
        view.delegate = context.coordinator
        view.drawsBackground = false
        view.isRichText = false
        view.isEditable = true
        view.isSelectable = true
        view.allowsUndo = true
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = false
        // 宽度不设限：打完一行不期望它自动换行（⏎ 是"确认"，不是换行）
        view.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                                   height: CGFloat.greatestFiniteMagnitude)
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.isAutomaticSpellingCorrectionEnabled = false
        view.isContinuousSpellCheckingEnabled = false
        view.isGrammarCheckingEnabled = false
        view.smartInsertDeleteEnabled = false
        // 🔴 让 NSTextView 永远"可以被压缩"：它的 intrinsicContentSize 会跟着文本变宽，
        // 优先级高点就会把外层布局撑开（同一条 emoji/长句能顶出半屏空白）。
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        view.setContentHuggingPriority(.defaultLow, for: .vertical)
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        view.string = text
        apply(fontSize: fontSize, color: color, to: view)
        return view
    }

    /// 文字框被 SwiftUI 拆掉时，把第一响应者还给窗口。
    ///
    /// 🔴 不还的话焦点一直挂在这个已经离开视图层级的小 NSTextView 上：
    /// 后续 ⌫ / Esc 都被当成"还在输入文字"而放行，结果什么都没发生
    /// （1.0.27 实测：确认文字后选中标注按 ⌫ 删不掉）。
    static func dismantleNSView(_ nsView: NSTextView, coordinator: Coordinator) {
        if nsView.window?.firstResponder === nsView {
            nsView.window?.makeFirstResponder(nil)
        }
    }

    func updateNSView(_ view: NSTextView, context: Context) {
        context.coordinator.parent = self
        // 🔴 只在真不一样时回写：文本变化本来就是 NSTextView 自己发出来的，
        // 无条件 set 会把正在组字的输入法打断（中文打一半被清空）。
        if view.string != text { view.string = text }
        apply(fontSize: fontSize, color: color, to: view)
    }

    private func apply(fontSize: CGFloat, color: NSColor, to view: NSTextView) {
        let font = NSFont.systemFont(ofSize: max(9, fontSize), weight: .medium)
        if view.font != font { view.font = font }
        if view.textColor != color {
            view.textColor = color
            // 光标也得跟着走，深色底图上默认黑光标看不见
            view.insertionPointColor = color
        }
    }

    /// 进窗口就抢焦点。
    ///
    /// 🔴 别在 `makeNSView` 里 `DispatchQueue.main.async { view.window?… }` 了：
    /// NSViewRepresentable 刚造出来的这一拍，view 还没挂进 window（`window` 是 nil，
    /// `makeFirstResponder` 静默失败）。1.0.27 第一次实测就是这样 —— 点完画布打字
    /// 一个字都进不去，画布上只留一个空选中框，看着像"文字工具坏了"。
    /// `viewDidMoveToWindow` 才是唯一能确定"已经挂上去了"的时机。
    final class AutoFocusTextView: NSTextView {
        private var didAutoFocus = false
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard !didAutoFocus, let window else { return }
            didAutoFocus = true
            // 这一拍 SwiftUI 可能还在往 window 上挂 hosting 层，下一轮再抢更稳
            DispatchQueue.main.async { [weak self, weak window] in
                guard let self, let window, self.window === window else { return }
                window.makeFirstResponder(self)
            }
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: CanvasTextEditor
        init(_ parent: CanvasTextEditor) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            parent.text = view.string
        }

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                parent.onCommit()
                return true
            case #selector(NSResponder.insertTab(_:)):
                // Tab 也当确认：这个临时输入框没有"下一个焦点"可去
                parent.onCommit()
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                parent.onCancel()
                return true
            default:
                return false
            }
        }
    }
}

private extension CGRect {
    init(from a: CGPoint, to b: CGPoint) {
        self.init(x: min(a.x, b.x), y: min(a.y, b.y),
                  width: abs(a.x - b.x), height: abs(a.y - b.y))
    }
}

/// 透明 PNG 的棋盘底
struct CheckerboardView: View {
    var body: some View {
        Canvas { context, size in
            let cell: CGFloat = 10
            for row in 0..<Int(ceil(size.height / cell)) {
                for col in 0..<Int(ceil(size.width / cell)) {
                    let rect = CGRect(x: CGFloat(col) * cell, y: CGFloat(row) * cell, width: cell, height: cell)
                    let isLight = (row + col) % 2 == 0
                    context.fill(Path(rect), with: .color(isLight ? Color(white: 0.94) : Color(white: 0.86)))
                }
            }
        }
    }
}
