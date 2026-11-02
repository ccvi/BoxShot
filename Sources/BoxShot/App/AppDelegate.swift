import AppKit
import AVFoundation
import CoreImage
import Foundation
import ScreenCaptureKit

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
        let overlayTall = CommandLine.arguments.contains("--show-overlay-tall")
            || FileManager.default.fileExists(atPath: "/tmp/boxshot-showoverlay-tall.trigger")
        // --show-overlay-color：顺手把颜色面板也打开，用来核对它是不是贴在工具条下面
        let overlayColor = CommandLine.arguments.contains("--show-overlay-color")
            || FileManager.default.fileExists(atPath: "/tmp/boxshot-showoverlay-color.trigger")
        if CommandLine.arguments.contains("--show-overlay") || overlayTall || overlayColor {
            try? FileManager.default.removeItem(atPath: "/tmp/boxshot-showoverlay-tall.trigger")
            try? FileManager.default.removeItem(atPath: "/tmp/boxshot-showoverlay-color.trigger")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                self?.showDiagnosticOverlay(tall: overlayTall, colors: overlayColor)
            }
        }
        // 诊断入口：--show-history 直接打开截图历史面板（库为空时先塞三张合成图），
        // 用来核对网格布局 / 缩略图 / 选中态，不用真的去截屏。
        if CommandLine.arguments.contains("--show-history") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                self?.showDiagnosticHistory()
            }
        }
        // 诊断入口：--memreport 打印内存占用与当前持有的大对象清单（对账用）。
        // 「不截图了内存怎么不降」先跑这个，再决定动哪里。
        let memTrigger = "/tmp/boxshot-memreport.trigger"
        if CommandLine.arguments.contains("--memreport")
            || FileManager.default.fileExists(atPath: memTrigger) {
            try? FileManager.default.removeItem(atPath: memTrigger)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                guard let self else { return }
                NSLog("[BoxShot][memreport]\n%@", self.model.memReport())
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
        // 诊断入口：--menutest 打印菜单栏每个项目的启用状态。
        // 菜单项 target 写错只会"变灰"，不报错也不崩 —— 只有把它打出来才看得见。
        let menuTrigger = "/tmp/boxshot-menutest.trigger"
        if CommandLine.arguments.contains("--menutest")
            || FileManager.default.fileExists(atPath: menuTrigger) {
            try? FileManager.default.removeItem(atPath: menuTrigger)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                guard let self else { return }
                let report = self.statusItem.menuStateReport()
                NSLog("[BoxShot][menu] %@", report)
                try? report.write(to: URL(fileURLWithPath: "/tmp/boxshot-menutest.log"),
                                  atomically: true, encoding: .utf8)
            }
        }
        // 诊断入口：--pintest 钉一张「上红下蓝」的合成图，量两件事：
        //   ① 图像朝向（红条到底在窗口上方还是下方 —— "贴图是倒的"）
        //   ② 能不能拖动（合成一次 HID 拖拽，比对窗口 origin 有没有真的动）
        // 这两条都只有端到端跑一遍才看得清：一个在绘制坐标系，一个在事件层。
        let pinTrigger = "/tmp/boxshot-pintest.trigger"
        if CommandLine.arguments.contains("--pintest")
            || FileManager.default.fileExists(atPath: pinTrigger) {
            try? FileManager.default.removeItem(atPath: pinTrigger)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                self?.runPinDiagnostics()
            }
        }
        // 诊断入口：--wintest 对比 CGWindowList 与 SCShareableContent 的窗口名单
        let winTestTrigger = "/tmp/boxshot-wintest.trigger"
        if CommandLine.arguments.contains("--wintest")
            || FileManager.default.fileExists(atPath: winTestTrigger) {
            try? FileManager.default.removeItem(atPath: winTestTrigger)
            runWindowDiagnostics()
            return
        }
        // 诊断入口：--qrflow 完整走一遍扫码链路（生成码 → 浮层 → 解码 → 打窗口层级）
        let qrFlowTrigger = "/tmp/boxshot-qrflow.trigger"
        if CommandLine.arguments.contains("--qrflow")
            || FileManager.default.fileExists(atPath: qrFlowTrigger) {
            try? FileManager.default.removeItem(atPath: qrFlowTrigger)
            runQRFlowDiagnostics()
            return
        }
        // 诊断入口：--captest 真抓一次整屏落 PNG + 采样色值
        let captureTrigger = "/tmp/boxshot-captest.trigger"
        if CommandLine.arguments.contains("--captest")
            || FileManager.default.fileExists(atPath: captureTrigger) {
            try? FileManager.default.removeItem(atPath: captureTrigger)
            runCaptureDiagnostics()
            return
        }
        // 诊断入口：--qrtest 用应用自己的解码器跑触发文件里那张图
        let qrTrigger = "/tmp/boxshot-qrtest.trigger"
        if CommandLine.arguments.contains("--qrtest")
            || FileManager.default.fileExists(atPath: qrTrigger) {
            runQRDiagnostics()
            return
        }
        // 诊断入口：--loupetest 离屏渲染一张放大镜 PNG（不用截图权限）
        let loupeTrigger = "/tmp/boxshot-loupetest.trigger"
        if CommandLine.arguments.contains("--loupetest")
            || FileManager.default.fileExists(atPath: loupeTrigger) {
            try? FileManager.default.removeItem(atPath: loupeTrigger)
            runLoupeDiagnostics()
            return
        }
        // 诊断入口：--arrowtest 离屏渲染三支箭头（用来验「够不够尖」）
        let arrowTrigger = "/tmp/boxshot-arrowtest.trigger"
        if CommandLine.arguments.contains("--arrowtest")
            || FileManager.default.fileExists(atPath: arrowTrigger) {
            try? FileManager.default.removeItem(atPath: arrowTrigger)
            runArrowDiagnostics()
            return
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
        // 诊断入口：--recordoptionstest 把录制选项弹层离屏渲染成 PNG（/tmp/boxshot-recordoptions.png），
        // 用来核对布局（顶部留白、四项设置是否都齐、取景框那行"当前 X pt"）。
        // 直接渲染视图、不走窗口，绕开"shell 起的进程窗口 screencapture 拍不到"的限制。
        let recordOptionsTrigger = "/tmp/boxshot-recordoptions.trigger"
        if CommandLine.arguments.contains("--recordoptionstest")
            || FileManager.default.fileExists(atPath: recordOptionsTrigger) {
            try? FileManager.default.removeItem(atPath: recordOptionsTrigger)
            NSLog("[BoxShot][recordoptionstest] 进入诊断，开始离屏渲染")
            let view = RecordOptionsView(model: self.model)
            view.layoutSubtreeIfNeeded()
            let bounds = view.bounds
            guard let rep = view.bitmapImageRepForCachingDisplay(in: bounds) else {
                NSLog("[BoxShot][recordoptionstest] 无法离屏渲染")
                return
            }
            view.cacheDisplay(in: bounds, to: rep)
            if let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: "/tmp/boxshot-recordoptions.png"))
                NSLog("[BoxShot][recordoptionstest] 已渲染 PNG，尺寸 \(bounds.width)×\(bounds.height)")
            }
            // 离屏 cacheDisplay 画不全 AppKit 控件（只有分段控件的 cell 会上色），
            // 所以同时开一个真窗口，配合 screencapture -x 看真实效果。
            let win = NSWindow(contentRect: NSRect(x: 0, y: 0,
                                                   width: bounds.width + 40,
                                                   height: bounds.height + 40),
                                styleMask: [.titled, .closable], backing: .buffered, defer: false)
            win.title = "录制选项（诊断）"
            win.contentView = view
            win.level = .floating
            win.center()
            win.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
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
                        log("面板 frame=\(editor.panelFrameForDiagnostics) 屏幕=\(screenFrame)")
                        let fullScreen = abs(f.width - screenFrame.width) < 2 && abs(f.height - screenFrame.height) < 2
                        log(fullScreen ? "❌ 框是整屏 —— 点到的是自家遮罩，不是目标窗口"
                                       : "✅ 窗口截图：拿到了一个具体窗口的框")
                        // 第二阶段：拖右下角手柄往里收 120pt，验"窗口截图也能改大小"。
                        // AppKit(左下原点) → 全局(左上原点)：y = 屏高 − 框底边
                        let x0 = f.width - 3
                        let y0 = screenFrame.height - f.minY - 3
                        let x1 = x0 - 120
                        let y1 = y0 - 120
                        log("拖右下角手柄 \(Int(x0)),\(Int(y0)) → \(Int(x1)),\(Int(y1))")
                        post(.mouseMoved, CGPoint(x: x0, y: y0))
                        post(.leftMouseDown, CGPoint(x: x0, y: y0))
                        var step = 0
                        let timer = Timer(timeInterval: 0.05, repeats: true) { t in
                            step += 1
                            let k = CGFloat(step) / 8
                            post(.leftMouseDragged, CGPoint(x: x0 + (x1 - x0) * k,
                                                            y: y0 + (y1 - y0) * k))
                            guard step >= 8 else { return }
                            t.invalidate()
                            post(.leftMouseUp, CGPoint(x: x1, y: y1))
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
                                if let e2 = self.model.overlayEditor {
                                    let f2 = e2.selectionFrame
                                    log("拖完之后 frame=\(f2)")
                                    log(f2.width < f.width - 40
                                        ? "✅ 窗口截图的框也能改大小"
                                        : "❌ 拖手柄没改到尺寸")
                                } else {
                                    log("❌ 拖完浮层没了")
                                }
                                exit(0)
                            }
                        }
                        RunLoop.main.add(timer, forMode: .common)
                        return
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

    /// tall = true 时用一个几乎顶满整屏高的框，专门验证工具条"上下都没位置 →
    /// 压进框内底部居中"这条分支（正常尺寸的框永远走不到它）。
    // ── 贴图诊断：朝向 + 能不能拖 ──────────────────────────────

    /// 诊断入口：`--loupetest` 把放大镜**离屏渲染**成 PNG（/tmp/boxshot-loupe.png）。
    /// 放大镜里三行信息、色块、网格对位这些 12pt 级排版，光读代码判断不了；
    /// 离屏画一遍既不用截图权限，也不用真去拖一个选区。
    /// 诊断入口：`--wintest` 「窗口截图」为什么报「目标窗口已关闭或不可截取」。
    ///
    /// 两步枚举用的不是同一套 API：
    ///   · 列表来自 `CGWindowListCopyWindowInfo(.optionOnScreenOnly)`（点选时看到的那个框）
    ///   · 真正截图靠 `SCShareableContent`（按 windowID 再查一次）
    /// 两边对不上就抛 windowNotFound。所以先把两边的 windowID 各列一遍，差集就是答案。
    /// 会先把截图遮罩打开再比 —— 遮罩是 level=.screenSaver 的全屏窗口，
    /// 正是"目标窗口被我们盖住"的现场。
    private func runWindowDiagnostics() {
        let logURL = URL(fileURLWithPath: "/tmp/boxshot-wintest.log")
        try? "".write(to: logURL, atomically: true, encoding: .utf8)
        func log(_ text: String) {
            NSLog("[BoxShot][wintest] %@", text)
            guard let handle = try? FileHandle(forWritingTo: logURL) else { return }
            handle.seekToEndOfFile()
            handle.write("\(text)\n".data(using: .utf8)!)
            try? handle.close()
        }

        // 先开遮罩：窗口点选模式的现场
        model.perform(.windowShot)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            Task { @MainActor in
                let list = ScreenCapture.onScreenWindows()
                log("CGWindowList 列出 \(list.count) 个可点窗口")
                for item in list.prefix(12) {
                    log("  CG id=\(item.windowID) \(item.ownerName) 「\(item.title ?? "")」 \(item.frame)")
                }

                // 顺手验一下底图裁剪的坐标换算：拿第一个窗口的框去裁，
                // 落成 PNG 后拿 `screencapture -R 同一个框` 对一眼就知道对不对。
                if let first = list.first,
                   let crop = self.model.diagnosticBackdropCrop(globalRect: first.frame) {
                    let rep = NSBitmapImageRep(cgImage: crop)
                    if let data = rep.representation(using: .png, properties: [:]) {
                        try? data.write(to: URL(fileURLWithPath: "/tmp/boxshot-backdrop-crop.png"),
                                        options: .atomic)
                        log("底图裁剪 id=\(first.windowID) frame=\(first.frame) → \(crop.width)×\(crop.height)")
                    }
                } else {
                    log("❌ 底图裁剪拿不到（needBackdrop 没生效？）")
                }

                // 再伪造一次"点了这个窗口"，但给个不存在的 windowID：
                // 必然走"窗口已关闭"的兜底，验底图裁剪能不能顶上。
                if let first = list.first {
                    let ok = self.model.diagnosticSimulateWindowConfirm(windowID: 999_999,
                                                                       frame: first.frame)
                    log(ok ? "已伪造窗口确认（id=999999），兜底路径应当已跑" : "❌ 没有活跃的遮罩")
                }

                do {
                    let onScreen = try await SCShareableContent
                        .excludingDesktopWindows(false, onScreenWindowsOnly: true)
                    let all = try await SCShareableContent
                        .excludingDesktopWindows(false, onScreenWindowsOnly: false)
                    let onScreenIDs = Set(onScreen.windows.map(\.windowID))
                    let allIDs = Set(all.windows.map(\.windowID))
                    log("SCK onScreenWindowsOnly=true → \(onScreen.windows.count) 个窗口")
                    log("SCK onScreenWindowsOnly=false → \(all.windows.count) 个窗口")

                    let missingOnScreen = list.filter { !onScreenIDs.contains($0.windowID) }
                    let missingAll = list.filter { !allIDs.contains($0.windowID) }
                    log("❗️按 onScreenOnly=true 查不到的有 \(missingOnScreen.count) 个")
                    for item in missingOnScreen {
                        log("   ✗ id=\(item.windowID) \(item.ownerName) 「\(item.title ?? "")」")
                    }
                    log("❗️按 onScreenOnly=false 仍查不到的有 \(missingAll.count) 个")
                    for item in missingAll {
                        log("   ✗ id=\(item.windowID) \(item.ownerName) 「\(item.title ?? "")」")
                    }
                } catch {
                    log("❌ SCShareableContent 抛错：\(error)")
                }
                // 伪造确认会开一个 Task 去抓图（SCK 要几十毫秒），
                // 这里多等几秒再退，否则兜底那条日志还没打出来进程就没了
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { exit(0) }
            }
        }
    }

    /// 诊断入口：`--qrflow` 走一遍完整的扫码链路，人不用在场：
    /// 用 CoreImage 现生成一张真二维码 → 钉成原位浮层（和截图后一模一样）
    /// → 调 `runQR` → 把结果窗口的层级 / 是否被浮层盖住打进日志，然后留 8 秒给人截图看。
    private func runQRFlowDiagnostics() {
        let logURL = URL(fileURLWithPath: "/tmp/boxshot-qrflow.log")
        try? "".write(to: logURL, atomically: true, encoding: .utf8)
        func log(_ text: String) {
            NSLog("[BoxShot][qrflow] %@", text)
            guard let handle = try? FileHandle(forWritingTo: logURL) else { return }
            handle.seekToEndOfFile()
            handle.write("\(text)\n".data(using: .utf8)!)
            try? handle.close()
        }

        // 现生成一张二维码（黑码白底，8 倍放大 —— Vision 认这个）
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { log("❌ 没有 CIQRCodeGenerator"); exit(1) }
        filter.setValue("https://www.ifmac.cn/".data(using: .utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let code = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)) else {
            log("❌ 生成二维码失败"); exit(1)
        }
        let padded = code.transformed(by: CGAffineTransform(translationX: 32, y: 32))
        let canvas = CIImage(color: CIColor.white).cropped(to: CGRect(origin: .zero,
                                                                     size: CGSize(width: padded.extent.width + 64,
                                                                                  height: padded.extent.height + 64)))
        let composed = padded.composited(over: canvas)
        guard let cg = CIContext().createCGImage(composed, from: composed.extent) else {
            log("❌ 生成位图失败"); exit(1)
        }
        log("二维码 \(cg.width)×\(cg.height)")

        // 钉成浮层：位置固定在屏幕中上部，尺寸按图算（按 2x 逻辑宽）
        let screen = ScreenCapture.activeScreen()
        let width = CGFloat(cg.width) / 2
        let height = CGFloat(cg.height) / 2
        let frame = CGRect(x: screen.frame.midX - width / 2,
                           y: screen.frame.maxY - height - 120,
                           width: width, height: height)
        model.openOverlayEditor(image: cg, frame: frame)
        log("浮层已在 \(frame) 打开")

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            log("开始解码…")
            self.model.runQR(image: cg) { payloads in
                log(payloads.isEmpty ? "❌ 没解出来" : "✅ 解出：\(payloads)")
                // 结果窗是在 completion **之后**才 show 的，这里得等一拍再数窗口
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                    for (index, window) in NSApp.windows.enumerated() where window.isVisible {
                        log("窗口#\(index) level=\(window.level.rawValue) " +
                            "\(type(of: window)) frame=\(window.frame) " +
                            "key=\(window.isKeyWindow)")
                    }
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) { exit(0) }
        }
    }

    /// 诊断入口：`--captest` 真抓一次整屏，落成 `/tmp/boxshot-capture.png` 并打日志。
    /// 放大镜里的像素、截图的内容都来自这一次 `captureDisplay`：
    /// 如果它是白的，镜里就是白的、截出来的图也扫不出码 —— 先把这一层钉死再往上查。
    private func runCaptureDiagnostics() {
        Task { @MainActor in
            let logURL = URL(fileURLWithPath: "/tmp/boxshot-captest.log")
            try? "".write(to: logURL, atomically: true, encoding: .utf8)
            func log(_ text: String) {
                NSLog("[BoxShot][captest] %@", text)
                guard let handle = try? FileHandle(forWritingTo: logURL) else { return }
                handle.seekToEndOfFile()
                handle.write("\(text)\n".data(using: .utf8)!)
                try? handle.close()
            }

            let screen = ScreenCapture.activeScreen()
            let displayID = ScreenCapture.display(for: screen)
            log("屏幕 frame=\(screen.frame) backing=\(screen.backingScaleFactor) " +
                "CGDisplayBounds=\(ScreenCapture.displayBoundsGlobal(displayID))")

            let started = Date()
            let image = try? await ScreenCapture.captureDisplay(displayID)
            let ms = Date().timeIntervalSince(started) * 1000
            guard let image else {
                log("❌ 抓屏失败（\(Int(ms))ms）")
                exit(1)
            }
            log("抓屏成功 \(Int(ms))ms \(image.width)×\(image.height) " +
                "bpp=\(image.bitsPerPixel) row=\(image.bytesPerRow)")

            let scale = CGFloat(image.width) / max(1, screen.frame.width)
            log("pixelScale（宽比）= \(scale)")

            // 几个固定采样点：视图坐标（左上原点）→ 像素
            let points: [(String, CGPoint)] = [
                ("左上 100,100", CGPoint(x: 100, y: 100)),
                ("中心", CGPoint(x: screen.frame.width / 2, y: screen.frame.height / 2)),
                ("右上", CGPoint(x: screen.frame.width - 100, y: 100)),
                ("左下", CGPoint(x: 100, y: screen.frame.height - 100)),
            ]
            var samples: [String] = []
            for (name, p) in points {
                let px = CGPoint(x: (p.x * scale).rounded(.down), y: (p.y * scale).rounded(.down))
                let color = Loupe.sampleColor(in: image, pixel: px)
                samples.append("\(name)=\(Loupe.hexPairs(color))")
            }
            log("采样 \(samples.joined(separator: " "))")

            let rep = NSBitmapImageRep(cgImage: image)
            if let data = rep.representation(using: .png, properties: [:]) {
                try? data.write(to: URL(fileURLWithPath: "/tmp/boxshot-capture.png"),
                                options: .atomic)
                log("已落 /tmp/boxshot-capture.png")
            }
            exit(0)
        }
    }

    /// 诊断入口：`--qrtest` 用**应用自己的解码器**跑一张图（路径写在触发文件里）。
    /// 标准 Vision 能解、应用里解不出来，那问题一定在喂进去的那张图上。
    private func runQRDiagnostics() {
        let path = (try? String(contentsOfFile: "/tmp/boxshot-qrtest.trigger", encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let logURL = URL(fileURLWithPath: "/tmp/boxshot-qrtest.log")
        try? "".write(to: logURL, atomically: true, encoding: .utf8)
        func log(_ text: String) {
            NSLog("[BoxShot][qrtest] %@", text)
            guard let handle = try? FileHandle(forWritingTo: logURL) else { return }
            handle.seekToEndOfFile()
            handle.write("\(text)\n".data(using: .utf8)!)
            try? handle.close()
        }
        guard !path.isEmpty,
              let image = NSImage(contentsOfFile: path)?
                .cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            log("❌ 读不到图：\(path)")
            exit(1)
        }
        log("读入 \(path) \(image.width)×\(image.height) bpp=\(image.bitsPerPixel)")
        Task { @MainActor in
            do {
                let payloads = try await OCREngine.decodeBarcodes(in: image)
                log(payloads.isEmpty ? "❌ 解不出来（0 条）"
                                     : "✅ 解出 \(payloads.count) 条：\(payloads)")
            } catch {
                log("❌ 抛错 \(error)")
            }
            exit(0)
        }
    }

    private func runLoupeDiagnostics() {
        let size = Loupe.size
        let canvas = CGRect(x: 0, y: 0, width: size.width + 80, height: size.height + 80)

        // 源图刻意做成"顶部一条红、底部一条蓝、中间浅灰"：
        // 放大镜里红条在上就是对的，红条跑到底下就是翻面了 —— 这是唯一能
        // 靠一张离线样张判死的方向性检查（对称图案看不出来）。
        let srcW = 320, srcH = 240
        guard let srcCtx = CGContext(data: nil, width: srcW, height: srcH,
                                     bitsPerComponent: 8, bytesPerRow: 0,
                                     space: CGColorSpaceCreateDeviceRGB(),
                                     bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                       | CGBitmapInfo.byteOrder32Little.rawValue) else { return }
        srcCtx.setFillColor(CGColor(srgbRed: 0.94, green: 0.94, blue: 0.94, alpha: 1))
        srcCtx.fill(CGRect(x: 0, y: 0, width: srcW, height: srcH))
        // 绘制坐标系是左下原点 → y 接近 height 的那条才是**图像顶部**
        srcCtx.setFillColor(CGColor(srgbRed: 0.85, green: 0.15, blue: 0.15, alpha: 1))
        srcCtx.fill(CGRect(x: 0, y: srcH - 20, width: srcW, height: 20))
        srcCtx.setFillColor(CGColor(srgbRed: 0.15, green: 0.25, blue: 0.85, alpha: 1))
        srcCtx.fill(CGRect(x: 0, y: 0, width: srcW, height: 20))
        guard let source = srcCtx.makeImage() else { return }

        guard let ctx = CGContext(data: nil, width: Int(canvas.width), height: Int(canvas.height),
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                    | CGBitmapInfo.byteOrder32Little.rawValue) else { return }
        ctx.setFillColor(CGColor(gray: 0.35, alpha: 1))
        ctx.fill(canvas)
        // 🔴 视图里是 y 向下的坐标系（isFlipped），这里要先把 CTM 翻过来，
        // 否则离屏渲染出来的上下位置跟真实上屏时不一致，验了个假的。
        ctx.translateBy(x: 0, y: canvas.height)
        ctx.scaleBy(x: 1, y: -1)

        // 🔴 文字是用 NSString.draw 画的，它只认 **NSGraphicsContext.current**。
        // 只建 CGContext 不设 current，网格和色块都出来了、文字一个没有
        // （第一版就是这样，白条空着）。flipped: true 是因为上面已经把 CTM 翻成 y 向下。
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        Loupe.draw(in: ctx,
                   source: source,
                   // 光标压在"红条下沿"：镜里上半截红、下半截灰，一眼能判方向
                   cursor: CGPoint(x: 160, y: 20),
                   bounds: canvas,
                   displaySize: CGSize(width: srcW, height: srcH),
                   pixelScale: 1,
                   lineColor: Loupe.color(fromHex: "#3B82F6"),
                   origin: .topLeft,
                   format: .hex,
                   hashPrefix: true)
        NSGraphicsContext.restoreGraphicsState()

        guard let out = ctx.makeImage() else { return }
        let rep = NSBitmapImageRep(cgImage: out)
        if let data = rep.representation(using: .png, properties: [:]) {
            try? data.write(to: URL(fileURLWithPath: "/tmp/boxshot-loupe.png"), options: .atomic)
            NSLog("[BoxShot][loupetest] 已写到 /tmp/boxshot-loupe.png %.0f×%.0f",
                  canvas.width, canvas.height)
        }
        exit(0)
    }

    /// 诊断入口：`--arrowtest` 把三支不同线宽的箭头**离屏渲染**成 PNG
    /// （/tmp/boxshot-arrow.png），并打印头部几何。
    ///
    /// 用户口径「箭头不够尖」是主观判断，改完不能只靠嘴说"变尖了"：
    /// 尖不尖 = 顶点张角 + 头部长度 / 线宽。把这两个数打出来，再看图确认。
    /// 顺便验一件容易漏的事 —— 箭杆的圆线帽有没有顶到尖端（那会让尖端发钝）。
    private func runArrowDiagnostics() {
        let w = 640, h = 300
        guard let base = Self.solidImage(width: w, height: h,
                                         color: CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)) else {
            NSLog("[BoxShot][arrowtest] 造底图失败"); exit(1)
        }
        var shapes: [AnnotationShape] = []
        for (index, width) in [2, 4, 8].enumerated() {
            let y = CGFloat(50 + index * 90)
            shapes.append(AnnotationShape(tool: .arrow,
                                          points: [CGPoint(x: 60, y: y + 40), CGPoint(x: 560, y: y)],
                                          color: .red, lineWidth: CGFloat(width)))
        }
        let effects = EffectImages(base: base)
        guard let out = EditorRenderer.render(base: base, shapes: shapes, effects: effects),
              let data = NSBitmapImageRep(cgImage: out).representation(using: .png, properties: [:]) else {
            NSLog("[BoxShot][arrowtest] 渲染失败"); exit(1)
        }
        try? data.write(to: URL(fileURLWithPath: "/tmp/boxshot-arrow.png"), options: .atomic)
        for width in [2.0, 4.0, 8.0] {
            let headLen = EditorRenderer.arrowHeadLength(width: width)
            let apex = 2 * EditorRenderer.arrowHeadSpread * 180 / .pi
            NSLog("[BoxShot][arrowtest] 线宽 %.0f → 头长 %.1f（%.1f×线宽）· 顶点张角 %.1f°",
                  width, headLen, headLen / width, apex)
        }
        NSLog("[BoxShot][arrowtest] 已写到 /tmp/boxshot-arrow.png %d×%d", w, h)
        exit(0)
    }

    private static func solidImage(width: Int, height: Int, color: CGColor) -> CGImage? {
        guard let ctx = CGContext(data: nil, width: width, height: height,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                    | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
        ctx.setFillColor(color)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()
    }

    private func runPinDiagnostics() {
        let logURL = URL(fileURLWithPath: "/tmp/boxshot-pintest.log")
        try? "".write(to: logURL, atomically: true, encoding: .utf8)
        func log(_ text: String) {
            NSLog("[BoxShot][pintest] %@", text)
            guard let handle = try? FileHandle(forWritingTo: logURL) else { return }
            handle.seekToEndOfFile()
            handle.write("\(text)\n".data(using: .utf8)!)
            try? handle.close()
        }

        // 「上红下蓝」的合成图。CGContext 的缓冲第 0 行是**图像顶部**，
        // 但绘制坐标系是左下原点 —— 所以"图像顶部"要画在 y = h - 60 那一带。
        let w = 400, h = 200
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                    | CGBitmapInfo.byteOrder32Little.rawValue) else { return }
        ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.setFillColor(CGColor(srgbRed: 0.9, green: 0.1, blue: 0.1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: h - 60, width: w, height: 60))
        ctx.setFillColor(CGColor(srgbRed: 0.1, green: 0.2, blue: 0.9, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: 60))
        guard let image = ctx.makeImage() else { return }
        // 上一次运行留下的贴图会被 restoreHistory 恢复出来，直接取第一个
        // floating 窗口会拿到**旧的**那张（尺寸还可能不对）。先记一份快照，
        // 之后按差集找本次新钉的那张。
        let before = Set(NSApp.windows.filter { $0.level == .floating }.map { ObjectIdentifier($0) })
        let restored = NSApp.windows.filter { $0.level == .floating }.map { "\($0.frame)" }
        model.pinImage(image)
        log("已钉图 400×200（图像顶部红、底部蓝）")
        log("恢复出来的旧贴图 \(restored.count) 张：\(restored.joined(separator: " / "))")

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
            guard let pin = NSApp.windows.first(where: {
                      $0.level == .floating && !before.contains(ObjectIdentifier($0))
                  }),
                  let screen = NSScreen.main else {
                log("❌ 没找到本次新钉的贴图窗口")
                return
            }
            let before = pin.frame
            log("贴图窗口 frame=\(before)（期望 200×100）")

            let center = CGPoint(x: before.midX, y: screen.frame.height - before.midY)
            let src = CGEventSource(stateID: .hidSystemState)
            func post(_ type: CGEventType, _ p: CGPoint) {
                CGEvent(mouseEventSource: src, mouseType: type,
                        mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
            }
            post(.mouseMoved, center)
            post(.leftMouseDown, center)
            for step in 1...10 {
                let p = CGPoint(x: center.x, y: center.y - CGFloat(step) * 8)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.03 * Double(step)) {
                    post(.leftMouseDragged, p)
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                post(.leftMouseUp, CGPoint(x: center.x, y: center.y - 80))
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    let after = pin.frame
                    let dy = after.origin.y - before.origin.y
                    log("拖动后 frame=\(after) · Δy=\(Int(dy))")
                    log(abs(dy) > 20 ? "✅ 贴图能拖动（Δy=\(Int(dy))）"
                                     : "❌ 贴图拖不动（Δy=\(Int(dy))）")
                }
            }
        }

        // 再钉一张**文本**贴图（不进管理器，所以不会污染 pins.json）：
        // 文字是不是真画出来了、有没有偏/Arial 掉成方框，只有看一眼才知道。
        // 置顶按钮要鼠标悬停才出现，程序侧只能验"按钮存在"（自检里有），这里验渲染。
        let sample = "文本贴图：这段文字应当可以直接选中并复制。\n第二行用于核对行距与换行。"
        if let textImage = PinManager.renderTextToImage(sample),
           let textPin = PinWindow(image: textImage, opacity: 1.0, shadow: true, text: sample) {
            textPin.setFrameOrigin(NSPoint(x: 400, y: 760))
            textPin.showPin()
            log("文本贴图放出来了 frame=\(textPin.frame) key=\(textPin.canBecomeKey) " +
                "视图=\(type(of: textPin.contentView!))")
            // 留住引用，避免 ARC 立刻收掉
            textPinHolder = textPin
        } else {
            log("❌ 文本贴图建不出来")
        }
    }

    /// `--pintest` 放出来的那张文本贴图（只为诊断期间不被回收）
    private var textPinHolder: PinWindow?

    private func showDiagnosticOverlay(tall: Bool = false, colors: Bool = false) {
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
        let frame = tall
            ? CGRect(x: 60, y: 40, width: 520, height: 1020)
            : CGRect(x: 200, y: 500, width: CGFloat(w) / scale, height: CGFloat(h) / scale)
        model.openOverlayEditor(image: image, frame: frame)
        if colors {
            let logURL = URL(fileURLWithPath: "/tmp/boxshot-overlaycolor.log")
            try? "".write(to: logURL, atomically: true, encoding: .utf8)
            func clog(_ text: String) {
                NSLog("[BoxShot][overlaycolor] %@", text)
                guard let handle = try? FileHandle(forWritingTo: logURL) else { return }
                handle.seekToEndOfFile()
                handle.write("\(text)\n".data(using: .utf8)!)
                try? handle.close()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                guard let editor = self.model.overlayEditor else { return }
                editor.showColorPanelForDiagnostics()
                let panel = editor.colorPanelFrameForDiagnostics
                clog("颜色面板 frame=\(panel) · AX=\(AXIsProcessTrusted())")
                clog("当前颜色=\(editor.docColorForDiagnostics) · 面板是key=\(editor.colorPanelIsKeyForDiagnostics)")
                clog("面板内 (74,24) 命中=\(editor.colorPanelHitTestForDiagnostics(CGPoint(x: 74, y: 24)))")
                // 🔴 比较必须拿"点击前"的快照：直接和 editor.docColorForDiagnostics 比，
                // 两边都是现读的同一个值，永远相等 → 每次都会误报"没换色"。
                let before = editor.docColorForDiagnostics

                // 合成一次点击：第 6 个色块（黑，最不容易和默认色撞）。
                // 坐标是 AppKit 左下原点 → 全局左上原点。
                // 面板内边距 10、色块 21 宽、间距 6：第 n 个色块中心 = minX+10+(21+6)*n+10.5
                let side = OverlayEditorController.swatchSide
                let cx = panel.minX + 10 + (side + 6) * 5 + side / 2
                let cy = panel.midY
                let screenH = ScreenCapture.activeScreen().frame.height
                let src = CGEventSource(stateID: .hidSystemState)
                func post(_ type: CGEventType, _ p: CGPoint) {
                    CGEvent(mouseEventSource: src, mouseType: type,
                            mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
                }
                let g = CGPoint(x: cx, y: screenH - cy)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    post(.mouseMoved, g)
                    post(.leftMouseDown, g)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                        post(.leftMouseUp, g)
                    }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
                    let now = self.model.overlayEditor?.docColorForDiagnostics ?? "nil"
                    clog("点击 \(Int(g.x)),\(Int(g.y)) 之后颜色=\(now)")
                    clog(now == before ? "⚠️ 点色块没换色" : "✅ 点色块换了颜色：\(before) → \(now)")
                }
            }
        }
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
            // 高亮：诊断里必须有一条，否则"高亮看不见"这类反馈只能靠猜
            doc.commit(AnnotationShape(tool: .highlight, points: [CGPoint(x: 150, y: 230), CGPoint(x: 520, y: 330)],
                                       color: .yellow, lineWidth: 0))
            overlay.refresh()
            // 工具条尺寸是"整体倍率"推出来的，改倍率必须能一眼看到实际数值 ——
            // 只靠肉眼对着截图比大小，30% 和 20% 是分不出来的。
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                let f = overlay.toolbarFrameForDiagnostics
                NSLog("[BoxShot][toolbar] frame=%@", NSStringFromRect(f))
            }
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
