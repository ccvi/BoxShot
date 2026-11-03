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

    /// 拖动结束：压一个撤销点（撤销 = 回到拖动前位置）
    func endMoveSelected() {
        defer { moveOrigin = nil }
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

    /// 改选中标注的颜色 / 粗细（进撤销栈）；没有选中时只改默认值
    func applyToSelected(color: RGBColor? = nil, lineWidth: CGFloat? = nil) {
        if color != nil { self.color = color! }
        if let lineWidth { self.lineWidth = lineWidth }
        guard let selectedID, let idx = shapes.firstIndex(where: { $0.id == selectedID }) else { return }
        pushUndo(shapes)
        if let color { shapes[idx].color = color }
        if let lineWidth { shapes[idx].lineWidth = lineWidth }
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
    @State private var editingText: (point: CGPoint, text: String)?
    @State private var statusMessage: String = ""
    /// 选择工具拖动中的上一次像素坐标
    @State private var selectDragLast: CGPoint?
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

                    for shape in doc.shapes {
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

                // 文字输入浮层
                if let editing = editingText {
                    TextField("输入文字，回车确认", text: Binding(
                        get: { editingText?.text ?? "" },
                        set: { editingText?.text = $0 }
                    ))
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 15))
                    .frame(width: 240)
                    .position(x: min(editing.point.x * fitScale + 120, displaySize.width - 120),
                              y: min(editing.point.y * fitScale + 18, displaySize.height - 20))
                    .onSubmit { commitEditingText() }
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
                    // 拖动选中标注：按下起点命中并锁定，之后按位移平移
                    if selectDragLast == nil {
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
                    if selectDragLast != nil { doc.endMoveSelected() }
                    selectDragLast = nil
                    return
                }
                guard var shape = draft else { return }
                draft = nil
                draftStart = nil
                if shape.points.count >= 2 {
                    if shape.tool == .mosaic || shape.tool == .blur {
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
        switch doc.tool {
        case .select:
            doc.select(at: p)
        case .text:
            doc.selectedID = nil
            editingText = (p, "")
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

    private func commitEditingText() {
        guard let editing = editingText, !editing.text.isEmpty else {
            editingText = nil
            return
        }
        let shape = AnnotationShape(tool: .text, points: [editing.point],
                                    color: doc.color, lineWidth: 0,
                                    text: editing.text,
                                    fontSize: max(22, 30))
        doc.commit(shape)
        editingText = nil
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
        HStack(spacing: 10) {
            // 工具
            HStack(spacing: 2) {
                ForEach(EditorTool.allCases) { tool in
                    Button {
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
                        .frame(width: 30, height: 28)
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

            // 颜色（有选中标注时直接改它）—— 与截图工具条同一份 6 色调色板
            HStack(spacing: 5) {
                ForEach(RGBColor.palette, id: \.hexString) { c in
                    Circle()
                        .fill(Color(nsColor: c.nsColor))
                        .frame(width: 16, height: 16)
                        .overlay(Circle().strokeBorder(doc.color == c ? Color.accentColor : Color.gray.opacity(0.4), lineWidth: 2))
                        .onTapGesture { doc.applyToSelected(color: c) }
                        .help(c.hexString)
                }
                ColorPicker("", selection: Binding(
                    get: { Color(nsColor: doc.color.nsColor) },
                    set: { new in
                        let ns = NSColor(new).usingColorSpace(.sRGB) ?? .red
                        doc.color = RGBColor(red: ns.redComponent, green: ns.greenComponent, blue: ns.blueComponent)
                    }), supportsOpacity: false)
                    .labelsHidden()
                    // 🔴 布局宽度必须给够：macOS 取色控件的胶囊本体比 26pt 宽，
                    // frame 限窄它不会缩、只会画出去压住左边的紫色圆点
                    //（2026-11-02 用户样张「颜色调整挡住了其他颜色」）。
                    // 44pt 是它的自然宽度，宁可留点空隙别再叠上去。
                    .padding(.leading, 3)
                    .frame(width: 46, height: 22)
            }

            // 粗细
            Slider(value: $doc.lineWidth, in: 2...24, step: 1)
                .frame(width: 90)

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

            Spacer()

            // 输出
            HStack(spacing: 8) {
                if doc.selectedShape != nil {
                    Button(role: .destructive) { doc.deleteSelected() } label: {
                        Label("删除", systemImage: "trash")
                    }
                    .keyboardShortcut(.delete, modifiers: [])
                    .help("删除选中标注 ⌫")
                }
                Button { onOCR() } label: { Label("OCR", systemImage: "text.below.photo") }
                    .help("识别图中文字并复制")
                Button {
                    withAnimation { doc.beautify = doc.beautify == nil ? BeautifyOptions() : nil }
                } label: { Label("美化", systemImage: "wand.and.stars") }
                    .help("截图美化（背景 / 圆角 / 阴影 / 边距）")
                Button { onPin() } label: { Label("贴图", systemImage: "pin") }
                    .help("把当前图钉到桌面")
                Button { onSave() } label: { Label("保存", systemImage: "square.and.arrow.down") }
                    .keyboardShortcut("s", modifiers: .command)
                    .help("保存 ⌘S")
                Button { onCopy() } label: { Label("复制", systemImage: "doc.on.doc") }
                    .keyboardShortcut("c", modifiers: .command)
                    .help("复制 ⌘C")
                Button { onClose() } label: { Label("完成", systemImage: "checkmark") }
                    .buttonStyle(.borderedProminent)
                    .help("完成并关闭 ⎋")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
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
