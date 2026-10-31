import CoreGraphics
import Foundation

// ============================================================
// 滚动截图拼接算法（纯函数，--selftest 可测）
//
// 思路：把两张图降采样成灰度行序列，穷举纵向偏移 d，找"上方图从第 d 行
// 开始的内容"与"下方图从第 0 行开始的内容"均方差最小的对齐位置。
// 对齐质量太差（方差高于阈值）判定为"页面没滚动"，本帧跳过。
//
// 为什么不用特征匹配：滚动截图的对齐只在一维（纵向）上，暴力搜索
// 240 宽 × 几百行候选偏移在毫秒级就能完成，鲁棒性反而更好。
// ============================================================

enum ImageStitch {

    struct GrayImage {
        var width: Int
        var height: Int
        var rows: [[UInt8]]   // 每行 width 个灰度值

        init(image: CGImage, sampleWidth: Int = 240) {
            let scale = CGFloat(sampleWidth) / CGFloat(image.width)
            let height = max(1, Int(CGFloat(image.height) * scale))
            let ctx = CGContext(data: nil, width: sampleWidth, height: height,
                                bitsPerComponent: 8, bytesPerRow: sampleWidth,
                                space: CGColorSpaceCreateDeviceGray(),
                                bitmapInfo: CGImageAlphaInfo.none.rawValue)!
            ctx.interpolationQuality = .medium
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: sampleWidth, height: height))
            let data = ctx.data!.bindMemory(to: UInt8.self, capacity: sampleWidth * height)
            rows = (0..<height).map { row in
                Array(UnsafeBufferPointer(start: data + row * sampleWidth, count: sampleWidth))
            }
            width = sampleWidth
            self.height = height
        }

        init(width: Int, height: Int, rows: [[UInt8]]) {
            self.width = width
            self.height = height
            self.rows = rows
        }
    }

    /// 在 bottom 里找 top 的内容延续位置。返回值 d 表示：top 的第 d 行
    /// 对应 bottom 的第 0 行（即页面滚动了 d 像素、bottom 能续上 top）。
    /// 找不到可靠对齐时返回 nil（页面没滚 / 内容跳变）。
    static func findScrollOffset(top: GrayImage, bottom: GrayImage,
                                 minOverlap: Int = 24,
                                 maxSearchRatio: Double = 0.9,
                                 qualityThreshold: Double = 26) -> Int? {
        let searchHeight = Int(Double(min(top.height, bottom.height)) * maxSearchRatio)
        var bestOffset: Int?
        var bestScore = Double.greatestFiniteMagnitude

        // d = top 里已经"滚出取景框"的行数，范围 [minOverlap, searchHeight)
        var d = minOverlap
        while d < searchHeight {
            let overlap = min(top.height - d, bottom.height)
            guard overlap >= minOverlap else { break }
            var totalDiff = 0
            var samples = 0
            for y in stride(from: 0, to: overlap, by: 2) {
                let rowTop = top.rows[y + d]
                let rowBottom = bottom.rows[y]
                for x in stride(from: 0, to: top.width, by: 2) {
                    totalDiff += abs(Int(rowTop[x]) - Int(rowBottom[x]))
                    samples += 1
                }
            }
            guard samples > 0 else { d += 2; continue }
            let score = Double(totalDiff) / Double(samples)
            if score < bestScore {
                bestScore = score
                bestOffset = d
            }
            d += 2
        }

        guard let offset = bestOffset, bestScore <= qualityThreshold else { return nil }
        return offset
    }

    /// 把 bottom 续到 top 下面。失败（没滚）返回 nil。
    static func stitchVertical(top: CGImage, bottom: CGImage,
                               scaleMismatchTolerance: Double = 0.02) -> CGImage? {
        guard abs(Double(top.width - bottom.width)) <= Double(top.width) * scaleMismatchTolerance else {
            return nil
        }
        // 取较小宽度统一缩放，避免两帧宽度差 1px 造成的累积错位
        let targetW = min(top.width, bottom.width)
        let topNorm = normalizeWidth(top, to: targetW)
        let bottomNorm = normalizeWidth(bottom, to: targetW)
        guard let topNorm, let bottomNorm else { return nil }

        let grayTop = GrayImage(image: topNorm)
        let grayBottom = GrayImage(image: bottomNorm)
        // 灰度图是降采样的：把偏移映射回原图像素
        let ratio = Double(topNorm.height) / Double(grayTop.height)
        guard let grayOffset = findScrollOffset(top: grayTop, bottom: grayBottom) else { return nil }
        let offset = max(1, Int(Double(grayOffset) * ratio))

        // 重叠区域取 top 的内容（下方帧可能带输入法/滚动条闪烁）
        let newHeight = topNorm.height + bottomNorm.height - offset
        let ctx = CGContext(data: nil, width: targetW, height: newHeight,
                            bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
        ctx.interpolationQuality = .medium
        // CG 坐标系左下原点：top 画在上部（y = newHeight - topH），bottom 画在下部
        ctx.draw(topNorm, in: CGRect(x: 0, y: CGFloat(newHeight - topNorm.height),
                                     width: CGFloat(targetW), height: CGFloat(topNorm.height)))
        ctx.draw(bottomNorm, in: CGRect(x: 0, y: 0,
                                        width: CGFloat(targetW), height: CGFloat(bottomNorm.height)))
        return ctx.makeImage()
    }

    private static func normalizeWidth(_ image: CGImage, to width: Int) -> CGImage? {
        guard image.width != width else { return image }
        let height = Int(CGFloat(image.height) * CGFloat(width) / CGFloat(image.width))
        let ctx = CGContext(data: nil, width: width, height: height,
                            bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
        ctx.interpolationQuality = .medium
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
        return ctx.makeImage()
    }

    /// 旋转 90°（横向滚动截图复用竖向算法）
    static func rotate90(_ image: CGImage) -> CGImage? {
        let w = image.width, h = image.height
        let ctx = CGContext(data: nil, width: h, height: w,
                            bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
        // 顺时针 90°：内容左边缘 → 新图上边缘
        ctx.translateBy(x: CGFloat(h), y: 0)
        ctx.rotate(by: .pi / 2)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }
}
