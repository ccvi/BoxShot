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
    /// 非致命提醒（没麦克风 / 没摄像头这类）：录还是录得下去，只是少一路音视频。
    /// 和 onError 分开是必须的 —— 混在一起时，工具条会把"麦克风没授权"
    /// 当成"录制启动失败"，把好好的录制界面退回去。
    var onWarning: (@MainActor (String) -> Void)?
    /// 录制完成后在 Finder 里定位文件（默认关，由工具条按设置传入）
    var revealInFinderOnFinish = false
    /// 录制完成提示音（音效名由工具条按设置传入；关掉提示音时传空串）。
    /// 这里以前无条件播 Glass —— 设置里关掉提示音，录完还是会"叮"一声。
    var finishedSoundName: String = ""
    /// 属于本进程、但**必须留在画面里**的窗口号（摄像头取景框）。
    ///
    /// 🔴 排除自己窗口的规则是按 pid 一刀切，摄像头取景框刚好也在本进程里，
    /// 于是被一起排掉了 —— 用户看到的症状就是"录出来的视频没有摄像头画面"。
    /// 取景框的设计本来就是"所见即所得地被录进画面"，这一个窗口必须放过。
    var keepVisibleWindowNumbers: Set<Int> = []
    /// 诊断用：最近一次建过滤器时，自己有多少窗口被排除、有几个被保留
    private(set) var lastExclusionReport: String = ""

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
    /// 摄像头是否真的在用（决定视频帧要不要走合成路径）
    private var cameraActive = false

    private var sessionStarted = false
    private var isStopping = false
    private var hasOutput = false
    /// 诊断（--recordcamera）要拿它去抽帧核对，所以对外只读
    private(set) var outputURL: URL?
    private var hud: RecordHUD?
    /// 用工具条录制时不再弹自带 HUD（曾经两个"计时+停止"同时上屏）
    private var showsHUD = true

    // ── 暂停 / 恢复 ─────────────────────────────────────────
    //
    // 暂停不能真的"停流"（SCStream 一停，恢复时首帧要等几百毫秒，
    // 而且 writer 的会话起点会乱）。做法是照旧收帧、但全部丢弃，
    // 恢复后把"暂停这段时间"从后续帧的 PTS 里减掉 —— 这样成片里
    // 时间轴是连续的，不会出现一段卡住的静止画面。
    //
    // 时间轴补偿必须靠 PTS 算，不能靠墙钟：SCStream 的 PTS 来自
    // 主机时钟，两者刻度不同，混用会算出一个离谱的偏移量。
    //
    // 这些状态由主线程写、采集回调读，用一把锁保护。
    private let stateLock = NSLock()
    private var paused = false
    private var pausedTotal = CMTime.zero
    private var pausedAt: CMTime?
    private var lastVideoPTS: CMTime?
    private var awaitingResumeGap = false

    /// 界面只读：当前是否处于暂停
    var isPaused: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return paused
    }

    func setPaused(_ value: Bool) {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard paused != value else { return }
        paused = value
        if value {
            pausedAt = lastVideoPTS
        } else {
            // 恢复后的第一帧到达时再算这段空隙（那时才知道"现在"是多少）
            awaitingResumeGap = pausedAt != nil
            if pausedAt == nil { awaitingResumeGap = false }
        }
    }

    /// 麦克风授权只问一次（重复调用会叠出多条请求）
    private var micRequested = false
    /// 首帧只打一行日志：查"点了录制却一帧都没有"时，这行是分水岭
    private var loggedFirstFrame = false

    // ── 启动 ────────────────────────────────────────────────

    /// region 为 nil = 全屏；否则为显示器局部坐标（点）
    func startRecording(displayID: CGDirectDisplayID, region: CGRect?, audio: RecordAudioSource,
                        camera: Bool, fps: Int, showCursor: Bool,
                        format: RecordFileFormat = .mov, quality: RecordQuality = .high,
                        showsHUD: Bool = true) throws {
        // 🔴 这里以前是 `guard … else { return }`：真正的"点了录制没反应"。
        // 上一路录制还没收完尾就再点一次，函数静默返回，调用方以为已经在录，
        // 按钮变成停止、计时器开始走，可一帧都不会有。宁可抛错让用户看见原因。
        guard writer == nil, stream == nil, captureSession == nil else {
            throw NSError(domain: "BoxShot", code: 3, userInfo: [
                NSLocalizedDescriptionKey: "上一次录制还在收尾，请稍等一秒再试",
            ])
        }
        self.showsHUD = showsHUD

        let url = Support.uniqueFileURL(in: Support.defaultSaveDirectory,
                                        name: Support.shotFileName(prefix: "boxshot-rec",
                                                                   ext: format.fileExtension))
        outputURL = url

        let scale = ScreenCapture.scaleFactor(for: displayID)
        let displayBounds = ScreenCapture.displayBoundsGlobal(displayID)
        let sourceRect = region ?? CGRect(origin: .zero, size: displayBounds.size)
        // 🔴 H.264 要求宽高是偶数：奇数尺寸在部分编码器上直接拒绝/出花屏。
        // 选区是用户随手拖的，500×301 这种很常见，这里统一向下取偶数。
        let pixelW = max(2, Int(sourceRect.width * scale) & ~1)
        let pixelH = max(2, Int(sourceRect.height * scale) & ~1)

        let writer = try AVAssetWriter(outputURL: url,
                                       fileType: format == .mp4 ? .mp4 : .mov)
        self.writer = writer

        // ── 视频输入（码率按质量档：像素 × 帧率 × 系数）──
        // 具体口径见 `videoOutputSettings`（与摄像头录制共用一份，别在这里另抄）
        let videoSettings = Self.videoOutputSettings(pixelW: pixelW, pixelH: pixelH,
                                                     fps: fps, quality: quality)
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
        let audioSettings = Self.audioOutputSettings
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

        // CIContext 一律建：暂停后要走"重编时间戳"的合成路径，
        // 那条路必须有 CIContext（以前只在开摄像头时才建）。
        ciContext = CIContext(options: [:])

        guard writer.startWriting() else {
            throw writer.error ?? NSError(domain: "BoxShot", code: 1,
                                          userInfo: [NSLocalizedDescriptionKey: "无法创建录制文件"])
        }

        // ── 麦克风 ──
        // 🔴 这里原来连着写了两遍（`audio == .mic && !isGIF` 和 `audio == .mic`，GIF 时代留下的），
        // 于是每次录音都会建两个 AVCaptureSession：第二个把第一个从 captureSession
        // 上顶掉，第一个就此失控地一直跑着占着麦克风，两路音频输出还同时往同一个
        // writer input 上 append —— 轻则成片音轨错乱，重则 writer 直接报错。
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
                // 排除自己：录制浮条 / 贴图不进画面。
                // 🔴 按 pid 认自己，不按 bundleIdentifier —— 裸二进制调试时它是 nil，
                //   过滤结果恒为空，等于没排除。ScreenCapture.captureRegion 早就是 pid 口径，这里跟上。
                let ownPID = ProcessInfo.processInfo.processIdentifier
                let keep = keepVisibleWindowNumbers
                let ownWindows = content.windows.filter {
                    $0.owningApplication?.processID == ownPID && !keep.contains(Int($0.windowID))
                }
                let filter = SCContentFilter(display: display, excludingWindows: ownWindows)
                NSLog("[BoxShot] 录制排除自家窗口 %d 个（保留 %d 个：摄像头取景框）",
                      ownWindows.count, keep.count)
                self.lastExclusionReport = "排除 \(ownWindows.count) 个 · 保留 \(keep.count) 个 · 本进程窗口 \(content.windows.filter { $0.owningApplication?.processID == ownPID }.count) 个"

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
                NSLog("[BoxShot] 录制已开始 \(pixelW)×\(pixelH) → \(url.lastPathComponent)")

                DispatchQueue.main.async {
                    self.showHUD()
                    self.notifyState(true)
                }
            } catch {
                NSLog("[BoxShot] 录制启动失败：\(error)")
                self.teardownPipeline()
                DispatchQueue.main.async {
                    self.onError?("无法开始录制：\(error.localizedDescription)")
                }
            }
        }
    }

    /// H.264 视频输出设置（只有这一个来源，别在调用处另抄一份）。
    ///
    /// 🔴 码率**必须**藏在 AVVideoCompressionPropertiesKey 里面：放顶层是老的写法，
    /// macOS 26 直接抛 NSInvalidArgumentException，Swift 的 try/catch 接不住 →
    /// 进程当场 SIGABRT（"点一下录制应用就消失"）。
    /// 60fps 全屏能算出 100 Mbps 以上，编码器拒绝 → 封顶 80 Mbps。
    private static func videoOutputSettings(pixelW: Int, pixelH: Int, fps: Int,
                                            quality: RecordQuality) -> [String: Any] {
        let rawBitrate = Int(Double(pixelW * pixelH) * Double(max(10, fps)) * quality.bitrateFactor)
        let bitrate = min(rawBitrate, 80_000_000)
        return [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: pixelW,
            AVVideoHeightKey: pixelH,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitrate,
                AVVideoExpectedSourceFrameRateKey: max(10, fps),
                AVVideoMaxKeyFrameIntervalKey: max(10, fps),
            ],
        ]
    }

    /// AAC 48k 立体声
    private static let audioOutputSettings: [String: Any] = [
        AVFormatIDKey: kAudioFormatMPEG4AAC,
        AVSampleRateKey: 48000,
        AVNumberOfChannelsKey: 2,
        AVEncoderBitRateKey: 128_000,
    ]

    // ── 停止 ────────────────────────────────────────────────

    func stop(reason: Reason) {
        guard !isStopping else { return }
        isStopping = true

        let streamRef = stream
        let writerRef = writer
        let url = outputURL
        let hadOutput = hasOutput

        // 1) 先停流（没有新帧了），2) 再 finishWriting，3) 最后回主线程收 HUD。
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
                    Support.playFeedbackSound(named: self.finishedSoundName)
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
        cameraActive = false
        ciContext = nil
        sessionStarted = false
        isStopping = false
        hasOutput = false
        outputURL = nil
        micRequested = false
        loggedFirstFrame = false
        stateLock.lock()
        paused = false
        pausedTotal = .zero
        pausedAt = nil
        lastVideoPTS = nil
        awaitingResumeGap = false
        stateLock.unlock()
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
            DispatchQueue.main.async { self.onWarning?("找不到可用摄像头，本次录制不含画中画") }
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
        cameraActive = true
    }

    private func requestMicThenCapture() {
        // 幂等：TCC 面板弹着的时候再点一次"录制"，不该再发一次请求
        guard !micRequested else { return }
        micRequested = true
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            guard granted else {
                DispatchQueue.main.async {
                    self.onWarning?("没有麦克风权限，本次录制无声（可在系统设置里授权）")
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
            DispatchQueue.main.async { self.onWarning?("找不到可用麦克风，本次录制无声") }
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
        guard !isStopping else { return }
        switch type {
        case .screen:
            handleScreenBuffer(sampleBuffer)
        case .audio:
            handleAudioBuffer(sampleBuffer)
        default:
            break
        }
    }

    // ── 视频帧 ──

    private func handleScreenBuffer(_ sampleBuffer: CMSampleBuffer) {
        guard CMSampleBufferDataIsReady(sampleBuffer),
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

        // 时间轴：暂停期间整帧丢弃；恢复后把这段空隙从 PTS 里减掉。
        stateLock.lock()
        let pausedNow = paused
        if awaitingResumeGap, let pausePoint = pausedAt {
            pausedTotal = CMTimeAdd(pausedTotal, CMTimeSubtract(pts, pausePoint))
            awaitingResumeGap = false
            pausedAt = nil
        }
        if !pausedNow { lastVideoPTS = pts }
        let shift = pausedTotal
        stateLock.unlock()

        if pausedNow { return }

        if !loggedFirstFrame {
            loggedFirstFrame = true
            NSLog("[BoxShot] 录制收到首帧")
        }

        guard let writer, let videoInput, let videoAdaptor else { return }
        let adjusted = shift > .zero ? CMTimeSubtract(pts, shift) : pts
        if !sessionStarted {
            writer.startSession(atSourceTime: adjusted)
            sessionStarted = true
        }
        guard videoInput.isReadyForMoreMediaData else { return }
        hasOutput = true

        if shift > .zero || cameraActive {
            // 需要重编时间戳（暂停补偿）或叠加摄像头 → 走合成路径
            composeAndAppend(screen: pixelBuffer, pts: adjusted, adaptor: videoAdaptor)
        } else {
            // 无摄像头、没暂停过：零拷贝直通
            videoInput.append(sampleBuffer)
        }
    }

    // ── 音频帧 ──

    private func handleAudioBuffer(_ sampleBuffer: CMSampleBuffer) {
        guard CMSampleBufferDataIsReady(sampleBuffer) else { return }
        stateLock.lock()
        let pausedNow = paused
        let shift = pausedTotal
        stateLock.unlock()
        guard sessionStarted, !pausedNow else { return }

        let buffer = shift > .zero ? retimed(sampleBuffer, shift: shift) : sampleBuffer
        guard let buffer else { return }
        // 系统音频与麦克风各自的 input 独立 ready
        if let input = systemAudioInput, input.isReadyForMoreMediaData {
            input.append(buffer)
        } else if systemAudioInput == nil, let micInput = micAudioInput, micInput.isReadyForMoreMediaData {
            micInput.append(buffer)
        }
    }

    /// 把一个 sample buffer 的整体时间戳往前挪 shift（暂停补偿）
    private func retimed(_ sampleBuffer: CMSampleBuffer, shift: CMTime) -> CMSampleBuffer? {
        var count: CMItemCount = 0
        guard CMSampleBufferGetSampleTimingInfoArray(sampleBuffer, entryCount: 0,
                                                     arrayToFill: nil,
                                                     entriesNeededOut: &count) == noErr,
              count > 0 else { return nil }
        var timings = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(), count: Int(count))
        guard CMSampleBufferGetSampleTimingInfoArray(sampleBuffer, entryCount: count,
                                                     arrayToFill: &timings,
                                                     entriesNeededOut: &count) == noErr else { return nil }
        for i in 0..<Int(count) {
            timings[i].presentationTimeStamp = CMTimeSubtract(timings[i].presentationTimeStamp, shift)
            if timings[i].decodeTimeStamp.isValid {
                timings[i].decodeTimeStamp = CMTimeSubtract(timings[i].decodeTimeStamp, shift)
            }
        }
        var out: CMSampleBuffer?
        let status = CMSampleBufferCreateCopyWithNewTiming(allocator: kCFAllocatorDefault,
                                                           sampleBuffer: sampleBuffer,
                                                           sampleTimingEntryCount: count,
                                                           sampleTimingArray: &timings,
                                                           sampleBufferOut: &out)
        return status == noErr ? out : nil
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
        guard !isStopping else { return }
        if output is AVCaptureVideoDataOutput {
            // 屏幕录制的画中画：只缓存最近一帧，等视频帧到货时合成
            if let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) {
                cameraLock.lock()
                cameraCIImage = CIImage(cvPixelBuffer: pixelBuffer)
                cameraLock.unlock()
            }
        } else if output is AVCaptureAudioDataOutput {
            // 🔴 走 handleAudioBuffer 而不是直接 append：暂停期间收到的音频要丢、
            // 恢复后要把暂停那段空隙从 PTS 里减掉。以前这里是裸 append，
            // 成片里"暂停"那几分钟是有声音的，恢复后又对不上嘴型。
            handleAudioBuffer(sampleBuffer)
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
        // 🔴 程序化创建的 NSWindow 默认 isReleasedWhenClosed = true：
        // close() 会自己 release 一次，而我们这边 `hud = nil` 又 release 一次 →
        // 双重释放，表现为"停止录制后随机闪退"（崩溃栈是 objc_release / __NSArrayM dealloc）。
        isReleasedWhenClosed = false
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
