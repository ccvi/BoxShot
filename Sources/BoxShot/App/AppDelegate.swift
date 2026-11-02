import AppKit
import AVFoundation
import Foundation

// ============================================================
// 应用装配
// ============================================================

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    /// PinWindow 等深层组件读设置用（内部可访问即可）
    let model: AppModel!
    private var statusItem: StatusItemController!

    override init() {
        self.model = AppModel()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(model.prefs.value.hideDockIcon ? .accessory : .regular)

        // 「开机自启动」已按用户要求从设置里整项去掉（1.0.9）。
        // 存量机器上可能已经写过 LaunchAgent，这里清一次 —— 否则会留下一个
        // 界面里根本关不掉的自动启动项。
        if LoginItem.isEnabled {
            try? LoginItem.setEnabled(false)
            model.prefs.value.launchAtLogin = false
        }

        // LSUIElement 应用没有系统菜单栏，文本框就按不出 ⌘C/⌘V——最小主菜单必备
        buildMainMenu()

        let statusItem = StatusItemController(model: model)
        self.statusItem = statusItem
        statusItem.install()
        statusItem.verifyPlacement()

        model.onRequestShowSettings = { [weak self] in
            self?.statusItem.showSettings()
        }
        model.bootstrap()
        model.registerGlobalHotKeys()

        // 诊断入口：--show-overlay 用合成渐变图呼出原位浮层（不走截图权限），
        // 配合 screencapture -R 核对浮层是否真的把图画出来了。
        if CommandLine.arguments.contains("--show-overlay") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                self?.showDiagnosticOverlay()
            }
        }
        // 诊断入口：--show-history 直接打开截图历史面板（库为空时先塞三张合成图），
        // 用来核对网格布局 / 缩略图 / 选中态，不用真的去截屏。
        if CommandLine.arguments.contains("--show-history") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                self?.showDiagnosticHistory()
            }
        }
        // 诊断入口：--scrolltest 直接开一次滚动截图（固定选区，不需要人拖），
        // 用来核对常驻缩略图面板的位置 / 尺寸 / 实时刷新。
        let scrollTrigger = "/tmp/boxshot-scrolltest.trigger"
        if CommandLine.arguments.contains("--scrolltest")
            || FileManager.default.fileExists(atPath: scrollTrigger) {
            try? FileManager.default.removeItem(atPath: scrollTrigger)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                guard let self else { return }
                let displayID = ScreenCapture.display(for: ScreenCapture.activeScreen())
                self.model.beginScrollCapture(displayID: displayID,
                                              region: CGRect(x: 120, y: 120, width: 900, height: 620))
            }
        }
        // 诊断入口：--recordcamera 走一遍"带摄像头取景框的真录制"，
        // 结束时从成片里抽一帧存 /tmp/boxshot-recordcamera-frame.jpg。
        // 「录出来的视频没有摄像头影像」这种问题只有端到端跑一次才看得清：
        // 是取景框没上屏、还是被"排除自家窗口"排掉了、还是根本没权限。
        let cameraTrigger = "/tmp/boxshot-recordcamera.trigger"
        if CommandLine.arguments.contains("--recordcamera")
            || FileManager.default.fileExists(atPath: cameraTrigger) {
            try? FileManager.default.removeItem(atPath: cameraTrigger)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.runRecordCameraDiagnostics()
            }
        }
        // 诊断入口：--esctest 打开区域截图遮罩 → 自己投一个 Esc 进去 → 看遮罩有没有收掉。
        // 「Esc 没生效」这种问题，光读代码看不出是"判断写错"还是"按键根本没进来"。
        let escTrigger = "/tmp/boxshot-esctest.trigger"
        if CommandLine.arguments.contains("--esctest")
            || FileManager.default.fileExists(atPath: escTrigger) {
            try? FileManager.default.removeItem(atPath: escTrigger)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                self?.runEscDiagnostics()
            }
        }
        // 诊断入口：--escwait 打开遮罩后**等外部真实按键** 15 秒（配合
        // `osascript -e 'tell application "System Events" to key code 53'` 或人手动按），
        // 用来区分「代码没接住」和「按键根本没进来」——本机 AX 未授权，
        // CGEvent.post 是空操作，光靠自投事件证明不了真实按键这条路。
        let escWaitTrigger = "/tmp/boxshot-escwait.trigger"
        if CommandLine.arguments.contains("--escwait")
            || FileManager.default.fileExists(atPath: escWaitTrigger) {
            try? FileManager.default.removeItem(atPath: escWaitTrigger)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                self?.runEscWaitDiagnostics()
            }
        }
        // 诊断入口：--dragtest 用合成鼠标拖一次框，验「松手即截图」这条路
        // （用户明确要求去掉"单击选区内 / 回车"那一步，这条流程必须端到端跑一遍）。
        let dragTrigger = "/tmp/boxshot-dragtest.trigger"
        if CommandLine.arguments.contains("--dragtest")
            || FileManager.default.fileExists(atPath: dragTrigger) {
            try? FileManager.default.removeItem(atPath: dragTrigger)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                self?.runDragTestDiagnostics()
            }
        }
        // 诊断入口：--windowtest 走一遍「窗口截图」（只点一下，不拖），
        // 验 windowPickMode 真的强制开了窗口高亮、并且点到的是别人家的窗口
        // 而不是盖在上面的自家遮罩。
        let windowTrigger = "/tmp/boxshot-windowtest.trigger"
        if CommandLine.arguments.contains("--windowtest")
            || FileManager.default.fileExists(atPath: windowTrigger) {
            try? FileManager.default.removeItem(atPath: windowTrigger)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                self?.runWindowTestDiagnostics()
            }
        }
        // 诊断入口：--show-settings 直接弹设置窗口，用来核对各页控件是否
        // 排对了、值是否真的跟着设置走（改完设置页最好截一张看一眼）。
        // 触发文件里可以写一个页号（0 通用 / 1 截图 / 2 贴图 / 3 OCR / 4 录制 /
        // 5 快捷键 / 6 关于），方便直接落到要核对的页。
        let settingsTrigger = "/tmp/boxshot-showsettings.trigger"
        if CommandLine.arguments.contains("--show-settings")
            || FileManager.default.fileExists(atPath: settingsTrigger) {
            let tab = Int((try? String(contentsOfFile: settingsTrigger, encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? "") ?? 0
            try? FileManager.default.removeItem(atPath: settingsTrigger)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                self?.statusItem.showSettings(tab: tab)
            }
        }
        // 诊断入口：--recordtest 不开界面、直接跑一遍录制引擎（3 秒）。
        // 结果写 /tmp/boxshot-recordtest.log —— 「点了录制没反应」这类问题
        // 只有把引擎单独拎出来跑一次，才知道是引擎起不来还是界面没接上。
        //
        // 也认标记文件：某些环境下 `open -a App --args …` 不会把参数传进来
        // （实测 LaunchServices 直接按原 argv 起进程），那就 touch 一个触发文件。
        let recordTestTrigger = "/tmp/boxshot-recordtest.trigger"
        if CommandLine.arguments.contains("--recordtest")
            || FileManager.default.fileExists(atPath: recordTestTrigger) {
            try? FileManager.default.removeItem(atPath: recordTestTrigger)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                self?.runRecordDiagnostics()
            }
        }
    }

    private var recordTestRecorder: RecorderController?

    private func runRecordDiagnostics() {
        let logURL = URL(fileURLWithPath: "/tmp/boxshot-recordtest.log")
        try? "".write(to: logURL, atomically: true, encoding: .utf8)
        func log(_ text: String) {
            NSLog("[BoxShot][recordtest] %@", text)
            guard let handle = try? FileHandle(forWritingTo: logURL) else { return }
            handle.seekToEndOfFile()
            handle.write("\(text)\n".data(using: .utf8)!)
            try? handle.close()
        }

        log("屏幕录制权限 = \(ScreenPermission.isGranted)")
        let displayID = ScreenCapture.display(for: ScreenCapture.activeScreen())

        let recorder = RecorderController()
        recorder.onError = { message in log("引擎报错：\(message)") }
        recorder.onStateChange = { recording in log("状态变更 recording=\(recording)") }
        recordTestRecorder = recorder

        do {
            try recorder.startRecording(displayID: displayID,
                                        region: CGRect(x: 0, y: 0, width: 320, height: 240),
                                        audio: .none, camera: false, fps: 30, showCursor: false,
                                        format: .mp4, quality: .medium, showsHUD: false)
            log("startRecording 同步部分成功")
        } catch {
            log("startRecording 抛错：\(error.localizedDescription)")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { exit(0) }
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
            log("准备停止")
            recorder.stop(reason: .user)
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                log("诊断结束")
                exit(0)
            }
        }
    }

    // ── 诊断：Esc 到底进不进得来 ────────────────────────────

    private func runEscDiagnostics() {
        let logURL = URL(fileURLWithPath: "/tmp/boxshot-esctest.log")
        try? "".write(to: logURL, atomically: true, encoding: .utf8)
        func log(_ text: String) {
            NSLog("[BoxShot][esctest] %@", text)
            guard let handle = try? FileHandle(forWritingTo: logURL) else { return }
            handle.seekToEndOfFile()
            handle.write("\(text)\n".data(using: .utf8)!)
            try? handle.close()
        }

        model.perform(.regionShot)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            log("遮罩已开：isActive=\(self.model.isRegionSelectorActive)")
            log("keyWindow=\(NSApp.keyWindow?.className ?? "nil") · isKey=\(NSApp.keyWindow?.isKeyWindow ?? false) · appActive=\(NSApp.isActive)")
            log("AX 可信（能发 HID 事件）=\(AXIsProcessTrusted())")
            // ① 先走"真按键"这一路：CGEvent 投到 HID 层，由窗口服务器分发给前台应用，
            //    跟手指按下去等价。postEvent 只是往自己的事件队列里塞，绕不过窗口服务器，
            //    所以它通过 ≠ 用户按下去也能过。
            let src = CGEventSource(stateID: .hidSystemState)
            if let down = CGEvent(keyboardEventSource: src, virtualKey: 53, keyDown: true),
               let up = CGEvent(keyboardEventSource: src, virtualKey: 53, keyDown: false) {
                down.post(tap: .cghidEventTap)
                up.post(tap: .cghidEventTap)
                log("已投递 HID 层真实 Esc")
            } else {
                log("HID 层 Esc 构造失败")
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
                if !self.model.isRegionSelectorActive {
                    log("✅ 真实 Esc 生效，遮罩已收起")
                    exit(0)
                }
                log("❌ 真实 Esc 没生效（当前 isActive=true）→ 退到 postEvent 这一路再试")
                if let ev = NSEvent.keyEvent(with: .keyDown, location: .zero,
                                             modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                             windowNumber: NSApp.keyWindow?.windowNumber ?? 0,
                                             context: nil, characters: "\u{1b}",
                                             charactersIgnoringModifiers: "\u{1b}",
                                             isARepeat: false, keyCode: 53) {
                    NSApp.postEvent(ev, atStart: false)
                    log("已投递 postEvent Esc")
                } else {
                    log("Esc 事件构造失败")
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                    log("postEvent 之后：isActive=\(self.model.isRegionSelectorActive)")
                    log(self.model.isRegionSelectorActive
                        ? "❌ 两条路都没生效"
                        : "⚠️ 只有 postEvent 生效（真按键这一路不通，先确认 AX 授权）")
                    exit(0)
                }
            }
        }
    }

    // ── 诊断：等外部真实按键 ──────────────────────────────────

    /// 打开遮罩 → 什么都不投，纯等 15 秒，看外部按下来的 Esc 能不能收掉遮罩。
    /// 本机 `AXIsProcessTrusted()` 是 false，`CGEvent.post` 等于往空气里发，
    /// 所以「自投 Esc 没生效」并不能说明真实按键不通；这条路径是唯一能证明的。
    private func runEscWaitDiagnostics() {
        let logURL = URL(fileURLWithPath: "/tmp/boxshot-escwait.log")
        try? "".write(to: logURL, atomically: true, encoding: .utf8)
        func log(_ text: String) {
            NSLog("[BoxShot][escwait] %@", text)
            guard let handle = try? FileHandle(forWritingTo: logURL) else { return }
            handle.seekToEndOfFile()
            handle.write("\(text)\n".data(using: .utf8)!)
            try? handle.close()
        }

        _ = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            log("收到 keyDown code=\(event.keyCode) chars=\(event.charactersIgnoringModifiers ?? "")")
            return event
        }

        model.perform(.regionShot)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            log("遮罩已开 isActive=\(self.model.isRegionSelectorActive)")
            log("keyWindow=\(NSApp.keyWindow?.className ?? "nil") · isKey=\(NSApp.keyWindow?.isKeyWindow ?? false) · appActive=\(NSApp.isActive)")
            log("AX 可信=\(AXIsProcessTrusted()) · 等外部真实 Esc 15 秒…")
            let deadline = Date().addingTimeInterval(15)
            let timer = Timer(timeInterval: 0.5, repeats: true) { t in
                let stillActive = self.model.isRegionSelectorActive
                if !stillActive || Date() > deadline {
                    t.invalidate()
                    log("结束：isActive=\(stillActive)")
                    log(stillActive ? "❌ 15 秒里没收到能结束截图的 Esc" : "✅ 外部真实 Esc 生效，遮罩已收起")
                    exit(0)
                }
            }
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    // ── 诊断：合成鼠标拖框，验「松手即截图」 ─────────────────

    /// 打开遮罩 → 用 CGEvent 合成一次左键拖动 → 松手。
    /// 判定标准：遮罩自己收掉，且浮层编辑器带着一个非空框冒出来。
    /// 之所以要合成而不是读代码：这条路径上有三件事接力（mouseUp → confirm →
    /// finish → delegate → 异步截图 → 浮层重开），只改一处很容易断开却看着"写了"。
    private func runDragTestDiagnostics() {
        let logURL = URL(fileURLWithPath: "/tmp/boxshot-dragtest.log")
        try? "".write(to: logURL, atomically: true, encoding: .utf8)
        func log(_ text: String) {
            NSLog("[BoxShot][dragtest] %@", text)
            guard let handle = try? FileHandle(forWritingTo: logURL) else { return }
            handle.seekToEndOfFile()
            handle.write("\(text)\n".data(using: .utf8)!)
            try? handle.close()
        }

        let src = CGEventSource(stateID: .hidSystemState)
        func post(_ type: CGEventType, _ p: CGPoint) {
            CGEvent(mouseEventSource: src, mouseType: type,
                    mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
        }

        model.perform(.regionShot)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            log("遮罩已开 isActive=\(self.model.isRegionSelectorActive) AX=\(AXIsProcessTrusted())")
            // 逻辑坐标（左上原点，点）。屏幕 1710×1107，取中间一块避免贴边。
            let start = CGPoint(x: 420, y: 300)
            let end   = CGPoint(x: 980, y: 720)
            post(.mouseMoved, start)
            post(.leftMouseDown, start)

            var step = 0
            let total = 10
            let timer = Timer(timeInterval: 0.05, repeats: true) { t in
                step += 1
                let f = CGFloat(step) / CGFloat(total)
                let p = CGPoint(x: start.x + (end.x - start.x) * f,
                                y: start.y + (end.y - start.y) * f)
                post(.leftMouseDragged, p)
                guard step >= total else { return }
                t.invalidate()
                post(.leftMouseUp, p)
                log("已松开左键（\(Int(end.x - start.x)) × \(Int(end.y - start.y))）")

                DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                    log("松手后：遮罩 isActive=\(self.model.isRegionSelectorActive)（应为 false）")
                    if let editor = self.model.overlayEditor {
                        log("浮层编辑器已出现 frame=\(editor.selectionFrame)")
                        log("✅ 松手即截图：遮罩已收、浮层已出")
                    } else {
                        log("❌ 没有浮层编辑器（截图没走通）")
                    }
                    exit(0)
                }
            }
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    // ── 诊断：窗口截图（点选窗口） ────────────────────────────

    /// 走 `windowShot` 动作 → 合成一次单击 → 看浮层是不是按"某个窗口的框"开的。
    /// 判定：浮层框要明显小于全屏，且遮罩已收。
    private func runWindowTestDiagnostics() {
        let logURL = URL(fileURLWithPath: "/tmp/boxshot-windowtest.log")
        try? "".write(to: logURL, atomically: true, encoding: .utf8)
        func log(_ text: String) {
            NSLog("[BoxShot][windowtest] %@", text)
            guard let handle = try? FileHandle(forWritingTo: logURL) else { return }
            handle.seekToEndOfFile()
            handle.write("\(text)\n".data(using: .utf8)!)
            try? handle.close()
        }

        let screenFrame = ScreenCapture.activeScreen().frame
        let src = CGEventSource(stateID: .hidSystemState)
        func post(_ type: CGEventType, _ p: CGPoint) {
            CGEvent(mouseEventSource: src, mouseType: type,
                    mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
        }

        model.perform(.windowShot)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            log("窗口模式遮罩已开 isActive=\(self.model.isRegionSelectorActive) 屏幕=\(screenFrame)")
            // 屏幕左上象限里点一下（那里通常有一个别人的窗口）
            let p = CGPoint(x: 480, y: 260)
            post(.mouseMoved, p)
            post(.leftMouseDown, p)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                post(.leftMouseUp, p)
                log("已在 \(Int(p.x)),\(Int(p.y)) 单击")

                DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                    log("点击后：遮罩 isActive=\(self.model.isRegionSelectorActive)（应为 false）")
                    if let editor = self.model.overlayEditor {
                        let f = editor.selectionFrame
                        log("浮层 frame=\(f)")
                        let fullScreen = abs(f.width - screenFrame.width) < 2 && abs(f.height - screenFrame.height) < 2
                        log(fullScreen ? "❌ 框是整屏 —— 点到的是自家遮罩，不是目标窗口"
                                       : "✅ 窗口截图：拿到了一个具体窗口的框")
                    } else {
                        log("❌ 没有浮层编辑器（点选窗口没走通）")
                    }
                    exit(0)
                }
            }
        }
    }

    // ── 诊断：带摄像头取景框的真录制 ──────────────────────────

    private var cameraProbeBubble: CameraBubbleController?

    private func runRecordCameraDiagnostics() {
        let logURL = URL(fileURLWithPath: "/tmp/boxshot-recordcamera.log")
        try? "".write(to: logURL, atomically: true, encoding: .utf8)
        func log(_ text: String) {
            NSLog("[BoxShot][recordcam] %@", text)
            guard let handle = try? FileHandle(forWritingTo: logURL) else { return }
            handle.seekToEndOfFile()
            handle.write("\(text)\n".data(using: .utf8)!)
            try? handle.close()
        }

        guard let screen = NSScreen.main else { log("没有屏幕"); exit(0) }
        let bubble = CameraBubbleController(size: .medium)
        cameraProbeBubble = bubble
        bubble.show(anchor: screen.visibleFrame)
        log("取景框已上屏：windowNumber=\(bubble.windowNumber) 边长=\(CameraBubbleSize.medium.side)")

        // 等摄像头会话真的出画（首次还要过权限）
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            let displayID = ScreenCapture.display(for: ScreenCapture.activeScreen())
            let recorder = RecorderController()
            self.recordTestRecorder = recorder
            recorder.keepVisibleWindowNumbers = [bubble.windowNumber]
            recorder.onError = { log("错误：\($0)") }
            recorder.onWarning = { log("提醒：\($0)") }
            var outURL: URL?
            do {
                try recorder.startRecording(displayID: displayID, region: nil, audio: .none,
                                            camera: false, fps: 30, showCursor: false,
                                            format: .mp4, quality: .medium, showsHUD: false)
                // outputURL 在收尾时会被清空，这里先拿住
                outURL = recorder.outputURL
                log("开始录制全屏 4 秒 → \(outURL?.lastPathComponent ?? "?")")
            } catch {
                log("启动失败：\(error.localizedDescription)")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { exit(0) }
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) {
                log("排除报告：\(recorder.lastExclusionReport)")
                recorder.stop(reason: .user)
                DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                    guard let url = outURL else { log("没有输出文件"); exit(0) }
                    log("输出：\(url.path)")
                    self.extractFrame(from: url, seconds: 2.0, log: log)
                    exit(0)
                }
            }
        }
    }

    /// 从成片里抽一帧存成 JPG：有摄像头画面的话，右下角那块应该是人像而不是桌面
    private func extractFrame(from url: URL, seconds: Double, log: (String) -> Void) {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        do {
            let cg = try generator.copyCGImage(at: CMTime(seconds: seconds, preferredTimescale: 600),
                                               actualTime: nil)
            let rep = NSBitmapImageRep(cgImage: cg)
            if let data = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.9]) {
                let out = "/tmp/boxshot-recordcamera-frame.jpg"
                try data.write(to: URL(fileURLWithPath: out))
                log("抽帧 \(cg.width)×\(cg.height) → \(out)")
            }
        } catch {
            log("抽帧失败：\(error.localizedDescription)")
        }
    }

    private func showDiagnosticHistory() {
        let store = ShotHistoryStore.shared
        if store.items.isEmpty {
            for index in 0..<3 {
                let w = 320 + index * 60, h = 200 + index * 40
                let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                    space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
                ctx.setFillColor(CGColor(srgbRed: 0.2 + 0.25 * Double(index), green: 0.4, blue: 0.8 - 0.2 * Double(index), alpha: 1))
                ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
                ctx.setFillColor(CGColor(gray: 1, alpha: 1))
                ctx.fill(CGRect(x: 20, y: 20, width: Double(w) / 2, height: 24))
                if let image = ctx.makeImage() {
                    store.record(image, limit: 20)
                }
            }
        }
        model.showShotHistory()
    }

    private func showDiagnosticOverlay() {
        let w = 800, h = 500
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
        for y in 0..<h {
            let t = Double(y) / Double(h)
            ctx.setFillColor(CGColor(srgbRed: 0.9, green: 1 - t * 0.8, blue: 0.2 + t * 0.5, alpha: 1))
            ctx.fill(CGRect(x: 0, y: y, width: w, height: 1))
        }
        ctx.setFillColor(CGColor(srgbRed: 0.1, green: 0.1, blue: 0.6, alpha: 1))
        ctx.fill(CGRect(x: 60, y: 60, width: 200, height: 120))
        guard let image = ctx.makeImage() else { return }
        // 2x 屏下 pointSize = 像素/2，框必须配 (400,250) 才能让图正好铺满
        let scale = NSScreen.screens.first?.backingScaleFactor ?? 2
        let frame = CGRect(x: 200, y: 500, width: CGFloat(w) / scale, height: CGFloat(h) / scale)
        model.openOverlayEditor(image: image, frame: frame)
        // 预置几条标注，核对浮层上的形状渲染（回归 1.0.1 "画了没显示"反馈）
        if let overlay = model.overlayEditor {
            let doc = overlay.docForDiagnostics
            doc.commit(AnnotationShape(tool: .rect, points: [CGPoint(x: 150, y: 40), CGPoint(x: 350, y: 100)],
                                       color: .red, lineWidth: 5))
            doc.commit(AnnotationShape(tool: .arrow, points: [CGPoint(x: 50, y: 150), CGPoint(x: 200, y: 210)],
                                       color: .green, lineWidth: 6))
            doc.commit(AnnotationShape(tool: .text, points: [CGPoint(x: 160, y: 130)],
                                       color: .black, lineWidth: 0, text: "形状渲染自检", fontSize: 48))
            doc.commit(AnnotationShape(tool: .mosaic, points: [CGPoint(x: 400, y: 40), CGPoint(x: 550, y: 120)],
                                       color: .black, lineWidth: 0))
            overlay.refresh()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.shutdown()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false   // 关掉设置窗口不等于退出：常驻工具
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        statusItem?.showSettings()
        return true
    }

    private func buildMainMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "关于 BoxShot",
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                        keyEquivalent: "")
        appMenu.addItem(.separator())
        let settingsItem = NSMenuItem(title: "设置…", action: #selector(showSettingsMenu), keyEquivalent: ",")
        settingsItem.target = self
        appMenu.addItem(settingsItem)
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "隐藏 BoxShot", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "退出 BoxShot", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "编辑")
        editMenu.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "重做", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "剪切", action: Selector(("cut:")), keyEquivalent: "x")
        editMenu.addItem(withTitle: "复制", action: Selector(("copy:")), keyEquivalent: "c")
        editMenu.addItem(withTitle: "粘贴", action: Selector(("paste:")), keyEquivalent: "v")
        editMenu.addItem(withTitle: "全选", action: Selector(("selectAll:")), keyEquivalent: "a")
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        let windowMenuItem = NSMenuItem()
        let windowMenu = NSMenu(title: "窗口")
        windowMenu.addItem(withTitle: "最小化", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "关闭", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowMenuItem.submenu = windowMenu
        mainMenu.addItem(windowMenuItem)

        NSApp.mainMenu = mainMenu
    }

    @objc private func showSettingsMenu() {
        statusItem.showSettings()
    }
}
