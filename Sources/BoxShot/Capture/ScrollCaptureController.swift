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
    /// 成功拼进来的段数（frameCount 也算失败帧，别拿它当段数用）
    private var segmentCount = 0
    /// 连续失败次数：≥3 就把基准换成当前帧重新开始，绝不让自己卡死
    private var consecutiveFailures = 0
    private var lastGrabAt = Date.distantPast
    /// 抓帧节流：滚动过程中最多每 0.2s 抓一帧。
    /// 🔴 只等"停手后抓一帧"是不够的：一次快速滑动就能滚掉一屏多，
    /// 两帧重叠不足就没法对齐，而一旦对不上、基准又不动，后面全废
    /// （用户实测症状就是"只截了一次"）。边滚边抓，步子才小。
    private let grabThrottle: TimeInterval = 0.2
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

    /// 取景框面板的矩形（AppKit 坐标）：选区四周各留 2px 画边框，上方留一条状态带。
    /// 选区本身必须完全落在面板的**透明区域**里，不能有任何绘制。
    static func panelRect(forRegion region: NSRect,
                          band: CGFloat = ScrollFrameView.bandHeight) -> NSRect {
        NSRect(x: region.minX - 2, y: region.minY - 2,
               width: region.width + 4, height: region.height + band + 4)
    }

    private func showFrame() {
        let region = selectionFrameAppKit
        // 🔴 面板比选区**大一圈**：左边/右边/下边各多 2px，上方多出一条状态带。
        // 选区内部必须完全透明 —— 见 ScrollFrameView.draw 的注释。
        let panel = NSPanel(contentRect: Self.panelRect(forRegion: region),
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
        segmentCount = 0
        consecutiveFailures = 0
        lastGrabAt = .distantPast
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
        // 滚动过程中就抓（节流），别等停手 —— 见 grabThrottle 的注释
        if Date().timeIntervalSince(lastGrabAt) >= grabThrottle {
            grabOrQueue()
        }
        // 尾部补一帧：确保最后停下来的那个位置一定被截到
        scrollDebounce?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.grabOrQueue() }
        scrollDebounce = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: item)
    }

    private func grabOrQueue() {
        guard isRunning else { return }
        if isBusy { pendingGrab = true } else { grabFrame() }
    }

    private func grabFrame() {
        guard isRunning, !isBusy else { return }
        isBusy = true
        lastGrabAt = Date()
        let displayID = self.displayID
        let region = self.region
        Task.detached(priority: .userInitiated) { [weak self] in
            let frame: CGImage?
            do {
                // 保险而已：真正的保证是取景框不在选区里画任何东西。
                // 别指望这个 excluding 能把本应用的面板剔掉（见 ScreenCapture 的注释）。
                frame = try await ScreenCapture.captureRegion(displayID: displayID, rect: region,
                                                              excludingOwnWindows: true)
            } catch {
                frame = nil
            }
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.handleFrame(frame)
                self.isBusy = false
                // 忙的时候用户又滚了 → 补一帧，保证滚动结果不丢
                if self.pendingGrab {
                    self.pendingGrab = false
                    self.grabFrame()
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
            segmentCount = 1
            frameView?.status = "已捕获 1 段，滚动页面继续"
            return
        }

        let isHorizontal = direction == 1
        var alignment: ImageStitch.Alignment?
        if isHorizontal {
            if let a = ImageStitch.rotate90(current), let b = ImageStitch.rotate90(frame) {
                alignment = ImageStitch.align(top: a, bottom: b, hint: lastOffset)
            }
        } else {
            alignment = ImageStitch.align(top: current, bottom: frame, hint: lastOffset)
        }

        guard let alignment else {
            handleFailure(frame: frame, current: current)
            return
        }

        // ── 拼接：累积图按偏移追加当前帧 ──
        var stitched: CGImage?
        if isHorizontal {
            if let acc = ImageStitch.rotate90(canvas),
               let b = ImageStitch.rotate90(frame),
               let joined = ImageStitch.append(bottom: b, to: acc, offset: alignment.offset) {
                stitched = rotateBack(joined)
            }
        } else {
            stitched = ImageStitch.append(bottom: frame, to: canvas, offset: alignment.offset)
        }

        guard let stitched else {
            frameView?.status = "拼接失败（图太长？），点 ✓ 先保存已截部分"
            return
        }
        accumulated = stitched
        lastFrame = frame
        lastOffset = alignment.offset
        consecutiveFailures = 0
        segmentCount += 1
        frameView?.status = "已捕获 \(segmentCount) 段 · 本段 +\(alignment.offset)px"
    }

    /// 这一帧没对上：先判是不是"往回滚"，再决定要不要重设基准。
    ///
    /// 🔴 绝不能只留一句提示然后原地等 —— 基准不动，用户再往下滚只会离它更远，
    /// 于是每一帧都失败，看着就像"只截了一次，之后怎么滚都不动"。
    private func handleFailure(frame: CGImage, current: CGImage) {
        consecutiveFailures += 1

        // 把当前帧当 top、上一帧当 bottom 反着对一次：能对上说明用户往回滚了
        let backward = ImageStitch.align(top: frame, bottom: current)
        if let backward {
            // 往回滚不需要重设基准：用户再往下滚回来就能继续
            frameView?.status = "往回滚了 \(backward.offset)px（往回的部分不拼），继续往下滚"
            return
        }

        if consecutiveFailures >= 3 {
            // 连续对不上（滚太快 / 页面自己变了）：换基准继续，别把整个流程卡死。
            // 代价是被跳过的内容不会出现在图里 —— 状态条上明说。
            lastFrame = frame
            lastOffset = nil
            consecutiveFailures = 0
            frameView?.status = "内容跳变，已跳过一段从当前画面继续（中间可能有缺口）"
            return
        }

        frameView?.status = "这一帧没对上（滚太快 / 页面在动），小步滚动试试"
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

// ── 取景框视图：只画选区外侧的边框 + 上方状态带 ──────────────
//
// 🔴 选区内部一个像素都不能画。
//
// 1.0.5 的教训：原来框里画着实时拼接预览，指望用
// `SCContentFilter(display:excludingWindows:)` 把自己这个面板从抓帧里剔掉。
// 实测无效 —— 面板在 `.floating` / `.statusBar` 层，而 `SCShareableContent.windows`
// 基本只给 layer-0 的普通窗口，按 pid 过滤出来是**空数组**，excluding 成了空操作。
// 结果每帧拍到的都是"上一帧的预览"（连状态胶囊都烧进画面），第一段之后永远对不上，
// 用户看到的症状就是"只截了一次"。
//
// 现在不依赖那个 API：面板做大一圈，把边框和状态条都放到选区**外面**，
// 选区内部保持全透明 —— 抓帧拿到的就是干净的页面内容。顺带的好处是
// 用户能看见页面在滚动，不再对着一帧冻结的图猜"到底截没截上"。

final class ScrollFrameView: NSView {

    weak var controller: ScrollCaptureController?

    /// 选区上方的状态带高度（状态条画在这里）
    static let bandHeight: CGFloat = 30

    var status: String = "正在捕获…" {
        didSet { needsDisplay = true }
    }

    override var isFlipped: Bool { true }

    /// 选区（要被截进画面的那块）在本视图里的位置
    var regionRect: CGRect {
        CGRect(x: 2, y: Self.bandHeight + 2,
               width: max(0, bounds.width - 4),
               height: max(0, bounds.height - Self.bandHeight - 4))
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        // 边框：四条**实心**细条，全部画在选区外侧。
        // 不用 stroke（2pt 描边居中，一半会压进选区，最终图片边缘多一条蓝线），
        // 也不用 fill + clear（万一视图被 layer 化，clear 擦不穿，整块会糊住选区）。
        let r = regionRect
        ctx.setFillColor(NSColor.controlAccentColor.cgColor)
        ctx.fill(CGRect(x: 0, y: r.minY - 2, width: bounds.width, height: 2))       // 上
        ctx.fill(CGRect(x: 0, y: r.maxY, width: bounds.width, height: 2))           // 下
        ctx.fill(CGRect(x: 0, y: r.minY, width: 2, height: r.height))               // 左
        ctx.fill(CGRect(x: bounds.width - 2, y: r.minY, width: 2, height: r.height))// 右

        // 状态条：画在上方留白带里
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: NSColor.white,
        ]
        let text = status
        let size = (text as NSString).size(withAttributes: attributes)
        let barRect = CGRect(x: 2, y: 3,
                             width: min(size.width + 20, bounds.width - 4),
                             height: Self.bandHeight - 6)
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.78).cgColor)
        ctx.addPath(CGPath(roundedRect: barRect, cornerWidth: 6, cornerHeight: 6, transform: nil))
        ctx.fillPath()
        ctx.saveGState()
        ctx.clip(to: barRect)
        (text as NSString).draw(at: CGPoint(x: barRect.minX + 10, y: barRect.minY + 4),
                                withAttributes: attributes)
        ctx.restoreGState()
    }
}
