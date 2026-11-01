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

    /// 关掉取景框（用户点了 ✕）—— 工具条据此同步按钮状态
    var onClose: (() -> Void)?

    private var panel: NSPanel?
    private var previewView: CameraPreviewView?
    private var session: AVCaptureSession?
    private(set) var shape: BubbleShape = .circle
    private var lastAnchor: CGRect = .zero

    var isVisible: Bool { panel != nil }

    /// anchor 是选区在 AppKit 全局坐标里的框；取景框贴它的右下角内侧。
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

    /// 圆形要方框，圆角矩形可以宽一点；都以选区短边的 1/4 为上限，别把画面挡没了
    private func fittedSide(for anchor: CGRect) -> CGFloat {
        let limit = max(96, min(anchor.width, anchor.height) / 4)
        return min(200, limit)
    }

    private func position(_ panel: NSPanel, anchor: CGRect) {
        let inset: CGFloat = 18
        var size = panel.frame.size
        size.width = fittedSide(for: anchor)
        size.height = (shape == .circle) ? size.width : size.width * 0.75
        if abs(panel.frame.width - size.width) > 0.5 || abs(panel.frame.height - size.height) > 0.5 {
            panel.setContentSize(size)
        }
        let x = anchor.maxX - size.width - inset
        let y = anchor.minY + inset
        panel.setFrameOrigin(NSPoint(x: x, y: y))
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

    /// 右键换形状（圆形 ⇄ 圆角矩形）——用户要求"可以是圆形或圆角矩形"
    override func rightMouseDown(with event: NSEvent) {
        onToggleShape?()
    }
}
