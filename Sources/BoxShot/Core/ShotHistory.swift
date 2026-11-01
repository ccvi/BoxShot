import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

// ============================================================
// 截图历史
//
// 每张截下来的图会留一份 PNG 到
//   ~/Library/Application Support/BoxShot/History/
// 旁边一个 history.json 记顺序、时间、尺寸。
//
// 为什么落盘而不是只留在内存里：截图的历史价值就在"刚才那张"，
// 应用一重启就没了等于没有；而且 PNG 落盘后缩略图可以按需读，
// 20 张原图也不占常驻内存。
//
// 失败一律静默：历史记录失败绝不能影响截图本身（这是附属功能）。
// ============================================================

struct ShotHistoryItem: Identifiable, Codable, Equatable {
    let id: UUID
    let fileName: String
    let date: Date
    let pixelWidth: Int
    let pixelHeight: Int

    var pixelSizeText: String { "\(pixelWidth) × \(pixelHeight)" }
}

@MainActor
final class ShotHistoryStore: ObservableObject {

    static let shared = ShotHistoryStore()

    @Published private(set) var items: [ShotHistoryItem] = []

    private var directory: URL
    private let manifestURL: URL

    private init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        directory = base.appendingPathComponent("BoxShot/History", isDirectory: true)
        manifestURL = directory.appendingPathComponent("history.json")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        load()
    }

    // ── 读写 ────────────────────────────────────────────────

    private func load() {
        guard let data = try? Data(contentsOf: manifestURL),
              let decoded = try? JSONDecoder().decode([ShotHistoryItem].self, from: data) else {
            items = []
            return
        }
        // 清单里可能有文件已被手工删掉的条目，读的时候顺手剔掉
        items = decoded.filter { FileManager.default.fileExists(atPath: url(for: $0).path) }
    }

    private func saveManifest() {
        guard let data = try? JSONEncoder().encode(items) else { return }
        try? data.write(to: manifestURL)
    }

    func url(for item: ShotHistoryItem) -> URL {
        directory.appendingPathComponent(item.fileName)
    }

    // ── 记录 ────────────────────────────────────────────────

    /// 记录一张新截图；limit = 0 表示不记录
    func record(_ image: CGImage, limit: Int) {
        guard limit > 0 else { return }
        let id = UUID()
        let name = "\(id.uuidString).png"
        let target = directory.appendingPathComponent(name)
        guard let destination = CGImageDestinationCreateWithURL(
            target as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return }

        items.insert(ShotHistoryItem(id: id, fileName: name, date: Date(),
                                     pixelWidth: image.width, pixelHeight: image.height),
                     at: 0)
        prune(to: limit)
        saveManifest()
    }

    private func prune(to limit: Int) {
        guard items.count > limit else { return }
        let dropped = items[limit...]
        for item in dropped { try? FileManager.default.removeItem(at: url(for: item)) }
        items = Array(items.prefix(limit))
    }

    // ── 读取 / 删除 ─────────────────────────────────────────

    func image(for item: ShotHistoryItem) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url(for: item) as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    func delete(_ item: ShotHistoryItem) {
        try? FileManager.default.removeItem(at: url(for: item))
        items.removeAll { $0.id == item.id }
        saveManifest()
    }

    func clear() {
        for item in items { try? FileManager.default.removeItem(at: url(for: item)) }
        items.removeAll()
        saveManifest()
    }
}
