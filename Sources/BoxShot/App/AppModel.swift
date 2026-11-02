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

    /// 「操作完成」的提示音：开关和音效名都在设置里，调用方只管喊一声。
    /// 散落在各控制器里的 `if prefs.playSound { … }` 就是为了这点事，
    /// 集中之后改提示音只要动这里一处。
    func playFeedbackSound() {
        guard prefs.value.playSound else { return }
        Support.playFeedbackSound(named: prefs.value.feedbackSound)
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
        // 万一上一块遮罩还挂着（上一次截图被别的东西打断了），这里主动收掉，
        // 否则新遮罩会叠在旧遮罩上 —— 点哪儿都没反应，看着像"截图功能坏了"。
        discardActiveSelector()
        pendingCopyDirectly = copyDirectly
        pendingPipeline = pipeline
        regionMode = .capture

        let selector = RegionSelector()
        selector.delegate = self
        regionSelector = selector
        // 🔴 windowPickMode 以前是**只进不出**的参数：接进来了却没人用，
        // 于是「窗口截图」跟「开始截图」一模一样 —— 除非用户在设置里碰巧
        // 开了窗口高亮，否则点窗口根本没有高亮可点，等于这个动作不存在。
        // 窗口模式必须强制高亮，并且不要十字线（要的是"点窗口"，不是"拉框"）。
        selector.begin(highlightWindows: windowPickMode || prefs.value.windowHighlight,
                       crosshair: windowPickMode ? false : prefs.value.showCrosshair,
                       // 窗口模式是"点窗口"，放大镜会正好盖住要点的标题栏，不给
                       loupe: windowPickMode ? nil : Loupe.Config(prefs.value),
                       // 但窗口模式**要底图**：瞬态弹窗（Edge 的「扫描 QR 码」这类）
                       // 会在遮罩弹出的一瞬间自己关掉，那时 SCK 已经查不到它了，
                       // 只能靠这张"点选那一刻"的整屏图按窗口框裁一块顶上。
                       needBackdrop: windowPickMode)
    }

    /// 诊断用：选区遮罩是不是还开着（--esctest 拿它判断 Esc 到底生效没有）
    var isRegionSelectorActive: Bool { regionSelector?.isActive ?? false }

    /// 诊断用：拿当前遮罩的底图按全局矩形裁一块（--wintest 验坐标换算）
    func diagnosticBackdropCrop(globalRect: CGRect) -> CGImage? {
        regionSelector?.cropBackdrop(globalRect: globalRect)
    }

    /// 诊断用：伪造一次"点选了这个窗口"，把**窗口已关闭的兜底路径**真跑一遍。
    /// 传一个不存在的 windowID，SCK 必然查不到 → 只能走底图裁剪。
    @discardableResult
    func diagnosticSimulateWindowConfirm(windowID: CGWindowID, frame: CGRect) -> Bool {
        guard let selector = regionSelector else { return false }
        let display = selector.currentDisplayID
        selector.finishForDiagnostics()
        let fake = ScreenWindowInfo(windowID: windowID, frame: frame,
                                    ownerName: "诊断", title: "已关闭的假窗口")
        regionSelector(selector, didConfirmWindow: fake, displayID: display)
        return true
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
    ///
    /// 🔴 这里**不播提示音**（1.0.9 用户口径）。"截图完成"指的是这件事有了结果：
    /// OCR 出字、识别码出内容、复制进剪贴板、保存成文件。只是把画面抓下来、
    /// 弹出个空浮层不算完成 —— 以前一抓就响，等于每张图都先响一次，
    /// 后面复制/保存又响一次，用户听到的是一串莫名其妙的叮叮声。
    private func routeCapturedImage(_ image: CGImage, overlayFrame frame: CGRect? = nil,
                                    fullDisplay: OverlayEditorController.FullDisplay? = nil) {
        // 历史先记：不管后面是弹浮层还是直接复制，这张图都得留痕
        ShotHistoryStore.shared.record(image, limit: prefs.value.maxShotHistory)
        switch pendingPipeline {
        case .editor:
            // "截图后弹出标注浮层"关掉时 = 直接复制到剪贴板，不弹任何界面
            // （这也是"完成"的一种，所以要响）
            if pendingCopyDirectly || !prefs.value.openEditorAfterShot {
                Support.copyImageToClipboard(image)
                playFeedbackSound()
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
        playFeedbackSound()
        controller.show(kind: .text(text), copied: true)
    }

    /// 解码。`completion` 回传结果，让浮层能就地闪一句「已复制 / 没认出来」——
    /// 用户点完按钮必须**当场**看见反馈，不能只靠一个可能被盖住的窗口。
    func runQR(image: CGImage, completion: (([String]) -> Void)? = nil) {
        Task { @MainActor in
            do {
                let payloads = try await OCREngine.decodeBarcodes(in: image)
                guard let first = payloads.first else {
                    completion?([])
                    // 🔴 这里原来是 `presentError`（NSAlert.runModal）：浮层还在屏幕上，
                    // 模态框既可能被挡、又把交互卡住，观感就是"点了没反应"。
                    // 改成开结果窗（已提到浮层之上）说清楚"没认出来"。
                    let empty = resultWindow ?? ResultWindowController()
                    resultWindow = empty
                    empty.show(kind: .text("没有识别到 QR / 条形码\n\n可以试着把码截大一点，\n或者确认码没有被遮挡。"),
                               copied: false)
                    return
                }
                Support.copyTextToClipboard(payloads.joined(separator: "\n"))
                playFeedbackSound()
                completion?(payloads)
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
            playFeedbackSound()
        } else {
            presentError("剪贴板里没有可贴图的内容（支持图片 / 文本 / HTML）")
        }
    }

    func pinImage(_ image: CGImage) {
        pinManager.pinImage(image, opacity: prefs.value.pinOpacity, shadow: prefs.value.pinShadow)
    }

    func pinFile(at url: URL) {
        if pinManager.pinFile(at: url, opacity: prefs.value.pinOpacity, shadow: prefs.value.pinShadow) {
            playFeedbackSound()
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
        // 滚动截图/录制用不到取色，不抓底图（省一次整屏截图的 ~100ms）
        selector.begin(highlightWindows: false, crosshair: true, loupe: nil)
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
            selector.begin(highlightWindows: false, crosshair: true, loupe: nil)
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
        releaseSelector(selector)
    }

    /// 内部可见：诊断入口（--scrolltest）要直接开一次滚动截图
    func beginScrollCapture(displayID: CGDirectDisplayID, region: CGRect) {
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
            var image: CGImage?
            do {
                image = try await ScreenCapture.captureWindow(window)
            } catch {
                // 🔴 窗口可能在遮罩弹出的一瞬间自己关掉：Edge「扫描 QR 码」这种瞬态面板
                // 在应用失焦时会自行消失（我们一 NSApp.activate 它就没了），
                // 之后按 windowID 去 SCK 查必然找不到 → 「目标窗口已关闭或不可截取」。
                // 遮罩出现**之前**我们抓过一张整屏底图，那一刻窗口还在，按它的框裁一块，
                // 用户拿到的正是点选时看到的画面 —— 比弹个错误有用得多。
                if let fallback = selector.cropBackdrop(globalRect: window.frame) {
                    NSLog("[BoxShot] 窗口 %u（%@）已不可截取，改用底图裁剪 %dx%d",
                          window.windowID, window.ownerName, fallback.width, fallback.height)
                    image = fallback
                } else {
                    self.presentError("窗口截图失败：\(error.localizedDescription)")
                }
            }
            guard let image else { return }

            // 窗口截图同样原位钉住（框 = 窗口框）
            let frame = ScreenCapture.appKitFrame(fromGlobalTopLeft: window.frame)

            // 🔴 窗口截图以前**不带整屏原图**，两个毛病一起冒：
            //   1. canResize = false → 截图框拖不动（用户："也可以调整大小"）；
            //   2. 浮层窗口 = 窗口框 + 上下留白，框一高就顶出屏幕，AppKit 的
            //      constrainFrameRect 会把整个窗口往下推，图跟着错位
            //      （用户："自动捕捉大窗口时，截图框不要移动"）。
            // 现在给它一份 FullDisplay：裁切基准 = 窗口图 + 窗口框（扩不出去，
            // 因为 commitResize 会 intersection 到这个框），浮层铺满整块屏幕。
            let displayFrame = ScreenCapture.appKitFrame(
                fromGlobalTopLeft: ScreenCapture.displayBoundsGlobal(displayID))
            let scale = CGFloat(image.width) / max(1, frame.width)
            let full = OverlayEditorController.FullDisplay(image: image,
                                                           frameAppKit: frame,
                                                           pixelScale: scale,
                                                           panelFrameAppKit: displayFrame)
            self.routeCapturedImage(image, overlayFrame: frame, fullDisplay: full)
        }
        releaseSelector(selector)
    }

    func regionSelectorDidCancel(_ selector: RegionSelector) {
        // 遮罩已经在 cancel() 里收掉了，这里只放引用。
        // 🔴 推迟一轮 runloop：这次取消是从遮罩自己的 keyDown 里调进来的，
        // 当场把 selector 析构掉，等于在自己的方法栈上自杀。
        releaseSelector(selector)
    }

    /// 延后清掉选区遮罩的强引用（原因见上）
    private func releaseSelector(_ selector: RegionSelector) {
        DispatchQueue.main.async { [weak self, weak selector] in
            guard let self, let selector, self.regionSelector === selector else { return }
            self.regionSelector = nil
        }
    }
}
