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
    ///
    /// - Parameter excludingOwnWindows: 请求把本应用自己的窗口从画面里剔掉。
    ///
    ///   🔴 这个参数**不可靠**，别把画面干净与否押在它身上。实测（macOS 26）：
    ///   我们的取景框是 `.floating` / `.statusBar` 层，而 `SCShareableContent.windows`
    ///   基本只列 layer-0 的普通窗口，按 pid 过滤出来是空数组 → excluding 变空操作。
    ///   1.0.5 就是信了它会排除自己，在选区里画实时预览，结果每帧拍到的都是
    ///   "上一帧的预览"，只截得下第一段。
    ///   现在的做法是**取景框压根不在选区里画东西**（见 ScrollFrameView），
    ///   这里传 true 只是额外买一道保险。
    static func captureRegion(displayID: CGDirectDisplayID, rect: CGRect,
                              excludingOwnWindows: Bool = false) async throws -> CGImage {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw CaptureError.displayNotFound
        }
        var ownWindows: [SCWindow] = []
        if excludingOwnWindows {
            // 按 pid 认自己，不按 bundleIdentifier：裸二进制调试时 bundle id 是 nil
            let pid = ProcessInfo.processInfo.processIdentifier
            ownWindows = content.windows.filter { $0.owningApplication?.processID == pid }
        }
        let filter = SCContentFilter(display: display, excludingWindows: ownWindows)
        let config = SCStreamConfiguration()
        config.captureResolution = .best
        let scale = scaleFactor(for: displayID)
        // 🔴 区域必须先对齐整设备像素再交给 ScreenCaptureKit。
        // 选区来自鼠标拖动，`rect.width` 常年是 644.5 / 620.3 这种小数：
        //   · 小数 sourceRect 会被 SCK 重采样，帧本身发虚，拼接对齐精度掉到亚像素；
        //   · `Int(rect.width * scale)` 取整后要的像素数跟真实能给的经常差 1 行/1 列。
        let snapped = snapToDevicePixels(rect, scale: scale)
        config.sourceRect = snapped
        config.width = Int((snapped.width * scale).rounded())
        config.height = Int((snapped.height * scale).rounded())
        config.showsCursor = false
        let raw = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        // 🔴 必须裁掉透明边，否则滚动截图成品里全是 1px 白线。见 trimmingTransparentEdges。
        return trimmingTransparentEdges(raw)
    }

    /// 把矩形四条边对齐到**整设备像素**（scale = 2 时对齐到 0.5pt）。
    ///
    /// 纯几何，自检直接喂数字。尺寸只可能差 1 个设备像素。
    static func snapToDevicePixels(_ rect: CGRect, scale: CGFloat) -> CGRect {
        guard scale > 0 else { return rect }
        let x0 = (rect.minX * scale).rounded() / scale
        let y0 = (rect.minY * scale).rounded() / scale
        let x1 = (rect.maxX * scale).rounded() / scale
        let y1 = (rect.maxY * scale).rounded() / scale
        return CGRect(x: x0, y: y0,
                      width: max(1 / scale, x1 - x0),
                      height: max(1 / scale, y1 - y0))
    }

    /// 裁掉图像**右边缘/下边缘**完全透明的行与列。
    ///
    /// 🔴 这是「滚动截图成品图里全是 1px 白线」的根因（1.0.29）。
    ///
    /// `SCScreenshotManager` 在 `config.width/height` 比它实际填充的像素多的时候，
    /// 不会报错，而是**把差的那 1 行/1 列留成 alpha = 0**。实测（macOS 26 / scale 2）：
    /// 同一个矩形重复抓 8 次，脏的永远是同一边、同样的像素数（确定性，不是偶发）；
    /// 只要 sourceRect 四条边不在整设备像素上，或者尺寸换算取整对不上，就会中招。
    ///
    /// 后果分两步放大：
    ///   ① 画布是透明底，`StitchCanvas.append` 只拷每帧**底部 off 行**，
    ///      正好把最后那行透明一起拼了进去 → 每个拼接缝埋一条透明行；
    ///   ② `CGImageDestination` 编 JPEG 时 alpha = 0 被铺成**纯白 255**
    ///      （实测：透明行存 JPEG 读回来就是 (255,255,255)）→ 用户看到的就是白线。
    ///      存 PNG 则是透明缝，在预览/白底网页上照样是一片白。
    ///
    /// 裁掉的这 1px 里本来就没有画面数据，且同一个区域每帧裁掉的量完全一致，
    /// 所以拼接几何不受影响（帧与帧的 overlap 依然连续）。
    static func trimmingTransparentEdges(_ image: CGImage) -> CGImage {
        // 没有 alpha 通道就没什么可裁的
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: return image
        default: break
        }
        let w = image.width, h = image.height
        guard w > 1, h > 1 else { return image }

        var rowsToTrim = 0
        while rowsToTrim < min(8, h - 1),
              edgeIsClear(image, rect: CGRect(x: 0, y: h - 1 - rowsToTrim, width: w, height: 1)) {
            rowsToTrim += 1
        }
        var colsToTrim = 0
        while colsToTrim < min(8, w - 1),
              edgeIsClear(image, rect: CGRect(x: w - 1 - colsToTrim, y: 0, width: 1, height: h)) {
            colsToTrim += 1
        }
        guard rowsToTrim > 0 || colsToTrim > 0 else { return image }
        let cropped = CGRect(x: 0, y: 0, width: w - colsToTrim, height: h - rowsToTrim)
        return image.cropping(to: cropped) ?? image
    }

    /// 这一小块（一行或一列）是不是**全透明**。
    ///
    /// 逐像素扫，不抽样：一行才 ~1800 个像素，抽样万一把"基本全透明但有一处画面"
    /// 的边判成空，就会把真内容裁掉。
    private static func edgeIsClear(_ image: CGImage, rect: CGRect) -> Bool {
        guard let slice = image.cropping(to: rect) else { return false }
        let sw = slice.width, sh = slice.height
        guard sw > 0, sh > 0,
              let ctx = CGContext(data: nil, width: sw, height: sh,
                                  bitsPerComponent: 8, bytesPerRow: sw * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                    | CGBitmapInfo.byteOrder32Little.rawValue) else { return false }
        ctx.draw(slice, in: CGRect(x: 0, y: 0, width: sw, height: sh))
        guard let base = ctx.data else { return false }
        let data = base.bindMemory(to: UInt8.self, capacity: sw * sh * 4)
        var i = 3
        while i < sw * sh * 4 {
            if data[i] != 0 { return false }
            i += 4
        }
        return true
    }


    /// 截取单个窗口（点选窗口模式）
    static func captureWindow(_ window: ScreenWindowInfo) async throws -> CGImage {
        var content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        var scWindow = content.windows.first(where: { $0.windowID == window.windowID })
        if scWindow == nil {
            // 我们的全屏遮罩一出场，目标窗口可能刚好被判成"不在屏上"（被遮住的瞬态面板），
            // 放宽到全部窗口再查一次 —— windowID 对得上就能截。
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            scWindow = content.windows.first(where: { $0.windowID == window.windowID })
        }
        guard let scWindow else {
            NSLog("[BoxShot] captureWindow 找不到 windowID=%u（owner=%@）",
                  window.windowID, window.ownerName)
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

    /// AppKit 全局坐标（主屏左下原点）→ 该显示器的局部坐标（左上原点）。
    ///
    /// `SCStreamConfiguration.sourceRect` 与选区都吃这套坐标，固定录制框要反过来算：
    /// NSScreen.visibleFrame 是 AppKit 全局坐标，直接当 sourceRect 用会上下颠倒。
    static func displayLocalRect(fromAppKit rect: CGRect, displayID: CGDirectDisplayID) -> CGRect {
        guard let screen = NSScreen.screens.first(where: { display(for: $0) == displayID }) else { return rect }
        let frame = screen.frame
        let x = rect.minX - frame.minX
        let yFromBottom = rect.minY - frame.minY
        let yFromTop = frame.height - yFromBottom - rect.height
        return CGRect(x: x, y: yFromTop, width: rect.width, height: rect.height)
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
