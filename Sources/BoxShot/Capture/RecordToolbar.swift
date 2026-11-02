import AppKit

// ============================================================
// 录屏工具条（1.0.1 按用户截图改版，参考 macOS 原生截图条）
//
// 区域录制：选区后虚线框原位钉住 + 底部工具条：
//   [✕关闭] [全屏] [重选区域] | [●记录/■停止 + 计时] | [🎙麦克风] [🔊系统声音] [📷摄像头] | [选项▾]
// 全屏录制：同样的工具条，无虚线框。
//
// 摄像头取景框是独立的圆形 / 圆角矩形小窗（CameraBubble），贴着选区右下角，
// 所见即所得地进录像；右键在圆形 ⇄ 圆角矩形之间切换，✕ 或工具条按钮关闭。
//
// 选项弹层：帧率、格式 MOV/MP4、质量、取景框大小（写回偏好设置）。
// ============================================================

@MainActor
final class RecordToolbarController: NSObject {

    var onClosed: (() -> Void)?
    var onRecordingChange: ((Bool) -> Void)?

    private weak var model: AppModel?
    private var displayID: CGDirectDisplayID = 0
    private var region: CGRect?          // nil = 全屏
    private var framePanel: NSPanel?
    private var toolbarPanel: NSPanel?
    private var recorder: RecorderController?
    private var isRecording = false
    /// 已按"开始"但引擎还没回话（SCStream.startCapture 是异步的）
    private var startingUp = false
    private var timer: Timer?
    private var startDate: Date?

    private var recordButton: NSButton?
    private var pauseButton: NSButton?
    private var timeLabel: NSTextField?
    private var micButton: NSButton?
    private var systemButton: NSButton?
    private var cameraButton: NSButton?
    private var cameraBubble: CameraBubbleController?
    private var popover: NSPopover?
    private var escMonitor: Any?

    // 暂停：计时要把暂停时长扣掉，否则成片 30 秒、显示 3 分钟
    private var isPaused = false
    private var pausedTotal: TimeInterval = 0
    private var pauseStartedAt: Date?

    init(model: AppModel?) {
        self.model = model
    }

    func begin(displayID: CGDirectDisplayID, region: CGRect?) {
        self.displayID = displayID
        self.region = region
        if let region {
            showFrame(region: region)
        }
        showToolbar()
        installEscMonitor()
    }

    private var selectionFrameAppKit: CGRect? {
        guard let region else { return nil }
        let globalTopLeft = ScreenCapture.globalTopLeftRect(fromDisplayLocal: region, displayID: displayID)
        return ScreenCapture.appKitFrame(fromGlobalTopLeft: globalTopLeft)
    }

    // ── 虚线取景框 ──────────────────────────────────────────

    private func showFrame(region localRect: CGRect) {
        guard let frame = selectionFrameAppKit else { return }
        let panel = NSPanel(contentRect: frame,
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        // 程序化窗口默认 close() 会自我释放，和 ARC 抢着放 → 随机闪退
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = DashedFrameView(frame: NSRect(origin: .zero, size: frame.size))
        framePanel = panel
        panel.makeKeyAndOrderFront(nil)
    }

    private func hideFrame() {
        framePanel?.orderOut(nil)
        framePanel = nil
    }

    // ── 工具条 ──────────────────────────────────────────────

    private func showToolbar() {
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 14, bottom: 10, right: 14)

        func add(_ symbol: String, _ title: String, tag: Int, tint: NSColor? = nil) -> NSButton {
            let button = NSButton(title: "", target: self, action: #selector(toolbarAction(_:)))
            button.bezelStyle = .regularSquare
            button.isBordered = false
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)?
                .withSymbolConfiguration(.init(pointSize: 19, weight: .medium))
            button.frame = NSRect(x: 0, y: 0, width: 44, height: 38)
            button.toolTip = title
            button.tag = tag
            button.contentTintColor = tint
            stack.addArrangedSubview(button)
            return button
        }

        add("xmark", "关闭", tag: 1, tint: .systemRed)
        add("rectangle.inset.filled", "全屏录制", tag: 2)
        add("rectangle.dashed", "重选区域", tag: 3)
        stack.addArrangedSubview(makeDivider())

        let record = add("record.circle", "开始录制", tag: 4, tint: .systemRed)
        recordButton = record
        // 暂停 / 恢复：录制中才启用
        let pause = add("pause.circle", "暂停 / 继续", tag: 9)
        pause.isEnabled = false
        pauseButton = pause
        let time = NSTextField(labelWithString: "00:00")
        time.font = NSFont.monospacedDigitSystemFont(ofSize: 15, weight: .semibold)
        time.textColor = .white
        time.isHidden = true
        timeLabel = time
        stack.addArrangedSubview(time)
        stack.addArrangedSubview(makeDivider())

        let mic = add("mic", "麦克风声音", tag: 5)
        let sys = add("speaker.wave.2", "系统声音", tag: 6)
        let cam = add("video", "摄像头取景框", tag: 8)
        micButton = mic
        systemButton = sys
        cameraButton = cam
        stack.addArrangedSubview(makeDivider())

        add("slider.horizontal.3", "录屏选项", tag: 7)

        refreshAudioButtons()
        refreshCameraButton()

        stack.layoutSubtreeIfNeeded()
        let size = stack.fittingSize
        let container = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        container.material = .hudWindow
        container.state = .active
        container.wantsLayer = true
        container.layer?.cornerRadius = 14
        container.addSubview(stack)
        stack.frame = container.bounds

        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = container

        position(panel)
        toolbarPanel = panel
        panel.makeKeyAndOrderFront(nil)
    }

    private func position(_ panel: NSPanel) {
        guard let screen = framePanel?.screen ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        let anchorFrame = selectionFrameAppKit ?? visible
        let belowY = anchorFrame.minY - panel.frame.height - 12
        let y = belowY >= visible.minY + 4 ? belowY : (region == nil ? visible.minY + 24 : anchorFrame.maxY + 12)
        let x = min(max(anchorFrame.midX - panel.frame.width / 2, visible.minX + 4),
                    visible.maxX - panel.frame.width - 4)
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    private func makeDivider() -> NSView {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 1, height: 26))
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.separatorColor.cgColor
        return view
    }

    private func refreshAudioButtons() {
        let source = model?.prefs.value.recordAudio ?? .none
        micButton?.contentTintColor = source == .mic ? .systemBlue : .white
        systemButton?.contentTintColor = source == .system ? .systemBlue : .white
    }

    private func refreshCameraButton() {
        let on = cameraBubble?.isVisible == true
        cameraButton?.contentTintColor = on ? .systemBlue : .white
        cameraButton?.toolTip = on ? "关闭摄像头取景框" : "打开摄像头取景框（画面右下角）"
    }

    /// 取景框的落位依据：区域录制贴选区右下角，全屏录制贴整块屏幕右下角
    private var cameraAnchorFrame: CGRect {
        selectionFrameAppKit ?? (framePanel?.screen ?? NSScreen.main)?.visibleFrame
            ?? CGRect(x: 0, y: 0, width: 1280, height: 800)
    }

    private func toggleCameraBubble() {
        if let bubble = cameraBubble, bubble.isVisible {
            bubble.close()
            cameraBubble = nil
            refreshCameraButton()
            return
        }
        let bubble = CameraBubbleController(size: model?.prefs.value.recordCameraSize ?? .medium)
        bubble.onClose = { [weak self] in
            self?.cameraBubble = nil
            self?.refreshCameraButton()
        }
        cameraBubble = bubble
        bubble.show(anchor: cameraAnchorFrame)
        refreshCameraButton()
    }

    // ── 动作 ────────────────────────────────────────────────

    @objc private func toolbarAction(_ sender: NSButton) {
        switch sender.tag {
        case 1: // 关闭
            close(stopRecording: true)
        case 2: // 全屏：去框，等"记录"
            region = nil
            hideFrame()
            if let panel = toolbarPanel { position(panel) }
            if let bubble = cameraBubble, bubble.isVisible { bubble.show(anchor: cameraAnchorFrame) }
        case 3: // 重选区域：先收掉自己，让 AppModel 重新走选区
            close(stopRecording: true)
            model?.perform(.recordRegion)
        case 4: // 记录 / 停止
            if isRecording { stopRecording() } else { startRecording() }
        case 5: // 麦克风
            model?.prefs.value.recordAudio = (model?.prefs.value.recordAudio == .mic) ? .none : .mic
            refreshAudioButtons()
        case 6: // 系统声音
            model?.prefs.value.recordAudio = (model?.prefs.value.recordAudio == .system) ? .none : .system
            refreshAudioButtons()
        case 8: // 摄像头取景框
            toggleCameraBubble()
        case 7: // 选项弹层
            toggleOptionsPopover(anchor: sender)
        case 9: // 暂停 / 继续
            togglePause()
        default:
            break
        }
    }

    private func togglePause() {
        guard isRecording, let recorder else { return }
        isPaused.toggle()
        recorder.setPaused(isPaused)
        if isPaused {
            pauseStartedAt = Date()
            pauseButton?.image = NSImage(systemSymbolName: "play.circle.fill",
                                         accessibilityDescription: "继续录制")?
                .withSymbolConfiguration(.init(pointSize: 16, weight: .medium))
            pauseButton?.contentTintColor = .systemYellow
            timeLabel?.textColor = .systemYellow
        } else {
            if let start = pauseStartedAt {
                pausedTotal += Date().timeIntervalSince(start)
            }
            pauseStartedAt = nil
            pauseButton?.image = NSImage(systemSymbolName: "pause.circle",
                                         accessibilityDescription: "暂停录制")?
                .withSymbolConfiguration(.init(pointSize: 16, weight: .medium))
            pauseButton?.contentTintColor = nil
            timeLabel?.textColor = .white
        }
        tick()
    }

    private func startRecording() {
        guard let model, recorder == nil else { return }
        let prefs = model.prefs.value
        let controller = RecorderController()
        controller.revealInFinderOnFinish = prefs.recordRevealInFinder
        // 提示音开关与音效都跟随设置；关掉就传空串，引擎那边就不响
        controller.finishedSoundName = prefs.playSound ? prefs.feedbackSound : ""
        controller.onStateChange = { [weak self] recording in
            guard let self, recording else { return }
            self.startingUp = false
            self.tick()
        }
        controller.onError = { [weak self] message in
            guard let self else { return }
            // 🔴 开始录制是**异步**的（SCStream 还要等系统把显示器/窗口列表给我们）。
            // 失败可能发生在按钮已经变成"停止"、计时器已经在走之后 —— 此时如果不
            // 把界面退回去，用户看到的就是"在录"，实际上一个字节都没写。
            if self.startingUp {
                self.recorder = nil
                self.isRecording = false
                self.startingUp = false
                self.timer?.invalidate()
                self.timer = nil
                self.resetRecordButton()
                self.onRecordingChange?(false)
            }
            self.model?.presentError(message)
        }
        // 少一路麦克风/摄像头不算启动失败：把话说清楚，录制继续。
        controller.onWarning = { [weak self] message in
            NSLog("[BoxShot] 录制提醒：\(message)")
            self?.timeLabel?.toolTip = message
            self?.model?.presentError(message)
        }
        do {
            // 🔴 摄像头取景框改成"上屏 + 被录进画面"（见 CameraBubble 注释），
            // 编码端不再合成画中画 —— 否则同一个摄像头会在成片里出现两次。
            if prefs.recordCamera, cameraBubble == nil {
                toggleCameraBubble()
            }
            // 🔴 取景框是本进程的窗口，而"排除自家窗口"是按 pid 一刀切的：
            // 不把它挑出来，摄像头画面会被一并从录制里排掉 ——
            // 用户看到的就是"录出来的视频没有摄像头影像"。
            let bubbleNumber = cameraBubble?.windowNumber ?? 0
            controller.keepVisibleWindowNumbers = bubbleNumber > 0 ? [bubbleNumber] : []
            try controller.startRecording(displayID: displayID,
                                          region: region,
                                          audio: prefs.recordAudio,
                                          camera: false,
                                          fps: prefs.recordFPS,
                                          showCursor: prefs.recordShowCursor,
                                          format: prefs.recordFormat,
                                          quality: prefs.recordQuality,
                                          showsHUD: false)
            recorder = controller
            isRecording = true
            startingUp = true
            isPaused = false
            pausedTotal = 0
            pauseStartedAt = nil
            startDate = Date()
            recordButton?.image = NSImage(systemSymbolName: "stop.circle.fill",
                                          accessibilityDescription: "停止录制")?
                .withSymbolConfiguration(.init(pointSize: 17, weight: .medium))
            recordButton?.contentTintColor = .systemRed
            pauseButton?.isEnabled = false   // 首帧到货前按暂停没意义
            pauseButton?.image = NSImage(systemSymbolName: "pause.circle",
                                         accessibilityDescription: "暂停录制")?
                .withSymbolConfiguration(.init(pointSize: 19, weight: .medium))
            pauseButton?.contentTintColor = nil
            timeLabel?.textColor = .white
            timeLabel?.isHidden = false
            timeLabel?.stringValue = "启动中…"
            timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
                DispatchQueue.main.async { self?.tick() }
            }
            onRecordingChange?(true)
        } catch {
            recorder = nil
            isRecording = false
            startingUp = false
            resetRecordButton()
            model.presentError("无法开始录制：\(error.localizedDescription)")
        }
    }

    /// 把"记录"按钮和计时器退回未录制状态（启动失败 / 停止后都要走这里）
    private func resetRecordButton() {
        timer?.invalidate()
        timer = nil
        recordButton?.image = NSImage(systemSymbolName: "record.circle",
                                      accessibilityDescription: "开始录制")?
            .withSymbolConfiguration(.init(pointSize: 17, weight: .medium))
        recordButton?.contentTintColor = .systemRed
        pauseButton?.isEnabled = false
        pauseButton?.image = NSImage(systemSymbolName: "pause.circle",
                                     accessibilityDescription: "暂停录制")?
            .withSymbolConfiguration(.init(pointSize: 19, weight: .medium))
        pauseButton?.contentTintColor = nil
        timeLabel?.textColor = .white
        timeLabel?.isHidden = true
    }

    private func stopRecording() {
        guard let recorder else { return }
        recorder.stop(reason: .user)
        self.recorder = nil
        isRecording = false
        startingUp = false
        isPaused = false
        resetRecordButton()
        onRecordingChange?(false)
        // 录完自动收工具条（文件已落盘，给个反馈就撤）
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            self?.close(stopRecording: false)
        }
    }

    private func tick() {
        guard let startDate else { return }
        guard !startingUp else { return }   // 启动中不跳秒，等首帧
        // 计时口径与成片一致：暂停这段时间不算
        var elapsed = Date().timeIntervalSince(startDate) - pausedTotal
        if isPaused, let pauseStartedAt { elapsed -= Date().timeIntervalSince(pauseStartedAt) }
        let seconds = max(0, Int(elapsed))
        timeLabel?.stringValue = String(format: "%02d:%02d", seconds / 60, seconds % 60)
        // 引擎真的起来了才让暂停可用
        if pauseButton?.isEnabled == false { pauseButton?.isEnabled = true }
    }

    func close(stopRecording shouldStop: Bool) {
        if isRecording, shouldStop {
            stopRecording()
        }
        // 🔴 以前无论有没有在录，teardown 都延后 1 秒。而 AppModel 要等
        // onClosed 回调才把 recordToolbar 置 nil —— 这一秒里再点菜单的
        // 「区域录制」会被 `if recordToolbar != nil` 当成"停止"，于是
        // 关掉刚打开的工具条：表现就是"点了区域录制没反应"。
        // 没在录就立刻收；在录才留时间给 writer 收尾。
        if shouldStop && isRecording {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.teardown()
            }
        } else {
            teardown()
        }
    }

    private func teardown() {
        if let escMonitor {
            NSEvent.removeMonitor(escMonitor)
            self.escMonitor = nil
        }
        timer?.invalidate()
        timer = nil
        startingUp = false
        cameraBubble?.close()
        cameraBubble = nil
        framePanel?.orderOut(nil)
        toolbarPanel?.orderOut(nil)
        framePanel = nil
        toolbarPanel = nil
        popover?.close()
        popover = nil
        // 一定要回调：AppModel 靠它把 recordToolbar 置 nil，
        // 不回调就等于留了个僵尸，之后点「区域录制」全被当成"停止"。
        onClosed?()
    }

    private func installEscMonitor() {
        // ⚠️ 监听必须存下来在 teardown 里移除：controller 每次新建都装一个，
        // 曾经只加不删，事件链上越积越多。
        escMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.toolbarPanel != nil, event.keyCode == 53 else { return event }
            // 🔴 录制中按 Esc **不再停录**：录了十分钟的素材不该被一个误触的
            // Esc 直接掐断。要停就点工具条上的停止按钮（用户明确要求：
            // 没主动取消就不能结束）。没开录时 Esc 才收掉工具条。
            if self.isRecording || self.startingUp { return nil }
            self.close(stopRecording: false)
            return nil
        }
    }

    // ── 选项弹层 ────────────────────────────────────────────

    private func toggleOptionsPopover(anchor: NSView) {
        if let popover, popover.isShown {
            popover.close()
            self.popover = nil
            return
        }
        guard let model else { return }
        let optionsView = RecordOptionsView(model: model)
        let content = NSViewController()
        content.view = optionsView

        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = content
        // 用内容视图的自适配尺寸，弹层不会被压成默认大小
        popover.contentSize = optionsView.bounds.size
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
        self.popover = popover
    }
}

// ── 虚线取景框 ───────────────────────────────────────────────

final class DashedFrameView: NSView {

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let rect = bounds.insetBy(dx: 2, dy: 2)
        ctx.setStrokeColor(NSColor.white.cgColor)
        ctx.setLineWidth(2)
        let dashed: [CGFloat] = [8, 6]
        ctx.setLineDash(phase: 0, lengths: dashed)
        ctx.stroke(rect)
        ctx.setLineDash(phase: 0, lengths: [])
        // 四角实线加固
        ctx.setStrokeColor(NSColor.controlAccentColor.cgColor)
        for corner in [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
                       CGPoint(x: rect.minX, y: rect.maxY), CGPoint(x: rect.maxX, y: rect.maxY)] {
            ctx.move(to: CGPoint(x: corner.x - 12, y: corner.y)); ctx.addLine(to: CGPoint(x: corner.x + 12, y: corner.y))
            ctx.move(to: CGPoint(x: corner.x, y: corner.y - 12)); ctx.addLine(to: CGPoint(x: corner.x, y: corner.y + 12))
        }
        ctx.strokePath()
    }
}

// ── 选项弹层内容 ─────────────────────────────────────────────
//
// 1.0.12：弹层 = 录制设置速调，四项：帧率 / 格式 / 质量 / 取景框大小（按用户样张）。
// 帧率、格式、质量用下拉（NSPopUpButton），取景框大小用分段 + 行尾「当前 X pt」。
// 顶部 / 底部 / 左右留白用 edgeInsets 控制 —— 旧版手动算 y 坐标，首行顶到上沿，
// 视觉上"顶部没空间"；想加一项还得重排全部坐标。全换 NSStackView 自动排。
// 显示光标开关只留在设置窗口的「录制」页，弹层按样张只放这四项。

final class RecordOptionsView: NSView {

    private weak var model: AppModel?

    init(model: AppModel) {
        self.model = model
        super.init(frame: .zero)

        let prefs = model.prefs.value

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .left
        stack.spacing = 12
        // 🔴 四边留白：弹层内容不再贴边（用户报的"顶部没空间"就是旧版没留白）
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 14, right: 16)

        // 帧率（下拉，8 档）
        let fps = NSPopUpButton()
        fps.addItems(withTitles: recordFPSOptions.map { "\($0)" })
        if let idx = recordFPSOptions.firstIndex(of: prefs.recordFPS) {
            fps.selectItem(at: idx)
        }
        fps.target = self
        fps.action = #selector(fpsChanged(_:))
        stack.addArrangedSubview(row("帧率", fps, width: 90))

        // 格式（下拉 MOV / MP4）
        let format = NSPopUpButton()
        format.addItems(withTitles: RecordFileFormat.allCases.map { $0.title })
        format.selectItem(at: prefs.recordFormat == .mov ? 0 : 1)
        format.target = self
        format.action = #selector(formatChanged(_:))
        stack.addArrangedSubview(row("格式", format, width: 90))

        // 质量（下拉 高 / 中等 / 低）
        let quality = NSPopUpButton()
        quality.addItems(withTitles: RecordQuality.allCases.map { $0.title })
        if let idx = RecordQuality.allCases.firstIndex(of: prefs.recordQuality) {
            quality.selectItem(at: idx)
        }
        quality.target = self
        quality.action = #selector(qualityChanged(_:))
        stack.addArrangedSubview(row("质量", quality, width: 90))

        // 取景框大小（分段 大 / 中 / 小，摄像头取景框边长）+ 行尾「当前 X pt」
        let size = NSSegmentedControl(labels: CameraBubbleSize.allCases.map { $0.title },
                                      trackingMode: .selectOne,
                                      target: self, action: #selector(sizeChanged(_:)))
        if let idx = CameraBubbleSize.allCases.firstIndex(of: prefs.recordCameraSize) {
            size.selectedSegment = idx
        }
        let pt = NSTextField(labelWithString: "当前 \(Int(prefs.recordCameraSize.side)) pt")
        pt.font = NSFont.systemFont(ofSize: 11)
        pt.textColor = .secondaryLabelColor
        pt.setContentCompressionResistancePriority(.required, for: .horizontal)
        stack.addArrangedSubview(row("取景框大小", size, width: 120, trailing: pt))

        addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(greaterThanOrEqualTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        layoutSubtreeIfNeeded()
        frame = NSRect(x: 0, y: 0, width: stack.fittingSize.width, height: stack.fittingSize.height)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// 一行：定宽标签（右对齐，宽度统一）+ 定宽控件（左对齐）+ 可选行尾说明。
    /// 标签列固定 68pt，各行的控件才会落在同一 x，不会参差。
    private func row(_ title: String, _ control: NSView, width: CGFloat, trailing: NSView? = nil) -> NSView {
        let h = NSStackView()
        h.orientation = .horizontal
        h.alignment = .centerY
        h.spacing = 8
        let label = NSTextField(labelWithString: title)
        label.font = NSFont.systemFont(ofSize: 13)
        label.alignment = .right
        label.setContentHuggingPriority(.required, for: .horizontal)
        label.setContentCompressionResistancePriority(.required, for: .horizontal)
        label.widthAnchor.constraint(equalToConstant: 68).isActive = true
        h.addArrangedSubview(label)
        control.setContentHuggingPriority(.defaultLow, for: .horizontal)
        control.widthAnchor.constraint(equalToConstant: width).isActive = true
        h.addArrangedSubview(control)
        if let trailing {
            h.addArrangedSubview(trailing)
        }
        return h
    }

    @objc private func fpsChanged(_ sender: NSPopUpButton) {
        guard let title = sender.titleOfSelectedItem, let value = Int(title) else { return }
        model?.prefs.value.recordFPS = value
    }

    @objc private func formatChanged(_ sender: NSPopUpButton) {
        model?.prefs.value.recordFormat = sender.indexOfSelectedItem == 0 ? .mov : .mp4
    }

    @objc private func qualityChanged(_ sender: NSPopUpButton) {
        let all = RecordQuality.allCases
        if all.indices.contains(sender.indexOfSelectedItem) {
            model?.prefs.value.recordQuality = all[sender.indexOfSelectedItem]
        }
    }

    @objc private func sizeChanged(_ sender: NSSegmentedControl) {
        let all = CameraBubbleSize.allCases
        guard all.indices.contains(sender.selectedSegment) else { return }
        model?.prefs.value.recordCameraSize = all[sender.selectedSegment]
    }
}
