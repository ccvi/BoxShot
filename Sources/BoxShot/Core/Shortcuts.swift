import AppKit
import Carbon.HIToolbox

// ============================================================
// 快捷键：键位描述 + 动作表
//
// 全局键统一走 Carbon RegisterEventHotKey（不需要辅助功能授权）。
// KeySpec 的实现沿用家族 BoxPaste 的成熟代码，差异只有一点：
//   BoxShot 的默认键位是 F 键（F7/F8）——功能键不参与打字，
//   允许"无修饰键"注册，所以 isUsableAsGlobal 里给功能键开了口子。
// ============================================================

/// 一个键位。`label` 录制时抓下来存着，显示键位不用自己维护 keyCode 表。
struct KeySpec: Codable, Equatable, Hashable {
    var keyCode: UInt16
    var command: Bool = false
    var shift: Bool = false
    var option: Bool = false
    var control: Bool = false
    var label: String = ""

    var display: String {
        var text = ""
        if control { text += "⌃" }
        if option { text += "⌥" }
        if shift { text += "⇧" }
        if command { text += "⌘" }
        return text + (label.isEmpty ? "键码 \(keyCode)" : label)
    }

    func matches(_ event: NSEvent) -> Bool {
        guard event.keyCode == keyCode else { return false }
        let flags = event.modifierFlags
        return flags.contains(.command) == command
            && flags.contains(.shift) == shift
            && flags.contains(.option) == option
            && flags.contains(.control) == control
    }

    var carbonModifiers: UInt32 {
        var mask: UInt32 = 0
        if command { mask |= UInt32(cmdKey) }
        if shift { mask |= UInt32(shiftKey) }
        if option { mask |= UInt32(optionKey) }
        if control { mask |= UInt32(controlKey) }
        return mask
    }

    /// 功能键（F1–F12 等）单独按下不算"抢键盘"，可以直接当全局热键；
    /// 其余无修饰键的组合一律拒绝——否则打字时应用会被频繁误触。
    var isUsableAsGlobal: Bool {
        if command || option || control { return true }
        return Self.functionKeyCodes.contains(Int(keyCode))
    }

    static let functionKeyCodes: Set<Int> = [
        kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6,
        kVK_F7, kVK_F8, kVK_F9, kVK_F10, kVK_F11, kVK_F12,
    ]

    static func from(_ event: NSEvent) -> KeySpec {
        KeySpec(keyCode: event.keyCode,
                command: event.modifierFlags.contains(.command),
                shift: event.modifierFlags.contains(.shift),
                option: event.modifierFlags.contains(.option),
                control: event.modifierFlags.contains(.control),
                label: label(for: event))
    }

    static func label(for event: NSEvent) -> String {
        switch Int(event.keyCode) {
        case kVK_Return, kVK_ANSI_KeypadEnter: return "↩"
        case kVK_Space:                        return "空格"
        case kVK_Delete:                       return "⌫"
        case kVK_Escape:                       return "⎋"
        case kVK_Tab:                          return "⇥"
        case kVK_LeftArrow:                    return "←"
        case kVK_RightArrow:                   return "→"
        case kVK_UpArrow:                      return "↑"
        case kVK_DownArrow:                    return "↓"
        case kVK_F1: return "F1"
        case kVK_F2: return "F2"
        case kVK_F3: return "F3"
        case kVK_F4: return "F4"
        case kVK_F5: return "F5"
        case kVK_F6: return "F6"
        case kVK_F7: return "F7"
        case kVK_F8: return "F8"
        case kVK_F9: return "F9"
        case kVK_F10: return "F10"
        case kVK_F11: return "F11"
        case kVK_F12: return "F12"
        default:
            if let characters = event.charactersIgnoringModifiers, !characters.isEmpty {
                return characters.uppercased()
            }
            return "键码 \(event.keyCode)"
        }
    }
}

/// 可配置动作。rawValue 写进设置文件，当成接口看待，不要改字符串。
enum ShotAction: String, Codable, CaseIterable, Identifiable {
    case regionShot         // 开始截图（区域）
    case regionCopy         // 截图复制（截完直接进剪贴板，不开编辑器）
    case captureLastRegion  // 重复上次区域截图
    case fullscreenShot     // 全屏截图
    case windowShot         // 窗口截图（点选窗口）
    case smartElement       // 智能元素截取（点一下，自动框住光标下那个 UI 元素）
    case scrollShot         // 滚动截图
    case ocrShot            // 截图 OCR
    case decodeQR           // 解码 QR / 条形码
    case measure            // 屏幕测量
    case recordRegion       // 区域录制
    case recordFullscreen   // 全屏录制
    case recordWindow       // 窗口录制（点选一个窗口，只录它自己）
    case recordCamera       // 摄像头录制（只录摄像头，不录屏幕）
    case pinClipboard       // 剪贴板贴图
    case openSettings       // 偏好设置

    var id: String { rawValue }

    var title: String {
        switch self {
        case .regionShot:        return "开始截图"
        case .regionCopy:        return "截图复制"
        case .captureLastRegion: return "重复上次区域截图"
        case .fullscreenShot:    return "全屏截图"
        case .windowShot:        return "窗口截图"
        case .smartElement:      return "智能元素截取"
        case .scrollShot:        return "滚动截图"
        case .ocrShot:           return "截图 OCR"
        case .decodeQR:          return "解码 QR/条形码"
        case .measure:           return "屏幕测量"
        case .recordRegion:      return "区域录制"
        case .recordFullscreen:  return "全屏录制"
        case .recordWindow:      return "窗口录制"
        case .recordCamera:      return "摄像头录制"
        case .pinClipboard:      return "剪贴板贴图"
        case .openSettings:      return "偏好设置"
        }
    }

    var defaultSpec: KeySpec? {
        // 1.0.1 起**出厂不预置任何全局热键**（用户要求）：
        // 用户在设置里自己录的键才生效。这里保留返回 nil 的形状，
        // 纯粹为了 SettingsView 的绑定类型不塌。
        return nil
    }
}
