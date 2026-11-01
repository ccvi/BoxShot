import AppKit
import SwiftUI

// ============================================================
// 截图历史面板
//
// 网格列出最近 N 张截图（缩略图 + 时间 + 像素尺寸）。
// 双击 = 打开标注编辑器；底部一排动作：复制 / 贴图 / Finder 显示 / 删除 / 清空。
//
// 缩略图按需从磁盘读并降采样（preparingThumbnail），不把原图常驻内存 ——
// 20 张 4K 截图全解压进内存就是几百 MB，面板一开风扇就响。
// ============================================================

@MainActor
final class HistoryWindowController: NSWindowController, NSWindowDelegate {

    private weak var model: AppModel?

    init(model: AppModel) {
        self.model = model
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 520),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "截图历史"
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
        window.delegate = self

        let root = ShotHistoryView(
            model: model,
            store: ShotHistoryStore.shared,
            onOpen: { [weak self] item in self?.open(item) },
            onCopy: { [weak self] item in self?.copy(item) },
            onPin: { [weak self] item in self?.pin(item) },
            onReveal: { [weak self] item in
                guard let self, let url = self.url(for: item) else { return }
                NSWorkspace.shared.activateFileViewerSelecting([url])
            })
        window.contentView = NSHostingView(rootView: root)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func show() {
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func url(for item: ShotHistoryItem) -> URL? {
        let url = ShotHistoryStore.shared.url(for: item)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private func open(_ item: ShotHistoryItem) {
        guard let image = ShotHistoryStore.shared.image(for: item) else { return }
        model?.openEditor(image: image)
    }

    private func copy(_ item: ShotHistoryItem) {
        guard let image = ShotHistoryStore.shared.image(for: item) else { return }
        Support.copyImageToClipboard(image)
        if model?.prefs.value.playSound == true { Support.playFeedbackSound() }
    }

    private func pin(_ item: ShotHistoryItem) {
        guard let image = ShotHistoryStore.shared.image(for: item) else { return }
        model?.pinImage(image)
    }
}

struct ShotHistoryView: View {

    let model: AppModel
    @ObservedObject var store: ShotHistoryStore

    var onOpen: (ShotHistoryItem) -> Void
    var onCopy: (ShotHistoryItem) -> Void
    var onPin: (ShotHistoryItem) -> Void
    var onReveal: (ShotHistoryItem) -> Void

    @State private var selectedID: UUID?

    private var selectedItem: ShotHistoryItem? {
        store.items.first { $0.id == selectedID }
    }

    var body: some View {
        VStack(spacing: 0) {
            if store.items.isEmpty {
                placeholder
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 176), spacing: 12)],
                              spacing: 12) {
                        ForEach(store.items) { item in
                            HistoryCell(item: item,
                                        url: store.url(for: item),
                                        isSelected: item.id == selectedID)
                                .onTapGesture { selectedID = item.id }
                                .simultaneousGesture(TapGesture(count: 2).onEnded {
                                    selectedID = item.id
                                    onOpen(item)
                                })
                                .contextMenu {
                                    Button("在编辑器中打开") { onOpen(item) }
                                    Button("复制到剪贴板") { onCopy(item) }
                                    Button("贴到桌面") { onPin(item) }
                                    Button("在 Finder 中显示") { onReveal(item) }
                                    Divider()
                                    Button("删除", role: .destructive) {
                                        store.delete(item)
                                        if selectedID == item.id { selectedID = nil }
                                    }
                                }
                        }
                    }
                    .padding(14)
                }
            }
            Divider()
            actionBar
        }
        .frame(minWidth: 560, minHeight: 380)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var placeholder: some View {
        VStack(spacing: 8) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 34))
                .foregroundStyle(.secondary)
            Text("还没有截图记录")
                .font(.headline)
            Text("截一张图，这里就会出现它")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var actionBar: some View {
        HStack(spacing: 8) {
            Text("共 \(store.items.count) 张")
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
            Button("打开标注") { if let item = selectedItem { onOpen(item) } }
                .disabled(selectedItem == nil)
            Button("复制") { if let item = selectedItem { onCopy(item) } }
                .disabled(selectedItem == nil)
            Button("贴图") { if let item = selectedItem { onPin(item) } }
                .disabled(selectedItem == nil)
            Button("Finder") { if let item = selectedItem { onReveal(item) } }
                .disabled(selectedItem == nil)
            Button("删除", role: .destructive) {
                if let item = selectedItem {
                    store.delete(item)
                    selectedID = nil
                }
            }
            .disabled(selectedItem == nil)
            Divider().frame(height: 18)
            Button("清空全部", role: .destructive) { store.clear(); selectedID = nil }
                .disabled(store.items.isEmpty)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

private struct HistoryCell: View {

    let item: ShotHistoryItem
    let url: URL
    let isSelected: Bool

    @State private var thumbnail: NSImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(nsColor: .controlBackgroundColor))
                if let thumbnail {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .padding(4)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .frame(height: 110)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(isSelected ? Color.accentColor : Color.gray.opacity(0.25),
                                  lineWidth: isSelected ? 2.5 : 1)
            )

            Text(Self.timeText(item.date))
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(item.pixelSizeText)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
        .task(id: item.id) {
            // 缩略图在后台解码 + 降采样，别把 4K 原图搬进内存。
            // 用 ImageIO 的缩略图接口（NSImage 没有等价的"只解码这么小"的入口）
            let target = url
            let image = await Task.detached(priority: .userInitiated) { () -> NSImage? in
                guard let source = CGImageSourceCreateWithURL(target as CFURL, nil) else { return nil }
                let options: [CFString: Any] = [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: 360,
                ]
                guard let thumb = CGImageSourceCreateThumbnailAtIndex(
                    source, 0, options as CFDictionary) else { return nil }
                return NSImage(cgImage: thumb, size: NSSize(width: thumb.width, height: thumb.height))
            }.value
            thumbnail = image
        }
    }

    private static func timeText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = Calendar.current.isDateInToday(date) ? "今天 HH:mm:ss" : "M月d日 HH:mm"
        return formatter.string(from: date)
    }
}
