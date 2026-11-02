import Foundation
import CoreImage
import Vision

// ============================================================
// OCR（VNRecognizeTextRequest）与 QR/条形码（VNDetectBarcodesRequest）
//
// Vision 的文字识别走 async API（macOS 13+），中英文都支持；
// 语言偏好 zh-Hans + en-US，识别精度用 .accurate。
//
// 保留换行：Vision 返回的是逐个 observation，没有"行"的概念——
// 同一行会被拆成多个 boundingBox（不同字号/间隔时尤其明显）。
// 做法：先按"纵向中线相近 + 横向区间重叠比例"把 observation 聚成行，
// 行内按 x 排序拼接，再按 y 排序输出行序列。
// ============================================================

enum OCREngine {

    // ── 文字识别 ──

    struct TextObservation {
        var text: String
        var bounds: CGRect   // 归一化（0-1），左上原点向下
    }

    static func recognizeText(in image: CGImage, keepLineBreaks: Bool, lineOverlap: Double) async throws -> String {
        let observations = try await recognizeObservations(in: image)

        guard keepLineBreaks else {
            return observations.map(\.text).joined(separator: " ")
        }

        let lines = groupIntoLines(observations, overlapThreshold: lineOverlap)
        return lines.joined(separator: "\n")
    }

    /// 识别并保留**每个词的包围盒**（归一化 0-1，左上原点）。
    /// 行聚类、表格重排都在 observations 上做，Vision 只跑这一次。
    static func recognizeObservations(in image: CGImage) async throws -> [TextObservation] {
        try await recognize(image: image)
    }

    private static func recognize(image: CGImage) async throws -> [TextObservation] {
        try await withCheckedThrowingContinuation { continuation in
            let once = OnceContinuation(continuation)
            let request = VNRecognizeTextRequest { request, error in
                if let error {
                    once.resume(throwing: error)
                    return
                }
                guard let results = request.results as? [VNRecognizedTextObservation] else {
                    once.resume(returning: [])
                    return
                }
                let observations: [TextObservation] = results.compactMap { obs in
                    guard let candidate = obs.topCandidates(1).first else { return nil }
                    // Vision 的 boundingBox 是左下原点；转成左上原点向下
                    let box = obs.boundingBox
                    let flipped = CGRect(x: box.minX, y: 1 - box.maxY, width: box.width, height: box.height)
                    return TextObservation(text: candidate.string, bounds: flipped)
                }
                once.resume(returning: observations)
            }
            request.recognitionLevel = .accurate
            request.recognitionLanguages = ["zh-Hans", "en-US"]
            request.usesLanguageCorrection = true

            let handler = VNImageRequestHandler(cgImage: image, options: [:])
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try handler.perform([request])
                } catch {
                    once.resume(throwing: error)
                }
            }
        }
    }

    /// Vision 的回调与 perform 抛错可能都会走 resume，checked continuation
    /// 只许 resume 一次——包一层哨兵，第二次起直接吞掉。
    private final class OnceContinuation<T> {
        private let continuation: CheckedContinuation<T, Error>
        private var resumed = false

        init(_ continuation: CheckedContinuation<T, Error>) {
            self.continuation = continuation
        }

        func resume(returning value: T) {
            lockSync {
                guard !resumed else { return }
                resumed = true
            }
            continuation.resume(returning: value)
        }

        func resume(throwing error: Error) {
            lockSync {
                guard !resumed else { return }
                resumed = true
            }
            continuation.resume(throwing: error)
        }

        private func lockSync(_ body: () -> Void) {
            objc_sync_enter(self)
            body()
            objc_sync_exit(self)
        }
    }

    /// 聚出来的行：格子带横向范围（表格分列要用），midY 用于圈定表格纵向范围
    struct OCRRow {
        var cells: [(minX: Double, maxX: Double, text: String)]
        var midY: Double
    }

    /// 把逐词 observation 聚成文本行（带格子信息）。
    /// 判据：纵向中线差距 < 行高的 60%，且横向区间与已有行的重叠率 > 阈值。
    static func groupedRows(_ observations: [TextObservation], overlapThreshold: Double) -> [OCRRow] {
        struct Line {
            var cells: [(minX: Double, maxX: Double, text: String)]
            var minY: Double
            var maxY: Double
            var minX: Double
            var maxX: Double
        }

        // 先按纵向位置排序，减少聚类的来回折腾
        let sorted = observations.sorted { $0.bounds.midY < $1.bounds.midY }
        var lines: [Line] = []

        for obs in sorted {
            let box = obs.bounds
            var merged = false
            for index in lines.indices {
                let line = lines[index]
                let lineMidY = (line.minY + line.maxY) / 2
                let lineHeight = max(line.maxY - line.minY, box.height, 0.001)
                let verticalDiff = abs(box.midY - lineMidY)
                let verticalClose = verticalDiff < lineHeight * 0.6
                // 纵向"接近但不够近"时，用横向重叠率辅助判定（不同字号同行）；
                // 纵向差距大时**绝不**合并——横向重叠不能独立成合并依据，
                // 否则上下两行只要横向对齐就会被错拼成一行。
                let verticalNear = verticalDiff < lineHeight * 1.1
                let overlapStart = max(line.minX, box.minX)
                let overlapEnd = min(line.maxX, box.maxX)
                let overlap = max(0, overlapEnd - overlapStart)
                let overlapRatio = overlap / max(min(box.width, line.maxX - line.minX), 0.0001)
                if verticalClose || (verticalNear && overlapRatio > overlapThreshold) {
                    lines[index].cells.append((box.minX, box.maxX, obs.text))
                    lines[index].minY = min(line.minY, box.minY)
                    lines[index].maxY = max(line.maxY, box.maxY)
                    lines[index].minX = min(line.minX, box.minX)
                    lines[index].maxX = max(line.maxX, box.maxX)
                    merged = true
                    break
                }
            }
            if !merged {
                lines.append(Line(cells: [(box.minX, box.maxX, obs.text)],
                                  minY: box.minY, maxY: box.maxY,
                                  minX: box.minX, maxX: box.maxX))
            }
        }

        return lines
            .sorted { ($0.minY + $0.maxY) / 2 < ($1.minY + $1.maxY) / 2 }
            .map { line in
                OCRRow(cells: line.cells.sorted { $0.minX < $1.minX },
                       midY: (line.minY + line.maxY) / 2)
            }
    }

    /// 把逐词 observation 聚成文本行。
    static func groupIntoLines(_ observations: [TextObservation], overlapThreshold: Double) -> [String] {
        groupedRows(observations, overlapThreshold: overlapThreshold)
            .map { $0.cells.map(\.text).joined(separator: " ") }
    }

    // ── 表格 → Markdown ──

    /// 尝试把 OCR 结果重排成 Markdown 表格；不像表格就返回 nil（调用方回落纯文本）。
    ///
    /// 思路：行聚类沿用 groupedRows；分列靠**列缝检测**——
    /// 收集多列行里"单元格之间的空白带"，横向求交后，
    /// 出现在 ≥ 一半多列行里的空白带才算列边界（空单元格天然被跳过）。
    /// 结构太散（行太少 / 列太多 / 缝对不上）就放弃，别硬拼。
    static func tableMarkdown(from observations: [TextObservation]) -> String? {
        let rows = groupedRows(observations, overlapThreshold: 0.5)
        let multi = rows.filter { $0.cells.count >= 2 }
        // 至少两行、至少两行有多列，且多列行占多数——否则大概率只是排版松散的段落
        guard rows.count >= 2, multi.count >= 2,
              Double(multi.count) / Double(rows.count) >= 0.5 else { return nil }

        // 只取表格纵向范围内的行（表上方的标题、下方的备注别混进来）
        let top = multi.map(\.midY).min() ?? 0
        let bottom = multi.map(\.midY).max() ?? 1
        let body = rows.filter { $0.midY >= top && $0.midY <= bottom }

        struct Gap { var lo: Double; var hi: Double; var count: Int }
        var merged: [Gap] = []
        for row in multi {
            for i in 1..<row.cells.count {
                let lo = row.cells[i - 1].maxX
                let hi = row.cells[i].minX
                guard hi - lo > 0.012 else { continue }  // 太窄是字距，不是列缝
                if let idx = merged.firstIndex(where: { $0.lo < hi && lo < $0.hi }) {
                    merged[idx].lo = max(merged[idx].lo, lo)
                    merged[idx].hi = min(merged[idx].hi, hi)
                    merged[idx].count += 1
                } else {
                    merged.append(Gap(lo: lo, hi: hi, count: 1))
                }
            }
        }
        let needed = max(2, Int(ceil(Double(multi.count) * 0.5)))
        let separators = merged
            .filter { $0.count >= needed && $0.hi > $0.lo }
            .map { ($0.lo + $0.hi) / 2 }
            .sorted()
        guard !separators.isEmpty else { return nil }
        let columnCount = separators.count + 1
        guard columnCount >= 2, columnCount <= 10 else { return nil }

        // 每行按列缝分格；同列撞上两个词（聚类误差）就拼一格
        var grid = body.map { row -> [String] in
            var cells = Array(repeating: "", count: columnCount)
            for cell in row.cells {
                let center = (cell.minX + cell.maxX) / 2
                let column = min(separators.filter { center > $0 }.count, columnCount - 1)
                cells[column] = cells[column].isEmpty ? cell.text : cells[column] + " " + cell.text
            }
            return cells
        }
        // 掐掉两边全空的列（列缝偏移时会出现）
        let used = (0..<columnCount).filter { column in grid.contains { !$0[column].isEmpty } }
        guard let first = used.first, let last = used.last, last > first else { return nil }
        grid = grid.map { Array($0[first...last]) }

        var markdown = "|" + grid[0].map { " \($0) |" }.joined() + "\n"
        markdown += "|" + String(repeating: " --- |", count: grid[0].count) + "\n"
        for row in grid.dropFirst() {
            markdown += "|" + row.map { " \($0) |" }.joined() + "\n"
        }
        return markdown
    }

    // ── QR / 条形码 ──

    /// 解 QR / 条形码。
    ///
    /// 🔴 一次原图不够。Vision 的条形码检测有两个已知的薄弱面：
    ///   ① **模块太小**（截图里码只有一两百像素）→ 检测器在候选阶段就漏掉；
    ///   ② **圆点 / 圆角定位图案**的 QR（Edge、Chrome 的「分享 → 二维码」就是这种，
    ///      它不是标准方块模块）→ 二值化后连通域对不上。
    /// 所以先试原图，解不出来再按「放大 → 灰度拉对比 → 形态学膨胀」逐级回退。
    /// 膨胀那一步是圆点 QR 的关键：把圆点撑成方块，连通域才对得上。
    static func decodeBarcodes(in image: CGImage) async throws -> [String] {
        do {
            if let payloads = try await detect(in: image), !payloads.isEmpty {
                return payloads
            }
        } catch {
            // 某一次检测抛错（比如当前系统不支持列表里的某个码制）不该直接判死：
            // 记一笔继续回退，全都不行才认输
            NSLog("[BoxShot] 条形码检测第 1 次抛错：%@", "\(error)")
        }
        for (index, prepared) in fallbackImages(from: image).enumerated() {
            if let payloads = try? await detect(in: prepared), !payloads.isEmpty {
                NSLog("[BoxShot] 条形码回退 #%d 解出来了", index + 1)
                return payloads
            }
        }
        return []
    }

    /// 单次检测。出错就抛，由调用方决定要不要继续回退。
    private static func detect(in image: CGImage) async throws -> [String]? {
        try await withCheckedThrowingContinuation { continuation in
            let once = OnceContinuation(continuation)
            let request = VNDetectBarcodesRequest { request, error in
                if let error {
                    once.resume(throwing: error)
                    return
                }
                let payloads = (request.results as? [VNBarcodeObservation])?
                    .compactMap { $0.payloadStringValue } ?? []
                once.resume(returning: payloads)
            }
            // 全格式覆盖：QR / EAN / Code128 / PDF417 / Aztec 等
            request.symbologies = [.qr, .ean13, .ean8, .code128, .code39, .code93,
                                   .pdf417, .aztec, .dataMatrix, .i2of5, .itf14]

            let handler = VNImageRequestHandler(cgImage: image, options: [:])
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try handler.perform([request])
                } catch {
                    once.resume(throwing: error)
                }
            }
        }
    }

    /// CIContext 建一次就够（每次新建要几十毫秒，回退链里会建好几次）
    private static let ciContext = CIContext()

    /// 回退用的几张预处理图。顺序就是试的顺序：便宜的、命中率高的在前。
    private static func fallbackImages(from image: CGImage) -> [CGImage] {
        let base = CIImage(cgImage: image)
        let maxSide = max(image.width, image.height)
        var out: [CGImage] = []

        // ① 放大 2 倍：模块太小时靠它。整屏图已经 3000+ 就别再翻了（6840 宽的图又慢又没用）
        if maxSide <= 2600, let big = render(base, scale: 2) {
            out.append(big)
        }
        // ② 灰度 + 拉对比：JPEG 压过的码边缘发虚、对比度被吃掉一截
        let grayscale = base.applyingFilter("CIColorControls", parameters: [
            kCIInputSaturationKey: 0,
            kCIInputContrastKey: 1.8,
        ])
        if let gray = render(grayscale, scale: 1) { out.append(gray) }
        // ③ 形态学最大值（膨胀）：圆点撑成方块，圆点风格 QR 基本靠这一步
        for radius in [1.5, 3.0] {
            let grown = grayscale.applyingFilter("CIMorphologyMaximum",
                                                 parameters: ["inputRadius": radius])
            if let grew = render(grown, scale: 1) { out.append(grew) }
        }
        return out
    }

    private static func render(_ image: CIImage, scale: CGFloat) -> CGImage? {
        let scaled = scale == 1 ? image
                                : image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        return ciContext.createCGImage(scaled, from: scaled.extent)
    }
}
