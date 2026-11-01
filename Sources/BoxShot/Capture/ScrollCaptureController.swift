import AppKit
import CoreGraphics

// ============================================================
// 滚动截图（1.0.2 按用户反馈改版：滚动之后再截，不是定时截）
//
// 选好取景框后：框**原位钉住**，先抓第一帧；之后监听全局滚轮，
// 等**滚动停止约 250ms** 再抓一帧拼接（自动按滚动方向选横/竖向）。
// 下方浮动工具栏：
//   [缩略图] [✕取消] [✓完成] | [贴图] [保存] [复制]
//
// 抓帧后台串行：滚动触发时若上一帧还在处理，记下待抓标记，处理完补一帧。
// ============================================================

@MainActor
final class ScrollCaptureController: NSObject {

    var onFinish: ((CGImage?) -> Void)?
    var onClosed: (() -> Void)?

    private weak var model: AppModel?

    private var displayID: CGDirectDisplayID = 0
    private var region: CGRect = .zero          // 显示器局部坐标（点）
    private var framePanel: NSPanel?
    private var toolbarPanel: NSPanel?
    private var frameView: ScrollFrameView?
    private var direction = 0                   // 0 竖向 / 1 横向
    private var isRunning = false
    private var isBusy = false
    private var pendingGrab = false             // 忙时滚过 → 忙完补抓
    private var scrollDebounce: DispatchWorkItem?
    private var accumulated: CGImage?
    /// 上一帧原图：对齐只拿"上一帧 vs 当前帧"算。
    /// 拿整张累积图去搜索的话，累积越长搜索范围越大，越容易匹配到错误的周期上
    /// —— 而且一旦错一帧，错误就永久留在图里，后面全跟着错。
    private var lastFrame: CGImage?
    private var lastOffset: Int?
    private var frameCount = 0
    private var monitors: [Any] = []

    init(model: AppModel?) {
        self.model = model
    }

    func begin(displayID: CGDirectDisplayID, region: CGRect) {
        self.displayID = displayID
        self.region = region
        showFrame()
        showToolbar()
        startCapturing()
    }

    // 选区框在 AppKit 坐标系里的位置（点）
    private var selectionFrameAppKit: CGRect {
        let globalTopLeft = ScreenCapture.globalTopLeftRect(fromDisplayLocal: region, displayID: displayID)
        return ScreenCapture.appKitFrame(fromGlobalTopLeft: globalTopLeft)
    }

    // ── 钉住的取景框 ────────────────────────────────────────

    private func showFrame() {
        let frame = selectionFrameAppKit
        let panel = NSPanel(contentRect: frame,
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let view = ScrollFrameView()
        view.controller = self
        panel.contentView = view
        frameView = view
        framePanel = panel
        panel.makeKeyAndOrderFront(nil)
    }

    // ── 工具栏 ──────────────────────────────────────────────

    private func showToolbar() {
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 10, bottom: 8, right: 10)

        func add(_ symbol: String, _ title: String, tint: NSColor? = nil, action: Selector? = nil) -> NSButton {
            let button = NSButton(title: "", target: self,
                                  action: action ?? #selector(toolbarAction(_:)))
            button.bezelStyle = .regularSquare
            button.isBordered = false
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)?
                .withSymbolConfiguration(.init(pointSize: 16, weight: .medium))
            button.frame = NSRect(x: 0, y: 0, width: 38, height: 32)
            button.toolTip = title
            button.contentTintColor = tint
            button.tag = Self.buttonTag(title)
            stack.addArrangedSubview(button)
            return button
        }

        add("photo.on.rectangle", "缩略图", tint: .white, action: #selector(showThumbnail))
        add("xmark", "取消", tint: .systemRed)
        add("checkmark", "完成", tint: .systemGreen)
        stack.addArrangedSubview(makeDivider())
        add("pin", "贴图")
        add("arrow.down.circle", "保存")
        add("doc.on.doc", "复制")

        stack.layoutSubtreeIfNeeded()
        let size = stack.fittingSize
        let container = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        container.material = .hudWindow
        container.state = .active
        container.wantsLayer = true
        container.layer?.cornerRadius = 10
        container.addSubview(stack)
        stack.frame = container.bounds

        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = container

        // 放取景框下方（放不下放上方），水平居中
        let frame = selectionFrameAppKit
        guard let screen = framePanel?.screen ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        let belowY = frame.minY - size.height - 10
        let y = belowY >= visible.minY + 4 ? belowY : frame.maxY + 10
        let x = min(max(frame.midX - size.width / 2, visible.minX + 4), visible.maxX - size.width - 4)
        panel.setFrameOrigin(NSPoint(x: x, y: y))

        toolbarPanel = panel
        panel.makeKeyAndOrderFront(nil)
    }

    private static func buttonTag(_ title: String) -> Int {
        switch title {
        case "缩略图": return 1
        case "取消": return 2
        case "完成": return 3
        case "贴图": return 4
        case "保存": return 5
        case "复制": return 6
        default: return 0
        }
    }

    private func makeDivider() -> NSView {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 1, height: 22))
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.separatorColor.cgColor
        return view
    }

    // ── 抓帧循环（滚动触发） ─────────────────────────────────

    private func startCapturing() {
        guard !isRunning else { return }
        isRunning = true
        accumulated = nil
        lastFrame = nil
        lastOffset = nil
        frameCount = 0
        grabFrame()
        installScrollMonitor()
        installEscMonitor()
    }

    /// 滚轮监听：全局（其他应用的内容）+ 本地（本应用窗口）各装一个，
    /// 滚轮事件不需要辅助功能授权。
    private func installScrollMonitor() {
        let note: (NSEvent) -> Void = { [weak self] event in
            self?.noteScroll(deltaX: event.deltaX, deltaY: event.deltaY)
        }
        monitors.append(NSEvent.addGlobalMonitorForEvents(matching: .scrollWheel, handler: note))
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            note(event)
            return event
        })
    }

    /// 每次滚动：按主导方向识别横/竖向，去抖 250ms 后抓帧
    private func noteScroll(deltaX: CGFloat, deltaY: CGFloat) {
        guard isRunning else { return }
        let ax = abs(deltaX), ay = abs(deltaY)
        if ax > 1 && ax > ay + 0.5 {
            if direction != 1 {
                direction = 1
                frameView?.status = "已识别横向滚动，停止滚动后拼接"
                frameView?.needsDisplay = true
            }
        } else if ay > 1 {
            if direction != 0 && frameCount > 1 {
                direction = 0
                frameView?.status = "已识别竖向滚动，停止滚动后拼接"
                frameView?.needsDisplay = true
            }
        }
        scrollDebounce?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.grabOrQueue() }
        scrollDebounce = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: item)
    }

    private func grabOrQueue() {
        guard isRunning else { return }
        if isBusy { pendingGrab = true } else { grabFrame() }
    }

    private func grabFrame() {
        guard isRunning, !isBusy else { return }
        isBusy = true
        let displayID = self.displayID
        let region = self.region
        Task.detached(priority: .userInitiated) { [weak self] in
            let frame: CGImage?
            do {
                // 🔴 必须排除自己的窗口：取景框正盖在选区上、里面还画着上一次的
                // 拼接预览，不排除就变成"每帧都在拍上一帧的预览"，拼出来全错。
                frame = try await ScreenCapture.captureRegion(displayID: displayID, rect: region,
                                                              excludingOwnWindows: true)
            } catch {
                frame = nil
            }
            await MainActor.run {
                self?.handleFrame(frame)
                self?.isBusy = false
                // 忙的时候用户又滚了 → 补一帧，保证滚动结果不丢
                if self?.pendingGrab == true {
                    self?.pendingGrab = false
                    self?.grabFrame()
                }
            }
        }
    }

    private func handleFrame(_ frame: CGImage?) {
        guard isRunning else { return }
        guard let frame else {
            frameView?.status = "抓帧失败，重试中…"
            return
        }
        defer { frameCount += 1 }

        guard let current = lastFrame, let canvas = accumulated else {
            accumulated = frame
            lastFrame = frame
            frameView?.preview = frame
            frameView?.status = "已捕获 1 段，请滚动内容"
            frameView?.needsDisplay = true
            return
        }

        // ── 对齐：只比较"上一帧 vs 当前帧" ──
        var alignment: ImageStitch.Alignment?
        if direction == 1 {
            if let a = ImageStitch.rotate90(current), let b = ImageStitch.rotate90(frame) {
                alignment = ImageStitch.align(top: a, bottom: b, hint: lastOffset)
            }
        } else {
            alignment = ImageStitch.align(top: current, bottom: frame, hint: lastOffset)
        }

        guard let alignment else {
            // 没对齐就不拼，也别动 lastFrame：下一帧拿同一张基准再比一次
            frameView?.status = "这一帧没对上（没滚 / 往回滚 / 滚过一屏），继续往下滚"
            frameView?.needsDisplay = true
            return
        }

        // ── 拼接：累积图按偏移追加当前帧 ──
        var stitched: CGImage?
        if direction == 1 {
            if let acc = ImageStitch.rotate90(canvas),
               let b = ImageStitch.rotate90(frame),
               let joined = ImageStitch.append(bottom: b, to: acc, offset: alignment.offset) {
                stitched = rotateBack(joined)
            }
        } else {
            stitched = ImageStitch.append(bottom: frame, to: canvas, offset: alignment.offset)
        }

        if let stitched {
            accumulated = stitched
            lastFrame = frame
            lastOffset = alignment.offset
            frameView?.preview = stitched
            frameView?.status = "已捕获 \(frameCount + 1) 段"
        } else {
            frameView?.status = "拼接失败（图太长？），点「完成」先保存已截部分"
        }
        frameView?.needsDisplay = true
    }

    private func rotateBack(_ image: CGImage) -> CGImage? {
        var result = image
        for _ in 0..<3 {
            guard let next = ImageStitch.rotate90(result) else { return nil }
            result = next
        }
        return result
    }

    // ── 工具栏动作 ──────────────────────────────────────────

    @objc private func toolbarAction(_ sender: NSButton) {
        switch sender.tag {
        case 2: finish(with: nil)
        case 3: finish(with: accumulated)
        case 4: pin()
        case 5: save()
        case 6: copyToClipboard()
        default: break
        }
    }

    @objc private func showThumbnail() {
        guard let image = accumulated else { return }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 560),
                              styleMask: [.titled, .closable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "滚动截图预览（\(image.width) × \(image.height)）"
        let imageView = NSImageView(frame: window.contentView!.bounds)
        imageView.image = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        imageView.autoresizingMask = [.width, .height]
        imageView.imageScaling = .scaleProportionallyUpOrDown
        window.contentView?.addSubview(imageView)
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func pin() {
        guard let image = accumulated else { return }
        model?.pinImage(image)
    }

    private func save() {
        guard let image = accumulated, let model else { return }
        let prefs = model.prefs.value
        let name = Support.shotFileName(prefix: "boxshot-scroll", ext: prefs.shotFormat.fileExtension)

        // autoSave：不再弹面板，直接落到设置目录
        if prefs.autoSave, let dirPath = prefs.saveDirectory, !dirPath.isEmpty {
            let url = Support.uniqueFileURL(in: URL(fileURLWithPath: dirPath, isDirectory: true), name: name)
            write(image: image, to: url, prefs: prefs)
            return
        }

        let panel = NSSavePanel()
        panel.nameFieldStringValue = name
        panel.allowedContentTypes = prefs.shotFormat == .png ? [.png] : [.jpeg]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        write(image: image, to: url, prefs: prefs)
    }

    private func write(image: CGImage, to url: URL, prefs: Preferences) {
        guard let data = ImageEncode.data(image, format: prefs.shotFormat, jpgQuality: prefs.jpgQuality) else {
            frameView?.status = "图片编码失败"
            frameView?.needsDisplay = true
            return
        }
        do {
            try data.write(to: url)
            frameView?.status = "已保存：\(url.lastPathComponent)"
            if prefs.playSound { Support.playFeedbackSound() }
        } catch {
            // 曾经 try? 静默吞错，写盘失败用户毫无感知
            frameView?.status = "保存失败：\(error.localizedDescription)"
        }
        frameView?.needsDisplay = true
    }

    private func copyToClipboard() {
        guard let image = accumulated else { return }
        Support.copyImageToClipboard(image)
        frameView?.status = "已复制到剪贴板"
        frameView?.needsDisplay = true
        if model?.prefs.value.playSound == true { Support.playFeedbackSound() }
    }

    private func finish(with image: CGImage?) {
        stop()
        closePanels()
        onFinish?(image)
    }

    private func stop() {
        isRunning = false
        scrollDebounce?.cancel()
        scrollDebounce = nil
        pendingGrab = false
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors.removeAll()
    }

    private func closePanels() {
        framePanel?.orderOut(nil)
        toolbarPanel?.orderOut(nil)
        framePanel = nil
        toolbarPanel = nil
        frameView = nil
        onClosed?()
    }

    private func installEscMonitor() {
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.framePanel != nil, event.keyCode == 53 else { return event }
            self.finish(with: nil)
            return nil
        })
    }
}

// ── 取景框视图：画实时拼接结果 + 状态条 ──────────────────────

final class ScrollFrameView: NSView {

    weak var controller: ScrollCaptureController?
    var preview: CGImage?
    var status: String = "正在捕获…"

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        // 实时预览：按宽度 1:1、顶部对齐；比框高就只露出上面部分
        if let preview {
            let scale = bounds.width / CGFloat(preview.width)
            let drawH = CGFloat(preview.height) * scale
            let drawRect = CGRect(x: 0, y: 0, width: bounds.width, height: drawH)
            ctx.saveGState()
            ctx.clip(to: CGRect(origin: .zero, size: bounds.size))
            ctx.translateBy(x: 0, y: drawRect.maxY)
            ctx.scaleBy(x: 1, y: -1)
            ctx.interpolationQuality = .medium
            ctx.draw(preview, in: CGRect(origin: .zero, size: drawRect.size))
            ctx.restoreGState()
        } else {
            ctx.setFillColor(NSColor.black.withAlphaComponent(0.25).cgColor)
            ctx.fill(bounds)
        }

        // 边框
        ctx.setStrokeColor(NSColor.controlAccentColor.cgColor)
        ctx.setLineWidth(2)
        ctx.stroke(bounds)

        // 顶部状态条（画在框内顶部，窗口不含框外区域）
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: NSColor.white,
        ]
        let text = status
        let size = (text as NSString).size(withAttributes: attributes)
        let barRect = CGRect(x: 0, y: 4, width: size.width + 20, height: size.height + 10)
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.75).cgColor)
        ctx.addPath(CGPath(roundedRect: barRect, cornerWidth: 6, cornerHeight: 6, transform: nil))
        ctx.fillPath()
        (text as NSString).draw(at: CGPoint(x: barRect.minX + 10, y: barRect.minY + 5),
                                withAttributes: attributes)
    }
}
