import AppKit

// ============================================================
// 录屏工具条（1.0.1 按用户截图改版，参考 macOS 原生截图条）
//
// 区域录制：选区后虚线框原位钉住 + 底部工具条：
//   [✕关闭] [全屏] [重选区域] | [●记录/■停止 + 计时] | [🎙麦克风] [🔊系统声音] | [选项▾]
// 全屏录制：同样的工具条，无虚线框。
//
// 选项弹层：格式 MOV/MP4、质量 高/中/低、显示光标（写回偏好设置）。
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
    private var timer: Timer?
    private var startDate: Date?

    private var recordButton: NSButton?
    private var timeLabel: NSTextField?
    private var micButton: NSButton?
    private var systemButton: NSButton?
    private var popover: NSPopover?
    private var escMonitor: Any?

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
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)

        func add(_ symbol: String, _ title: String, tag: Int, tint: NSColor? = nil) -> NSButton {
            let button = NSButton(title: "", target: self, action: #selector(toolbarAction(_:)))
            button.bezelStyle = .regularSquare
            button.isBordered = false
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)?
                .withSymbolConfiguration(.init(pointSize: 16, weight: .medium))
            button.frame = NSRect(x: 0, y: 0, width: 38, height: 32)
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
        let time = NSTextField(labelWithString: "00:00")
        time.font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
        time.textColor = .white
        time.isHidden = true
        timeLabel = time
        stack.addArrangedSubview(time)
        stack.addArrangedSubview(makeDivider())

        let mic = add("mic", "麦克风声音", tag: 5)
        let sys = add("speaker.wave.2", "系统声音", tag: 6)
        micButton = mic
        systemButton = sys
        stack.addArrangedSubview(makeDivider())

        add("slider.horizontal.3", "录屏选项", tag: 7)

        refreshAudioButtons()

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
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 1, height: 22))
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.separatorColor.cgColor
        return view
    }

    private func refreshAudioButtons() {
        let source = model?.prefs.value.recordAudio ?? .none
        micButton?.contentTintColor = source == .mic ? .systemBlue : .white
        systemButton?.contentTintColor = source == .system ? .systemBlue : .white
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
        case 7: // 选项弹层
            toggleOptionsPopover(anchor: sender)
        default:
            break
        }
    }

    private func startRecording() {
        guard let model, recorder == nil else { return }
        let prefs = model.prefs.value
        let controller = RecorderController()
        controller.revealInFinderOnFinish = prefs.recordRevealInFinder
        controller.onError = { [weak self] message in
            self?.recordButton?.contentTintColor = .systemRed
            // 异步启动失败（SCStream 起不来等）不能只染红按钮，用户看不见原因
            self?.model?.presentError(message)
        }
        do {
            try controller.startRecording(displayID: displayID,
                                          region: region,
                                          audio: prefs.recordAudio,
                                          camera: prefs.recordCamera,
                                          fps: prefs.recordFPS,
                                          showCursor: prefs.recordShowCursor,
                                          format: prefs.recordFormat,
                                          quality: prefs.recordQuality,
                                          showsHUD: false)
            recorder = controller
            isRecording = true
            startDate = Date()
            recordButton?.image = NSImage(systemSymbolName: "stop.circle.fill",
                                          accessibilityDescription: "停止录制")?
                .withSymbolConfiguration(.init(pointSize: 14, weight: .medium))
            recordButton?.contentTintColor = .systemRed
            timeLabel?.isHidden = false
            timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
                DispatchQueue.main.async { self?.tick() }
            }
            tick()
            onRecordingChange?(true)
        } catch {
            model.presentError("无法开始录制：\(error.localizedDescription)")
        }
    }

    private func stopRecording() {
        guard let recorder else { return }
        recorder.stop(reason: .user)
        self.recorder = nil
        isRecording = false
        timer?.invalidate()
        timer = nil
        recordButton?.image = NSImage(systemSymbolName: "record.circle",
                                      accessibilityDescription: "开始录制")?
            .withSymbolConfiguration(.init(pointSize: 14, weight: .medium))
        timeLabel?.isHidden = true
        onRecordingChange?(false)
        // 录完自动收工具条（文件已落盘，给个反馈就撤）
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            self?.close(stopRecording: false)
        }
    }

    private func tick() {
        guard let startDate else { return }
        let elapsed = max(0, Int(Date().timeIntervalSince(startDate)))
        timeLabel?.stringValue = String(format: "%02d:%02d", elapsed / 60, elapsed % 60)
    }

    func close(stopRecording shouldStop: Bool) {
        if isRecording, shouldStop {
            stopRecording()
        }
        // 给 writer 一点收尾时间
        if shouldStop {
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
        framePanel?.orderOut(nil)
        toolbarPanel?.orderOut(nil)
        framePanel = nil
        toolbarPanel = nil
        popover?.close()
        popover = nil
        onClosed?()
    }

    private func installEscMonitor() {
        // ⚠️ 监听必须存下来在 teardown 里移除：controller 每次新建都装一个，
        // 曾经只加不删，事件链上越积越多。
        escMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.toolbarPanel != nil, event.keyCode == 53 else { return event }
            self.close(stopRecording: true)
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
        let content = NSViewController()
        content.view = RecordOptionsView(model: model)

        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = content
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

final class RecordOptionsView: NSView {

    private weak var model: AppModel?

    init(model: AppModel) {
        self.model = model
        super.init(frame: NSRect(x: 0, y: 0, width: 240, height: 170))

        let prefs = model.prefs.value

        let formatLabel = label("格式")
        let format = NSSegmentedControl(labels: ["MOV", "MP4"], trackingMode: .selectOne, target: self, action: #selector(formatChanged(_:)))
        format.selectedSegment = prefs.recordFormat == .mov ? 0 : 1

        let qualityLabel = label("质量")
        let quality = NSSegmentedControl(labels: ["高", "中等", "低"], trackingMode: .selectOne, target: self, action: #selector(qualityChanged(_:)))
        quality.selectedSegment = prefs.recordQuality == .high ? 0 : (prefs.recordQuality == .medium ? 1 : 2)

        let cursor = NSButton(checkboxWithTitle: "显示光标", target: self, action: #selector(cursorChanged(_:)))
        cursor.state = prefs.recordShowCursor ? .on : .off

        let note = NSTextField(wrappingLabelWithString: "输出保存到桌面；区域/全屏在工具条上选择。")
        note.font = NSFont.systemFont(ofSize: 11)
        note.textColor = .secondaryLabelColor
        note.frame = NSRect(x: 16, y: 8, width: 208, height: 30)

        let rows: [(NSView, NSView)] = [
            (formatLabel, format), (qualityLabel, quality), (NSView(), cursor),
        ]
        var y: CGFloat = 128
        for (left, right) in rows {
            left.frame = NSRect(x: 16, y: y, width: 52, height: 22)
            right.frame = NSRect(x: 76, y: y - 2, width: 150, height: 26)
            addSubview(left)
            addSubview(right)
            y -= 38
        }
        addSubview(note)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private func label(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = NSFont.systemFont(ofSize: 13)
        label.alignment = .right
        return label
    }

    @objc private func formatChanged(_ sender: NSSegmentedControl) {
        model?.prefs.value.recordFormat = sender.selectedSegment == 0 ? .mov : .mp4
    }

    @objc private func qualityChanged(_ sender: NSSegmentedControl) {
        switch sender.selectedSegment {
        case 0: model?.prefs.value.recordQuality = .high
        case 1: model?.prefs.value.recordQuality = .medium
        default: model?.prefs.value.recordQuality = .low
        }
    }

    @objc private func cursorChanged(_ sender: NSButton) {
        model?.prefs.value.recordShowCursor = sender.state == .on
    }
}
