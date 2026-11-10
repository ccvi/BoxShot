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
        // 落盘根目录只认 `Support.appSupportRoot`：以前这里自己又拼了一遍
        // "BoxShot/History"，哪天两边对不上就是「文件在 A、清单读 B」——
        // 表现恰好是"历史永远是空的"，而且三处失败全是静默 return，查不出来。
        directory = Support.appSupportRoot.appendingPathComponent("History", isDirectory: true)
        manifestURL = directory.appendingPathComponent("history.json")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        load()
    }

    // ── 读写 ────────────────────────────────────────────────

    private func load() {
        guard let data = try? Data(contentsOf: manifestURL),
              let decoded = try? JSONDecoder().decode([ShotHistoryItem].self, from: data) else {
            items = []
            lastLoadStatus = FileManager.default.fileExists(atPath: manifestURL.path)
                ? "清单存在但读不出（解码失败或被拒）"
                : "还没有清单文件（第一次用）"
            return
        }
        // 清单里可能有文件已被手工删掉的条目，读的时候顺手剔掉
        let kept = decoded.filter { FileManager.default.fileExists(atPath: url(for: $0).path) }
        lastLoadStatus = "读到 \(decoded.count) 条，留下 \(kept.count) 条"
        items = kept
    }

    private func saveManifest() {
        guard let data = try? JSONEncoder().encode(items) else { return }
        try? data.write(to: manifestURL)
    }

    func url(for item: ShotHistoryItem) -> URL {
        directory.appendingPathComponent(item.fileName)
    }

    // ── 诊断 ────────────────────────────────────────────────
    //
    // 🔴 这里原来是三处静默 `return`：历史"没记录"的时候，谁也说不清是
    // 没被调用、写不了 PNG，还是清单没落盘 —— 2026-11-10 用户报「截图历史失灵」，
    // 第一轮排查就卡在"目录根本不存在，但不知道卡在哪一步"。
    // 现在每条失败路径都留一句话，配上目录 / 清单的真实路径。

    private(set) var lastRecordStatus = "本次启动还没记录过"
    private(set) var lastLoadStatus = "尚未读取"

    var directoryPathForDiagnostics: String { directory.path }
    var manifestPathForDiagnostics: String { manifestURL.path }

    /// 目录里实际有多少个文件（和 items.count 对不上 = 清单与文件不同步）
    var fileCountForDiagnostics: Int {
        (try? FileManager.default.contentsOfDirectory(atPath: directory.path))?.count ?? -1
    }

    // ── 记录 ────────────────────────────────────────────────

    /// 记录一张新截图；limit = 0 表示不记录
    func record(_ image: CGImage, limit: Int) {
        guard limit > 0 else {
            lastRecordStatus = "跳过：设置里的历史张数是 0"
            return
        }
        let id = UUID()
        let name = "\(id.uuidString).png"
        let target = directory.appendingPathComponent(name)
        guard let destination = CGImageDestinationCreateWithURL(
            target as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            lastRecordStatus = "建不了 PNG 目标：\(target.path)"
            return
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            lastRecordStatus = "PNG 写盘失败：\(target.path)"
            return
        }

        items.insert(ShotHistoryItem(id: id, fileName: name, date: Date(),
                                     pixelWidth: image.width, pixelHeight: image.height),
                     at: 0)
        prune(to: limit)
        saveManifest()
        lastRecordStatus = "成功：\(name)（目录里现有 \(items.count) 条）"
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
