import AppKit
import AVFoundation

// ============================================================
// 摄像头取景框（录制时右下角那个圆形 / 圆角矩形小窗）
//
// 🔴 它是**真的屏幕窗口**，不是叠加层：录进视频的方式就是"被 ScreenCaptureKit
// 拍到"，而不是在编码端再合成一次（Recorder 那条画中画合成路径不再启用）。
// 原因很实际 —— 想"窗口在屏幕上可见、但又不进录像"只有一个办法：把它塞进
// SCContentFilter.excludingWindows。可我们的面板在 .floating / .statusBar 层，
// 而 SCShareableContent.windows 基本只列 layer-0 普通窗口，压根拿不到它，
// excluding 是空操作（滚动截图取景框那次已经踩过一模一样的坑）。
// 所以这里选"所见即所得"：屏幕上什么样，视频里就什么样。
//
// 附带好处：形状（圆形 / 圆角矩形）、位置、开关全都是所见即所得，
// 不需要在编码侧再维持一套坐标，改形状也不用动视频管线。
// ============================================================

@MainActor
final class CameraBubbleController {

    enum BubbleShape {
        case circle
        case roundedRect
    }

    /// 取景框摆哪儿：两种录制模式两种口径
    enum Placement {
        case bottomTrailing   // 区域 / 全屏录制：贴选区右下角（1.0.20 之前的口径）
        case centered         // 摄像头录制：摆在固定录制框正中
    }

    /// 关掉取景框（用户点了 ✕）—— 工具条据此同步按钮状态
    var onClose: (() -> Void)?

    private var panel: NSPanel?
    private var previewView: CameraPreviewView?
    private var session: AVCaptureSession?
    private(set) var shape: BubbleShape = .circle
    private var lastAnchor: CGRect = .zero
    /// 取景框大小档位（设置 → 录制 → 取景框大小；弹层里切换要实时生效，所以是 var）
    private(set) var size: CameraBubbleSize
    private let placement: Placement
    /// 贴右下角时离右 / 下边的内缩（pt）。设置里可调，录着改也要立刻生效。
    private var inset: CGFloat

    init(size: CameraBubbleSize,
         placement: Placement = .bottomTrailing,
         inset: CGFloat = CameraBubbleController.defaultBottomTrailingInset) {
        self.size = size
        self.placement = placement
        self.inset = inset
    }

    /// 同一档位在两种模式下的实际点数不同（画中画 200/150/100，摄像头录制 680/600/500）
    private var side: CGFloat {
        placement == .centered ? size.cameraSide : size.side
    }

    /// 弹层 / 设置里切换档位时实时生效：只改窗口大小和位置，摄像头会话不动
    /// （重建会话会黑一下，没必要）。
    func resize(to newSize: CameraBubbleSize) {
        guard newSize != size else { return }
        size = newSize
        if let panel { position(panel, anchor: lastAnchor) }
    }

    /// 边距在设置里改了：只挪位置，不动窗口大小、也不重建会话
    func applyInset(_ newInset: CGFloat) {
        guard newInset != inset else { return }
        inset = newInset
        if let panel { position(panel, anchor: lastAnchor) }
    }

    var isVisible: Bool { panel != nil }

    /// 取景框窗口号：录制时需要把它从"排除自家窗口"里挑出来，
    /// 否则摄像头的画面根本进不了成片（详见 Recorder.keepVisibleWindowNumbers）
    var windowNumber: Int { panel?.windowNumber ?? 0 }

    /// anchor 是录制框在 AppKit 全局坐标里的框。
    func show(anchor: CGRect) {
        lastAnchor = anchor
        if let panel {
            position(panel, anchor: anchor)
            return
        }

        let side = fittedSide(for: anchor)
        let frame = CGRect(origin: .zero, size: CGSize(width: side, height: side))
        let view = CameraPreviewView(frame: frame, shape: shape)
        view.onClose = { [weak self] in self?.close() }
        view.onToggleShape = { [weak self] in self?.toggleShape() }

        let panel = NSPanel(contentRect: frame,
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        // .floating：盖住被录的应用，但让工具条（.statusBar）压在自己上面
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = view
        self.panel = panel
        self.previewView = view

        startSession()
        position(panel, anchor: anchor)
        panel.orderFront(nil)
    }

    func toggleShape() {
        shape = (shape == .circle) ? .roundedRect : .circle
        previewView?.apply(shape: shape)
        if let panel { position(panel, anchor: lastAnchor) }
    }

    func close() {
        stopSession()
        panel?.orderOut(nil)
        panel = nil
        previewView = nil
        onClose?()
        onClose = nil
    }

    // ── 位置 ────────────────────────────────────────────────

    /// 取景框实际边长：档位点数在放不下时才收（最小 96pt）。
    ///
    /// 两种模式的收法不同，因为诉求相反：
    /// · 画中画（右下角小窗）：按短边 **45%** 收 —— 170pt 的圆压在 300×200 的选区上
    ///   会把被录内容盖掉大半，这种极端情况必须缩。
    /// · 摄像头录制（居中大窗）：只在**真的塞不进**录制框**时才收（按 100% 短边）——
    ///   用户口径是"我设 680 就是 680"，680 的圆放进 721 高的框里就该原样落地。
    static func fittedSide(wanted: CGFloat, anchor: CGRect, placement: Placement) -> CGFloat {
        let ratio: CGFloat = (placement == .centered) ? 1.0 : 0.45
        return min(wanted, max(96, min(anchor.width, anchor.height) * ratio))
    }

    private func fittedSide(for anchor: CGRect) -> CGFloat {
        Self.fittedSide(wanted: side, anchor: anchor, placement: placement)
    }

    /// 画中画贴右下角时的默认内缩（pt）。**真正用的是 `inset` 这个实例属性**
    /// （设置 → 录制 → 取景框边距，`Preferences.recordCameraInset`），
    /// 这里只是构造时的兜底值。
    nonisolated static let defaultBottomTrailingInset: CGFloat = 30

    /// 画中画的原点（AppKit 左下原点）。纯函数是为了让自检能盯住
    /// 「右边缝 = inset、下边缝 = inset」这两件事 —— 符号写反了窗口会跑到框外，
    /// 而 AppKit 钳位后看着像"位置不对"，很难靠肉眼定位。
    static func bottomTrailingOrigin(anchor: CGRect, size: CGSize,
                                     inset: CGFloat = defaultBottomTrailingInset) -> CGPoint {
        CGPoint(x: anchor.maxX - size.width - inset, y: anchor.minY + inset)
    }

    /// 落位：画中画贴右下角，摄像头录制摆正中
    private func position(_ panel: NSPanel, anchor: CGRect) {
        var size = panel.frame.size
        size.width = fittedSide(for: anchor)
        size.height = (shape == .circle) ? size.width : size.width * 0.75
        if abs(panel.frame.width - size.width) > 0.5 || abs(panel.frame.height - size.height) > 0.5 {
            panel.setContentSize(size)
        }
        let x: CGFloat
        let y: CGFloat
        switch placement {
        case .bottomTrailing:
            let origin = Self.bottomTrailingOrigin(anchor: anchor, size: size, inset: inset)
            x = origin.x
            y = origin.y
        case .centered:
            x = anchor.midX - size.width / 2
            y = anchor.midY - size.height / 2
        }
        panel.setFrameOrigin(NSPoint(x: x, y: y))
        // 落位诊断：坐标是 AppKit 全局（左下原点），和录制框同一个坐标系。
        // 「取景框怎么没在框中间」这类问题，只有把两个矩形打出来才对得上账。
        NSLog("[BoxShot] 取景框落位 框=(%.0f,%.0f %.0f×%.0f) 取景框=%.0f×%.0f → (%.0f,%.0f)",
              anchor.minX, anchor.minY, anchor.width, anchor.height,
              size.width, size.height, x, y)
    }

    // ── 采集 ────────────────────────────────────────────────

    private func startSession() {
        AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
            guard granted else {
                DispatchQueue.main.async { self?.previewView?.showFallback("没有摄像头权限") }
                return
            }
            DispatchQueue.main.async { self?.configureSession() }
        }
    }

    private func configureSession() {
        let session = AVCaptureSession()
        session.sessionPreset = .high
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front)
                ?? AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else {
            previewView?.showFallback("找不到摄像头")
            return
        }
        session.addInput(input)
        self.session = session

        guard let layer = previewView?.previewLayer else { return }
        layer.session = session
        // 自拍镜像：不镜像的话用户看到自己的手是反的，很容易以为坏了
        if let connection = layer.connection, connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = true
        }
        // startRunning 会阻塞到硬件就绪，绝不能放主线程
        DispatchQueue.global(qos: .userInitiated).async {
            session.startRunning()
        }
    }

    private func stopSession() {
        let session = self.session
        self.session = nil
        previewView?.previewLayer.session = nil
        guard let session, session.isRunning else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            session.stopRunning()
        }
    }
}

// ── 预览视图：圆角裁切 + 镜像 + 右上角关闭 ────────────────────

final class CameraPreviewView: NSView {

    let previewLayer = AVCaptureVideoPreviewLayer()
    var onClose: (() -> Void)?
    var onToggleShape: (() -> Void)?

    private let closeButton = NSButton()
    private let fallbackLabel = NSTextField(labelWithString: "")
    private var shape: CameraBubbleController.BubbleShape

    /// 独立取景窗（摄像头录制）自己控制条上有 ✕，画面里就别再挂一个
    var showsCloseButton = true {
        didSet { closeButton.isHidden = !showsCloseButton }
    }

    init(frame: NSRect, shape: CameraBubbleController.BubbleShape) {
        self.shape = shape
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.borderColor = NSColor.white.withAlphaComponent(0.85).cgColor
        layer?.borderWidth = 1.5
        layer?.masksToBounds = true

        previewLayer.videoGravity = .resizeAspectFill
        previewLayer.frame = bounds
        layer?.addSublayer(previewLayer)

        closeButton.bezelStyle = .circular
        closeButton.isBordered = false
        closeButton.image = NSImage(systemSymbolName: "xmark.circle.fill",
                                    accessibilityDescription: "关闭摄像头")
        closeButton.contentTintColor = .white
        closeButton.imageScaling = .scaleNone
        closeButton.target = self
        closeButton.action = #selector(closeClicked)
        closeButton.toolTip = "关闭摄像头取景框"
        addSubview(closeButton)

        fallbackLabel.font = .systemFont(ofSize: 11, weight: .medium)
        fallbackLabel.textColor = .white
        fallbackLabel.alignment = .center
        fallbackLabel.isHidden = true
        addSubview(fallbackLabel)

        apply(shape: shape)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func layout() {
        super.layout()
        previewLayer.frame = bounds
        // resize() 只改窗口大小，圆角要跟着新边长算，否则圆形放大后会缺一角
        layer?.cornerRadius = (shape == .circle) ? bounds.width / 2 : 18
        let side: CGFloat = 22
        closeButton.frame = NSRect(x: bounds.maxX - side - 4, y: bounds.maxY - side - 4,
                                   width: side, height: side)
        fallbackLabel.frame = NSRect(x: 8, y: bounds.midY - 10, width: bounds.width - 16, height: 20)
    }

    func apply(shape: CameraBubbleController.BubbleShape) {
        self.shape = shape
        layer?.cornerRadius = (shape == .circle) ? bounds.width / 2 : 18
    }

    func showFallback(_ text: String) {
        fallbackLabel.stringValue = text
        fallbackLabel.isHidden = false
        previewLayer.isHidden = true
    }

    @objc private func closeClicked() {
        onClose?()
    }

    /// 换形状（圆形 ⇄ 圆角矩形）——用户要求"可以是圆形或圆角矩形"。
    ///
    /// 🔴 1.0.18 起**单击**也切换：以前只认右键，用户找不到入口（原话
    /// "点击摄像头框区域可以切换成圆角矩形"）。右键保留，习惯了的照旧。
    override func mouseDown(with event: NSEvent) {
        onToggleShape?()
    }

    override func rightMouseDown(with event: NSEvent) {
        onToggleShape?()
    }
}
