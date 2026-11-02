import AppKit

// ============================================================
// 菜单栏图标与菜单
// ============================================================

@MainActor
final class StatusItemController: NSObject {

    private let model: AppModel
    private var statusItem: NSStatusItem?
    private var settingsWindow: SettingsWindowController?

    init(model: AppModel) {
        self.model = model
    }

    func install() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        guard let button = item.button else { return }
        button.image = NSImage(systemSymbolName: "camera.viewfinder",
                               accessibilityDescription: "BoxShot")
        button.image?.size = NSSize(width: 18, height: 18)
        item.menu = buildMenu()
        statusItem = item
    }

    /// macOS 26 上「创建成功」≠「看得见」：图标真的摆上菜单栏要等系统排版。
    /// 落位判据（家族 FastFind/BoxPaste 定案）：y >= 0 且高度 > 24。
    /// x=0 且 h=22 说明 bundle id 的状态栏登记被烧坏了（唯一修法是换 id）。
    func verifyPlacement() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            guard let frame = self?.statusItem?.button?.window?.frame else {
                NSLog("[BoxShot] 状态栏项窗口查不到（可能是假阴性，见 BoxPaste 10-16 日志）")
                return
            }
            if frame.origin.y >= 0 && frame.height > 24 {
                NSLog("[BoxShot] 状态栏图标落位正常：\(frame)")
            } else {
                NSLog("[BoxShot] ⚠ 状态栏图标落位异常：\(frame)")
            }
        }
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()

        func item(_ title: String, _ action: ShotAction? = nil, key: String = "",
                  selector: Selector? = nil, symbol: String? = nil) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: selector ?? #selector(runAction(_:)), keyEquivalent: key)
            if let action { item.representedObject = action.rawValue }
            // 🔴 这里以前写的是 `selector == nil ? self : nil` —— 正好写反了：
            // 走 runAction 的（截图那批）指到 self 没问题，而带自定义 selector 的
            // 四个人（截图历史 / 从 Finder 贴图 / 隐藏·显示所有贴图 / 关闭所有贴图）
            // target 成了 nil → 走响应链 → 链上根本没有 StatusItemController →
            // 菜单项全变**灰色不可点**。症状就是"截图历史按不了""贴图的按钮也按不了"，
            // 而上面那几个截图菜单项好好的 —— 太容易被当成两件不同的事了。
            item.target = self
            if let symbol {
                item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                    .withSymbolConfiguration(.init(pointSize: 12, weight: .regular))
            }
            return item
        }

        menu.addItem(item("开始截图", .regionShot, key: keyHint(.regionShot), symbol: "camera.viewfinder"))
        menu.addItem(item("截图复制", .regionCopy, symbol: "doc.on.doc"))
        let repeatItem = item("重复上次区域截图", .captureLastRegion, key: keyHint(.captureLastRegion), symbol: "arrow.clockwise")
        repeatItem.isEnabled = model.lastRegionShot != nil
        menu.addItem(repeatItem)
        menu.addItem(item("全屏截图", .fullscreenShot, symbol: "rectangle.inset.filled"))
        menu.addItem(item("窗口截图", .windowShot, symbol: "macwindow"))
        menu.addItem(item("滚动截图", .scrollShot, symbol: "arrow.down.to.line.compact"))
        menu.addItem(item("截图历史…", nil, selector: #selector(showHistory), symbol: "clock.arrow.circlepath"))
        menu.addItem(.separator())

        menu.addItem(item("截图 OCR", .ocrShot, key: keyHint(.ocrShot), symbol: "text.below.photo"))
        menu.addItem(item("解码 QR/条形码", .decodeQR, symbol: "qrcode.viewfinder"))
        menu.addItem(item("屏幕测量", .measure, symbol: "ruler"))
        menu.addItem(.separator())

        let recordTitle = model.isRecording ? "停止录制" : "区域录制"
        menu.addItem(item(recordTitle, .recordRegion, key: keyHint(.recordRegion), symbol: "record.circle"))
        menu.addItem(item("全屏录制", .recordFullscreen, symbol: "video.fill"))
        menu.addItem(.separator())

        menu.addItem(item("贴图", .pinClipboard, key: keyHint(.pinClipboard), symbol: "pin"))
        menu.addItem(item("从 Finder 贴图", nil, selector: #selector(pinFromFinder), symbol: "folder"))
        menu.addItem(item("隐藏 / 显示所有贴图", nil, selector: #selector(togglePins), symbol: "eye.slash"))
        menu.addItem(item("关闭所有贴图", nil, selector: #selector(closeAllPins), symbol: "eye.slash.fill"))
        menu.addItem(.separator())

        menu.addItem(item("偏好设置", .openSettings, key: ",", symbol: "gearshape"))
        let quit = NSMenuItem(title: "退出 BoxShot", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.keyEquivalentModifierMask = [.shift, .command]
        menu.addItem(quit)
        return menu
    }

    private func keyHint(_ action: ShotAction) -> String {
        model.prefs.value.spec(for: action)?.keyEquivalentHint ?? ""
    }

    @objc private func runAction(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let action = ShotAction(rawValue: raw) else { return }
        model.perform(action)
    }

    @objc private func pinFromFinder() {
        model.pinFromFinder()
    }

    @objc private func togglePins() {
        model.toggleAllPins()
    }

    @objc private func closeAllPins() {
        model.closeAllPins()
    }

    @objc private func showHistory() {
        model.showShotHistory()
    }

    /// 诊断用：把每个菜单项的 isEnabled 打出来。
    /// 🔴 菜单项的 target / action 写错**不会有任何报错**，只会静静地变灰 ——
    /// "截图历史按不了""贴图那几个按钮按不了"就是这么来的，光看代码很难发现。
    /// 菜单只在弹出时校验，所以这里手动 `menu.update()` 一次。
    func menuStateReport() -> String {
        guard let menu = statusItem?.menu else { return "没有菜单" }
        menu.update()
        return menu.items.filter { !$0.isSeparatorItem }
            .map { "\($0.title)=\($0.isEnabled ? "✅" : "❌灰")" }
            .joined(separator: " · ")
    }

    func showSettings(tab: Int = 0) {        if settingsWindow == nil {
            settingsWindow = SettingsWindowController(model: model, initialTab: tab)
        }
        settingsWindow?.show()
    }
}

private extension KeySpec {
    /// NSMenuItem.keyEquivalent 用的字符串（F 键等需要特殊字符）
    var keyEquivalentHint: String {
        if label.hasPrefix("F"), let number = Int(label.dropFirst()), (1...12).contains(number) {
            return String(Character(UnicodeScalar(NSF1FunctionKey + number - 1)!))
        }
        return ""
    }
}
