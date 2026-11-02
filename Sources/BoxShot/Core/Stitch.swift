import CoreGraphics
import Foundation

// ============================================================
// 滚动截图拼接（纯函数，--selftest 可测）
//
// 一维对齐：把两帧降采样成灰度行序列，穷举纵向偏移 d，找
// 「top 的第 d 行 = bottom 的第 0 行」那个位置。
//
// 为什么不用特征匹配：滚动对齐只在一维上，暴力搜几百个候选偏移就是毫秒级，
// 鲁棒性反而比特征点稳（网页上重复的图标/文字会让特征匹配乱跳）。
//
// 1.0.5 重写的原因（1.0.4 拼出来"不连续、全错"）：
//   ① 抓帧没排除自己的取景框 → 每帧拍到的是上一帧的预览（真正的根因在
//      ScreenCapture.captureRegion，这里只负责对齐得准）；
//   ② 偏移精度只有"2 个灰度行"，换算回原图是 8~16 像素 → 每拼一段就重影；
//   ③ 没有纹理校验，纯色区里任何偏移得分都低，会挑一个完全错误的 d；
//   ④ 固定头部（sticky header）在两帧里位置不变，会把 d 往 0 拖。
//
// 现在分三段：240 宽粗搜 → 480 宽细搜 → 原分辨率逐像素精修，
// 最后落到 1 像素精度；比较时跳过底部 10%（剔除固定头和底栏）。
// ============================================================

enum ImageStitch {

    /// 对齐结果
    struct Alignment {
        /// 原图像素：top 的第 offset 行 == bottom 的第 0 行（也就是页面滚了多少像素）
        let offset: Int
        /// 原分辨率下重叠区的平均绝对差（0…255，越小越像）
        let score: Double
        /// 重叠区的纹理强度（相邻像素平均差），用来判"是不是空白页"
        let texture: Double
    }

    /// 诊断开关（--selftest 里打开，把搜索过程打到 stderr）
    static var debugLog = false

    /// 灰度高（1 字节/像素，行优先，第 0 行 = 图像顶部）
    private struct Gray {
        let width: Int
        let height: Int
        let data: [UInt8]
    }

    // ── 对外 ────────────────────────────────────────────────

    /// 求两帧的滚动偏移。失败返回 nil（没滚 / 滚太多 / 画面是空白 / 往回滚了）。
    ///
    /// - Parameter hint: 上一段已知的偏移。等距重复的内容（表格、列表、发票明细）
    ///   里 137 / 37 / 237 这类偏移**逐像素完全相等**，单看像素无解，
    ///   只能靠"这次大概也滚了这么多"来定夺。
    ///
    /// 三段式：240 宽粗搜定位 → 多个候选窗口各自在原分辨率精修 → 在
    /// 「逐像素对得上」的解里按 hint（或最小误差）选一个。
    /// 1.0.5 调试时 hint 只用来在粗搜的"并列解"里挑，而粗搜在亚像素处
    /// 得分差异纯属噪声，正确周期可能根本没进并列集合 —— 于是每滚一段
    /// 就跳到下一个周期，拼出来内容重复。所以精修必须对**多个窗口**都做。
    static func align(top: CGImage, bottom: CGImage, hint: Int? = nil) -> Alignment? {
        let targetW = min(top.width, bottom.width)
        guard targetW > 16, top.height > 16, bottom.height > 16,
              let t = normalized(top, width: targetW),
              let b = normalized(bottom, width: targetW) else { return nil }

        // ── 1) 粗搜：240 宽灰度、步长 2，只负责"大概在哪" ──
        let coarseW = min(240, targetW)
        guard let gTop = makeGray(t, width: coarseW),
              let gBottom = makeGray(b, width: coarseW) else { return nil }
        let ratio = Double(t.height) / Double(gTop.height)   // 1 个灰度行 = 多少原像素

        var candidates: [(d: Int, score: Double)] = []
        // 搜索上界按"至少留 5% 重叠"算（原来写死 0.92 = 8%，把"滚了大半屏"
        // 的合法帧也挡在外面，而快速滑动恰好就是这样）
        // d 的物理含义是"bottom 第 0 行落在 top 第 d 行"，所以上界只看 top 的高度：
        // 重叠 = min(top 高 - d, bottom 高)。写 `bottom 高 - 重叠` 是错的 ——
        // 它会连带禁掉"底部帧比 top 矮"的合法情况（页面到底了、最后一帧不满屏）。
        let minOverlapRows = max(8, gBottom.height / 25)
        let maxD = gTop.height - minOverlapRows
        var d = 2
        while d <= maxD {
            if let s = score(top: gTop, bottom: gBottom, d: d, rowStep: 2, colStep: 2) {
                candidates.append((d, s.mad))
            }
            d += 2
        }
        guard !candidates.isEmpty else { return nil }

        // 候选窗口：粗搜前几名 + （有 hint 时）离 hint 最近的那个。
        // 10 而不是 6：强横向条纹页（表格 / 代码编辑器）在粗搜里同相位候选一大把，
        // 多精修几个窗口是毫秒级开销，换第一段（无 hint）多一分命中真解的机会。
        var centers = Set(candidates.sorted { $0.score < $1.score }.prefix(10).map(\.d))
        if let hint {
            let hintCoarse = Double(hint) / ratio
            if let nearest = candidates.min(by: {
                abs(Double($0.d) - hintCoarse) < abs(Double($1.d) - hintCoarse)
            }) {
                centers.insert(nearest.d)
            }
        }

        // ── 2) 每个窗口在原分辨率（宽 = 图像宽）逐像素精修 ──
        guard let fTop = makeGray(t, width: targetW),
              let fBottom = makeGray(b, width: targetW) else { return nil }
        let span = max(3, Int(ratio.rounded()) + 2)
        let rowStep = max(1, fBottom.height / 80)
        let colStep = max(1, targetW / 320)

        if debugLog {
            FileHandle.standardError.write("[stitch] maxD=\(maxD) 窗口=\(centers.sorted()) ratio=\(String(format: "%.2f", ratio)) span=\(span)\n".data(using: .utf8)!)
        }
        var solutions: [(d: Int, mad: Double, texture: Double)] = []
        for center in centers.sorted() {
            let base = Int((Double(center) * ratio).rounded())
            guard let r = refineWindow(top: fTop, bottom: fBottom, base: base, span: span,
                                       rowStep: rowStep, colStep: colStep) else { continue }
            // 相邻窗口精修出来的可能是同一个偏移。🔴 合并时留 **mad 更小的那个**，
            // 不是先到的 —— 窗口按 center 升序扫，低窗口可能先交出一个"还行但不是
            // 最优"的解（1.0.15 实测：伪解 d=136 mad=14.7 先进队，把真解 d=137
            // mad=0 当重复项丢了，第一段就差一个像素）。
            if let idx = solutions.firstIndex(where: { abs($0.d - r.d) <= 1 }) {
                if r.mad < solutions[idx].mad { solutions[idx] = r }
                continue
            }
            solutions.append(r)
        }
        guard !solutions.isEmpty else { return nil }

        // ── 3) 择优 ──
        let chosen: (d: Int, mad: Double, texture: Double)
        if let hint {
            // 多个"逐像素相等"的解 → 取离上一段偏移最近的那个（周期性内容全靠这条）
            chosen = solutions.min { abs($0.d - hint) < abs($1.d - hint) }!
        } else {
            chosen = solutions.min { $0.mad < $1.mad }!
        }
        if debugLog {
            let list = solutions.map { "d=\($0.d)(mad=\(String(format: "%.2f", $0.mad)))" }.joined(separator: " ")
            FileHandle.standardError.write("[stitch] 合格解：\(list) → 选 d=\(chosen.d)（hint=\(hint.map(String.init) ?? "无")）\n".data(using: .utf8)!)
        }
        return Alignment(offset: chosen.d, score: chosen.mad, texture: chosen.texture)
    }

    /// 在 base±span 里挑 mad 最小的偏移，并做质量门。
    ///
    /// 质量门 ①：像素级对上（mad 很小，只容忍亚像素重采样的误差）。
    /// 质量门 ②：得跟"错的偏移"拉开差距 —— 纯色 / 空白画面里每个候选的 mad 都是 0，
    /// 最优解毫无意义。1.0.5 曾用 `texture >= 1 || mad <= 1.5` 兜底，纯色恰好走后者，
    /// 把"什么都不像"当成"完美匹配"拼了进去。改成看候选间分离度，跟画面亮不亮、
    /// 有没有细节都无关。
    private static func refineWindow(top: Gray, bottom: Gray, base: Int, span: Int,
                                     rowStep: Int, colStep: Int)
        -> (d: Int, mad: Double, texture: Double)? {
        // 上界只能按 top 的高度收（d 可以大于 bottom 的高度，
        // 只要 bottom 第 0 行还能落到 top 里面去）—— 拿 bottom.height 卡会
        // 把"底部帧不满屏"的合法偏移整个切掉
        let lower = max(2, base - span)
        let upper = min(top.height - 2, base + span)
        guard lower <= upper else { return nil }

        var best: (d: Int, mad: Double, texture: Double)?
        var allMads: [Double] = []
        for candidate in lower...upper {
            guard let s = score(top: top, bottom: bottom, d: candidate,
                                rowStep: rowStep, colStep: colStep) else { continue }
            allMads.append(s.mad)
            if best == nil || s.mad < best!.mad {
                best = (candidate, s.mad, s.texture)
            }
        }
        guard let result = best, !allMads.isEmpty else { return nil }

        let meanMad = allMads.reduce(0, +) / Double(allMads.count)
        if debugLog {
            let info = "窗口 \(lower)...\(upper) best=d\(result.d) mad=\(String(format: "%.2f", result.mad)) mean=\(String(format: "%.1f", meanMad))"
            FileHandle.standardError.write("[stitch]   \(info)\n".data(using: .utf8)!)
        }
        // 门 ①：整数像素级对上（mad 很小，只容忍亚像素重采样的误差）。
        if result.mad <= 6, meanMad - result.mad >= 8 { return result }
        // 门 ②：亚像素余量（1.0.15）。触控板 / 平滑滚动停下的位置经常带小数
        // （比如 137.4px），两帧各自带着抗锯齿重采样渲染，正确 d 的 mad 会被
        // 抬到 10~20、跟相邻 d 拉不出深坑 —— 这不是"对错了"，是"对上了但带着
        // 半像素误差"。放宽容忍，但要求与窗口内其他候选的分离度更大（防低纹理瞎拼）。
        if result.mad <= 20, meanMad - result.mad >= 12 { return result }
        return nil
    }

    /// 把 bottom 接到 top 下面（内部自己求偏移）。失败返回 nil。
    static func stitchVertical(top: CGImage, bottom: CGImage) -> CGImage? {
        guard let alignment = align(top: top, bottom: bottom) else { return nil }
        return append(bottom: bottom, to: top, offset: alignment.offset)
    }

    /// 按已知偏移把 bottom 追加到 top 下面。
    /// CG 坐标是左下原点：top 画上部、bottom 画下部，重叠 offset 行。
    ///
    /// 🔴 新高度 = 已有高度 + offset，不是 (top + bottom - 重叠)。
    /// 因为 offset 是"bottom 的第 0 行落在 top 的第 offset 行"，bottom 真正的
    /// 新内容只有 offset 行；写成 `t.height + b.height - overlap` 等于把
    /// bottom 的重叠部分又整整加了一遍，画布会比页面实际高度多出一大截
    /// （1.0.5 自检：1173 行的页面拼出 2330 行）。
    static func append(bottom: CGImage, to top: CGImage, offset: Int) -> CGImage? {
        let targetW = min(top.width, bottom.width)
        guard targetW > 0,
              let t = normalized(top, width: targetW),
              let b = normalized(bottom, width: targetW) else { return nil }
        // offset 必须小于 bottom 高度（必须真有重叠），否则说明没对齐
        guard offset >= 0, offset < b.height else { return nil }
        let newHeight = t.height + offset
        // 上限 30000 行：再长就不是截图了，是内存事故
        guard newHeight > 0, newHeight <= 30000 else { return nil }

        guard let ctx = CGContext(data: nil, width: targetW, height: newHeight,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                    | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(t, in: CGRect(x: 0, y: CGFloat(newHeight - t.height),
                               width: CGFloat(targetW), height: CGFloat(t.height)))
        ctx.draw(b, in: CGRect(x: 0, y: 0,
                               width: CGFloat(targetW), height: CGFloat(b.height)))
        return ctx.makeImage()
    }

    /// 旋转 90° 顺时针（横向滚动截图复用竖向算法）
    static func rotate90(_ image: CGImage) -> CGImage? {
        let w = image.width, h = image.height
        guard let ctx = CGContext(data: nil, width: h, height: w,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                    | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.translateBy(x: CGFloat(h), y: 0)
        ctx.rotate(by: .pi / 2)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }

    // ── 灰度采样 ────────────────────────────────────────────

    private static func makeGray(_ image: CGImage, width targetWidth: Int) -> Gray? {
        let w = max(1, min(targetWidth, image.width))
        let h = max(1, Int((Double(image.height) * Double(w) / Double(image.width)).rounded()))
        guard let ctx = CGContext(data: nil, width: w, height: h,
                                  bitsPerComponent: 8, bytesPerRow: w,
                                  space: CGColorSpaceCreateDeviceGray(),
                                  bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let base = ctx.data else { return nil }
        let raw = base.bindMemory(to: UInt8.self, capacity: w * h)
        // 🔴 别翻转。CGContext 的**绘制坐标系**是左下原点，但**位图缓冲区**本身就是
        // top-down（缓冲第 0 行 = 图像最上面一行），`CGImage.cropping(to:)` 的 y 也
        // 从顶部算。1.0.5 调试时曾在这里多翻一次，结果两张图同时上下颠倒，
        // 正偏移 d 在数学上永远对不上（只有 d = -offset 才成立），粗搜全落随机水平。
        let data = Array(UnsafeBufferPointer(start: raw, count: w * h))
        return Gray(width: w, height: h, data: data)
    }

    /// 比较 top[y+d] 与 bottom[y]，返回平均绝对差 + 纹理强度
    private static func score(top: Gray, bottom: Gray, d: Int,
                              rowStep: Int, colStep: Int) -> (mad: Double, texture: Double)? {
        let overlap = min(top.height - d, bottom.height)
        guard overlap > 8 else { return nil }

        // 跳过当前帧顶部 10% + 底部 4%：固定表头 / 固定底栏在两帧里位置不变，
        // 留着它们会把最优解往 d≈0 拖（那样"看起来"最像）。
        // 🔴 上限压到 overlap/4：滚到只剩几十行重叠时（快速滑动就是这样），
        // 按帧高算出来的 50 行比重叠区本身还大，会把比较区削成负数 ——
        // 结果"明明能对上却返回 nil"，宁可少跳过一点也不能没有可比的像素。
        let skipTop = min(max(2, Int(Double(bottom.height) * 0.10)), max(2, overlap / 4))
        let skipBottom = min(max(1, Int(Double(bottom.height) * 0.04)), max(1, overlap / 4))
        let last = overlap - skipBottom
        guard last - skipTop >= 8 else { return nil }

        var total = 0, samples = 0
        var textureTotal = 0, textureSamples = 0
        var y = skipTop
        while y < last {
            let baseTop = (y + d) * top.width
            let baseBottom = y * bottom.width
            var x = 0
            while x < top.width {
                total += abs(Int(top.data[baseTop + x]) - Int(bottom.data[baseBottom + x]))
                samples += 1
                let nextX = x + colStep
                if nextX < top.width {
                    textureTotal += abs(Int(top.data[baseTop + nextX]) - Int(top.data[baseTop + x]))
                    textureSamples += 1
                }
                x = nextX
            }
            y += rowStep
        }
        guard samples > 0 else { return nil }
        return (Double(total) / Double(samples),
                textureSamples > 0 ? Double(textureTotal) / Double(textureSamples) : 0)
    }

    private static func normalized(_ image: CGImage, width: Int) -> CGImage? {
        guard image.width != width else { return image }
        let height = max(1, Int(CGFloat(image.height) * CGFloat(width) / CGFloat(image.width)))
        guard let ctx = CGContext(data: nil, width: width, height: height,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                    | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
        return ctx.makeImage()
    }
}
