import AppKit
import CoreGraphics
import CoreImage
import Foundation
import ImageIO

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
    case highlight  // 高亮：半透明色块（拖一个矩形，整块染色），和马克笔的"笔画"不同
    case ellipse
    case line
    case arrow
    case step    // 步骤标注：点击放圆底数字 ①②③，序号按数组顺序渲染（删了自动重排）
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
        case .highlight: return "sun.max"
        case .ellipse:   return "circle"
        case .line:      return "line.diagonal"
        case .arrow:     return "arrow.up.right"
        case .step:      return "1.circle"
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
        case .highlight: return "高亮（点亮这块，其余压暗）"
        case .ellipse:   return "椭圆"
        case .line:      return "直线"
        case .arrow:     return "箭头"
        case .step:      return "步骤标注（点击放编号，自动递增）"
        case .text:      return "文字"
        case .mosaic:    return "马赛克"
        case .blur:      return "模糊"
        case .measure:   return "测距"
        case .colorPick: return "取色"
        case .crop:      return "裁剪（拖出保留范围，⏎ 应用）"
        }
    }

    /// 拖拽生成形状（false = 单击生效，如选择/文字/取色/步骤标注）
    var isDragTool: Bool {
        switch self {
        case .select, .text, .colorPick, .step: return false
        default: return true
        }
    }

    /// 工具条按钮上的**文字标签**（nil = 用 symbol 图标）。
    /// 文字工具以前用 SF Symbol「textformat」，在中文环境的 macOS 上
    /// 这个字形渲染出来就是「格式」两个字（2026-11-02 用户样张口径：
    /// 「工具条的文字：格式 改为 文字」）—— 改成直接显示文字标签，
    /// 浮层工具条与编辑窗口工具条共用这一份。
    var toolbarLabel: String? {
        switch self {
        case .text: return "文字"
        default: return nil
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
        case .rect, .highlight, .ellipse, .mosaic, .blur, .measure:
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
        case .step:
            guard let at = points.first else { return false }
            return hypot(p.x - at.x, p.y - at.y) <= EditorRenderer.stepBubbleRadius + 6
        }
    }

    /// 选中框（渲染虚线框 + 拖动限制用）
    var displayBounds: CGRect? {
        switch tool {
        case .select:
            return nil
        case .crop:
            return nil
        case .rect, .highlight, .ellipse, .mosaic, .blur, .measure:
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
        case .step:
            guard let at = points.first else { return nil }
            let r = EditorRenderer.stepBubbleRadius
            return CGRect(x: at.x - r, y: at.y - r, width: r * 2, height: r * 2)
        }
    }

    /// 平移一份（拖动标注用）
    func translated(dx: CGFloat, dy: CGFloat) -> AnnotationShape {
        var copy = self
        copy.points = points.map { CGPoint(x: $0.x + dx, y: $0.y + dy) }
        return copy
    }

    // ── 可拖节点（用户 2026-11-04：「截图和编辑时，标注的箭头、矩形、椭圆、直线，
    //    有修改的节点可以修改」，配的样张是矩形四角 + 四边中点共 8 个白色方块）──
    //
    // 只有这四种给节点：
    //   · 矩形 / 椭圆 8 个（4 角 + 4 边中点）—— 任一条边都能单独拉；
    //   · 直线 / 箭头 2 个端点 —— 它们本来就只有两个点，给边中点没有意义。
    // 其余（画笔 / 马克笔 / 文字 / 高亮 / 马赛克 / 模糊 / 测距 / 步骤 / 取色）不参与：
    // 高亮和马赛克虽然也是矩形语义，但用户这次点名的只有这四种，先不扩。

    /// 这个形状的节点（**图像像素坐标**），顺序固定 —— 模型层、浮层、编辑窗口
    /// 三处都按这个下标取，别再各写一套。
    ///
    /// 矩形 / 椭圆一律先规范化成"左上 → 右下"，所以从左下往右上拉出来的框，
    /// 节点位置也对得上（点序本身不规整，但 8 个点永远是这 8 个位置）。
    var handlePoints: [CGPoint] {
        guard points.count >= 2 else { return [] }
        switch tool {
        case .rect, .ellipse:
            let r = rect(from: points[0], to: points[points.count - 1])
            return [
                CGPoint(x: r.minX, y: r.minY),   // 0 左上
                CGPoint(x: r.midX, y: r.minY),   // 1 上
                CGPoint(x: r.maxX, y: r.minY),   // 2 右上
                CGPoint(x: r.maxX, y: r.midY),   // 3 右
                CGPoint(x: r.maxX, y: r.maxY),   // 4 右下
                CGPoint(x: r.midX, y: r.maxY),   // 5 下
                CGPoint(x: r.minX, y: r.maxY),   // 6 左下
                CGPoint(x: r.minX, y: r.midY),   // 7 左
            ]
        case .line, .arrow:
            return [points[0], points[points.count - 1]]
        default:
            return []
        }
    }

    /// 命中哪个节点；`tolerance` 是**图像像素**（调用方按自己的缩放换算成屏幕 9pt 左右）。
    /// 手柄压在形状边缘上，稍微点偏一点也得能抓住，所以容差比手柄本身大一圈。
    func handleIndex(near point: CGPoint, tolerance: CGFloat) -> Int? {
        for (index, handle) in handlePoints.enumerated()
        where hypot(handle.x - point.x, handle.y - point.y) <= tolerance {
            return index
        }
        return nil
    }

    /// 把第 `index` 个节点拖到 `point`（图像像素）之后的形状。
    ///
    /// 矩形 / 椭圆：**对角保持不动**，只挪被拖的那条边（边中点只改一个轴）。
    /// 拖过头会翻面 —— 用 min/max 归一，不做事先拦截，跟系统里拖框的手感一致。
    /// 直线 / 箭头：改对应那个端点。
    func adjusting(handle index: Int, to point: CGPoint) -> AnnotationShape {
        var copy = self
        guard points.count >= 2 else { return copy }
        switch tool {
        case .line, .arrow:
            if index == 0 {
                copy.points[0] = point
            } else if index == points.count - 1 {
                copy.points[points.count - 1] = point
            }
        case .rect, .ellipse:
            let r = rect(from: points[0], to: points[points.count - 1])
            var minX = r.minX, minY = r.minY, maxX = r.maxX, maxY = r.maxY
            switch index {
            case 0: minX = point.x; minY = point.y     // 左上
            case 1: minY = point.y                     // 上
            case 2: maxX = point.x; minY = point.y     // 右上
            case 3: maxX = point.x                     // 右
            case 4: maxX = point.x; maxY = point.y     // 右下
            case 5: maxY = point.y                     // 下
            case 6: minX = point.x; maxY = point.y     // 左下
            case 7: minX = point.x                     // 左
            default: return copy
            }
            // 点序统一成 [左上, 右下]：拖过对角之后 min/max 会自动交换，
            // 形状不会消失、也不会变成负宽高（负宽高的 rect 渲染出来是空的）。
            copy.points = [CGPoint(x: min(minX, maxX), y: min(minY, maxY)),
                           CGPoint(x: max(minX, maxX), y: max(minY, maxY))]
        default:
            break
        }
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

    // 六个主色按用户给的色卡取值（直接从他那张图上取的像素中心）：
    // 黄 #F8CE43 / 绿 #62C563 / 蓝 #3887FB / 红 #EB4259 / 橙 #F3933D / 紫 #BD3DDD
    static let yellow = srgb(248, 206, 67)    // #F8CE43
    static let green  = srgb(98, 197, 99)     // #62C563
    static let blue   = srgb(56, 135, 251)    // #3887FB
    static let red    = srgb(235, 66, 89)     // #EB4259
    static let orange = srgb(243, 147, 61)    // #F3933D
    static let purple = srgb(189, 61, 221)    // #BD3DDD

    /// 用 0–255 写色值，免得手算浮点把 hexString 算歪一档
    static func srgb(_ r: Int, _ g: Int, _ b: Int) -> RGBColor {
        RGBColor(red: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255)
    }
    // 白 / 黑不在色卡里，但取色标注、文字这类地方仍然用得到
    static let white  = RGBColor(red: 1, green: 1, blue: 1)
    static let black  = RGBColor(red: 0, green: 0, blue: 0)

    var cgColor: CGColor { CGColor(srgbRed: red, green: green, blue: blue, alpha: alpha) }
    var nsColor: NSColor { NSColor(calibratedRed: red, green: green, blue: blue, alpha: alpha) }

    var hexString: String {
        String(format: "#%02X%02X%02X",
               Int(round(red * 255)), Int(round(green * 255)), Int(round(blue * 255)))
    }

    // 截图工具条与编辑窗口**共用**的调色板（顺序 = 用户色卡顺序）。
    // 以前编辑窗口另写一份 [.red,.blue,.yellow,.green,.white,.black]，
    // 两处各自漂移：工具条刚统一完色卡，编辑器还是老六色 —— 2026-11-02
    // 用户口径「编辑功能…跟截图的工具条颜色对应」。以后加色只改这一处。
    //
    // 2026-11-04 用户口径「颜色增加一个色：黑色」→ 六色后面补黑。
    // 黑色放在**最后**：前面六个是他最早给的色卡顺序，插在中间等于把
    // 他已经形成的肌肉记忆打乱；补在末尾只是多一颗。
    static let palette: [RGBColor] = [.yellow, .green, .blue, .red, .orange, .purple, .black]
}

// ── 截图美化（Xnapper 式：背景 + 圆角 + 阴影 + padding） ──────

/// 挂在 EditorDocument 上的美化参数。nil = 关闭。
/// 底图不动：美化是**渲染时**往底图外面套壳（导出 / 预览同一套几何），
/// 不烧进图像，参数随时改随时还原。
struct BeautifyOptions: Equatable {
    var background: Background = .color(RGBColor.srgb(245, 245, 247))
    /// 底图四周留白（图像像素）
    var padding: CGFloat = 48
    /// 底图圆角
    var cornerRadius: CGFloat = 16
    var shadow: Bool = true

    /// 阴影参数固定不做 UI（参数越多越不会用）：blur 24 / 下移 8
    static let shadowBlur: CGFloat = 24
    static let shadowOffsetY: CGFloat = 8

    enum Background: Equatable {
        case color(RGBColor)
        case gradient(RGBColor, RGBColor)
    }

    /// 纯色预设：色卡 + 白 + 黑 + 苹果灰（跟调色板同一套色值来源）
    ///
    /// 黑色 2026-11-04 进了调色板，而这里本来就有一个黑 —— 直接相加会让
    /// 美化背景的预设里出现两个一模一样的黑块。所以白/黑/灰这组先滤掉调色板里
    /// 已有的，保证"每个预设看上去都不一样"。
    static let solidPresets: [RGBColor] = RGBColor.palette
        + [RGBColor.white, RGBColor.black, RGBColor.srgb(245, 245, 247)]
            .filter { !RGBColor.palette.contains($0) }

    /// 渐变预设：蓝紫 / 橙黄 / 白灰（对角线）
    static let gradientPresets: [(RGBColor, RGBColor)] = [
        (RGBColor.blue, RGBColor.purple),
        (RGBColor.yellow, RGBColor.orange),
        (RGBColor.white, RGBColor.srgb(229, 231, 235)),
    ]
}

// ── 效果图缓存 ───────────────────────────────────────────────

final class EffectImages {

    /// 一块裁剪过的效果图。`rect` 是它在**底图像素坐标（左上原点）**里的位置 ——
    /// 画的时候必须知道它从哪儿来，否则整块会贴到左上角。
    struct Cropped {
        let image: CGImage
        let rect: CGRect
    }

    let base: CGImage
    private var pixelatedCache: (rect: CGRect, image: CGImage)?
    private var blurredCache: (rect: CGRect, image: CGImage)?

    /// 全应用共用一个。以前每次出效果图都 `CIContext(options:)` 新建一个 ——
    /// 创建是几十毫秒级 + 分配一整套 GPU 资源，第一次上马赛克/模糊
    /// 能感觉到卡一下。OCR 那边早就是 static，这里跟上。
    private static let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    init(base: CGImage) {
        self.base = base
    }

    private var fullRect: CGRect {
        CGRect(x: 0, y: 0, width: base.width, height: base.height)
    }

    /// 马赛克：CIPixellate，块大小随**整幅**尺寸走。
    ///
    /// 🔴 按 `rect`（所有马赛克标注的并集外接矩形）只铺设这一块。
    /// 以前不管用户涂多小一块，都生成一张整幅效果图 —— 整屏截图 2880×1864
    /// 就是 20.5MB，马赛克 + 模糊两张 41MB，还一直挂到编辑器关闭。
    /// 现在滤镜仍在整幅 CIImage 上算（块大小的基准不能变），但只把这块
    /// 光栅化出来，像素上与原做法完全一致。
    func pixelated(covering rect: CGRect? = nil) -> Cropped? {
        let region = clamped(rect)
        if let hit = pixelatedCache, hit.rect == region {
            return Cropped(image: hit.image, rect: region)
        }
        let extent = fullRect
        guard let filter = CIFilter(name: "CIPixellate") else { return nil }
        filter.setValue(CIImage(cgImage: base), forKey: kCIInputImageKey)
        filter.setValue(max(10, Int(min(extent.width, extent.height) / 60)), forKey: "inputScale")
        guard let output = filter.outputImage?.cropped(to: extent),
              let image = Self.ciContext.createCGImage(output, from: Self.ciRect(region, in: base)) else {
            return nil
        }
        pixelatedCache = (region, image)
        return Cropped(image: image, rect: region)
    }

    /// 模糊：CIGaussianBlur + 裁回原边界（模糊会把边缘糊出去）
    func blurred(covering rect: CGRect? = nil) -> Cropped? {
        let region = clamped(rect)
        if let hit = blurredCache, hit.rect == region {
            return Cropped(image: hit.image, rect: region)
        }
        let extent = fullRect
        guard let filter = CIFilter(name: "CIGaussianBlur") else { return nil }
        filter.setValue(CIImage(cgImage: base), forKey: kCIInputImageKey)
        filter.setValue(10.0, forKey: kCIInputRadiusKey)
        guard let output = filter.outputImage?.cropped(to: extent),
              let image = Self.ciContext.createCGImage(output, from: Self.ciRect(region, in: base)) else {
            return nil
        }
        blurredCache = (region, image)
        return Cropped(image: image, rect: region)
    }

    /// 标注坐标是"左上原点"，CI 的 extent 是"左下原点" —— 取子区域时必须翻一次 y，
    /// 少翻就是"位置对、内容是另一块"（本项目的老坑，见 CGImage.cropping）。
    private static func ciRect(_ topLeft: CGRect, in base: CGImage) -> CGRect {
        CGRect(x: topLeft.minX, y: CGFloat(base.height) - topLeft.maxY,
               width: topLeft.width, height: topLeft.height)
    }

    /// 夹进底图范围内，并且取整（子像素区域会让 CGImage 尺寸对不上）
    private func clamped(_ rect: CGRect?) -> CGRect {
        guard let rect, !rect.isNull, rect.width > 0, rect.height > 0 else { return fullRect }
        let inside = rect.integral.intersection(fullRect)
        guard !inside.isNull, inside.width >= 1, inside.height >= 1 else { return fullRect }
        return inside
    }
}

// ── 合成渲染 ─────────────────────────────────────────────────

enum EditorRenderer {

    /// 高亮（聚光点亮）压暗的强度：0.6 黑 → 白底变 102 灰。
    /// 这个数是从用户给的样张里量出来的（框外 (102,102,102) / 框内纯白），
    /// 不是随手定的；改大改小都会跟他的预期不一样。
    static let highlightDimAlpha: CGFloat = 0.6

    /// 把底图 + 全部标注压成一张成品图（保存 / 复制 / 贴图都用它）。
    /// `beautify` 非 nil 时先套美化壳（背景 + 圆角底图 + 阴影 + padding），
    /// 标注坐标仍是**底图像素坐标**，渲染时整体平移 padding。
    static func render(base: CGImage, shapes: [AnnotationShape], effects: EffectImages,
                       beautify: BeautifyOptions? = nil) -> CGImage? {
        let pad = beautify?.padding ?? 0
        let width = base.width + Int(pad) * 2
        let height = base.height + Int(pad) * 2
        guard let ctx = CGContext(data: nil,
                                  width: width, height: height,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }

        if let b = beautify {
            // 背景铺满整张画布（标准空间直接画）
            let canvas = CGRect(x: 0, y: 0, width: width, height: height)
            switch b.background {
            case .color(let c):
                ctx.setFillColor(c.cgColor)
                ctx.fill(canvas)
            case .gradient(let from, let to):
                let space = CGColorSpaceCreateDeviceRGB()
                if let gradient = CGGradient(colorsSpace: space,
                                             colors: [from.cgColor, to.cgColor] as CFArray,
                                             locations: [0, 1]) {
                    // 对角线（左上 → 右下）：标准空间 y 向上，起点给左下角
                    ctx.drawLinearGradient(gradient,
                                           start: CGPoint(x: 0, y: CGFloat(height)),
                                           end: CGPoint(x: CGFloat(width), y: 0),
                                           options: [])
                }
            }
            // 圆角底图 + 投影。先填一个不透明圆角矩形（阴影由它的形状投出），
            // 关掉阴影后再把底图裁进同一个圆角矩形 —— 底图自身带透明区时
            // 透出来的是白色，跟编辑器里棋盘底的观感一致。
            let imgRect = CGRect(x: pad, y: pad,
                                 width: CGFloat(base.width), height: CGFloat(base.height))
            let rounded = CGPath(roundedRect: imgRect,
                                 cornerWidth: b.cornerRadius, cornerHeight: b.cornerRadius,
                                 transform: nil)
            ctx.saveGState()
            if b.shadow {
                ctx.setShadow(offset: CGSize(width: 0, height: -BeautifyOptions.shadowOffsetY),
                              blur: BeautifyOptions.shadowBlur)
            }
            ctx.addPath(rounded)
            ctx.setFillColor(RGBColor.white.cgColor)
            ctx.fillPath()
            ctx.restoreGState()
            ctx.saveGState()
            ctx.addPath(rounded)
            ctx.clip()
            ctx.draw(base, in: imgRect)
            ctx.restoreGState()
        } else {
            ctx.draw(base, in: CGRect(x: 0, y: 0, width: width, height: height))
        }

        // 先在**未翻转**的标准空间画底图（此空间里 CGImage 方向才是正的），
        // 再翻成"左上原点向下"画标注——形状坐标按 y 向下存。
        // 顺序反了底图会整体上下颠倒（形状位置对、内容倒）。
        // 美化时标注坐标系的原点跟着挪到底图左上角（整体平移 padding）。
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: 1, y: -1)
        if beautify != nil { ctx.translateBy(x: pad, y: pad) }

        // 🔴 这里传的是**底图高度**不是画布高度：drawCoreText / 高亮的画布矩形
        // 都在"底图左上原点"的空间里工作（美化时原点已平移到 padding 处），
        // 传整张画布的高会把 CoreText 文字画飞。
        drawShapes(shapes, in: ctx, effects: effects, canvasHeight: CGFloat(base.height))
        return ctx.makeImage()
    }

    /// 供原位编辑浮层复用：在"左上原点"的翻转上下文里画一批标注。
    /// 步骤标注的序号在这里统一分配：按数组顺序数（渲染 = 预览 = 同一套），
    /// 删掉中间一步后剩下的自动重排，不需要"重置序号"按钮。
    static func drawShapes(_ shapes: [AnnotationShape], in ctx: CGContext,
                           effects: EffectImages, canvasHeight: CGFloat) {
        // 同类效果只生成一块：所有该效果标注的**并集外接矩形**。
        // 两处马赛克隔得远会多算中间那段空白，但比"每个标注各生成一份"省得多，
        // 也比"整幅生成"省 —— 用户通常只涂屏幕的一小块。
        let mosaicRect = unionRect(of: .mosaic, in: shapes)
        let blurRect = unionRect(of: .blur, in: shapes)
        for shape in shapes {
            let effectRect: CGRect?
            switch shape.tool {
            case .mosaic: effectRect = mosaicRect
            case .blur:   effectRect = blurRect
            default:      effectRect = nil
            }
            draw(shape: shape, in: ctx, effects: effects, canvasHeight: canvasHeight,
                 effectRect: effectRect,
                 stepNumber: shape.tool == .step ? stepNumber(of: shape, in: shapes) : 0)
        }
    }

    /// 马赛克 / 模糊的生效矩形：取拖拽的首尾两点围成的框（左上原点，图像像素）
    static func shapeRect(_ shape: AnnotationShape) -> CGRect? {
        guard shape.points.count >= 2,
              let a = shape.points.first, let b = shape.points.last else { return nil }
        return rect(from: a, to: b)
    }

    /// 某类标注的并集外接矩形（左上原点，图像像素）。渲染和 SwiftUI 预览共用，
    /// 两边算出来的区域必须是同一块，不然预览和存下来的图会不一样。
    static func unionRect(of tool: EditorTool, in shapes: [AnnotationShape]) -> CGRect? {
        var result: CGRect?
        for shape in shapes where shape.tool == tool {
            guard let box = shapeRect(shape) else { continue }
            result = result.map { $0.union(box) } ?? box
        }
        return result
    }

    // ── 步骤标注几何（渲染与自检共用） ──

    /// 圆底半径（图像像素）
    static let stepBubbleRadius: CGFloat = 26
    /// 数字字号
    static let stepFontSize: CGFloat = 28

    /// 某个步骤标注的序号：在 shapes 数组里排第几个 step（1 起）。
    /// 预览（SwiftUI）与导出（CG）必须共用这一份，不然屏幕上和存下来对不上号。
    static func stepNumber(of shape: AnnotationShape, in shapes: [AnnotationShape]) -> Int {
        var count = 0
        for item in shapes {
            if item.tool == .step { count += 1 }
            if item.id == shape.id { break }
        }
        return max(1, count)
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

    private static func draw(shape: AnnotationShape, in ctx: CGContext, effects: EffectImages,
                             canvasHeight: CGFloat, effectRect: CGRect? = nil, stepNumber: Int = 0) {
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

        case .highlight:
            // 1.0.10 用户口径（他附的 longshot…111915.jpg）：高亮 = **聚光点亮**。
            // 拖出来那块**一个像素都不动**（字还是纯黑、底色还是原样），
            // 把图里其余部分压暗 60% —— 视觉上"只把这块点亮"。
            //
            // 以前实现成"半透明染色（multiply 0.38）"，那是荧光笔，不是他要的：
            // 染色会把字冲淡，而他给的样张里被标记处的文字比周围更清楚。
            // 所以这里不用 shape.color（聚光没有"颜色"这个概念），
            // 恒定用黑色压暗；even-odd 两个矩形一次裁出"矩形外面"再填满整幅画布。
            guard let a = shape.points.first, let b = shape.points.last else { return }
            let canvas = CGRect(x: 0, y: 0,
                                width: CGFloat(effects.base.width),
                                height: canvasHeight)
            ctx.saveGState()
            ctx.addRect(canvas)
            ctx.addRect(rect(from: a, to: b))
            ctx.clip(using: .evenOdd)
            ctx.setFillColor(CGColor(gray: 0, alpha: Self.highlightDimAlpha))
            ctx.fill(canvas)
            ctx.restoreGState()

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
            // 🔴 箭杆**不能画到箭尖**：round cap 会在尖端留一个半径 width/2 的圆头，
            // 看上去就是"钝的"。箭杆只画到头部里侧，尖端交给下面那个三角形。
            let stem = arrowStemEnd(from: a, to: b, width: width)
            ctx.move(to: a); ctx.addLine(to: stem); ctx.strokePath()
            drawArrowHead(from: a, to: b, width: width, in: ctx)

        case .step:
            // 圆底 + 白色数字。序号由 drawShapes 统一分配（数组顺序），
            // 删除中间步骤自动重排；颜色跟当前画笔色。
            guard let p = shape.points.first, stepNumber > 0 else { return }
            let r = stepBubbleRadius
            ctx.setFillColor(color.cgColor)
            ctx.fillEllipse(in: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2))
            let font = NSFont.systemFont(ofSize: stepFontSize, weight: .bold)
            let line = NSAttributedString(string: "\(stepNumber)", attributes: [
                .font: font, .foregroundColor: NSColor.white,
            ])
            let lineSize = line.size()
            let box = CGRect(x: p.x - ceil(lineSize.width) / 2 - 2,
                             y: p.y - ceil(lineSize.height) / 2 - 2,
                             width: ceil(lineSize.width) + 4, height: ceil(lineSize.height) + 4)
            drawCoreText(line, in: box, canvasHeight: canvasHeight, ctx: ctx)

        case .text:
            drawText(shape.text, at: shape.points.first ?? .zero,
                     color: color, fontSize: shape.fontSize > 0 ? shape.fontSize : 30,
                     canvasHeight: canvasHeight, in: ctx)

        case .mosaic, .blur:
            guard let shapeRect = Self.shapeRect(shape),
                  let effect = (shape.tool == .mosaic ? effects.pixelated(covering: effectRect)
                                                      : effects.blurred(covering: effectRect)) else { return }
            ctx.saveGState()
            // 两点语义 = 拖拽起止点围成的矩形区域。
            // 🔴 不能用直线路径 clip：直线是零面积的，裁剪后什么都画不出来
            //（1.0.1"画了马赛克但看不见"的根因）。
            ctx.addPath(CGPath(rect: shapeRect, transform: nil))
            ctx.clip()
            // 效果图与底图同理：翻转空间里直接 draw 会上下颠倒，
            // 临时还原标准空间再画（clip 已记录在设备空间，不受影响）。
            // 标准空间是左下原点，所以裁剪块的位置要再翻一次 y。
            ctx.translateBy(x: 0, y: canvasHeight)
            ctx.scaleBy(x: 1, y: -1)
            ctx.draw(effect.image, in: CGRect(x: effect.rect.minX,
                                              y: canvasHeight - effect.rect.maxY,
                                              width: effect.rect.width,
                                              height: effect.rect.height))
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

    // ── 箭头几何（渲染与自检共用） ──

    /// 箭头头部的长度：跟着线宽长，但有下限（细线也得看得出来）。
    /// 1.0.12 由 `width * 3.5` 加到 `width * 5.2` —— 头越长、同宽下尖角越锐。
    static func arrowHeadLength(width: CGFloat) -> CGFloat {
        max(16, width * 5.2)
    }

    /// 头部两根斜边相对轴线的张角。0.42 → 0.30 弧度（24° → 17°），
    /// 顶点总张角从 48° 收到 34°，看上去才是"尖的"。
    static let arrowHeadSpread: CGFloat = 0.30

    /// 箭杆终点：收到头部里侧，避免圆线帽顶出一个钝头
    static func arrowStemEnd(from a: CGPoint, to b: CGPoint, width: CGFloat) -> CGPoint {
        let angle = atan2(b.y - a.y, b.x - a.x)
        let back = arrowHeadLength(width: width) * 0.55
        return CGPoint(x: b.x - back * cos(angle), y: b.y - back * sin(angle))
    }

    /// 头部四点多边形：[尖, 左翼, 底边内凹点, 右翼]。
    /// CG 渲染和 SwiftUI 预览**必须共用一个** —— 以前两处各写一遍，
    /// 改了形状其中一处没跟上，屏幕上和存下来的就不是一支箭头了。
    static func arrowHeadPoints(from a: CGPoint, to b: CGPoint, width: CGFloat) -> [CGPoint] {
        let angle = atan2(b.y - a.y, b.x - a.x)
        let headLen = arrowHeadLength(width: width)
        let spread = arrowHeadSpread
        let p1 = CGPoint(x: b.x - headLen * cos(angle - spread), y: b.y - headLen * sin(angle - spread))
        let p2 = CGPoint(x: b.x - headLen * cos(angle + spread), y: b.y - headLen * sin(angle + spread))
        // 底边中点向尖端收进去一点 → 两翼往后掠，视觉上更尖（▷ 而不是 ▲）
        let notch = CGPoint(x: b.x - headLen * 0.78 * cos(angle),
                            y: b.y - headLen * 0.78 * sin(angle))
        return [b, p1, notch, p2]
    }

    private static func drawArrowHead(from a: CGPoint, to b: CGPoint, width: CGFloat, in ctx: CGContext) {
        let pts = arrowHeadPoints(from: a, to: b, width: width)
        ctx.move(to: pts[0])
        for p in pts.dropFirst() { ctx.addLine(to: p) }
        ctx.closePath()
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

    /// 🔴 不走 `NSBitmapImageRep`。
    ///
    /// `NSBitmapImageRep(cgImage:)` 会先把整幅图**拷一份**进自己的位图缓冲
    /// （整屏 2880×1864 就是 20.5MB），编码完才释放。`CGImageDestination` 直接把
    /// CGImage 交给 ImageIO 编码，中间不再多一份全图 —— 保存大图时的峰值几乎减半。
    ///
    /// 用 "public.png" / "public.jpeg" 这两个 UTI 字符串，省得为一个常量引入
    /// UniformTypeIdentifiers；两者都是稳定的系统 UTI。
    static func data(_ image: CGImage, format: ShotFormat, jpgQuality: Double) -> Data? {
        let uti = (format == .png) ? "public.png" : "public.jpeg"
        let buffer = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            buffer as CFMutableData, uti as CFString, 1, nil) else { return nil }
        var properties: [CFString: Any] = [:]
        if format == .jpg {
            properties[kCGImageDestinationLossyCompressionQuality] = max(0.1, min(1, jpgQuality))
        }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return buffer as Data
    }
}
