import AppKit

// ============================================================
// 菜单栏图标与菜单
// ============================================================

@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {

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
        let menu = NSMenu()
        menu.delegate = self
        fillMenu(menu)
        item.menu = menu
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

    // 🔴 菜单每次**展开前**重建（menuNeedsUpdate）：不然设置里新录的快捷键、
    // 录制状态（区域录制/停止录制）、「重复上次区域截图」的可用态，
    // 全都要重启应用才能在菜单里看到 —— 用户「设了快捷键但菜单里没显示」就是这么来的。
    func menuNeedsUpdate(_ menu: NSMenu) {
        fillMenu(menu)
    }

    private func fillMenu(_ menu: NSMenu) {
        menu.removeAllItems()

        func item(_ title: String, _ action: ShotAction? = nil, key: String = "",
                  selector: Selector? = nil, symbol: String? = nil) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: selector ?? #selector(runAction(_:)), keyEquivalent: key)
            if let action {
                item.representedObject = action.rawValue
                // 把用户设置里录的快捷键回填到菜单项上做**显示**。
                // 状态栏菜单不是主菜单，keyEquivalent 在菜单收起时不会被触发，
                // 真正的全局触发仍走 Carbon 热键 —— 不会双执行。
                if let spec = model.prefs.value.spec(for: action),
                   let (character, modifiers) = spec.menuKeyEquivalent {
                    item.keyEquivalent = character
                    item.keyEquivalentModifierMask = modifiers
                }
            }
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

        menu.addItem(item("开始截图", .regionShot, symbol: "camera.viewfinder"))
        menu.addItem(item("截图复制", .regionCopy, symbol: "doc.on.doc"))
        let repeatItem = item("重复上次区域截图", .captureLastRegion, symbol: "arrow.clockwise")
        repeatItem.isEnabled = model.lastRegionShot != nil
        menu.addItem(repeatItem)
        menu.addItem(item("全屏截图", .fullscreenShot, symbol: "rectangle.inset.filled"))
        menu.addItem(item("窗口截图", .windowShot, symbol: "macwindow"))
        menu.addItem(item("滚动截图", .scrollShot, symbol: "arrow.down.to.line.compact"))
        menu.addItem(item("截图历史…", nil, selector: #selector(showHistory), symbol: "clock.arrow.circlepath"))
        menu.addItem(.separator())

        menu.addItem(item("截图 OCR", .ocrShot, symbol: "text.below.photo"))
        menu.addItem(item("解码 QR/条形码", .decodeQR, symbol: "qrcode.viewfinder"))
        menu.addItem(item("屏幕测量", .measure, symbol: "ruler"))
        menu.addItem(.separator())

        let recordTitle = model.isRecording ? "停止录制" : "区域录制"
        menu.addItem(item(recordTitle, .recordRegion, symbol: "record.circle"))
        menu.addItem(item("全屏录制", .recordFullscreen, symbol: "video.fill"))
        // 用户指定：入口就放在「全屏录制」正下方
        menu.addItem(item("摄像头录制", .recordCamera, symbol: "camera.fill"))
        menu.addItem(.separator())

        menu.addItem(item("贴图", .pinClipboard, symbol: "pin"))
        menu.addItem(item("从 Finder 贴图", nil, selector: #selector(pinFromFinder), symbol: "folder"))
        menu.addItem(item("隐藏 / 显示所有贴图", nil, selector: #selector(togglePins), symbol: "eye.slash"))
        menu.addItem(item("关闭所有贴图", nil, selector: #selector(closeAllPins), symbol: "eye.slash.fill"))
        menu.addItem(.separator())

        menu.addItem(item("偏好设置", .openSettings, key: ",", symbol: "gearshape"))
        let quit = NSMenuItem(title: "退出 BoxShot", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.keyEquivalentModifierMask = [.shift, .command]
        menu.addItem(quit)
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
    /// NSMenuItem 的 keyEquivalent 映射（**只用来显示**，触发仍走 Carbon 全局热键）。
    /// 返回 nil = 这个键位没法映射成菜单快捷键显示（如「键码 87」这种录不认识的键）。
    var menuKeyEquivalent: (character: String, modifiers: NSEvent.ModifierFlags)? {
        var modifiers: NSEvent.ModifierFlags = []
        if command { modifiers.insert(.command) }
        if shift { modifiers.insert(.shift) }
        if option { modifiers.insert(.option) }
        if control { modifiers.insert(.control) }

        // 功能键 F1–F12
        if label.hasPrefix("F"), let number = Int(label.dropFirst()), (1...12).contains(number) {
            return (String(Character(UnicodeScalar(NSF1FunctionKey + number - 1)!)), modifiers)
        }
        // 特殊键（label 来自 KeySpec.label(for:)，照着那张表映射）
        switch label {
        case "↩":  return ("\r", modifiers)
        case "空格": return (" ", modifiers)
        case "⌫":  return ("\u{7F}", modifiers)
        case "⎋":  return ("\u{1B}", modifiers)
        case "⇥":  return ("\t", modifiers)
        case "←":  return (String(UnicodeScalar(NSLeftArrowFunctionKey)!), modifiers)
        case "→":  return (String(UnicodeScalar(NSRightArrowFunctionKey)!), modifiers)
        case "↑":  return (String(UnicodeScalar(NSUpArrowFunctionKey)!), modifiers)
        case "↓":  return (String(UnicodeScalar(NSDownArrowFunctionKey)!), modifiers)
        default:
            // 普通字符键：label 是录制时 uppercased 的单字符（字母/数字/符号）
            if label.count == 1, let scalar = label.unicodeScalars.first,
               scalar.value >= 0x20, scalar.value < 0xF700, scalar.value != 0x7F {
                return (label, modifiers)
            }
            return nil
        }
    }
}
