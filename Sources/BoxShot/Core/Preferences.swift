import AppKit
import Combine
import Foundation
import SwiftUI

// ============================================================
// 设置项：一份 Codable 结构 + 带落盘的容器（沿用家族 PreferencesStore 形状）
// ============================================================

/// 截图保存格式
enum ShotFormat: String, Codable, CaseIterable, Identifiable {
    case png
    case jpg

    var id: String { rawValue }
    var title: String { rawValue.uppercased() }
    var fileExtension: String { rawValue }
}

/// 录制音源
enum RecordAudioSource: String, Codable, CaseIterable, Identifiable {
    case none      // 无声
    case system    // 系统声音
    case mic       // 麦克风

    var id: String { rawValue }
    var title: String {
        switch self {
        case .none:   return "无"
        case .system: return "系统声音"
        case .mic:    return "麦克风"
        }
    }
}

/// 录制封装格式
///
/// 🔴 GIF 已移除（1.0.12）：GIF 走「帧序列逐帧收 CGImage、收工一次性编码」，
/// 600 帧 × 1000px 全程常驻内存能到 1.8GB，是全应用唯一的内存事故点。
/// 老配置里存的 `"gif"` 会在解码时迁回 `.mp4`（见 `init(from:)`）——
/// 不能直接删 enum 项就完事：decodeIfPresent 碰到未知值会抛错，
/// 整份设置就会回退出厂，快捷键、保存目录全没了。
enum RecordFileFormat: String, Codable, CaseIterable, Identifiable {
    case mov
    case mp4

    var id: String { rawValue }
    var title: String { rawValue.uppercased() }
    var fileExtension: String { rawValue }

    /// 老配置的迁移：`"gif"` → `.mp4`，其余原样
    static func from(legacyRaw raw: String?) -> RecordFileFormat? {
        switch raw {
        case "gif": return .mp4
        case "mov": return .mov
        case "mp4": return .mp4
        default:    return nil
        }
    }
}

/// MOV / MP4 的帧率档位。
///
/// 24 / 25 是影视与 PAL 的老口径（用户给的参考图里就有），48 / 50 / 60 给高帧率素材。
/// 引擎侧的换算见 `Recorder`：`minimumFrameInterval` 用 `min(60, fps)`、
/// `AVVideoExpectedSourceFrameRateKey` 用 `max(10, fps)`，这两头都能吃下 48/50/60。
let recordFPSOptions: [Int] = [10, 15, 24, 25, 30, 48, 50, 60]

/// 摄像头取景框的大小档位（两个场景两套数，别混用）。
///
/// · `side`       —— **区域录制 / 全屏录制**贴在选区右下角的小窗：大 200 / 中 150 / 小 100。
///   1.0.20 一度把这一套合并成 600/550/500，结果区域录制里一个 600 的圆把画面盖掉大半，
///   用户要求「区域录制、全屏录制还原成之前的」—— 所以恢复。1.0.24 用户再往下收一档
///   （中 180→150、小 150→100，大 200 不动）：画中画是配角，越小越不挡被录内容。
///   🔴 别和 `cameraSide` 那套（680/600/500）混，两套数各归各的场景。
/// · `cameraSide` —— **摄像头录制**（固定录制框）里居中摆的那个大取景框：
///   大 680 / 中 600 / 小 500（1.0.24 起，「大」再放大一档；虚线录制框尺寸不动）。
///   用户口径就是这三个数 —— 人脸要看得清。
enum CameraBubbleSize: String, Codable, CaseIterable, Identifiable {
    case large
    case medium
    case small

    var id: String { rawValue }
    var title: String {
        switch self {
        case .large:  return "大"
        case .medium: return "中"
        case .small:  return "小"
        }
    }
    /// 区域 / 全屏录制里画中画取景框的边长，单位 pt
    var side: CGFloat {
        switch self {
        case .large:  return 200
        case .medium: return 150
        case .small:  return 100
        }
    }
    /// 摄像头录制（固定录制框）里取景框的边长，单位 pt
    var cameraSide: CGFloat {
        switch self {
        case .large:  return 680
        case .medium: return 600
        case .small:  return 500
        }
    }
}

/// 录制质量（映射 H.264 平均码率系数）
enum RecordQuality: String, Codable, CaseIterable, Identifiable {
    case high
    case medium
    case low

    var id: String { rawValue }
    var title: String {
        switch self {
        case .high:   return "高"
        case .medium: return "中等"
        case .low:    return "低"
        }
    }
    /// bits per pixel per frame 的经验系数
    var bitrateFactor: Double {
        switch self {
        case .high:   return 0.12
        case .medium: return 0.06
        case .low:    return 0.03
        }
    }
}

/// 放大镜里「坐标」的零点放在哪个角（用户设置里的「捕捉原点在」）
enum LoupeOrigin: String, Codable, CaseIterable, Identifiable {
    case topLeft
    case topRight
    case bottomLeft
    case bottomRight

    var id: String { rawValue }
    var title: String {
        switch self {
        case .topLeft:     return "左上角"
        case .topRight:    return "右上角"
        case .bottomLeft:  return "左下角"
        case .bottomRight: return "右下角"
        }
    }
}

/// 放大镜里色值的写法
enum ColorTextFormat: String, Codable, CaseIterable, Identifiable {
    case hex
    case rgb
    case hsl

    var id: String { rawValue }
    var title: String {
        switch self {
        case .hex: return "HEX"
        case .rgb: return "RGB"
        case .hsl: return "HSL"
        }
    }
}

struct Preferences: Codable, Equatable {
    // ── 通用 ──
    var launchAtLogin: Bool = false
    /// 菜单栏应用默认不占 Dock；贴图多的时候用户可能想让 Dock 图标回来
    var hideDockIcon: Bool = true
    var playSound: Bool = true          // 操作完成提示音
    /// 提示音音效名（系统音效，见 SoundFeedback.options）
    var feedbackSound: String = SoundFeedback.defaultName
    var showCrosshair: Bool = true      // 选区时显示放大取色十字线

    // ── 截图 ──
    var shotFormat: ShotFormat = .png
    var jpgQuality: Double = 0.9
    /// 打开编辑器（false = 截完直接按"输出动作"走，不弹编辑器）
    var openEditorAfterShot: Bool = true
    /// 智能识别窗口：移动鼠标时高亮所在窗口
    var windowHighlight: Bool = true
    /// 保存目录（nil = 每次问）；空字符串 = 桌面
    var saveDirectory: String? = nil
    /// 自动保存到目录（不再每次询问）
    var autoSave: Bool = false
    /// Retina 截图缩小到 1x
    var downscaleRetina: Bool = false
    /// 截图历史保留张数（0 = 不记录）
    var maxShotHistory: Int = 20

    // ── 放大镜（选区取色） ──
    /// 选区时在光标旁显示放大镜（像素网格 + 坐标 + 色值）
    var magnifierEnabled: Bool = true
    /// 放大镜里十字线 / 边线的颜色（十六进制串，UI 用 ColorPicker 编辑）
    var magnifierLineColor: String = "#3B82F6"
    /// 「坐标」的零点在哪个角
    var magnifierOrigin: LoupeOrigin = .bottomLeft
    /// 色值写法
    var magnifierColorFormat: ColorTextFormat = .hex
    /// HEX 前面带 `#`
    var magnifierHashPrefix: Bool = true

    // ── 贴图 ──
    var pinDoubleClick: PinDoubleClickAction = .close
    var pinOpacity: Double = 1.0
    var pinShadow: Bool = true
    var maxPinHistory: Int = 20

    // ── OCR ──
    var ocrKeepLineBreaks: Bool = true
    /// 换行计算重叠参数（两行横向重叠超过该比例视为同一行折行）
    var ocrLineOverlap: Double = 0.2
    var ocrIncremental: Bool = false   // 增量累积识别（结果不清空、往剪贴板追加）
    var ocrAutoOpenLink: Bool = true   // QR 是链接时识别后自动打开

    // ── 测量 ──
    var measureShowTips: Bool = true

    // ── 录制 ──
    var recordAudio: RecordAudioSource = .mic
    var recordCamera: Bool = false     // 摄像头画中画
    var recordCameraSize: CameraBubbleSize = .medium
    /// 摄像头录制（固定录制框）里取景框的大小：默认大 600
    var cameraRecordSize: CameraBubbleSize = .large
    var recordFPS: Int = 30
    var recordShowCursor: Bool = true
    var recordFormat: RecordFileFormat = .mp4
    var recordQuality: RecordQuality = .high
    /// 录制完成后在 Finder 里定位文件（不然文件默默躺在桌面找不到）
    var recordRevealInFinder: Bool = true
    var shortcuts: [String: KeySpec] = [:]   // 出厂不预置热键（1.0.1 用户要求）

    /// 严格读取：设置里没录就是 nil，**不回退默认值**——
    /// 之前回退默认值，导致设置里点"清除"后界面又显示回 F7（清除不了的根因）。
    func spec(for action: ShotAction) -> KeySpec? {
        shortcuts[action.rawValue]
    }

    // 手写解码：新增字段缺了就用默认值，升级不丢配置。
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let f = Preferences()
        launchAtLogin = try c.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? f.launchAtLogin
        hideDockIcon = try c.decodeIfPresent(Bool.self, forKey: .hideDockIcon) ?? f.hideDockIcon
        playSound = try c.decodeIfPresent(Bool.self, forKey: .playSound) ?? f.playSound
        // 存量配置里可能记着已经下线的音效名（或别人机器上的名字），
        // 落回默认 —— 否则设置页的 Picker 会显示成空白
        let storedSound = try c.decodeIfPresent(String.self, forKey: .feedbackSound) ?? f.feedbackSound
        feedbackSound = SoundFeedback.availableNames.contains(storedSound) ? storedSound : f.feedbackSound
        showCrosshair = try c.decodeIfPresent(Bool.self, forKey: .showCrosshair) ?? f.showCrosshair
        shotFormat = try c.decodeIfPresent(ShotFormat.self, forKey: .shotFormat) ?? f.shotFormat
        jpgQuality = try c.decodeIfPresent(Double.self, forKey: .jpgQuality) ?? f.jpgQuality
        openEditorAfterShot = try c.decodeIfPresent(Bool.self, forKey: .openEditorAfterShot) ?? f.openEditorAfterShot
        windowHighlight = try c.decodeIfPresent(Bool.self, forKey: .windowHighlight) ?? f.windowHighlight
        saveDirectory = try c.decodeIfPresent(String.self, forKey: .saveDirectory) ?? f.saveDirectory
        autoSave = try c.decodeIfPresent(Bool.self, forKey: .autoSave) ?? f.autoSave
        downscaleRetina = try c.decodeIfPresent(Bool.self, forKey: .downscaleRetina) ?? f.downscaleRetina
        maxShotHistory = try c.decodeIfPresent(Int.self, forKey: .maxShotHistory) ?? f.maxShotHistory
        magnifierEnabled = try c.decodeIfPresent(Bool.self, forKey: .magnifierEnabled) ?? f.magnifierEnabled
        magnifierLineColor = try c.decodeIfPresent(String.self, forKey: .magnifierLineColor) ?? f.magnifierLineColor
        magnifierOrigin = try c.decodeIfPresent(LoupeOrigin.self, forKey: .magnifierOrigin) ?? f.magnifierOrigin
        magnifierColorFormat = try c.decodeIfPresent(ColorTextFormat.self, forKey: .magnifierColorFormat) ?? f.magnifierColorFormat
        magnifierHashPrefix = try c.decodeIfPresent(Bool.self, forKey: .magnifierHashPrefix) ?? f.magnifierHashPrefix
        pinDoubleClick = try c.decodeIfPresent(PinDoubleClickAction.self, forKey: .pinDoubleClick) ?? f.pinDoubleClick
        pinOpacity = try c.decodeIfPresent(Double.self, forKey: .pinOpacity) ?? f.pinOpacity
        pinShadow = try c.decodeIfPresent(Bool.self, forKey: .pinShadow) ?? f.pinShadow
        maxPinHistory = try c.decodeIfPresent(Int.self, forKey: .maxPinHistory) ?? f.maxPinHistory
        ocrKeepLineBreaks = try c.decodeIfPresent(Bool.self, forKey: .ocrKeepLineBreaks) ?? f.ocrKeepLineBreaks
        ocrLineOverlap = try c.decodeIfPresent(Double.self, forKey: .ocrLineOverlap) ?? f.ocrLineOverlap
        ocrIncremental = try c.decodeIfPresent(Bool.self, forKey: .ocrIncremental) ?? f.ocrIncremental
        ocrAutoOpenLink = try c.decodeIfPresent(Bool.self, forKey: .ocrAutoOpenLink) ?? f.ocrAutoOpenLink
        measureShowTips = try c.decodeIfPresent(Bool.self, forKey: .measureShowTips) ?? f.measureShowTips
        recordAudio = try c.decodeIfPresent(RecordAudioSource.self, forKey: .recordAudio) ?? f.recordAudio
        recordCamera = try c.decodeIfPresent(Bool.self, forKey: .recordCamera) ?? f.recordCamera
        recordCameraSize = try c.decodeIfPresent(CameraBubbleSize.self, forKey: .recordCameraSize) ?? f.recordCameraSize
        cameraRecordSize = try c.decodeIfPresent(CameraBubbleSize.self, forKey: .cameraRecordSize) ?? f.cameraRecordSize
        recordFPS = try c.decodeIfPresent(Int.self, forKey: .recordFPS) ?? f.recordFPS
        recordShowCursor = try c.decodeIfPresent(Bool.self, forKey: .recordShowCursor) ?? f.recordShowCursor
        // recordFormat 手动映射（不再走 decodeIfPresent(RecordFileFormat.self)）：
        // 老配置里可能存着 "gif"，直接解 enum 会抛错 → 整份设置回退出厂。
        let storedFormat = try c.decodeIfPresent(String.self, forKey: .recordFormat)
        recordFormat = RecordFileFormat.from(legacyRaw: storedFormat) ?? f.recordFormat
        recordQuality = try c.decodeIfPresent(RecordQuality.self, forKey: .recordQuality) ?? f.recordQuality
        recordRevealInFinder = try c.decodeIfPresent(Bool.self, forKey: .recordRevealInFinder) ?? f.recordRevealInFinder
        // 快捷键缺省就是空表（1.0.1 起出厂不预置）
        shortcuts = try c.decodeIfPresent([String: KeySpec].self, forKey: .shortcuts) ?? [:]
    }

    init() {}

    enum CodingKeys: String, CodingKey {
        case launchAtLogin, hideDockIcon, playSound, feedbackSound, showCrosshair
        case shotFormat, jpgQuality, openEditorAfterShot, windowHighlight, saveDirectory, autoSave, downscaleRetina
        case maxShotHistory
        case magnifierEnabled, magnifierLineColor, magnifierOrigin, magnifierColorFormat, magnifierHashPrefix
        case pinDoubleClick, pinOpacity, pinShadow, maxPinHistory
        case ocrKeepLineBreaks, ocrLineOverlap, ocrIncremental, ocrAutoOpenLink
        case measureShowTips
        case recordAudio, recordCamera, recordCameraSize, cameraRecordSize, recordFPS, recordShowCursor
        case recordFormat, recordQuality, recordRevealInFinder
        case shortcuts
    }
}

enum PinDoubleClickAction: String, Codable, CaseIterable, Identifiable {
    case close
    case shrink
    case viewLarge   // 打开大图查看

    var id: String { rawValue }
    var title: String {
        switch self {
        case .close:     return "关闭"
        case .shrink:    return "缩小"
        case .viewLarge: return "查看大图"
        }
    }
}

@MainActor
final class PreferencesStore: ObservableObject {
    @Published var value: Preferences {
        didSet {
            guard value != oldValue else { return }
            // 「自动保存」勾上了但没有保存目录 = 等于没开（以前的实现就是
            // `guard let dirPath` 直接 return，用户看到的是"打开了却什么都不发生"）。
            // 这里当场补成桌面，界面上也跟着显示出来，不留"看着开了其实空转"的状态。
            if value.autoSave, (value.saveDirectory ?? "").isEmpty {
                value.saveDirectory = Support.defaultSaveDirectory.path
                return
            }
            save()
            didChange?(oldValue, value)
        }
    }

    var didChange: (@MainActor (Preferences, Preferences) -> Void)?

    private let defaults: UserDefaults
    private static let key = "com.pcxx.boxshot.preferences"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.key),
           let decoded = try? JSONDecoder().decode(Preferences.self, from: data) {
            value = decoded
        } else {
            value = Preferences()
        }
        if value.launchAtLogin != LoginItem.isEnabled {
            value.launchAtLogin = LoginItem.isEnabled
        }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(value) else { return }
        defaults.set(data, forKey: Self.key)
    }

    func binding<T>(_ keyPath: WritableKeyPath<Preferences, T>) -> Binding<T> {
        Binding(get: { self.value[keyPath: keyPath] },
                set: { self.value[keyPath: keyPath] = $0 })
    }
}
