import Foundation
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
        let observations = try await recognize(image: image)

        guard keepLineBreaks else {
            return observations.map(\.text).joined(separator: " ")
        }

        let lines = groupIntoLines(observations, overlapThreshold: lineOverlap)
        return lines.joined(separator: "\n")
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

    /// 把逐词 observation 聚成文本行。
    /// 判据：纵向中线差距 < 行高的 60%，且横向区间与已有行的重叠率 > 阈值。
    static func groupIntoLines(_ observations: [TextObservation], overlapThreshold: Double) -> [String] {
        struct Line {
            var items: [(x: Double, text: String)]
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
                    lines[index].items.append((box.minX, obs.text))
                    lines[index].minY = min(line.minY, box.minY)
                    lines[index].maxY = max(line.maxY, box.maxY)
                    lines[index].minX = min(line.minX, box.minX)
                    lines[index].maxX = max(line.maxX, box.maxX)
                    merged = true
                    break
                }
            }
            if !merged {
                lines.append(Line(items: [(box.minX, obs.text)],
                                  minY: box.minY, maxY: box.maxY,
                                  minX: box.minX, maxX: box.maxX))
            }
        }

        return lines
            .sorted { ($0.minY + $0.maxY) / 2 < ($1.minY + $1.maxY) / 2 }
            .map { line in
                line.items
                    .sorted { $0.x < $1.x }
                    .map(\.text)
                    .joined(separator: " ")
            }
    }

    // ── QR / 条形码 ──

    static func decodeBarcodes(in image: CGImage) async throws -> [String] {
        try await withCheckedThrowingContinuation { continuation in
            let once = OnceContinuation(continuation)
            let request = VNDetectBarcodesRequest { request, error in
                if let error {
                    once.resume(throwing: error)
                    return
                }
                let payloads = (request.results as? [VNBarcodeObservation])?.compactMap { $0.payloadStringValue } ?? []
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
}
