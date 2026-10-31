import AppKit
import CoreGraphics
import ScreenCaptureKit

// ============================================================
// 屏幕捕获：截图 / 窗口枚举 / 坐标换算
//
// 统一走 ScreenCaptureKit（macOS 14+）：
//   · SCScreenshotManager 单帧截图，不用已废弃的 CGDisplayCreateImage
//   · CGWindowList 只用来枚举窗口几何（做"智能识别窗口"的高亮），
//     它只需要窗口边界，不读窗口内容，不依赖屏幕录制授权
//
// 坐标系备忘（三套，别混）：
//   · CGWindowList / NSEvent 全局坐标：主屏左上角为原点，向下为正
//   · SCStreamConfiguration.sourceRect：相对目标显示器左上角，向下为正
//   · CGDisplayBounds：每台显示器的全局框
// 全局 → 显示器局部 = 减去该显示器的 bounds.origin。
// ============================================================

struct ScreenWindowInfo: Equatable {
    var windowID: CGWindowID
    var frame: CGRect        // 全局坐标
    var ownerName: String
    var title: String?
}

enum ScreenCapture {

    // ── 权限 ──

    static func ensurePermission() -> Bool {
        if ScreenPermission.isGranted { return true }
        ScreenPermission.request()
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "需要「屏幕录制」权限"
            alert.informativeText = "请在 系统设置 → 隐私与安全性 → 屏幕录制 中勾选 BoxShot，然后重新打开 BoxShot。"
            alert.addButton(withTitle: "打开系统设置")
            alert.addButton(withTitle: "稍后")
            if alert.runModal() == .alertFirstButtonReturn {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
            }
        }
        return false
    }

    // ── 显示器 ──

    /// 覆盖鼠标所在的屏幕（1.0.0 的选区只做单屏，多屏拼接留待后续版本）
    static func activeScreen() -> NSScreen {
        let location = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(location) }
            ?? NSScreen.main
            ?? NSScreen.screens[0]
    }

    static func display(for screen: NSScreen) -> CGDirectDisplayID {
        screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID ?? CGMainDisplayID()
    }

    /// NSScreen.frame 与 CGDisplayBounds 的差异：NSScreen 坐标原点在主屏左下角，
    /// CGDisplayBounds 在主屏左上角。这里统一换算成"屏幕录制"那套（左上原点）。
    static func displayBoundsGlobal(_ displayID: CGDirectDisplayID) -> CGRect {
        CGDisplayBounds(displayID)
    }

    // ── 窗口枚举（智能识别窗口用） ──

    /// 屏上普通层级的窗口，按从上到下排序（数组越靠前越在上层）。
    /// 只取 bounds / 名字，不碰像素，所以没有屏幕录制授权也能用。
    static func onScreenWindows() -> [ScreenWindowInfo] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] else { return [] }
        var result: [ScreenWindowInfo] = []
        for info in list {
            // 只看普通窗口层（kCGWindowLayer == 0），跳过菜单栏 / Dock / 输入法面板
            guard let layer = info[kCGWindowLayer as String] as? Int, layer == 0,
                  let windowID = info[kCGWindowNumber as String] as? UInt32,
                  let bounds = info[kCGWindowBounds as String] as? [String: CGFloat] else { continue }
            let frame = CGRect(x: bounds["X"] ?? 0, y: bounds["Y"] ?? 0,
                               width: bounds["Width"] ?? 0, height: bounds["Height"] ?? 0)
            guard frame.width >= 60, frame.height >= 40 else { continue } // 跳过小浮窗
            let owner = info[kCGWindowOwnerName as String] as? String ?? ""
            let title = info[kCGWindowName as String] as? String
            result.append(ScreenWindowInfo(windowID: windowID, frame: frame,
                                           ownerName: owner, title: title))
        }
        return result
    }

    /// 命中测试：返回包含该全局坐标点、且"最靠上"的窗口（排除自己）
    static func topLevelWindow(at globalPoint: CGPoint, excluding: Set<CGWindowID> = []) -> ScreenWindowInfo? {
        onScreenWindows().first { $0.frame.contains(globalPoint) && !excluding.contains($0.windowID) }
    }

    // ── 截图（SCScreenshotManager） ──

    /// 截取整个显示器
    static func captureDisplay(_ displayID: CGDirectDisplayID) async throws -> CGImage {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw CaptureError.displayNotFound
        }
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        config.captureResolution = .best
        let scale = scaleFactor(for: displayID)
        config.width = Int(CGFloat(display.width) * scale)
        config.height = Int(CGFloat(display.height) * scale)
        config.showsCursor = false
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }

    /// 截取显示器上的一个矩形区域（rect 用该显示器的**局部坐标**，点单位）
    static func captureRegion(displayID: CGDirectDisplayID, rect: CGRect) async throws -> CGImage {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw CaptureError.displayNotFound
        }
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        config.captureResolution = .best
        config.sourceRect = rect
        let scale = scaleFactor(for: displayID)
        config.width = Int(rect.width * scale)
        config.height = Int(rect.height * scale)
        config.showsCursor = false
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }

    /// 截取单个窗口（点选窗口模式）
    static func captureWindow(_ window: ScreenWindowInfo) async throws -> CGImage {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let scWindow = content.windows.first(where: { $0.windowID == window.windowID }) else {
            throw CaptureError.windowNotFound
        }
        let filter = SCContentFilter(desktopIndependentWindow: scWindow)
        let config = SCStreamConfiguration()
        config.captureResolution = .best
        let scale = window.frame.width > 0 ? max(1, NSScreen.main.map { $0.backingScaleFactor } ?? 2) : 2
        config.width = Int(window.frame.width * scale)
        config.height = Int(window.frame.height * scale)
        config.showsCursor = false
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }

    // ── 坐标换算 ──

    /// CG 全局坐标（主屏左上原点，向下为正）→ AppKit 全局坐标（主屏左下原点，向上为正）。
    /// x 两套坐标一致；y = 主屏高度 - cgY - h。
    static func appKitFrame(fromGlobalTopLeft rect: CGRect) -> CGRect {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? rect.maxY
        return CGRect(x: rect.minX,
                      y: primaryHeight - rect.maxY,
                      width: rect.width,
                      height: rect.height)
    }

    /// 显示器局部坐标（左上原点）→ CG 全局坐标（左上原点）：加上显示器原点即可
    static func globalTopLeftRect(fromDisplayLocal rect: CGRect, displayID: CGDirectDisplayID) -> CGRect {
        let origin = displayBoundsGlobal(displayID).origin
        return CGRect(x: origin.x + rect.minX, y: origin.y + rect.minY,
                      width: rect.width, height: rect.height)
    }

    // ── 缩放 ──

    static func scaleFactor(for displayID: CGDirectDisplayID) -> CGFloat {
        for screen in NSScreen.screens {
            if display(for: screen) == displayID { return screen.backingScaleFactor }
        }
        return 2
    }

    enum CaptureError: LocalizedError {
        case displayNotFound
        case windowNotFound

        var errorDescription: String? {
            switch self {
            case .displayNotFound: return "找不到目标显示器"
            case .windowNotFound:  return "目标窗口已关闭或不可截取"
            }
        }
    }
}
