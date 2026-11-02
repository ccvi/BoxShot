import AppKit
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
