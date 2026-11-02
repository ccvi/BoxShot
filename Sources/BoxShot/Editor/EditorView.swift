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
    @Published var tool: EditorTool = .rect
    @Published var color: RGBColor = .red
    @Published var lineWidth: CGFloat = 4
    /// 当前选中的标注（"选择"工具点选；⌫ 删除；拖动移动）
    @Published var selectedID: UUID?

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

    // ── 撤销 / 重做 ──

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    func commit(_ shape: AnnotationShape) {
        undoStack.append(shapes)
        redoStack.removeAll()
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
        undoStack.append(previous)
        redoStack.removeAll()
    }

    /// 删除选中标注（⌫ / Delete）
    func deleteSelected() {
        guard let selectedID, let idx = shapes.firstIndex(where: { $0.id == selectedID }) else { return }
        undoStack.append(shapes)
        redoStack.removeAll()
        shapes.remove(at: idx)
        self.selectedID = nil
    }

    /// 改选中标注的颜色 / 粗细（进撤销栈）；没有选中时只改默认值
    func applyToSelected(color: RGBColor? = nil, lineWidth: CGFloat? = nil) {
        if color != nil { self.color = color! }
        if let lineWidth { self.lineWidth = lineWidth }
        guard let selectedID, let idx = shapes.firstIndex(where: { $0.id == selectedID }) else { return }
        undoStack.append(shapes)
        redoStack.removeAll()
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
        EditorRenderer.render(base: baseImage, shapes: shapes, effects: effects)
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
            if cropRect != nil { cropBar }
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

    private var displaySize: CGSize {
        CGSize(width: doc.imageSize.width * fitScale, height: doc.imageSize.height * fitScale)
    }

    private var canvas: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                // 画布：棋盘底（透出 PNG 透明区）+ 图像 + 已提交标注 + 草稿
                CheckerboardView()
                    .frame(width: displaySize.width, height: displaySize.height)

                Canvas { context, _ in
                    context.scaleBy(x: fitScale, y: fitScale)
                    context.draw(Image(decorative: doc.baseImage, scale: 1),
                                 in: CGRect(origin: .zero, size: doc.imageSize))

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
                handleTap(clampToImage(CGPoint(x: location.x / fitScale, y: location.y / fitScale)))
            }
            .onChange(of: geo.size) { _ in measureFit(with: geo.size) }
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
                let p = clampToImage(CGPoint(x: value.location.x / fitScale,
                                             y: value.location.y / fitScale))
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
        guard doc.imageSize.width > 0, doc.imageSize.height > 0 else { return }
        let scale = min(availW / doc.imageSize.width, availH / doc.imageSize.height, 1.0)
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
            // 半透明整块染色（截图浮层那边用 multiply，SwiftUI 这边只能给 opacity）
            guard let a = shape.points.first, let b = shape.points.last else { return }
            context.fill(Path(CGRect(from: a, to: b)), with: .color(color.opacity(0.38)))

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
            var path = Path()
            path.move(to: a); path.addLine(to: b)
            context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: width, lineCap: .round))
            let angle = atan2(b.y - a.y, b.x - a.x)
            let headLen = max(12, width * 3.5)
            let spread: CGFloat = 0.42
            var head = Path()
            head.move(to: b)
            head.addLine(to: CGPoint(x: b.x - headLen * cos(angle - spread), y: b.y - headLen * sin(angle - spread)))
            head.addLine(to: CGPoint(x: b.x - headLen * cos(angle + spread), y: b.y - headLen * sin(angle + spread)))
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
            guard let effect = (shape.tool == .mosaic ? doc.effects.pixelated : doc.effects.blurred) else { return }
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
                layer.draw(Image(decorative: effect, scale: 1),
                           in: CGRect(origin: .zero, size: doc.imageSize))
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
                        Image(systemName: tool.symbol)
                            .font(.system(size: 14))
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

            // 颜色（有选中标注时直接改它）
            HStack(spacing: 5) {
                ForEach([RGBColor.red, .blue, .yellow, .green, .white, .black], id: \.hexString) { c in
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
                    .frame(width: 26, height: 22)
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
