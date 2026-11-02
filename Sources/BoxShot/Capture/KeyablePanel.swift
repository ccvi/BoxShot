import AppKit

// ============================================================
// 能被键盘"认"的无边框窗口
//
// 🔴 无边框窗口的 `canBecomeKey` 默认是 **false**。也就是说
// `makeKeyAndOrderFront` 叫了也白叫：窗口永远不会成为 key window，
// 键盘事件根本不会路由到它的 first responder —— 遮罩里写的
// Esc / 回车 / 方向键看起来"实现了"，实际上从来没收到过一次按键。
//
// 这就是"全局按 Esc 强制结束截屏没生效"的根因：不是 Esc 的判断写错了，
// 是那个按键压根没进来。选区遮罩（区域截图、窗口截图都走它）和
// 标注浮层（Esc / ⌘Z / ⌘C / ⌘S / ⌫）都是同一个毛病。
//
// 修法只有一个字：覆写 canBecomeKey 返回 true。
// ============================================================

/// 用来当"隐形键盘窗口"的面板（浮层、遮罩、取景框都用它）
final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    /// 不要抢"主窗口"身份：菜单栏应用没有主窗口概念，
    /// 成了 main window 反而会让窗口关闭时的行为变得难猜
    override var canBecomeMain: Bool { false }
}

/// 同上，给必须用 NSWindow 的场合（选区遮罩就是这么建的）
final class KeyableWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
