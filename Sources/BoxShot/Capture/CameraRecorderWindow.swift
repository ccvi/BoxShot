import AppKit
import AVFoundation

// ============================================================
// 摄像头录制取景窗（1.0.18，用户要求「就只录制摄像头」）
//
// 窗口 = 上方方形预览 + 下方一条控制条：
//   [✕] [大|中|小]              [00:00] [● 录制]
// 预览复用 `CameraPreviewView`：镜像、圆角裁切、单击换形状都在它里面，
// 和录屏右下角那个画中画取景框是同一份代码 —— 免得两处行为不一致。
//
// 🔴 预览与录制共用同一个 AVCaptureSession（见 Recorder.prepareCameraOnlyPreview）：
// 同一台摄像头开两份会话会互相抢硬件，常见症状是"预览有画面、录出来全黑"。
// ============================================================

@MainActor
final class CameraRecorderWindowController: NSObject {

    var onClosed: (() -> Void)?
    var onRecordingChange: ((Bool) -> Void)?

    /// 控制条高度（预览高度 = 边长，所以窗口高 = 边长 + 这条）
    static let barHeight: CGFloat = 56

    /// 圆形 = 正方形画幅；圆角矩形沿用取景框的 4:3（宽 × 0.75）
    static func previewHeight(side: CGFloat, shape: CameraBubbleController.BubbleShape) -> CGFloat {
        shape == .circle ? side : side * 0.75
    }

    /// 窗口内容高度：预览 + 控制条
    static func contentHeight(side: CGFloat, shape: CameraBubbleController.BubbleShape) -> CGFloat {
        previewHeight(side: side, shape: shape) + barHeight
    }

    private weak var model: AppModel?
    private var panel: NSPanel?
    private var container: NSView?
    private var previewView: CameraPreviewView?
    private var bar: NSView?
    private var closeButton: NSButton?
    private var sizeControl: NSSegmentedControl?
    private var timeLabel: NSTextField?
    private var recordButton: NSButton?

    /// 会话与 writer 都由它管：录完一次还能再录，不用重建会话
    private let recorder = RecorderController()
    private var isRecording = false
    private var startingUp = false
    private var timer: Timer?
    private var startDate: Date?
    /// 音频提醒只弹一次：设置里选了「系统声音」时，每次点录制都弹框太烦，
    /// 但完全不说话又会让人拿到一个无声文件还不知道
    private var warnedAudio = false
    private var shape: CameraBubbleController.BubbleShape = .circle

    init(model: AppModel) {
        self.model = model
        super.init()
    }

    private var size: CameraBubbleSize {
        model?.prefs.value.cameraWindowSize ?? .large
    }

    /// 圆形 = 正方形画幅；圆角矩形沿用取景框的 4:3（宽 × 0.75）
    private func previewHeight(for side: CGFloat) -> CGFloat {
        Self.previewHeight(side: side, shape: shape)
    }

    // ── 窗口 ────────────────────────────────────────────────

    func show() {
        guard panel == nil else { return }
        let side = size.windowSide
        let contentHeight = Self.contentHeight(side: side, shape: shape)

        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: side, height: contentHeight),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        // 程序化窗口默认 close() 会自我释放，和 ARC 抢着放 → 随机闪退
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let container = NSView(frame: NSRect(x: 0, y: 0, width: side, height: contentHeight))
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor(calibratedWhite: 0.13, alpha: 1).cgColor
        container.layer?.cornerRadius = 14
        container.layer?.masksToBounds = true
        panel.contentView = container

        let preview = CameraPreviewView(frame: .zero, shape: shape)
        // 控制条上本来就有 ✕，画面里再挂一个就是两套按钮
        preview.showsCloseButton = false
        preview.onToggleShape = { [weak self] in self?.toggleShape() }
        container.addSubview(preview)

        let bar = DragBarView(frame: .zero)
        bar.wantsLayer = true
        bar.layer?.backgroundColor = NSColor(calibratedWhite: 0.09, alpha: 1).cgColor
        container.addSubview(bar)

        let close = NSButton(title: "", target: self, action: #selector(closeClicked))
        close.isBordered = false
        close.bezelStyle = .regularSquare
        close.image = NSImage(systemSymbolName: "xmark.circle.fill",
                              accessibilityDescription: "关闭")?
            .withSymbolConfiguration(.init(pointSize: 16, weight: .medium))
        close.contentTintColor = .secondaryLabelColor
        close.toolTip = "关闭取景窗"
        bar.addSubview(close)

        let segmented = NSSegmentedControl(labels: CameraBubbleSize.allCases.map { $0.title },
                                           trackingMode: .selectOne,
                                           target: self, action: #selector(sizeChanged(_:)))
        if let idx = CameraBubbleSize.allCases.firstIndex(of: size) {
            segmented.selectedSegment = idx
        }
        bar.addSubview(segmented)

        let time = NSTextField(labelWithString: "00:00")
        time.font = NSFont.monospacedDigitSystemFont(ofSize: 15, weight: .semibold)
        time.textColor = .white
        time.alignment = .right
        time.isHidden = true
        bar.addSubview(time)

        let record = NSButton(title: "录制", target: self, action: #selector(toggleRecording))
        record.bezelStyle = .rounded
        record.image = NSImage(systemSymbolName: "record.circle", accessibilityDescription: "开始录制")?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .semibold))
        record.imagePosition = .imageLeading
        record.contentTintColor = .systemRed
        record.sizeToFit()
        bar.addSubview(record)

        self.panel = panel
        self.container = container
        self.previewView = preview
        self.bar = bar
        self.closeButton = close
        self.sizeControl = segmented
        self.timeLabel = time
        self.recordButton = record

        layoutContents()
        position(panel)
        panel.orderFront(nil)
        startPreview()
    }

    private func layoutContents() {
        guard let container, let previewView, let bar, let panel else { return }
        let side = size.windowSide
        let previewH = previewHeight(for: side)
        let height = previewH + Self.barHeight

        if abs(panel.frame.width - side) > 0.5 || abs(panel.frame.height - height) > 0.5 {
            panel.setContentSize(NSSize(width: side, height: height))
            container.frame = NSRect(x: 0, y: 0, width: side, height: height)
        }
        previewView.frame = NSRect(x: 0, y: Self.barHeight, width: side, height: previewH)
        bar.frame = NSRect(x: 0, y: 0, width: side, height: Self.barHeight)

        closeButton?.frame = NSRect(x: 12, y: (Self.barHeight - 22) / 2, width: 22, height: 22)
        sizeControl?.frame = NSRect(x: 46, y: (Self.barHeight - 24) / 2, width: 148, height: 24)

        if let record = recordButton {
            record.sizeToFit()
            record.frame.origin = NSPoint(x: side - 14 - record.frame.width,
                                          y: (Self.barHeight - record.frame.height) / 2)
        }
        if let time = timeLabel, let record = recordButton {
            time.frame = NSRect(x: record.frame.minX - 10 - 62,
                                y: (Self.barHeight - 18) / 2, width: 62, height: 18)
        }
    }

    private func position(_ panel: NSPanel) {
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        let x = visible.midX - panel.frame.width / 2
        // 略高于正中：避开 Dock，也不至于顶到菜单栏
        let y = visible.minY + max(40, (visible.height - panel.frame.height) * 0.55)
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    // ── 预览 ────────────────────────────────────────────────

    private func startPreview() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            attachPreviewSession()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                DispatchQueue.main.async {
                    if granted {
                        self.attachPreviewSession()
                    } else {
                        self.previewView?.showFallback("没有摄像头权限")
                    }
                }
            }
        default:
            previewView?.showFallback("没有摄像头权限\n可在系统设置里授权")
        }
    }

    private func attachPreviewSession() {
        guard let session = recorder.prepareCameraOnlyPreview() else {
            previewView?.showFallback("找不到可用摄像头")
            return
        }
        guard let layer = previewView?.previewLayer else { return }
        layer.session = session
        // 自拍镜像：不镜像的话用户看到自己的手是反的
        if let connection = layer.connection, connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = true
        }
    }

    // ── 控制条动作 ──────────────────────────────────────────

    @objc private func sizeChanged(_ sender: NSSegmentedControl) {
        let all = CameraBubbleSize.allCases
        guard all.indices.contains(sender.selectedSegment) else { return }
        model?.prefs.value.cameraWindowSize = all[sender.selectedSegment]
        layoutContents()
    }

    /// 单击画面 / 点形状按钮都能换（用户要求：点取景框区域切圆角矩形）
    private func toggleShape() {
        shape = (shape == .circle) ? .roundedRect : .circle
        previewView?.apply(shape: shape)
        layoutContents()
    }

    @objc private func closeClicked() {
        close()
    }

    @objc private func toggleRecording() {
        if isRecording { stopRecording() } else { startRecording() }
    }

    private func startRecording() {
        guard let model else { return }
        let prefs = model.prefs.value

        recorder.revealInFinderOnFinish = prefs.recordRevealInFinder
        recorder.finishedSoundName = prefs.playSound ? prefs.feedbackSound : ""
        recorder.onStateChange = { [weak self] recording in
            guard let self, recording else { return }
            self.startingUp = false
            self.tick()
        }
        recorder.onError = { [weak self] message in
            guard let self else { return }
            self.isRecording = false
            self.startingUp = false
            self.resetRecordButton()
            self.onRecordingChange?(false)
            self.model?.presentError(message)
        }
        // 少一路麦克风 / 系统声音不算启动失败：说清楚，录制继续
        recorder.onWarning = { [weak self] message in
            NSLog("[BoxShot] 摄像头录制提醒：\(message)")
            guard let self else { return }
            self.timeLabel?.toolTip = message
            guard !self.warnedAudio else { return }
            self.warnedAudio = true
            self.model?.presentError(message)
        }

        do {
            try recorder.startCameraOnlyRecording(audio: prefs.recordAudio,
                                                  fps: prefs.recordFPS,
                                                  format: prefs.recordFormat,
                                                  quality: prefs.recordQuality,
                                                  showsHUD: false)
            isRecording = true
            startingUp = true
            startDate = Date()
            recordButton?.title = "停止"
            recordButton?.image = NSImage(systemSymbolName: "stop.circle.fill",
                                          accessibilityDescription: "停止录制")?
                .withSymbolConfiguration(.init(pointSize: 13, weight: .semibold))
            recordButton?.contentTintColor = .systemRed
            // 录制中给画面套一圈红框：一眼看得出在录
            previewView?.layer?.borderColor = NSColor.systemRed.cgColor
            previewView?.layer?.borderWidth = 3
            timeLabel?.isHidden = false
            timeLabel?.textColor = .white
            timeLabel?.stringValue = "启动中…"
            layoutContents()
            timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
                DispatchQueue.main.async { self?.tick() }
            }
            onRecordingChange?(true)
        } catch {
            resetRecordButton()
            model.presentError("无法开始录制：\(error.localizedDescription)")
        }
    }

    private func stopRecording() {
        guard isRecording else { return }
        recorder.stop(reason: .user)
        isRecording = false
        startingUp = false
        resetRecordButton()
        onRecordingChange?(false)
    }

    private func resetRecordButton() {
        timer?.invalidate()
        timer = nil
        recordButton?.title = "录制"
        recordButton?.image = NSImage(systemSymbolName: "record.circle", accessibilityDescription: "开始录制")?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .semibold))
        recordButton?.contentTintColor = .systemRed
        timeLabel?.isHidden = true
        previewView?.layer?.borderColor = NSColor.white.withAlphaComponent(0.85).cgColor
        previewView?.layer?.borderWidth = 1.5
        layoutContents()
    }

    private func tick() {
        guard let startDate, !startingUp else { return }
        let seconds = max(0, Int(Date().timeIntervalSince(startDate)))
        timeLabel?.stringValue = String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

    // ── 关闭 ────────────────────────────────────────────────

    /// 关窗前一定收尾：录制中直接关会把 writer 丢在半空（文件是 0 字节或坏的）
    func close() {
        if isRecording {
            recorder.stop(reason: .user)
            isRecording = false
            onRecordingChange?(false)
        }
        timer?.invalidate()
        timer = nil
        startingUp = false
        previewView?.previewLayer.session = nil
        recorder.shutdownCameraSession()
        panel?.orderOut(nil)
        panel = nil
        previewView = nil
        container = nil
        bar = nil
        onClosed?()
        onClosed = nil
    }
}

// ── 控制条：按住空白处拖窗口 ─────────────────────────────────

/// 画面点击要留给"换形状"，所以拖拽入口放在控制条背景上。
final class DragBarView: NSView {
    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }
}
