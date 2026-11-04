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

/// 可以拖着走的工具条容器。
///
/// 用户口径（1.0.27）：「截图时，工具条可以拖动调整位置」—— 工具条常横在选区正下方，
/// 正好压住要标注的那块内容，得能挪开。1.0.29 起**录屏工具条也用它**（用户口径
/// 「录制的工具条可以拖动调整位置，跟截图工具条一样的拖动效果」）。
///
/// 🔴 无边框 `NSPanel` 默认**不响应拖动**（没有标题栏，`isMovableByWindowBackground`
/// 也是 false），所以要在容器视图上自己接 `mouseDown` 调 `performDrag(with:)`。
/// 按钮自己会吃掉 mouseDown，所以这里只会收到"按钮间隙 / 内边距"上的按下，
/// 跟点按钮不打架。
///
/// 拖过之后位置就固定在那儿（`positionToolbar` 只在建工具条时算一次）；
/// 换一张截图会重新按 `toolbarOrigin` 算回默认位置 —— 那是新浮层，不该继承旧位置。
final class DraggableToolbarContainer: NSView {
    /// 用户真的按下拖动时回调一次。
    ///
    /// 截图工具条不设它（默认位置算完就不管了）；录屏工具条靠它区分"还没动过"和
    /// "用户亲手挪过"—— 后者不该在切换全屏录制时被 `position()` 弹回中间。
    var onDrag: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        onDrag?()
        window?.performDrag(with: event)
    }
}
