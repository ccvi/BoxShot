import AppKit
import CoreGraphics

// ============================================================
// 滚动截图（1.0.2 按用户反馈改版：滚动之后再截，不是定时截）
//
// 选好取景框后：框**原位钉住**，先抓第一帧；之后监听全局滚轮，
// 等**滚动停止约 250ms** 再抓一帧拼接（自动按滚动方向选横/竖向）。
// 下方浮动工具栏：[✕取消] [✓完成] | [贴图] [保存] [复制]
//
// 🔴 只拼"停下来"的帧（1.0.15）：滚动途中抓到的帧带着平滑滚动的
// 亚像素相位 + 运动残影，像素差天然超标，会被拼接质量门拒掉 —— 用户看到
// 的就是"明明滚得不快却老提示没对上"；更糟的是连挂 3 帧会重置基准，
// 拿运动中的帧当基准，后面拼出来全是错位。所以途中不抓帧，停稳再抓。
//
// 🔴 1.0.25 补充：**触摸板不能只等停稳**。两指一划惯性动辄滚出一两屏，
// 惯性事件源源不断把去抖一直往后推（用户看到"半天不动"），真停稳时页面
// 已经离基准一整屏开外 —— 两帧零重叠，对齐必然失败，连挂 3 次就是
// "内容跳变已跳过一段"。所以精确 delta（触摸板）按**累计滚动距离**中途
// 抓帧：每滚约 40% 框高抓一帧，相邻帧永远有一半以上重叠；运动帧对不上
// 不计入失败数（亚像素/重绘是常态，不是内容跳变）。鼠标滚轮一格一点，
// 停稳再抓本来就够，路径原样不动。
//
// 抓帧后台串行：停稳触发时若上一帧还在处理，记下待抓标记，处理完补一帧。
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
    private var pendingGrabInMotion = false     // 补抓的那帧当时页面还在动吗
    private var scrollDebounce: DispatchWorkItem?
    /// 触摸板自上次抓帧以来累计的滚动距离（pt，取两轴里大的那个）
    private var scrollDistance: CGFloat = 0
    /// 触摸板距离抓帧：累计滚动每达到区域高的这个比例就抓一帧（0.4 → 相邻帧 60% 重叠）
    static let motionCaptureFraction: CGFloat = 0.4
    /// 距离抓帧的下限（pt）：太小的选区不该每滚几像素就抓
    static let motionCaptureMinDistance: CGFloat = 48
    /// 纯函数：触摸板距离抓帧的触发距离（自检直接喂数字验）
    static func motionCaptureDistance(regionHeight: CGFloat) -> CGFloat {
        max(motionCaptureMinDistance, regionHeight * motionCaptureFraction)
    }
    /// 拼接画布（增量，只画新增行）。**不再持有整幅累积图**：
    /// 老写法每帧新开一块整幅位图重画全图，O(N²) 拷贝 + 两份全图常驻。
    private var canvas: ImageStitch.StitchCanvas?
    /// 缩略图用的低分辨率画布（180 宽）。每帧只多画一条 180 宽的窄带，
    /// 这样刷新预览不必为了一张缩略图去合成整幅长图。
    private var previewCanvas: ImageStitch.StitchCanvas?
    /// 画布当前所处的空间（0 未旋转 / 1 旋转 90°）。第一帧抓下来时还不知道
    /// 用户要横着滚还是竖着滚，方向变了得把画布搬到另一个空间（只搬一次）。
    private var canvasDirection = 0
    static let previewWidth = 180
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
    /// finish 只走一遍：动作后的延迟关 + 用户点 ✓/✕ 可能撞车
    private var didFinish = false
    private var monitors: [Any] = []
    /// 缩略图（实时预览）面板：用户要求"强制打开、不能关闭"，
    /// 所以它在 begin() 里就建好、跟着整个流程存在，连标题栏和关闭按钮都没有。
    private var previewPanel: NSPanel?
    private var previewScroll: NSScrollView?
    private var previewImageView: NSImageView?
    private var previewTitle: NSTextField?
    /// 缩略图尺寸（用户指定）
    static let previewSize = NSSize(width: 180, height: 600)

    init(model: AppModel?) {
        self.model = model
    }

    func begin(displayID: CGDirectDisplayID, region: CGRect) {
        self.displayID = displayID
        self.region = region
        showFrame()
        showToolbar()
        showPreview()
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
        let panel = KeyablePanel(contentRect: Self.panelRect(forRegion: region),
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
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)

        func add(_ symbol: String, _ title: String, tint: NSColor? = nil, action: Selector? = nil) -> NSButton {
            let button = NSButton(title: "", target: self,
                                  action: action ?? #selector(toolbarAction(_:)))
            button.bezelStyle = .regularSquare
            button.isBordered = false
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)?
                .withSymbolConfiguration(.init(pointSize: 19, weight: .medium))
            button.frame = NSRect(x: 0, y: 0, width: 44, height: 38)
            button.toolTip = title
            button.contentTintColor = tint
            button.tag = Self.buttonTag(title)
            stack.addArrangedSubview(button)
            return button
        }

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
        container.layer?.cornerRadius = 12
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
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 1, height: 28))
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.separatorColor.cgColor
        return view
    }

    // ── 抓帧循环（滚动触发） ─────────────────────────────────

    private func startCapturing() {
        guard !isRunning else { return }
        isRunning = true
        canvas = nil
        previewCanvas = nil
        canvasDirection = 0
        lastFrame = nil
        lastOffset = nil
        frameCount = 0
        segmentCount = 0
        consecutiveFailures = 0
        scrollDistance = 0
        grabFrame()
        installScrollMonitor()
        installEscMonitor()
    }

    /// 滚轮监听：全局（其他应用的内容）+ 本地（本应用窗口）各装一个，
    /// 滚轮事件不需要辅助功能授权。
    private func installScrollMonitor() {
        let note: (NSEvent) -> Void = { [weak self] event in
            self?.noteScroll(event)
        }
        monitors.append(NSEvent.addGlobalMonitorForEvents(matching: .scrollWheel, handler: note))
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            note(event)
            return event
        })
    }

    /// 每次滚动：按主导方向识别横/竖向；**途中不抓帧**（运动中的帧没法用，
    /// 见类头注释），去抖 250ms 等停稳后再抓一帧拼接。
    ///
    /// 例外（1.0.25）：触摸板（精确 delta）按累计距离中途抓帧 ——
    /// 惯性一动一两屏，等停稳两帧就零重叠了，见类头注释。
    private func noteScroll(_ event: NSEvent) {
        guard isRunning else { return }
        let dx = event.deltaX, dy = event.deltaY
        let ax = abs(dx), ay = abs(dy)
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

        // 触摸板：累计滚动距离达到区域高的 40% 就抓一帧（此时页面还在动，
        // 帧标成 inMotion —— 对不上不算失败）。鼠标滚轮（非精确 delta）不走这条。
        if event.hasPreciseScrollingDeltas {
            scrollDistance += max(ax, ay)
            if scrollDistance >= Self.motionCaptureDistance(regionHeight: region.height) {
                scrollDistance = 0
                scrollDebounce?.cancel()
                grabOrQueue(inMotion: true)
                return
            }
        }

        // 尾部去抖：停稳 250ms 后抓帧拼接。0.18 太贴 —— 触控板惯性刚结束
        // 那一下还可能带亚像素相位，宁可多等 70ms 也要拿到"静止"的画面。
        scrollDebounce?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.grabOrQueue(inMotion: false) }
        scrollDebounce = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: item)
    }

    private func grabOrQueue(inMotion: Bool) {
        guard isRunning else { return }
        if isBusy {
            pendingGrab = true
            pendingGrabInMotion = inMotion
        } else {
            grabFrame(inMotion: inMotion)
        }
    }

    private func grabFrame(inMotion: Bool = false) {
        guard isRunning, !isBusy else { return }
        isBusy = true
        scrollDistance = 0
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
                self.handleFrame(frame, inMotion: inMotion)
                self.isBusy = false
                // 忙的时候用户又滚了 → 补一帧，保证滚动结果不丢
                if self.pendingGrab {
                    let motion = self.pendingGrabInMotion
                    self.pendingGrab = false
                    self.grabFrame(inMotion: motion)
                }
            }
        }
    }

    private func handleFrame(_ frame: CGImage?, inMotion: Bool) {
        guard isRunning else { return }
        guard let frame else {
            frameView?.status = "抓帧失败，重试中…"
            return
        }
        defer { frameCount += 1 }

        // 第一帧：开画布（全分辨率 + 预览各一块）
        guard let current = lastFrame, canvas != nil else {
            openCanvas(with: frame)
            lastFrame = frame
            segmentCount = 1
            frameView?.status = "已捕获 1 段，滚动页面继续"
            refreshPreview()
            return
        }

        let isHorizontal = direction == 1
        // 页面根本没动（滚到头 / 光标压在不可滚区域）：静默跳过。
        // 以前这种帧会一路"没对上"→"内容跳变"，把"没滚"演成一次故障。
        // 横竖都做这个判断：两帧逐像素一样，跟方向无关。
        if ImageStitch.isNearlyIdentical(current, frame) {
            frameView?.status = "页面没动（可能到头了），继续滚动"
            return
        }
        var alignment: ImageStitch.Alignment?
        if isHorizontal {
            if let a = ImageStitch.rotate90(current), let b = ImageStitch.rotate90(frame) {
                alignment = ImageStitch.align(top: a, bottom: b, hint: lastOffset)
            }
        } else {
            alignment = ImageStitch.align(top: current, bottom: frame, hint: lastOffset)
        }

        guard let alignment else {
            handleFailure(frame: frame, current: current, inMotion: inMotion)
            return
        }

        // 方向可能是在第一帧之后才识别出来的（用户先横着滚）：
        // 把已拼好的画布搬进新的空间，只搬这一次。
        if canvasDirection != direction, !realignCanvas(to: direction) {
            frameView?.status = "拼接失败（图太长？），点 ✓ 先保存已截部分"
            return
        }

        // ── 拼接：只把这一帧新增的那几行画进画布 ──
        guard let stitched = toStitchSpace(frame),
              canvas?.append(stitched, offset: alignment.offset) == true else {
            frameView?.status = "拼接失败（图太长？），点 ✓ 先保存已截部分"
            return
        }
        // 预览画布吃同一份原始帧，偏移在内部按宽度比例自己缩
        previewCanvas?.append(stitched, offset: alignment.offset)
        lastFrame = frame
        lastOffset = alignment.offset
        consecutiveFailures = 0
        segmentCount += 1
        frameView?.status = "已捕获 \(segmentCount) 段 · 本段 +\(alignment.offset)px"
        refreshPreview()
    }

    // ── 画布空间（竖向直接拼 / 横向先转 90°） ────────────────

    /// 搬进拼接空间：横向滚动的每一帧先顺时针转 90°，一套竖向算法吃两种方向。
    /// 转的是**每一帧**（几十 KB 的行），不是每帧把整幅累积图转两遍 —— 那是 O(N²)。
    private func toStitchSpace(_ image: CGImage) -> CGImage? {
        direction == 1 ? ImageStitch.rotate90(image) : image
    }

    private func fromStitchSpace(_ image: CGImage) -> CGImage? {
        direction == 1 ? rotateBack(image) : image
    }

    /// 建画布（第一帧，或方向变化后重建）
    private func openCanvas(with frame: CGImage) {
        guard let base = toStitchSpace(frame),
              let main = ImageStitch.StitchCanvas(width: base.width),
              main.start(base) else { return }
        canvas = main
        let preview = ImageStitch.StitchCanvas(width: Self.previewWidth)
        preview?.start(base)
        previewCanvas = preview
        canvasDirection = direction
    }

    /// 方向变了：把已拼好的图搬进新的空间。一次性 O(N)，横向滚动只会走一次。
    private func realignCanvas(to newDirection: Int) -> Bool {
        guard let canvas, let old = canvas.image() else { return false }
        // 先退回"未旋转"空间，再进新空间
        guard let natural = fromStitchSpace(old) else { return false }
        direction = newDirection
        guard let moved = toStitchSpace(natural),
              let fresh = ImageStitch.StitchCanvas(width: moved.width),
              fresh.start(moved) else { return false }
        self.canvas = fresh
        let preview = ImageStitch.StitchCanvas(width: Self.previewWidth)
        preview?.start(moved)
        previewCanvas = preview
        canvasDirection = newDirection
        return true
    }


    /// 这一帧没对上：先判是不是"往回滚"，再决定要不要重设基准。
    ///
    /// 🔴 绝不能只留一句提示然后原地等 —— 基准不动，用户再往下滚只会离它更远，
    /// 于是每一帧都失败，看着就像"只截了一次，之后怎么滚都不动"。
    ///
    /// 🔴 运动帧（触摸板距离抓帧）对不上**不算失败**：亚像素相位 / 重绘半帧
    /// 是惯性滚动的常态，不是"内容跳变"。计进失败数的话，一次快滑就能连挂
    /// 3 帧 → 错误地重置基准。直接静默跳过，等停稳那帧来补。
    private func handleFailure(frame: CGImage, current: CGImage, inMotion: Bool) {
        guard !inMotion else { return }
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

        frameView?.status = "这一帧没对上（页面变化 / 滚动幅度太大），小步滚动试试"
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
        case 3: finish(with: outputImage())
        case 4: pin()
        case 5: save()
        case 6: copyToClipboard()
        default: break
        }
    }

    // ── 缩略图（常驻，不能关闭） ─────────────────────────────

    /// 用户要求：滚动截图时缩略图**强制打开、不能关闭**，默认贴在截图框右边，
    /// 右边没位置就换左边，大小固定 180 × 600。
    ///
    /// 所以它是个无边框面板：没有标题栏、没有关闭按钮，也不接收鼠标事件
    /// （`ignoresMouseEvents`）—— 鼠标从它上面滚过去时，滚轮事件直接落到
    /// 下面的页面，不会把用户"卡"在缩略图里。
    private func showPreview() {
        let size = Self.previewSize
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let container = NSView(frame: NSRect(origin: .zero, size: size))
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.82).cgColor
        container.layer?.cornerRadius = 10
        container.layer?.borderWidth = 1
        container.layer?.borderColor = NSColor.white.withAlphaComponent(0.22).cgColor
        container.layer?.masksToBounds = true

        let header = NSTextField(labelWithString: "滚动截图预览")
        header.font = .systemFont(ofSize: 11, weight: .semibold)
        header.textColor = NSColor.white.withAlphaComponent(0.9)
        header.frame = NSRect(x: 10, y: size.height - 22, width: size.width - 20, height: 16)
        header.autoresizingMask = [.width, .minYMargin]
        container.addSubview(header)

        let scroll = NSScrollView(frame: NSRect(x: 1, y: 1, width: size.width - 2, height: size.height - 27))
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.autoresizingMask = [.width, .height]

        let imageView = NSImageView()
        imageView.imageScaling = .scaleAxesIndependently   // 尺寸由我们自己按宽度算
        imageView.wantsLayer = true
        scroll.documentView = imageView
        container.addSubview(scroll)

        panel.contentView = container
        previewPanel = panel
        previewScroll = scroll
        previewImageView = imageView
        previewTitle = header

        panel.setFrameOrigin(previewOrigin(for: size))
        panel.orderFront(nil)
        refreshPreview()
    }

    /// 缩略图落位：优先截图框右侧，右边放不下换左侧，都放不下就贴屏幕边缘。
    /// 关键约束是**不能被自己的取景框拍到**（重合了每帧都会把缩略图录进画面）。
    private func previewOrigin(for size: NSSize) -> NSPoint {
        guard let screen = framePanel?.screen ?? NSScreen.main else { return .zero }
        return Self.previewOrigin(region: selectionFrameAppKit,
                                  visible: screen.visibleFrame, size: size)
    }

    /// 纯几何部分抽成 static：不依赖面板状态，自检能直接喂数字验。
    static func previewOrigin(region: CGRect, visible: CGRect, size: NSSize) -> NSPoint {
        let gap: CGFloat = 12
        // 竖直方向：顶边对齐截图框顶边，再夹进可见区域
        func clampedY() -> CGFloat {
            min(max(region.maxY - size.height, visible.minY + 4), visible.maxY - size.height - 4)
        }
        let rightX = region.maxX + gap
        if rightX + size.width <= visible.maxX - 4 {
            return NSPoint(x: rightX, y: clampedY())
        }
        let leftX = region.minX - gap - size.width
        if leftX >= visible.minX + 4 {
            return NSPoint(x: leftX, y: clampedY())
        }
        // 两边都不够（截图框几乎占满整屏宽）：贴右边，并尽量躲开选区
        let x = min(max(rightX, visible.minX + 4), visible.maxX - size.width - 4)
        let fallbackY = (region.minY - gap - size.height >= visible.minY + 4)
            ? region.minY - gap - size.height      // 挪到框的下方
            : clampedY()
        return NSPoint(x: x, y: fallbackY)
    }

    /// 把最新的累积图刷进预览（没铺满按宽度铺满；铺满后整幅缩到框内，见下）
    private func refreshPreview() {
        guard let imageView = previewImageView, let scroll = previewScroll,
              let preview = previewCanvas?.image(),
              let image = fromStitchSpace(preview) else { return }
        if let canvas {
            previewTitle?.stringValue = "滚动截图预览 \(canvas.width)×\(canvas.height)"
        }

        let viewWidth = max(80, scroll.contentView.bounds.width)
        let viewHeight = max(80, scroll.contentView.bounds.height)
        let docSize = Self.previewDocumentSize(imageWidth: image.width, imageHeight: image.height,
                                               viewWidth: viewWidth, viewHeight: viewHeight)
        // 高度超框后宽度随比例缩小、水平居中：整幅长图一眼看全，不再滚动
        imageView.frame = NSRect(origin: NSPoint(x: max(0, (viewWidth - docSize.width) / 2), y: 0),
                                 size: docSize)
        imageView.image = NSImage(cgImage: image,
                                  size: NSSize(width: image.width, height: image.height))
        scroll.documentView = imageView
        // NSImageView 不是 flipped：y=0 在底部，滚到 0 就是看最新的那段
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 0))
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    /// 纯函数：缩略图显示尺寸（自检直接喂数字验）。
    ///
    /// 用户口径 1.0.25：长图没铺满缩略图框时按宽度铺满（原行为）；
    /// **一旦铺满**（按宽度铺满后高度超出框），就改成整幅缩到框内 ——
    /// 高度贴框、宽度按比例缩小并水平居中，越长图宽越窄，不再滚动预览。
    static func previewDocumentSize(imageWidth: Int, imageHeight: Int,
                                    viewWidth: CGFloat, viewHeight: CGFloat) -> NSSize {
        guard imageWidth > 0, imageHeight > 0, viewWidth > 0, viewHeight > 0 else { return .zero }
        let scale = min(viewWidth / CGFloat(imageWidth), viewHeight / CGFloat(imageHeight))
        return NSSize(width: CGFloat(imageWidth) * scale,
                      height: CGFloat(imageHeight) * scale)
    }

    /// 出图：保存 / 复制 / 贴图 / 交编辑窗口时才合成整幅。
    /// 合成（`makeImage`）是整块拷贝，绝不能放进每帧的路径里。
    private func outputImage() -> CGImage? {
        guard let composite = canvas?.image() else { return nil }
        return fromStitchSpace(composite)
    }

    private func pin() {
        guard let image = outputImage() else { return }
        model?.pinImage(image)
        finishAfterAction()
    }

    private func save() {
        guard let image = outputImage(), let model else { return }
        let prefs = model.prefs.value
        let name = Support.shotFileName(prefix: "boxshot-scroll", ext: prefs.shotFormat.fileExtension)

        // autoSave：不再弹面板，直接落到设置目录
        if prefs.autoSave, let dirPath = prefs.saveDirectory, !dirPath.isEmpty {
            let url = Support.uniqueFileURL(in: URL(fileURLWithPath: dirPath, isDirectory: true), name: name)
            if write(image: image, to: url, prefs: prefs) { finishAfterAction() }
            return
        }

        let panel = NSSavePanel()
        panel.nameFieldStringValue = name
        panel.allowedContentTypes = prefs.shotFormat == .png ? [.png] : [.jpeg]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if write(image: image, to: url, prefs: prefs) { finishAfterAction() }
    }

    @discardableResult
    private func write(image: CGImage, to url: URL, prefs: Preferences) -> Bool {
        guard let data = ImageEncode.data(image, format: prefs.shotFormat, jpgQuality: prefs.jpgQuality) else {
            frameView?.status = "图片编码失败"
            frameView?.needsDisplay = true
            return false
        }
        var ok = false
        do {
            try data.write(to: url)
            ok = true
            frameView?.status = "已保存：\(url.lastPathComponent)"
            if prefs.playSound { Support.playFeedbackSound(named: prefs.feedbackSound) }
        } catch {
            // 曾经 try? 静默吞错，写盘失败用户毫无感知
            frameView?.status = "保存失败：\(error.localizedDescription)"
        }
        frameView?.needsDisplay = true
        return ok
    }

    private func copyToClipboard() {
        guard let image = outputImage() else { return }
        Support.copyImageToClipboard(image)
        frameView?.status = "已复制到剪贴板"
        frameView?.needsDisplay = true
        model?.playFeedbackSound()
        finishAfterAction()
    }

    /// 完成即关（设置 → 截图，与普通截图浮层同一个开关）：
    /// 滚动截图工具条上的**贴图 / 保存 / 复制**成功后就地收掉整个会话
    /// （取景框、工具条、缩略图、滚轮监听全撤）。延迟 0.5s 是为了让状态条
    /// 那句"已保存 / 已复制"来得及看；✕ 和 ✓ 不受这个开关影响。
    private func finishAfterAction() {
        guard let model, model.prefs.value.closeAfterAction else { return }
        let holder = self
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            holder.finish(with: nil)
        }
    }

    private func finish(with image: CGImage?) {
        guard !didFinish else { return }
        didFinish = true
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
        // 🔴 画布是整个会话里最大的一块内存（长截图的画布可达上百 MB）。
        // finish() 的 image 参数已经把结果带走，这里不留手 ——
        // 不然 controller 虽然 dealloc 了，分配器手里的"刚释放的大页"还是又脏又占。
        canvas = nil
        previewCanvas = nil
        lastFrame = nil
    }

    private func closePanels() {
        previewPanel?.orderOut(nil)
        previewPanel = nil
        previewScroll = nil
        previewImageView = nil
        previewTitle = nil
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
        didSet { if status != oldValue { needsDisplay = true } }
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
