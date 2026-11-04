import AppKit

// ============================================================
// 悬浮工具条的统一样式
//
// 用户口径（2026-11-04）：**「所有工具条 底色改为 #E6E6E6，工具条的图标颜色改为
// 黑色，颜色图标除外。」** 当天又补了一句：**「编辑标注窗口的工具条不用改底色，
// 保持原来的就行了。」** —— 所以这里的四处是：
//   · 截图浮层工具条（OverlayEditor）
//   · 录制工具条（RecordToolbar）
//   · 录制时长 HUD（Recorder）
//   · 滚动截图工具条（ScrollCaptureController）
// 编辑窗口（EditorView）**不在范围内**，它继续用 SwiftUI 的 controlBackgroundColor，
// 跟着窗口外观走。别顺手给它也套上主题。
//
// 之前这四处各写各的：截图浮层用写死的 0.13 深灰 + 纯白图标，录制工具条 /
// 滚动截图工具条用 `.hudWindow` 毛玻璃。改一个地方得翻四个文件，还容易漏。
// 现在只有这一个来源。
//
// 加新工具条也必须用这里，别再手写颜色。
// ============================================================

enum ToolbarTheme {

    /// 工具条底色 **#E6E6E6**（230, 230, 230）。
    ///
    /// 用 sRGB 而不是 `calibratedWhite`：那个跟显示器色彩配置走，
    /// 同一个 0.9 在不同屏幕上不是同一个灰，跟设计稿对不上。
    static let background = NSColor(srgbRed: 230.0 / 255.0,
                                    green: 230.0 / 255.0,
                                    blue: 230.0 / 255.0,
                                    alpha: 1)

    /// 图标与文字：**纯黑，写死**。
    ///
    /// 🔴 不能交给 `.labelColor`：它跟着系统外观翻（深色模式下是白），
    /// 而工具条底色是写死的浅灰 —— 系统一开深色模式，图标就白底白图看不见了。
    /// 反过来（以前底色写死深灰、前景写死白色）在浅色模式踩过同一个坑。
    static let foreground = NSColor.black

    /// 浅色外观。切了之后分隔线、NSPopUpButton、禁用态、以后加的控件都按浅色解析，
    /// 比逐个手写前景色彻底 —— 以前这条理由写的是"切 darkAqua"，方向正好反过来。
    static let appearance = NSAppearance(named: .aqua)

    /// 竖分隔线：浅底上用半透明黑。系统的 `separatorColor` 在浅色外观下偏淡，
    /// 压在 #E6E6E6 上几乎看不见。
    static let divider = NSColor.black.withAlphaComponent(0.18)

    /// 色块 / "当前颜色"圆点的描边：白边在浅底上等于没有（以前是 white 0.75）。
    /// 🔴 只描边，**色块本身的填充不动** —— 用户明确说"颜色图标除外"，
    /// 那颗圆点必须显示用户真正选中的红 / 黄 / 蓝，不能被主题色染掉。
    static let swatchBorder = NSColor.black.withAlphaComponent(0.35)

    /// 工具条里的次要底色（分组块、hover 态）：在 #E6E6E6 上略深一点点。
    static let subtleFill = NSColor.black.withAlphaComponent(0.06)
}
