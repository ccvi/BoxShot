import AppKit
import Combine
import Foundation
import ScreenCaptureKit

// ============================================================
// 状态中枢：把菜单 / 热键 / 设置 接到各个功能控制器上
// ============================================================

@MainActor
final class AppModel: ObservableObject {

    let prefs: PreferencesStore

    // 功能控制器（懒建：只有真的用到才创建窗口/流）
    private var regionSelector: RegionSelector?
    private var editorController: EditorWindowController?   // 独立编辑窗口（滚动截图结果等）
    var overlayEditor: OverlayEditorController?             // 原位钉住浮层（区域/全屏/窗口截图）
    private var measureOverlay: MeasureOverlay?
    private var scrollController: ScrollCaptureController?
    private var recordToolbar: RecordToolbarController?
    let pinManager = PinManager()
    private var resultWindow: ResultWindowController?
    private var historyWindow: HistoryWindowController?

    /// 录制中状态（状态栏菜单显示"停止录制"）
    @Published private(set) var isRecording = false

    /// 上一次注册全局热键时被系统拒掉的键位。
    /// 🔴 这个必须能被界面看到：注册失败以前只 NSLog，用户在设置里录了个
    /// 纯字母键，看着"设置成功了"，实际一次都不会触发 —— 这就是"快捷键不可用"。
    @Published private(set) var failedShortcuts: [KeySpec] = []

    init(prefs store: PreferencesStore? = nil) {
        let resolved = store ?? MainActor.assumeIsolated { PreferencesStore() }
        self.prefs = resolved
        resolved.didChange = { [weak self] old, new in
            self?.applyPreferenceChanges(old: old, new: new)
        }
    }

    func bootstrap() {
        pinManager.restoreHistory(limit: prefs.value.maxPinHistory)
    }

    func shutdown() {
        recordToolbar?.close(stopRecording: true)
    }

    // ── 动作路由 ─────────────────────────────────────────────

    func perform(_ action: ShotAction) {
        switch action {
        case .regionShot:
            startRegionShot(copyDirectly: false)
        case .regionCopy:
            startRegionShot(copyDirectly: true)
        case .fullscreenShot:
            shotFullscreen(copyDirectly: false)
        case .windowShot:
            startRegionShot(copyDirectly: false, windowPickMode: true)
        case .captureLastRegion:
            repeatLastRegionShot()
        case .scrollShot:
            startScrollShot()
        case .ocrShot:
            startRegionShot(copyDirectly: false, pipeline: .ocr)
        case .decodeQR:
            startRegionShot(copyDirectly: false, pipeline: .qr)
        case .measure:
            startMeasure()
        case .recordRegion:
            startRecording(fullscreen: false)
        case .recordFullscreen:
            startRecording(fullscreen: true)
        case .pinClipboard:
            pinFromClipboard()
        case .openSettings:
            onRequestShowSettings?()
        }
    }

    var onRequestShowSettings: (() -> Void)?

    func registerGlobalHotKeys() {
        var entries: [(KeySpec, @MainActor () -> Void)] = []
        for action in ShotAction.allCases {
            guard let spec = prefs.value.spec(for: action) else { continue }
            entries.append((spec, { [weak self] in self?.perform(action) }))
        }
        let failed = HotKeyCenter.shared.replaceAll(with: entries)
        failedShortcuts = failed
        if !failed.isEmpty {
            NSLog("[BoxShot] 热键注册失败：\(failed.map(\.display).joined(separator: ", "))")
        }
    }

    private func applyPreferenceChanges(old: Preferences, new: Preferences) {
        if old.shortcuts != new.shortcuts {
            registerGlobalHotKeys()
        }
        if old.launchAtLogin != new.launchAtLogin {
            try? LoginItem.setEnabled(new.launchAtLogin)
        }
        if old.hideDockIcon != new.hideDockIcon {
            NSApp.setActivationPolicy(new.hideDockIcon ? .accessory : .regular)
        }
    }

    // ── 截图管线 ─────────────────────────────────────────────

    private enum Pipeline {
        case editor
        case ocr
        case qr
    }

    /// 选区结果的用途：截成图 / 作为录制区域 / 作为滚动截图的取景框
    private enum RegionMode {
        case capture
        case record
        case scroll
    }

    private var pendingCopyDirectly = false
    private var pendingPipeline: Pipeline = .editor
    private var regionMode: RegionMode = .capture

    /// 上一次成功截图的区域（"重复上次区域截图"用）
    private(set) var lastRegionShot: (region: CGRect, displayID: CGDirectDisplayID)?

    /// 用上次的区域再截一次（不重新选区）
    private func repeatLastRegionShot() {
        guard let last = lastRegionShot else { return }
        guard ScreenCapture.ensurePermission() else { return }
        pendingCopyDirectly = false
        pendingPipeline = .editor
        Task { @MainActor in
            await self.captureAndRoute(displayID: last.displayID, region: last.region)
        }
    }

    private func startRegionShot(copyDirectly: Bool, windowPickMode: Bool = false, pipeline: Pipeline = .editor) {
        guard ScreenCapture.ensurePermission() else { return }
        // 已经有编辑器开着时先收掉，避免同时改两张图
        guard editorController == nil || !editorController!.isVisible else { return }
        // Esc 不再负责退出选区遮罩了，万一上一块遮罩还挂着，这里主动收掉，
        // 否则新遮罩会叠在旧遮罩上（点哪儿都没反应）。
        discardActiveSelector()
        pendingCopyDirectly = copyDirectly
        pendingPipeline = pipeline
        regionMode = .capture

        let selector = RegionSelector()
        selector.delegate = self
        regionSelector = selector
        selector.begin(highlightWindows: prefs.value.windowHighlight,
                       crosshair: prefs.value.showCrosshair)
    }

    /// 收掉可能还留在屏上的选区遮罩（重复触发截图/录制时用）
    private func discardActiveSelector() {
        guard let selector = regionSelector else { return }
        regionSelector = nil
        if selector.isActive { selector.cancel() }
    }

    private func shotFullscreen(copyDirectly: Bool) {
        guard ScreenCapture.ensurePermission() else { return }
        pendingCopyDirectly = copyDirectly
        pendingPipeline = .editor
        let displayID = ScreenCapture.display(for: ScreenCapture.activeScreen())
        Task { @MainActor in
            await self.captureAndRoute(displayID: displayID, region: nil)
        }
    }

    private func captureAndRoute(displayID: CGDirectDisplayID, region: CGRect?) async {
        do {
            var image: CGImage
            if let region {
                image = try await ScreenCapture.captureRegion(displayID: displayID, rect: region)
                lastRegionShot = (region, displayID)
            } else {
                image = try await ScreenCapture.captureDisplay(displayID)
            }
            // "Retina 缩小到 1x"：输出前把 2x 图缩回逻辑尺寸（文件更小、跨平台 1:1）
            if prefs.value.downscaleRetina, ScreenCapture.scaleFactor(for: displayID) > 1,
               let scaled = Support.downscaleTo1x(image) {
                image = scaled
            }
            // 选区框在屏幕上的位置（AppKit 坐标），供原位浮层钉在原地
            let frame: CGRect?
            if let region {
                frame = ScreenCapture.appKitFrame(
                    fromGlobalTopLeft: ScreenCapture.globalTopLeftRect(fromDisplayLocal: region, displayID: displayID))
            } else {
                frame = ScreenCapture.appKitFrame(
                    fromGlobalTopLeft: ScreenCapture.displayBoundsGlobal(displayID))
            }
            // 🔴 区域截图额外留一张**整屏原图**：标注浮层要靠它支持"随时把截图框
            // 拉大"（扩出去的那块必须是当初那一帧，不能重新截——重新截会拍到我们
            // 自己的浮层，内容也可能已经变了）。没拿到也不影响主流程，只是不能扩。
            var fullDisplay: OverlayEditorController.FullDisplay?
            if let region, let frame {
                if let full = try? await ScreenCapture.captureDisplay(displayID) {
                    fullDisplay = OverlayEditorController.FullDisplay(
                        image: full,
                        frameAppKit: ScreenCapture.appKitFrame(
                            fromGlobalTopLeft: ScreenCapture.displayBoundsGlobal(displayID)),
                        pixelScale: CGFloat(full.width) / max(1, ScreenCapture.displayBoundsGlobal(displayID).width))
                }
                _ = frame
            }
            routeCapturedImage(image, overlayFrame: frame, fullDisplay: fullDisplay)
        } catch {
            presentError("截图失败：\(error.localizedDescription)")
        }
    }

    /// 截好的图按 pending 设定分流：直接复制 / OCR / QR / 原位浮层
    private func routeCapturedImage(_ image: CGImage, overlayFrame frame: CGRect? = nil,
                                    fullDisplay: OverlayEditorController.FullDisplay? = nil) {
        if prefs.value.playSound { Support.playFeedbackSound() }
        // 历史先记：不管后面是弹浮层还是直接复制，这张图都得留痕
        ShotHistoryStore.shared.record(image, limit: prefs.value.maxShotHistory)
        switch pendingPipeline {
        case .editor:
            // "截图后弹出标注浮层"关掉时 = 直接复制到剪贴板，不弹任何界面
            if pendingCopyDirectly || !prefs.value.openEditorAfterShot {
                Support.copyImageToClipboard(image)
            } else if let frame {
                openOverlayEditor(image: image, frame: frame, fullDisplay: fullDisplay)
            } else {
                openEditor(image: image)
            }
        case .ocr:
            runOCR(image: image)
        case .qr:
            runQR(image: image)
        }
    }

    func presentError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.runModal()
    }

    // ── 编辑器 ──────────────────────────────────────────────

    /// 原位钉住浮层（区域/全屏/窗口截图的默认标注界面）
    /// shapes 用于裁剪后重开：把已有标注带进新尺寸的文档里
    func openOverlayEditor(image: CGImage, frame: CGRect,
                           fullDisplay: OverlayEditorController.FullDisplay? = nil,
                           shapes: [AnnotationShape] = []) {
        let controller = OverlayEditorController(model: self, image: image,
                                                 selectionFrameAppKit: frame,
                                                 fullDisplay: fullDisplay,
                                                 shapes: shapes)
        overlayEditor = controller
        controller.onClose = { [weak self, weak controller] in
            if let controller, self?.overlayEditor === controller {
                self?.overlayEditor = nil
            }
        }
        controller.show()
    }

    /// 独立编辑窗口（滚动截图等不适合原位 1:1 显示的结果）
    func openEditor(image: CGImage) {
        let controller = EditorWindowController(model: self)
        editorController = controller
        controller.show(image: image)
    }

    func editorDidClose(_ controller: EditorWindowController) {
        if editorController === controller { editorController = nil }
    }

    // ── 截图历史 ────────────────────────────────────────────

    func showShotHistory() {
        let controller = historyWindow ?? HistoryWindowController(model: self)
        historyWindow = controller
        controller.show()
    }

    // ── OCR / QR ────────────────────────────────────────────

    func runOCR(image: CGImage) {
        Task { @MainActor in
            do {
                let text = try await OCREngine.recognizeText(in: image,
                                                             keepLineBreaks: prefs.value.ocrKeepLineBreaks,
                                                             lineOverlap: prefs.value.ocrLineOverlap)
                appendOCRResult(text)
            } catch {
                presentError("OCR 识别失败：\(error.localizedDescription)")
            }
        }
    }

    private func appendOCRResult(_ text: String) {
        // 结果窗口始终复用同一个（新结果替换旧内容），连续识别不丢上一段
        let controller = resultWindow ?? ResultWindowController()
        resultWindow = controller
        guard !text.isEmpty else {
            controller.show(kind: .text("（没有识别到文字）"), copied: false)
            return
        }
        if prefs.value.ocrIncremental {
            let existing = NSPasteboard.general.string(forType: .string) ?? ""
            Support.copyTextToClipboard(existing.isEmpty ? text : existing + "\n" + text)
        } else {
            Support.copyTextToClipboard(text)
        }
        if prefs.value.playSound { Support.playFeedbackSound() }
        controller.show(kind: .text(text), copied: true)
    }

    func runQR(image: CGImage) {
        Task { @MainActor in
            do {
                let payloads = try await OCREngine.decodeBarcodes(in: image)
                guard let first = payloads.first else {
                    presentError("没有识别到 QR / 条形码")
                    return
                }
                Support.copyTextToClipboard(payloads.joined(separator: "\n"))
                if prefs.value.playSound { Support.playFeedbackSound() }
                if prefs.value.ocrAutoOpenLink,
                   first.lowercased().hasPrefix("http://") || first.lowercased().hasPrefix("https://"),
                   let url = URL(string: first) {
                    NSWorkspace.shared.open(url)
                }
                let controller = resultWindow ?? ResultWindowController()
                resultWindow = controller
                controller.show(kind: .payloads(payloads), copied: true)
            } catch {
                presentError("解码失败：\(error.localizedDescription)")
            }
        }
    }

    // ── 贴图 ────────────────────────────────────────────────

    func pinFromClipboard() {
        if pinManager.pinFromClipboard(opacity: prefs.value.pinOpacity, shadow: prefs.value.pinShadow) {
            if prefs.value.playSound { Support.playFeedbackSound() }
        } else {
            presentError("剪贴板里没有可贴图的内容（支持图片 / 文本 / HTML）")
        }
    }

    func pinImage(_ image: CGImage) {
        pinManager.pinImage(image, opacity: prefs.value.pinOpacity, shadow: prefs.value.pinShadow)
    }

    func pinFile(at url: URL) {
        if pinManager.pinFile(at: url, opacity: prefs.value.pinOpacity, shadow: prefs.value.pinShadow) {
            if prefs.value.playSound { Support.playFeedbackSound() }
        } else {
            presentError("这个文件贴不了图（支持图片 / 文本 / HTML）")
        }
    }

    func toggleAllPins() {
        pinManager.toggleAllVisible()
    }

    func closeAllPins() {
        pinManager.closeAll()
    }

    func pinFromFinder() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "选择要贴图的图片 / 文本 / HTML 文件"
        if panel.runModal() == .OK, let url = panel.url {
            pinFile(at: url)
        }
    }

    // ── 屏幕测量 ────────────────────────────────────────────

    private func startMeasure() {
        guard measureOverlay == nil else { return }
        let overlay = MeasureOverlay()
        overlay.showTips = prefs.value.measureShowTips
        overlay.onFinish = { [weak self] _, _ in }
        measureOverlay = overlay
        overlay.begin()
    }

    // ── 滚动截图 ────────────────────────────────────────────

    private func startScrollShot() {
        guard ScreenCapture.ensurePermission() else { return }
        guard scrollController == nil else { return }
        discardActiveSelector()
        regionMode = .scroll
        let selector = RegionSelector()
        selector.delegate = self
        regionSelector = selector
        selector.begin(highlightWindows: false, crosshair: true)
    }

    // ── 录制 ────────────────────────────────────────────────

    /// 区域/全屏录制统一走"截图条式"工具条：
    /// 区域模式选区后虚线框钉住；全屏模式直接出工具条，按"记录"才真正开录。
    private func startRecording(fullscreen: Bool) {
        guard ScreenCapture.ensurePermission() else { return }
        if let existing = recordToolbar {
            // 已经有一根工具条：录制中 = 菜单项就是"停止"；
            // 没在录 = 先把它收掉，然后照常重新选区，而不是什么都不做。
            // 🔴 以前这里无条件 `return`，只要工具条还挂着（哪怕已经点过 ✕，
            // 收尾延后一秒），再点「区域录制」就完全没反应 —— 这就是"点击录制不了"。
            let wasRecording = isRecording
            existing.close(stopRecording: true)
            if wasRecording { return }
        }
        let displayID = ScreenCapture.display(for: ScreenCapture.activeScreen())
        if fullscreen {
            discardActiveSelector()
            showRecordToolbar(displayID: displayID, region: nil)
        } else {
            discardActiveSelector()
            regionMode = .record
            let selector = RegionSelector()
            selector.delegate = self
            regionSelector = selector
            selector.begin(highlightWindows: false, crosshair: true)
        }
    }

    private func showRecordToolbar(displayID: CGDirectDisplayID, region: CGRect?) {
        let controller = RecordToolbarController(model: self)
        recordToolbar = controller
        controller.onClosed = { [weak self, weak controller] in
            if let controller, self?.recordToolbar === controller {
                self?.recordToolbar = nil
            }
        }
        controller.onRecordingChange = { [weak self] recording in
            self?.isRecording = recording
        }
        controller.begin(displayID: displayID, region: region)
    }

    func toggleRecording() {
        if isRecording {
            recordToolbar?.close(stopRecording: true)
        } else {
            startRecording(fullscreen: false)
        }
    }
}

// ── 选区结果承接 ─────────────────────────────────────────────

extension AppModel: RegionSelectionDelegate {

    func regionSelector(_ selector: RegionSelector, didConfirmRegion rect: CGRect, displayID: CGDirectDisplayID) {
        switch regionMode {
        case .capture:
            Task { @MainActor in
                await self.captureAndRoute(displayID: displayID, region: rect)
            }
        case .record:
            regionMode = .capture
            showRecordToolbar(displayID: displayID, region: rect)
        case .scroll:
            regionMode = .capture
            beginScrollCapture(displayID: displayID, region: rect)
        }
    }

    private func beginScrollCapture(displayID: CGDirectDisplayID, region: CGRect) {
        let controller = ScrollCaptureController(model: self)
        scrollController = controller
        controller.onFinish = { [weak self] image in
            if let image { self?.openEditor(image: image) }
        }
        controller.onClosed = { [weak self] in
            self?.scrollController = nil
        }
        controller.begin(displayID: displayID, region: region)
    }

    func regionSelector(_ selector: RegionSelector, didConfirmWindow window: ScreenWindowInfo, displayID: CGDirectDisplayID) {
        Task { @MainActor in
            do {
                let image = try await ScreenCapture.captureWindow(window)
                // 窗口截图同样原位钉住（框 = 窗口框）
                let frame = ScreenCapture.appKitFrame(fromGlobalTopLeft: window.frame)
                self.routeCapturedImage(image, overlayFrame: frame)
            } catch {
                self.presentError("窗口截图失败：\(error.localizedDescription)")
            }
        }
    }

    func regionSelectorDidCancel(_ selector: RegionSelector) {
        // 空实现：遮罩已在 cancel() 里收掉
    }
}
