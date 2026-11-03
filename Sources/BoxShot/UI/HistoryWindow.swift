import AppKit
import Quartz
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

/// 选中项。放 ObservableObject 里而不是视图 @State：
/// 空格预览要挂在窗口控制器上，控制器得读得到当前选中的是哪张。
final class HistorySelection: ObservableObject {
    @Published var selectedID: UUID?
}

@MainActor
final class HistoryWindowController: NSWindowController, NSWindowDelegate, QLPreviewPanelDataSource {

    private weak var model: AppModel?
    let selection = HistorySelection()
    private var keyMonitor: Any?

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
            selection: selection,
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

    /// 关掉就放手：控制器 + 已解码的缩略图不该在窗口关了之后还常驻内存
    var onClose: (() -> Void)?

    func show() {
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        installKeyMonitor()
    }

    // ── 空格预览（QuickLook，Finder 同款手感） ──────────────

    /// 选中项在 store.items 里的下标；没选中返回 nil（空格不做任何事）
    private var currentIndex: Int? {
        guard let selectedID = selection.selectedID else { return nil }
        return ShotHistoryStore.shared.items.firstIndex { $0.id == selectedID }
    }

    /// 只拦两个地方的空格：历史窗口上的（打开预览）、QL 面板上的（关闭预览）。
    /// 其他窗口的空格原样放行。QL 面板属于本进程，本地监听能收到它的事件。
    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.keyCode == 49 else { return event }
            // Swift 里 QLPreviewPanel.shared() 返回可选
            guard let panel = QLPreviewPanel.shared() else { return event }
            if panel.isVisible, event.window === panel {
                panel.orderOut(nil)
                return nil
            }
            guard event.window === self.window, let index = self.currentIndex else { return event }
            panel.dataSource = self
            panel.makeKeyAndOrderFront(nil)
            panel.currentPreviewItemIndex = index
            return nil
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
    }

    // ── QLPreviewPanelDataSource ──

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        ShotHistoryStore.shared.items.count
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem {
        let item = ShotHistoryStore.shared.items[index]
        return HistoryPreviewItem(url: ShotHistoryStore.shared.url(for: item))
    }

    func windowWillClose(_ notification: Notification) {
        removeKeyMonitor()
        onClose?()
    }

    // ── 诊断：从外部驱动「空格预览 / 关窗」（--memprobe 用） ──
    //
    // 空格预览走 QLPreviewPanel.shared()，那是**进程级单例**：只要预览过一次，
    // 面板窗口就会一直挂在 NSApp.windows 里。这块到底留不留整屏 drawable
    // 只能实测，所以做成可以从探针里一键开/关。

    func previewForDiagnostics(index: Int) -> Bool {
        let items = ShotHistoryStore.shared.items
        guard let panel = QLPreviewPanel.shared(), index >= 0, index < items.count else { return false }
        selection.selectedID = items[index].id
        panel.dataSource = self
        panel.currentPreviewItemIndex = index
        panel.makeKeyAndOrderFront(nil)
        return true
    }

    func closePreviewForDiagnostics() {
        QLPreviewPanel.shared()?.orderOut(nil)
    }

    func closeWindowForDiagnostics() {
        window?.close()
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
        model?.playFeedbackSound()
    }

    private func pin(_ item: ShotHistoryItem) {
        guard let image = ShotHistoryStore.shared.image(for: item) else { return }
        model?.pinImage(image)
    }
}

struct ShotHistoryView: View {

    let model: AppModel
    @ObservedObject var store: ShotHistoryStore
    @ObservedObject var selection: HistorySelection

    /// 读取别名：视图里大量只读判断沿用旧名
    private var selectedID: UUID? { selection.selectedID }

    var onOpen: (ShotHistoryItem) -> Void
    var onCopy: (ShotHistoryItem) -> Void
    var onPin: (ShotHistoryItem) -> Void
    var onReveal: (ShotHistoryItem) -> Void

    /// 全部图片的磁盘总大小（后台算，随条目数变化重算）
    @State private var totalSizeText: String = ""

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
                                .onTapGesture { selection.selectedID = item.id }
                                .simultaneousGesture(TapGesture(count: 2).onEnded {
                                    selection.selectedID = item.id
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
                                        if selectedID == item.id { selection.selectedID = nil }
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
        // 条目增删（含清空/删除）后重算总大小；用 count 当 id，条目数不变就不用重算
        .task(id: store.items.count) { await recomputeTotalSize() }
    }

    /// 遍历每张图的文件属性累加 size。文件在磁盘上（几十张 4K 也就几 MB 的
    /// stat 开销），放后台队列算，别卡主线程；有文件被手动删掉的就跳过。
    private func recomputeTotalSize() async {
        guard !store.items.isEmpty else {
            totalSizeText = ""
            return
        }
        let urls = store.items.map { ShotHistoryStore.shared.url(for: $0).path }
        let total = await Task.detached(priority: .utility) { () -> Int64 in
            let fm = FileManager.default
            var sum: Int64 = 0
            for path in urls {
                if let size = try? fm.attributesOfItem(atPath: path)[.size] as? Int64 {
                    sum += size
                }
            }
            return sum
        }.value
        totalSizeText = total > 0
            ? ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
            : ""
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
            // 2026-11-02 用户口径：底部显示全部图片的总大小
            Text(totalSizeText.isEmpty
                 ? "共 \(store.items.count) 张"
                 : "共 \(store.items.count) 张 · \(totalSizeText)")
                .font(.callout)
                .monospacedDigit()
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
                    selection.selectedID = nil
                }
            }
            .disabled(selectedItem == nil)
            Divider().frame(height: 18)
            Button("清空全部", role: .destructive) { store.clear(); selection.selectedID = nil }
                .disabled(store.items.isEmpty)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

/// QuickLook 的预览项：就是历史目录里那张图的文件 URL
private final class HistoryPreviewItem: NSObject, QLPreviewItem {
    let url: URL
    init(url: URL) { self.url = url }
    var previewItemURL: URL? { url }
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
