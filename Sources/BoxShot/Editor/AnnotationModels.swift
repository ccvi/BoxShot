import AppKit
import CoreGraphics
import CoreImage
import Foundation

// ============================================================
// 标注模型与合成渲染
//
// 形状一律存在**图像像素坐标**里（不是视图坐标）：编辑器显示有缩放，
// 保存/复制/贴图用的却是原始分辨率，坐标换算只该发生一次。
//
// 马赛克 / 模糊不预烧进图像：渲染时先画底图，再"裁剪到笔画路径内画
// 整张效果图"。这样撤销/重做只是丢弃形状数组，底图永远干净。
// ============================================================

enum EditorTool: String, CaseIterable, Identifiable {
    case select     // 选择 / 移动 / 删除已画标注（macshot 式"点选编辑"）
    case pen        // 随手涂鸦
    case marker     // 马可笔（半透明粗笔）
    case rect
    case ellipse
    case line
    case arrow
    case text
    case mosaic
    case blur
    case measure    // 像素测距
    case colorPick  // 取色标注
    case crop       // 裁剪：拖出保留范围，⏎ 应用（不是标注，不进形状表）

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .select:    return "cursorarrow"
        case .pen:       return "pencil.tip"
        case .marker:    return "highlighter"
        case .rect:      return "rectangle"
        case .ellipse:   return "circle"
        case .line:      return "line.diagonal"
        case .arrow:     return "arrow.up.right"
        case .text:      return "textformat"
        case .mosaic:    return "squareshape.split.2x2"
        case .blur:      return "drop"
        case .measure:   return "ruler"
        case .colorPick: return "eyedropper"
        case .crop:      return "crop"
        }
    }

    var title: String {
        switch self {
        case .select:    return "选择 / 移动（⌫ 删除）"
        case .pen:       return "画笔"
        case .marker:    return "马可笔"
        case .rect:      return "矩形"
        case .ellipse:   return "椭圆"
        case .line:      return "直线"
        case .arrow:     return "箭头"
        case .text:      return "文字"
        case .mosaic:    return "马赛克"
        case .blur:      return "模糊"
        case .measure:   return "测距"
        case .colorPick: return "取色"
        case .crop:      return "裁剪（拖出保留范围，⏎ 应用）"
        }
    }

    /// 拖拽生成形状（false = 单击生效，如选择/文字/取色）
    var isDragTool: Bool {
        switch self {
        case .select, .text, .colorPick: return false
        default: return true
        }
    }
}

struct AnnotationShape: Equatable {
    var id = UUID()
    var tool: EditorTool
    /// 图像像素坐标；笔画类是点列，形状类是 [起点, 终点]
    var points: [CGPoint]
    var color: RGBColor
    var lineWidth: CGFloat
    var text: String = ""
    var fontSize: CGFloat = 0   // 0 = 用默认字号

    /// 归一化的可比较标识（撤销栈去重用）
    var signature: String {
        "\(tool.rawValue)|\(points.map { "\($0.x),\($0.y)" }.joined(separator: ";"))|\(color)|\(lineWidth)|\(text)"
    }

    // ── 命中测试 / 移动（"点选编辑"用，坐标都是图像像素） ──

    /// 命中容差：笔画线宽再放宽一点，方便点选细线
    private var hitPadding: CGFloat { max(8, lineWidth) }

    /// 是否命中该标注（自上而下点选用）
    func hitTest(_ p: CGPoint) -> Bool {
        switch tool {
        case .select:
            return false
        case .crop:
            return false
        case .rect, .ellipse, .mosaic, .blur, .measure:
            guard let a = points.first, let b = points.last else { return false }
            return rect(from: a, to: b).insetBy(dx: -hitPadding, dy: -hitPadding).contains(p)
        case .line, .arrow, .pen, .marker:
            guard points.count >= 2 else { return false }
            for i in 0..<(points.count - 1) {
                if distance(p, toSegment: (points[i], points[i + 1])) <= hitPadding { return true }
            }
            return false
        case .text:
            guard let at = points.first else { return false }
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: fontSize > 0 ? fontSize : 30, weight: .medium),
            ]
            let size = (text as NSString).size(withAttributes: attributes)
            let box = CGRect(x: at.x, y: at.y,
                             width: max(40, ceil(size.width) + 4),
                             height: max(fontSize * 1.4, ceil(size.height) + 4))
            return box.insetBy(dx: -8, dy: -8).contains(p)
        case .colorPick:
            guard let at = points.first else { return false }
            return hypot(p.x - at.x, p.y - at.y) <= 20
        }
    }

    /// 选中框（渲染虚线框 + 拖动限制用）
    var displayBounds: CGRect? {
        switch tool {
        case .select:
            return nil
        case .crop:
            return nil
        case .rect, .ellipse, .mosaic, .blur, .measure:
            guard let a = points.first, let b = points.last else { return nil }
            return rect(from: a, to: b).insetBy(dx: -hitPadding / 2, dy: -hitPadding / 2)
        case .line, .arrow, .pen, .marker:
            guard let first = points.first else { return nil }
            var bounds = CGRect(x: first.x, y: first.y, width: 0, height: 0)
            for p in points { bounds = bounds.union(CGRect(x: p.x, y: p.y, width: 0, height: 0)) }
            return bounds.insetBy(dx: -hitPadding / 2, dy: -hitPadding / 2)
        case .text:
            guard let at = points.first else { return nil }
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: fontSize > 0 ? fontSize : 30, weight: .medium),
            ]
            let size = (text as NSString).size(withAttributes: attributes)
            return CGRect(x: at.x, y: at.y,
                          width: max(40, ceil(size.width) + 4),
                          height: max(fontSize * 1.4, ceil(size.height) + 4))
        case .colorPick:
            guard let at = points.first else { return nil }
            return CGRect(x: at.x - 14, y: at.y - 14, width: 28 + 60, height: 28)
        }
    }

    /// 平移一份（拖动标注用）
    func translated(dx: CGFloat, dy: CGFloat) -> AnnotationShape {
        var copy = self
        copy.points = points.map { CGPoint(x: $0.x + dx, y: $0.y + dy) }
        return copy
    }

    private func distance(_ p: CGPoint, toSegment segment: (CGPoint, CGPoint)) -> CGFloat {
        let (a, b) = segment
        let dx = b.x - a.x, dy = b.y - a.y
        let lengthSq = dx * dx + dy * dy
        guard lengthSq > 0 else { return hypot(p.x - a.x, p.y - a.y) }
        let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / lengthSq))
        let proj = CGPoint(x: a.x + t * dx, y: a.y + t * dy)
        return hypot(p.x - proj.x, p.y - proj.y)
    }

    private func rect(from a: CGPoint, to b: CGPoint) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y),
               width: abs(a.x - b.x), height: abs(a.y - b.y))
    }
}

/// 存 RGB 就够（取色/画笔），避免跨 SwiftUI/CoreGraphics 的颜色空间歧义
struct RGBColor: Equatable {
    var red: Double
    var green: Double
    var blue: Double
    var alpha: Double = 1

    static let red    = RGBColor(red: 0.95, green: 0.26, blue: 0.21)
    static let blue   = RGBColor(red: 0.15, green: 0.45, blue: 0.95)
    static let yellow = RGBColor(red: 1.00, green: 0.78, blue: 0.10)
    static let green  = RGBColor(red: 0.20, green: 0.72, blue: 0.35)
    static let white  = RGBColor(red: 1, green: 1, blue: 1)
    static let black  = RGBColor(red: 0, green: 0, blue: 0)

    var cgColor: CGColor { CGColor(srgbRed: red, green: green, blue: blue, alpha: alpha) }
    var nsColor: NSColor { NSColor(calibratedRed: red, green: green, blue: blue, alpha: alpha) }

    var hexString: String {
        String(format: "#%02X%02X%02X",
               Int(round(red * 255)), Int(round(green * 255)), Int(round(blue * 255)))
    }
}

// ── 效果图缓存 ───────────────────────────────────────────────

final class EffectImages {
    let base: CGImage
    private var pixelatedCache: CGImage?
    private var blurredCache: CGImage?

    init(base: CGImage) {
        self.base = base
    }

    /// 马赛克：CIPixellate，块大小随图像尺寸走
    var pixelated: CGImage? {
        if let hit = pixelatedCache { return hit }
        let made = Self.applyFilter(base, filterName: "CIPixellate") { filter, extent in
            filter.setValue(max(10, Int(min(extent.width, extent.height) / 60)), forKey: "inputScale")
        }
        pixelatedCache = made
        return made
    }

    /// 模糊：CIGaussianBlur + 裁回原边界（模糊会把边缘糊出去）
    var blurred: CGImage? {
        if let hit = blurredCache { return hit }
        let extent = CGRect(x: 0, y: 0, width: base.width, height: base.height)
        let ciBase = CIImage(cgImage: base)
        guard let filter = CIFilter(name: "CIGaussianBlur") else { return nil }
        filter.setValue(ciBase, forKey: kCIInputImageKey)
        filter.setValue(10.0, forKey: kCIInputRadiusKey)
        guard let output = filter.outputImage?.cropped(to: extent) else { return nil }
        let context = CIContext(options: [.useSoftwareRenderer: false])
        blurredCache = context.createCGImage(output, from: extent)
        return blurredCache
    }

    private static func applyFilter(_ image: CGImage, filterName: String,
                                    configure: (CIFilter, CGRect) -> Void) -> CGImage? {
        let extent = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        guard let filter = CIFilter(name: filterName) else { return nil }
        filter.setValue(CIImage(cgImage: image), forKey: kCIInputImageKey)
        configure(filter, extent)
        guard let output = filter.outputImage?.cropped(to: extent) else { return nil }
        let context = CIContext(options: [.useSoftwareRenderer: false])
        return context.createCGImage(output, from: extent)
    }
}

// ── 合成渲染 ─────────────────────────────────────────────────

enum EditorRenderer {

    /// 把底图 + 全部标注压成一张成品图（保存 / 复制 / 贴图都用它）
    static func render(base: CGImage, shapes: [AnnotationShape], effects: EffectImages) -> CGImage? {
        let width = base.width
        let height = base.height
        guard let ctx = CGContext(data: nil,
                                  width: width, height: height,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }

        // 先在**未翻转**的标准空间画底图（此空间里 CGImage 方向才是正的），
        // 再翻成"左上原点向下"画标注——形状坐标按 y 向下存。
        // 顺序反了底图会整体上下颠倒（形状位置对、内容倒）。
        ctx.draw(base, in: CGRect(x: 0, y: 0, width: width, height: height))
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: 1, y: -1)

        drawShapes(shapes, in: ctx, effects: effects, canvasHeight: CGFloat(height))
        return ctx.makeImage()
    }

    /// 供原位编辑浮层复用：在"左上原点"的翻转上下文里画一批标注
    static func drawShapes(_ shapes: [AnnotationShape], in ctx: CGContext,
                           effects: EffectImages, canvasHeight: CGFloat) {
        for shape in shapes {
            draw(shape: shape, in: ctx, effects: effects, canvasHeight: canvasHeight)
        }
    }

    /// 选中标注的虚线框（调用方已变换到图像像素空间）
    static func drawSelection(for shape: AnnotationShape, in ctx: CGContext) {
        guard let bounds = shape.displayBounds else { return }
        ctx.saveGState()
        ctx.setStrokeColor(NSColor.controlAccentColor.cgColor)
        ctx.setLineWidth(1.5)
        ctx.setLineDash(phase: 0, lengths: [6, 4])
        ctx.stroke(bounds)
        ctx.setLineDash(phase: 0, lengths: [])
        ctx.restoreGState()
    }

    private static func draw(shape: AnnotationShape, in ctx: CGContext, effects: EffectImages, canvasHeight: CGFloat) {
        let color = shape.color
        let width = max(1, shape.lineWidth)

        switch shape.tool {
        case .select, .crop:
            return
        case .pen, .marker:
            guard let path = strokePath(of: shape) else { return }
            ctx.saveGState()
            ctx.setStrokeColor(color.cgColor)
            ctx.setLineWidth(width)
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)
            if shape.tool == .marker {
                ctx.setAlpha(0.45)
                ctx.setBlendMode(.multiply)
            }
            ctx.addPath(path)
            ctx.strokePath()
            ctx.restoreGState()

        case .rect:
            guard let a = shape.points.first, let b = shape.points.last else { return }
            ctx.setStrokeColor(color.cgColor)
            ctx.setLineWidth(width)
            ctx.stroke(rect(from: a, to: b))

        case .ellipse:
            guard let a = shape.points.first, let b = shape.points.last else { return }
            ctx.setStrokeColor(color.cgColor)
            ctx.setLineWidth(width)
            ctx.strokeEllipse(in: rect(from: a, to: b))

        case .line:
            guard let a = shape.points.first, let b = shape.points.last else { return }
            ctx.setStrokeColor(color.cgColor)
            ctx.setLineWidth(width)
            ctx.setLineCap(.round)
            ctx.move(to: a); ctx.addLine(to: b); ctx.strokePath()

        case .arrow:
            guard let a = shape.points.first, let b = shape.points.last else { return }
            ctx.setStrokeColor(color.cgColor)
            ctx.setFillColor(color.cgColor)
            ctx.setLineWidth(width)
            ctx.setLineCap(.round)
            ctx.move(to: a); ctx.addLine(to: b); ctx.strokePath()
            drawArrowHead(from: a, to: b, width: width, in: ctx)

        case .text:
            drawText(shape.text, at: shape.points.first ?? .zero,
                     color: color, fontSize: shape.fontSize > 0 ? shape.fontSize : 30,
                     canvasHeight: canvasHeight, in: ctx)

        case .mosaic, .blur:
            guard let effect = (shape.tool == .mosaic ? effects.pixelated : effects.blurred),
                  let a = shape.points.first, let b = shape.points.last else { return }
            ctx.saveGState()
            // 两点语义 = 拖拽起止点围成的矩形区域。
            // 🔴 不能用直线路径 clip：直线是零面积的，裁剪后什么都画不出来
            //（1.0.1"画了马赛克但看不见"的根因）。
            ctx.addPath(CGPath(rect: rect(from: a, to: b), transform: nil))
            ctx.clip()
            // 效果图与底图同理：翻转空间里直接 draw 会上下颠倒，
            // 临时还原标准空间再画（clip 已记录在设备空间，不受影响）。
            ctx.translateBy(x: 0, y: canvasHeight)
            ctx.scaleBy(x: 1, y: -1)
            ctx.draw(effect, in: CGRect(x: 0, y: 0, width: effects.base.width, height: effects.base.height))
            ctx.restoreGState()

        case .measure:
            guard let a = shape.points.first, let b = shape.points.last else { return }
            ctx.setStrokeColor(color.cgColor)
            ctx.setFillColor(color.cgColor)
            ctx.setLineWidth(2)
            ctx.setLineCap(.round)
            ctx.move(to: a); ctx.addLine(to: b); ctx.strokePath()
            for p in [a, b] {
                ctx.fillEllipse(in: CGRect(x: p.x - 4, y: p.y - 4, width: 8, height: 8))
            }
            let distance = Int(hypot(a.x - b.x, a.y - b.y))
            drawTag("\(distance) px", at: CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2 - 18),
                    background: color, canvasHeight: canvasHeight, in: ctx)

        case .colorPick:
            guard let p = shape.points.first else { return }
            ctx.setFillColor(color.cgColor)
            ctx.fillEllipse(in: CGRect(x: p.x - 12, y: p.y - 12, width: 24, height: 24))
            ctx.setStrokeColor(RGBColor.white.cgColor)
            ctx.setLineWidth(2.5)
            ctx.strokeEllipse(in: CGRect(x: p.x - 12, y: p.y - 12, width: 24, height: 24))
            drawTag(color.hexString, at: CGPoint(x: p.x + 16, y: p.y - 12),
                    background: RGBColor.black, canvasHeight: canvasHeight, in: ctx)
        }
    }

    private static func rect(from a: CGPoint, to b: CGPoint) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y),
               width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    /// 笔画类的连续路径（points 有序点列）
    private static func strokePath(of shape: AnnotationShape) -> CGPath? {
        guard shape.points.count >= 2 else { return nil }
        let path = CGMutablePath()
        path.move(to: shape.points[0])
        for p in shape.points.dropFirst() { path.addLine(to: p) }
        return path
    }

    private static func drawArrowHead(from a: CGPoint, to b: CGPoint, width: CGFloat, in ctx: CGContext) {
        let angle = atan2(b.y - a.y, b.x - a.x)
        let headLen = max(12, width * 3.5)
        let spread: CGFloat = 0.42
        let p1 = CGPoint(x: b.x - headLen * cos(angle - spread), y: b.y - headLen * sin(angle - spread))
        let p2 = CGPoint(x: b.x - headLen * cos(angle + spread), y: b.y - headLen * sin(angle + spread))
        ctx.move(to: b); ctx.addLine(to: p1); ctx.addLine(to: p2); ctx.closePath()
        ctx.fillPath()
    }

    private static func drawText(_ text: String, at point: CGPoint, color: RGBColor,
                                 fontSize: CGFloat, canvasHeight: CGFloat, in ctx: CGContext) {
        guard !text.isEmpty else { return }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: fontSize, weight: .medium),
            .foregroundColor: color.nsColor,
        ]
        let line = NSAttributedString(string: text, attributes: attributes)
        let lineSize = line.size()
        let box = CGRect(x: point.x, y: point.y,
                         width: max(40, ceil(lineSize.width) + 4),
                         height: max(fontSize * 1.4, ceil(lineSize.height) + 4))
        drawCoreText(line, in: box, canvasHeight: canvasHeight, ctx: ctx)
    }

    private static func drawTag(_ text: String, at point: CGPoint, background: RGBColor,
                                canvasHeight: CGFloat, in ctx: CGContext) {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 20, weight: .semibold)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: NSColor.white,
        ]
        let line = NSAttributedString(string: text, attributes: attributes)
        let size = line.size()
        let box = CGRect(x: point.x, y: point.y, width: size.width + 16, height: size.height + 10)
        ctx.setFillColor(background.cgColor)
        ctx.addPath(CGPath(roundedRect: box, cornerWidth: 6, cornerHeight: 6, transform: nil))
        ctx.fillPath()
        let inner = CGRect(x: box.minX + 8, y: box.minY + 4, width: ceil(size.width) + 2, height: ceil(size.height) + 2)
        drawCoreText(line, in: inner, canvasHeight: canvasHeight, ctx: ctx)
    }

    /// CoreText 的文字绘制假设"左下原点"标准坐标系；整体上下文已被翻成
    /// 左上原点，直接画会把字画倒。这里临时还原一次再画。
    private static func drawCoreText(_ text: NSAttributedString, in box: CGRect,
                                     canvasHeight: CGFloat, ctx: CGContext) {
        ctx.saveGState()
        ctx.translateBy(x: 0, y: canvasHeight)
        ctx.scaleBy(x: 1, y: -1)
        let bottomLeftBox = CGRect(x: box.minX, y: canvasHeight - box.maxY, width: box.width, height: box.height)
        let framesetter = CTFramesetterCreateWithAttributedString(text)
        let path = CGPath(rect: bottomLeftBox, transform: nil)
        let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: text.length), path, nil)
        CTFrameDraw(frame, ctx)
        ctx.restoreGState()
    }
}

// ── 图像编码 ─────────────────────────────────────────────────

enum ImageEncode {
    static func data(_ image: CGImage, format: ShotFormat, jpgQuality: Double) -> Data? {
        let rep = NSBitmapImageRep(cgImage: image)
        switch format {
        case .png:
            return rep.representation(using: .png, properties: [:])
        case .jpg:
            return rep.representation(using: .jpeg,
                                      properties: [.compressionFactor: max(0.1, min(1, jpgQuality))])
        }
    }
}
