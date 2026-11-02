import AppKit
import CoreGraphics
import Foundation

// ============================================================
// 选区放大镜（取色镜）
//
// 参考用户给的样张：光标旁一块方块，里面是**像素化的画面**（一格 = 一个源像素），
// 中间一个十字 + 实心中心格，下面一小条白底信息：
//     坐标: (719,565)
//     区域: [318,340]
//     色值: ■ #64 9E 60
// 按 C 复制色值。
//
// 设计取舍：
//   · 几何、文本全部做成**纯函数**，`--selftest` 能直接喂数字验 ——
//     这种"贴边翻转 / 原点口径"的几何，只靠肉眼截图很难发现算错了哪一边。
//   · 画面用"裁一小块 + 最近邻放大"实现（`interpolationQuality = .none`），
//     不是一个格子一个格子地 draw —— 后者每帧要几百次 drawImage，鼠标一动就卡。
//   · 放大镜画在遮罩视图里（同一块屏幕的同一个视图），不另开窗口：
//     少一个窗口就少一类"非 key 窗口收不到事件 / 层级压不住"的问题。
// ============================================================

enum Loupe {

    /// 一次选区会话里用到的放大镜设置（从 Preferences 拍一份快照，
    /// 会话中途改设置不该影响已经打开的那次截图）
    struct Config {
        var enabled: Bool
        var lineColor: RGBColor
        var origin: LoupeOrigin
        var format: ColorTextFormat
        var hashPrefix: Bool

        init(enabled: Bool, lineColor: RGBColor, origin: LoupeOrigin,
             format: ColorTextFormat, hashPrefix: Bool) {
            self.enabled = enabled
            self.lineColor = lineColor
            self.origin = origin
            self.format = format
            self.hashPrefix = hashPrefix
        }

        init(_ prefs: Preferences) {
            self.init(enabled: prefs.magnifierEnabled,
                      lineColor: Loupe.color(fromHex: prefs.magnifierLineColor),
                      origin: prefs.magnifierOrigin,
                      format: prefs.magnifierColorFormat,
                      hashPrefix: prefs.magnifierHashPrefix)
        }
    }

    /// 一个源像素放大成多少点
    static let cell: CGFloat = 10
    /// 网格是 cells × cells 个像素
    static let cells = 15
    /// 正方形网格的边长
    static var gridSide: CGFloat { cell * CGFloat(cells) }
    /// 下面信息条的高度（三行 12pt 文本 + 内边距）
    static let infoHeight: CGFloat = 74
    static var size: CGSize { CGSize(width: gridSide, height: gridSide + infoHeight) }
    /// 与光标、与屏幕边的间距
    static let gap: CGFloat = 16

    // ── 落位 ────────────────────────────────────────────────

    /// 放大镜左上角（视图坐标，y 向下）。
    /// 默认在光标右下方；右边放不下翻到左边，下边放不下翻到上边，
    /// 最后再整体夹进屏幕 —— 夹的顺序不能反：先翻再夹，否则贴边时镜会盖住光标。
    static func origin(cursor: CGPoint, size: CGSize, bounds: CGRect) -> CGPoint {
        var x = cursor.x + gap
        if x + size.width > bounds.maxX - 4 {
            x = cursor.x - gap - size.width
        }
        var y = cursor.y + gap
        if y + size.height > bounds.maxY - 4 {
            y = cursor.y - gap - size.height
        }
        x = min(max(bounds.minX + 4, x), max(bounds.minX + 4, bounds.maxX - size.width - 4))
        y = min(max(bounds.minY + 4, y), max(bounds.minY + 4, bounds.maxY - size.height - 4))
        return CGPoint(x: x, y: y)
    }

    // ── 坐标口径 ────────────────────────────────────────────

    /// 把"显示局部坐标（左上原点，点）"换算成用户选的那个原点口径。
    /// 例如选左下角：y 要翻成 displaySize.height - y。
    static func displayCoordinate(point: CGPoint, origin: LoupeOrigin,
                                  displaySize: CGSize) -> CGPoint {
        let x: CGFloat
        let y: CGFloat
        switch origin {
        case .topLeft:
            x = point.x
            y = point.y
        case .topRight:
            x = displaySize.width - point.x
            y = point.y
        case .bottomLeft:
            x = point.x
            y = displaySize.height - point.y
        case .bottomRight:
            x = displaySize.width - point.x
            y = displaySize.height - point.y
        }
        return CGPoint(x: x.rounded(), y: y.rounded())
    }

    /// 放大镜裁的是"以光标像素为中心"的 cells×cells 方块，返回它在**源图像素**里的左上角。
    /// 钳在图像内，贴边时窗口跟着内移（否则裁出来会越界、边缘出现空白格）。
    static func cropOrigin(cursorPixel: CGPoint, cellCount: Int, imageSize: CGSize) -> CGPoint {
        let half = CGFloat(cellCount) / 2
        var x = cursorPixel.x - half
        var y = cursorPixel.y - half
        x = min(max(0, x), max(0, imageSize.width - CGFloat(cellCount)))
        y = min(max(0, y), max(0, imageSize.height - CGFloat(cellCount)))
        return CGPoint(x: x, y: y)
    }

    // ── 色值文本 ────────────────────────────────────────────

    /// 六个十六进制位，不带 #
    static func hexPairs(_ color: RGBColor) -> String {
        String(format: "%02X%02X%02X",
               Int(round(color.red * 255)),
               Int(round(color.green * 255)),
               Int(round(color.blue * 255)))
    }

    /// 界面上显示的色值（样张里是 `#64 9E 60`，两位一组、空格分开）
    static func display(_ color: RGBColor, format: ColorTextFormat, hashPrefix: Bool) -> String {
        switch format {
        case .hex:
            let pairs = stride(from: 0, to: 6, by: 2).map { offset -> String in
                let start = hexPairs(color).index(hexPairs(color).startIndex, offsetBy: offset)
                let end = hexPairs(color).index(start, offsetBy: 2)
                return String(hexPairs(color)[start..<end])
            }
            return (hashPrefix ? "#" : "") + pairs.joined(separator: " ")
        case .rgb:
            return "RGB(\(Int(round(color.red * 255))), \(Int(round(color.green * 255))), \(Int(round(color.blue * 255))))"
        case .hsl:
            let hsl = hslComponents(color)
            return "HSL(\(Int(round(hsl.h))), \(Int(round(hsl.s * 100)))%, \(Int(round(hsl.l * 100)))%)"
        }
    }

    /// 按 C 复制出去的文本：**紧凑、不带空格**，方便直接贴进代码 / 设计工具。
    /// 显示用中带空格的写法，复制用紧凑写法 —— 两个场景要的东西不一样。
    static func copyable(_ color: RGBColor, format: ColorTextFormat, hashPrefix: Bool) -> String {
        switch format {
        case .hex:
            return (hashPrefix ? "#" : "") + hexPairs(color)
        case .rgb:
            return "rgb(\(Int(round(color.red * 255))), \(Int(round(color.green * 255))), \(Int(round(color.blue * 255))))"
        case .hsl:
            let hsl = hslComponents(color)
            return "hsl(\(Int(round(hsl.h))), \(Int(round(hsl.s * 100)))%, \(Int(round(hsl.l * 100)))%)"
        }
    }

    /// 设置页那一行「示例: #D18C72」用的示例色
    static let sampleColor = RGBColor.srgb(0xD1, 0x8C, 0x72)

    static func hslComponents(_ color: RGBColor) -> (h: Double, s: Double, l: Double) {
        let r = color.red, g = color.green, b = color.blue
        let maxV = max(r, g, b), minV = min(r, g, b)
        let l = (maxV + minV) / 2
        guard maxV != minV else { return (0, 0, l) }
        let d = maxV - minV
        let s = l > 0.5 ? d / (2 - maxV - minV) : d / (maxV + minV)
        var h: Double
        switch maxV {
        case r: h = (g - b) / d + (g < b ? 6 : 0)
        case g: h = (b - r) / d + 2
        default: h = (r - g) / d + 4
        }
        h *= 60
        return (h < 0 ? h + 360 : h, s, l)
    }

    /// 十六进制串 ⇄ RGBColor（设置页的 ColorPicker 用它，颜色跟着设置一起落盘）
    static func color(fromHex hex: String) -> RGBColor {
        var text = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("#") { text.removeFirst() }
        guard text.count == 6, let value = UInt32(text, radix: 16) else {
            return RGBColor.srgb(0x3B, 0x82, 0xF6)
        }
        return RGBColor.srgb(Int((value >> 16) & 0xFF), Int((value >> 8) & 0xFF), Int(value & 0xFF))
    }

    // ── 绘制 ────────────────────────────────────────────────

    /// 画放大镜。`source` 是整屏截图，`cursor` 是视图坐标（左上原点，点）。
    /// 调用方负责把它放在最上层（同一视图里最后画）。
    static func draw(in ctx: CGContext,
                     source: CGImage,
                     cursor: CGPoint,
                     bounds: CGRect,
                     displaySize: CGSize,
                     pixelScale: CGFloat,
                     lineColor: RGBColor,
                     origin: LoupeOrigin,
                     format: ColorTextFormat,
                     hashPrefix: Bool) {

        let loupeSize = size
        let topLeft = Loupe.origin(cursor: cursor, size: loupeSize, bounds: bounds)
        let frame = CGRect(origin: topLeft, size: loupeSize)
        let grid = CGRect(x: frame.minX, y: frame.minY, width: gridSide, height: gridSide)
        let info = CGRect(x: frame.minX, y: frame.maxY - infoHeight,
                          width: gridSide, height: infoHeight)

        // 光标所在的源像素 + 裁哪一块
        let cursorPixel = CGPoint(x: (cursor.x * pixelScale).rounded(.down),
                                  y: (cursor.y * pixelScale).rounded(.down))
        let crop = cropOrigin(cursorPixel: cursorPixel,
                              cellCount: cells,
                              imageSize: CGSize(width: source.width, height: source.height))
        let cropRect = CGRect(x: crop.x, y: crop.y,
                              width: CGFloat(cells), height: CGFloat(cells))

        ctx.saveGState()
        // 底部信息条（白底，跟样张一致：镜身深色、信息条白底黑字）
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fill(info)

        // 像素块：裁一小块 + 最近邻放大，一格 = 一个源像素
        if let sub = source.cropping(to: cropRect) {
            ctx.saveGState()
            ctx.interpolationQuality = .none
            // 🔴 本视图 isFlipped（y 向下），在这个坐标系里直接 draw(cgImage) 会上下颠倒，
            // 和截图浮层 / 贴图一样要走标准配方翻回 y 向上的空间再画。
            ctx.translateBy(x: grid.minX, y: grid.maxY)
            ctx.scaleBy(x: 1, y: -1)
            ctx.draw(sub, in: CGRect(x: 0, y: 0, width: grid.width, height: grid.height))
            ctx.restoreGState()
        }

        // 网格线：细，用线色压到 18% 不抢眼
        ctx.setStrokeColor(lineColor.cgColor.copy(alpha: 0.18) ?? lineColor.cgColor)
        ctx.setLineWidth(0.5)
        for i in 0...cells {
            let offset = CGFloat(i) * cell
            ctx.move(to: CGPoint(x: grid.minX + offset, y: grid.minY))
            ctx.addLine(to: CGPoint(x: grid.minX + offset, y: grid.maxY))
            ctx.move(to: CGPoint(x: grid.minX, y: grid.minY + offset))
            ctx.addLine(to: CGPoint(x: grid.maxX, y: grid.minY + offset))
        }
        ctx.strokePath()

        // 十字 + 中心格（样张里的粗十字）
        let centerX = grid.minX + grid.width / 2
        let centerY = grid.minY + grid.height / 2
        ctx.setFillColor(lineColor.cgColor)
        ctx.fill(CGRect(x: grid.minX, y: centerY - 3, width: grid.width, height: 6))
        ctx.fill(CGRect(x: centerX - 3, y: grid.minY, width: 6, height: grid.height))
        // 中心那一格实心：光标就在这一像素上
        ctx.fill(CGRect(x: centerX - cell / 2, y: centerY - cell / 2, width: cell, height: cell))

        // 镜身描边
        ctx.setStrokeColor(lineColor.cgColor.copy(alpha: 0.9) ?? lineColor.cgColor)
        ctx.setLineWidth(1.5)
        ctx.stroke(CGRect(x: frame.minX + 0.75, y: frame.minY + 0.75,
                          width: frame.width - 1.5, height: frame.height - 1.5))

        // 三行信息
        let sampled = sampleColor(in: source, pixel: CGPoint(x: cursorPixel.x, y: cursorPixel.y))
        let coordinate = displayCoordinate(point: cursor, origin: origin, displaySize: displaySize)
        let regionPoint = displayCoordinate(
            point: CGPoint(x: crop.x / max(pixelScale, 0.01), y: crop.y / max(pixelScale, 0.01)),
            origin: origin, displaySize: displaySize)

        let valueText = display(sampled, format: format, hashPrefix: hashPrefix)
        let rows: [(String, String)] = [
            ("坐标:", "(\(Int(coordinate.x)),\(Int(coordinate.y)))"),
            ("区域:", "[\(Int(regionPoint.x)),\(Int(regionPoint.y))]"),
            ("色值:", valueText),
        ]
        let labelAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .regular),
            .foregroundColor: NSColor.black,
        ]
        let valueAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.black,
        ]
        var textY = info.minY + 10
        for (index, row) in rows.enumerated() {
            (row.0 as NSString).draw(at: CGPoint(x: info.minX + 10, y: textY), withAttributes: labelAttrs)
            var valueX = info.minX + 44
            // 色值那行先画一个小色块
            if index == 2 {
                let swatch = CGRect(x: valueX, y: textY + 1, width: 14, height: 13)
                ctx.setFillColor(sampled.cgColor)
                ctx.fill(swatch)
                ctx.setStrokeColor(NSColor.black.withAlphaComponent(0.25).cgColor)
                ctx.setLineWidth(0.5)
                ctx.stroke(swatch)
                valueX += 20
            }
            (row.1 as NSString).draw(at: CGPoint(x: valueX, y: textY), withAttributes: valueAttrs)
            textY += 21
        }
        ctx.restoreGState()
    }

    /// 读源图某个像素的颜色（BGRA 小端，和 `EditorDocument.pixelColor` 同一套解法）
    static func sampleColor(in image: CGImage, pixel: CGPoint) -> RGBColor {
        let x = Int(pixel.x), y = Int(pixel.y)
        guard x >= 0, y >= 0, x < image.width, y < image.height,
              let data = image.dataProvider?.data,
              let ptr = CFDataGetBytePtr(data) else { return .black }
        let offset = y * image.bytesPerRow + x * (image.bitsPerPixel / 8)
        guard offset + 3 < CFDataGetLength(data) else { return .black }
        return RGBColor(red: Double(ptr[offset + 2]) / 255,
                        green: Double(ptr[offset + 1]) / 255,
                        blue: Double(ptr[offset]) / 255)
    }
}
