import AVFoundation
import CoreGraphics
import CoreImage
import ScreenCaptureKit

// ============================================================
// 屏幕录制
//
// 管线：
//   SCStream ──视频帧(CVPixelBuffer)──→ [可选: 摄像头画中画合成] ──→ AVAssetWriter
//            └─系统音频(CMSampleBuffer)──────────────────────────→ AVAssetWriter
//   AVCaptureSession(麦克风) ─音频帧(CMSampleBuffer)─────────────→ AVAssetWriter
//
// 输出 MOV (H.264 + AAC)。
//
// 关键时序：AVAssetWriter 要 startSession(atSourceTime:)，统一用**第一帧
// 视频的 PTS** 作为会话起点；音频帧在会话开始前到达直接丢弃（丢零点几秒
// 开头的声音，比留一个 PTS 早于会话起点的坏文件强）。
//
// 线程约定：本类**不是** MainActor。SCStream 的回调在内部串行队列上，
// AVCapture 的回调在各自的 delegate queue 上；只有 HUD / 状态回调回主线程。
// 会话中的可变状态（writer / inputs / sessionStarted）只在启动前写、
// stopCapture 之后再清理，运行期只读。
// ============================================================

final class RecorderController: NSObject {

    enum Reason { case user, quit }

    var onStateChange: (@MainActor (Bool) -> Void)?
    var onError: (@MainActor (String) -> Void)?
    /// 录制完成后在 Finder 里定位文件（默认关，由工具条按设置传入）
    var revealInFinderOnFinish = false

    private var stream: SCStream?
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var videoAdaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var systemAudioInput: AVAssetWriterInput?
    private var micAudioInput: AVAssetWriterInput?

    private var captureSession: AVCaptureSession?
    private var ciContext: CIContext?

    /// 摄像头最近一帧（摄像头自己的 delegate queue 写，视频帧队列读）。
    /// 用 NSLock 保护：两边的回调频率都高，读写竞争真实存在。
    private let cameraLock = NSLock()
    private var cameraCIImage: CIImage?

    private var sessionStarted = false
    private var isStopping = false
    private var hasOutput = false
    private var outputURL: URL?
    private var hud: RecordHUD?
    /// 用工具条录制时不再弹自带 HUD（曾经两个"计时+停止"同时上屏）
    private var showsHUD = true

    // ── 启动 ────────────────────────────────────────────────

    /// region 为 nil = 全屏；否则为显示器局部坐标（点）
    func startRecording(displayID: CGDirectDisplayID, region: CGRect?, audio: RecordAudioSource,
                        camera: Bool, fps: Int, showCursor: Bool,
                        format: RecordFileFormat = .mov, quality: RecordQuality = .high,
                        showsHUD: Bool = true) throws {
        guard writer == nil else { return }
        self.showsHUD = showsHUD
        let url = Support.uniqueFileURL(in: Support.defaultSaveDirectory,
                                        name: Support.shotFileName(prefix: "boxshot-rec",
                                                                   ext: format.fileExtension))
        outputURL = url

        let writer = try AVAssetWriter(outputURL: url,
                                       fileType: format == .mp4 ? .mp4 : .mov)
        self.writer = writer

        let scale = ScreenCapture.scaleFactor(for: displayID)
        let displayBounds = ScreenCapture.displayBoundsGlobal(displayID)
        let sourceRect = region ?? CGRect(origin: .zero, size: displayBounds.size)
        let pixelW = Int(sourceRect.width * scale)
        let pixelH = Int(sourceRect.height * scale)

        // ── 视频输入（码率按质量档：像素 × 帧率 × 系数）──
        let bitrate = Int(Double(pixelW * pixelH) * Double(max(10, fps)) * quality.bitrateFactor)
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: pixelW,
            AVVideoHeightKey: pixelH,
            AVVideoAverageBitRateKey: bitrate,
        ]
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = true
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: videoInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: pixelW,
                kCVPixelBufferHeightKey as String: pixelH,
            ])
        if writer.canAdd(videoInput) { writer.add(videoInput) }
        self.videoInput = videoInput
        self.videoAdaptor = adaptor

        // ── 音频输入（AAC 48k 立体声）──
        let audioSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48000,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 128_000,
        ]
        if audio == .system {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            input.expectsMediaDataInRealTime = true
            if writer.canAdd(input) { writer.add(input) }
            systemAudioInput = input
        }
        if audio == .mic {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            input.expectsMediaDataInRealTime = true
            if writer.canAdd(input) { writer.add(input) }
            micAudioInput = input
        }

        if camera {
            ciContext = CIContext(options: [:])
        }

        guard writer.startWriting() else {
            throw writer.error ?? NSError(domain: "BoxShot", code: 1,
                                          userInfo: [NSLocalizedDescriptionKey: "无法创建录制文件"])
        }

        // ── 麦克风 ──
        if audio == .mic {
            requestMicThenCapture()
        }

        // ── SCStream ──
        Task {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
                guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
                    throw NSError(domain: "BoxShot", code: 2,
                                  userInfo: [NSLocalizedDescriptionKey: "找不到目标显示器"])
                }
                // 排除自己：录制浮条 / 贴图不进画面
                let ownWindows = content.windows.filter {
                    $0.owningApplication?.bundleIdentifier == Bundle.main.bundleIdentifier
                }
                let filter = SCContentFilter(display: display, excludingWindows: ownWindows)

                let config = SCStreamConfiguration()
                config.captureResolution = .best
                config.sourceRect = sourceRect
                config.width = pixelW
                config.height = pixelH
                config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(max(10, min(60, fps))))
                config.queueDepth = 8
                config.showsCursor = showCursor
                config.capturesAudio = (audio == .system)
                config.sampleRate = 48000
                config.channelCount = 2
                config.excludesCurrentProcessAudio = true

                let stream = SCStream(filter: filter, configuration: config, delegate: nil)
                try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: nil)
                if audio == .system {
                    try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: nil)
                }
                self.stream = stream
                if camera {
                    startCameraCapture()
                }
                try await stream.startCapture()

                DispatchQueue.main.async {
                    self.showHUD()
                    self.notifyState(true)
                }
            } catch {
                self.teardownPipeline()
                DispatchQueue.main.async {
                    self.onError?("无法开始录制：\(error.localizedDescription)")
                }
            }
        }
    }

    // ── 停止 ────────────────────────────────────────────────

    func stop(reason: Reason) {
        guard !isStopping else { return }
        isStopping = true

        let streamRef = stream
        let writerRef = writer
        let hadOutput = hasOutput
        let url = outputURL

        // 1) 先停流（没有新帧了），2) 再 finishWriting（拿到完整文件），
        //    3) 最后回主线程收 HUD。
        Task {
            try? await streamRef?.stopCapture()
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                DispatchQueue.global().async {
                    if let writer = writerRef {
                        let semaphore = DispatchSemaphore(value: 0)
                        writer.finishWriting { semaphore.signal() }
                        _ = semaphore.wait(timeout: .now() + 10)
                    }
                    continuation.resume()
                }
            }
            DispatchQueue.main.async {
                self.hud?.close()
                self.hud = nil
                self.teardownPipeline()
                self.notifyState(false)
                if reason == .user && hadOutput, let url {
                    Support.playFeedbackSound()
                    NSLog("[BoxShot] 录制完成：\(url.path)")
                    // 文件别"人间蒸发"：按设置在 Finder 里定位
                    if self.revealInFinderOnFinish {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    }
                }
            }
        }
    }

    private func teardownPipeline() {
        captureSession?.stopRunning()
        captureSession = nil
        stream = nil
        writer = nil
        videoInput = nil
        videoAdaptor = nil
        systemAudioInput = nil
        micAudioInput = nil
        cameraLock.lock(); cameraCIImage = nil; cameraLock.unlock()
        ciContext = nil
        sessionStarted = false
        isStopping = false
        hasOutput = false
        outputURL = nil
    }

    private func notifyState(_ recording: Bool) {
        MainActor.assumeIsolated { self.onStateChange?(recording) }
    }

    // ── HUD ─────────────────────────────────────────────────

    private func showHUD() {
        guard showsHUD else { return }
        MainActor.assumeIsolated {
            let hud = RecordHUD()
            hud.onStop = { [weak self] in self?.stop(reason: .user) }
            hud.show()
            self.hud = hud
        }
    }

    // ── 摄像头（画中画） ─────────────────────────────────────

    private func startCameraCapture() {
        let session = AVCaptureSession()
        session.sessionPreset = .high
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front)
                ?? AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device) else {
            DispatchQueue.main.async { self.onError?("找不到可用摄像头，本次录制不含画中画") }
            return
        }
        session.beginConfiguration()
        if session.canAddInput(input) { session.addInput(input) }
        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.setSampleBufferDelegate(self, queue: DispatchQueue(label: "boxshot.camera"))
        if session.canAddOutput(output) { session.addOutput(output) }
        session.commitConfiguration()
        session.startRunning()
        captureSession = session
    }

    private func requestMicThenCapture() {
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            guard granted else {
                DispatchQueue.main.async {
                    self.onError?("没有麦克风权限，本次录制无声（可在系统设置里授权）")
                }
                return
            }
            DispatchQueue.main.async { self.beginMicCapture() }
        }
    }

    private func beginMicCapture() {
        let session = AVCaptureSession()
        guard let device = AVCaptureDevice.default(for: .audio),
              let input = try? AVCaptureDeviceInput(device: device) else {
            DispatchQueue.main.async { self.onError?("找不到可用麦克风，本次录制无声") }
            return
        }
        session.beginConfiguration()
        if session.canAddInput(input) { session.addInput(input) }
        let output = AVCaptureAudioDataOutput()
        output.setSampleBufferDelegate(self, queue: DispatchQueue(label: "boxshot.mic"))
        if session.canAddOutput(output) { session.addOutput(output) }
        session.commitConfiguration()
        session.startRunning()
        captureSession = session
    }
}

// ── SCStream 输出：视频 + 系统音频 ───────────────────────────

extension RecorderController: SCStreamOutput {

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard !isStopping, let writer else { return }
        switch type {
        case .screen:
            guard let videoInput, let videoAdaptor,
                  CMSampleBufferDataIsReady(sampleBuffer),
                  let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
            let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            if !sessionStarted {
                writer.startSession(atSourceTime: pts)
                sessionStarted = true
            }
            guard videoInput.isReadyForMoreMediaData else { return }
            hasOutput = true

            if ciContext != nil {
                // 摄像头画中画：GPU 合成后经池缓冲交给 writer
                composeAndAppend(screen: pixelBuffer, pts: pts, adaptor: videoAdaptor)
            } else {
                // 无摄像头：零拷贝直通
                videoInput.append(sampleBuffer)
            }

        case .audio:
            guard sessionStarted, CMSampleBufferDataIsReady(sampleBuffer) else { return }
            // 系统音频与麦克风共用"会话已开始"的门；各自的 input 独立 ready
            if let input = systemAudioInput, input.isReadyForMoreMediaData {
                input.append(sampleBuffer)
            } else if systemAudioInput == nil, let micInput = micAudioInput, micInput.isReadyForMoreMediaData {
                // 理论不会走到（SCStream 只在 system 音源时才给音频）——兜底
                micInput.append(sampleBuffer)
            }

        default:
            break
        }
    }

    private func composeAndAppend(screen: CVPixelBuffer, pts: CMTime, adaptor: AVAssetWriterInputPixelBufferAdaptor) {
        guard let ciContext, let pool = adaptor.pixelBufferPool else { return }
        let screenImage = CIImage(cvPixelBuffer: screen)
        var composed = screenImage

        cameraLock.lock()
        let camera = cameraCIImage
        cameraLock.unlock()

        if let camera {
            // 小窗放右下角，宽 = 画面宽 / 5，水平镜像（自拍直觉），上下留 4% 边距
            let extent = screenImage.extent
            let pipW = extent.width / 5
            let margin = extent.width * 0.03
            let s = pipW / camera.extent.width
            // 先镜像缩放（x 取负），再平移到右下角
            let transform = CGAffineTransform(translationX: extent.maxX - margin + pipW, y: extent.minY + margin)
                .scaledBy(x: -s, y: s)
            composed = camera.transformed(by: transform).composited(over: composed)
        }

        var outBuffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &outBuffer)
        guard let outBuffer else { return }
        ciContext.render(composed, to: outBuffer,
                         bounds: screenImage.extent,
                         colorSpace: CGColorSpaceCreateDeviceRGB())
        adaptor.append(outBuffer, withPresentationTime: pts)
    }
}

// ── AVCapture 输出：摄像头帧 / 麦克风帧 ──────────────────────

extension RecorderController: AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        if output is AVCaptureVideoDataOutput {
            // 摄像头帧：只缓存最近一帧，等视频帧到货时合成
            if let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) {
                cameraLock.lock()
                cameraCIImage = CIImage(cvPixelBuffer: pixelBuffer)
                cameraLock.unlock()
            }
        } else if output is AVCaptureAudioDataOutput {
            guard sessionStarted, CMSampleBufferDataIsReady(sampleBuffer),
                  let micAudioInput, micAudioInput.isReadyForMoreMediaData else { return }
            micAudioInput.append(sampleBuffer)
        }
    }
}

// ============================================================
// 录制浮条：时长 + 停止按钮
// ============================================================

@MainActor
final class RecordHUD: NSPanel {

    var onStop: (() -> Void)?

    private let timeLabel = NSTextField(labelWithString: "00:00")
    private var timer: Timer?
    private var startDate = Date()

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 148, height: 40),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        level = .statusBar
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let container = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: 148, height: 40))
        container.material = .hudWindow
        container.state = .active
        container.wantsLayer = true
        container.layer?.cornerRadius = 20

        let stopButton = NSButton(title: "", target: self, action: #selector(stopClicked))
        stopButton.bezelStyle = .circular
        stopButton.image = NSImage(systemSymbolName: "stop.fill", accessibilityDescription: "停止录制")
        stopButton.frame = NSRect(x: 10, y: 8, width: 24, height: 24)

        timeLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 14, weight: .semibold)
        timeLabel.textColor = .white
        timeLabel.frame = NSRect(x: 42, y: 11, width: 90, height: 18)

        container.addSubview(stopButton)
        container.addSubview(timeLabel)
        contentView = container
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func show() {
        guard let screen = NSScreen.main else { return }
        startDate = Date()
        let x = screen.frame.maxX - frame.width - 24
        let y = screen.frame.maxY - frame.height - 12
        setFrameOrigin(NSPoint(x: x, y: y))
        makeKeyAndOrderFront(nil)
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            DispatchQueue.main.async { self?.tick() }
        }
        tick()
    }

    private func tick() {
        let elapsed = max(0, Int(Date().timeIntervalSince(startDate)))
        timeLabel.stringValue = String(format: "%02d:%02d", elapsed / 60, elapsed % 60)
    }

    @objc private func stopClicked() {
        onStop?()
    }

    override func close() {
        timer?.invalidate()
        timer = nil
        super.close()
    }
}
