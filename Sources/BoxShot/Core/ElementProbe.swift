import AppKit
import ApplicationServices

// ============================================================
// 智能元素截取：查出光标底下那个 UI 元素
//
// 用户口径（2026-11-06）：「增加：智能元素截取的功能」，参考图里它排在
// 「识别文字（OCR）」下面 —— 即"点一下就把这个元素截下来"，而不是让用户自己拉框。
//
// 实现只能走辅助功能（AX）：macOS 上除了 AX，没有第二个能问到"这个按钮的框在哪"的
// 公开接口。代价是要**辅助功能授权**（跟 BoxMouse 一样），所以：
//   · 没授权 → 先弹系统授权提示，同时**回退到窗口级**（SCK 窗口列表，不需要新权限），
//     功能不至于完全不能用；
//   · AX 调用设 0.25 秒超时 —— 目标应用卡死时，光标一动整块遮罩就跟着卡。
// ============================================================

enum ElementProbe {

    struct Hit: Equatable {
        /// 全局坐标（左上原点），跟 CGWindowList / 视图的全局坐标同一套
        var rect: CGRect
        /// 给用户看的名字，如「窗口：Safari」「AXButton：确定」
        var label: String
        /// 命中的是不是整窗（决定提示文案说"元素"还是"窗口"）
        var isWindow: Bool
    }

    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// 已经"打开过网页辅助功能"的进程 → 上次设置的时间
    private static var deepAccessLastSet: [pid_t: TimeInterval] = [:]
    /// 同一个进程多久之内不重复设置。
    /// 🔴 不能"一次就永久记住"：Chromium 在没有辅助技术持续查询时会把
    /// 可访问性树收回去（实测闲置几十秒后失效），那时又只剩整窗 Group。
    /// 15 秒后允许再设一次，既不骚扰又能自愈。
    private static let deepAccessRetryInterval: TimeInterval = 15

    /// 🔴 网页类应用（Chromium / Firefox / Electron）默认**不建**辅助功能树 ——
    /// 出于性能考虑，它只在"有辅助技术在场"时才把 DOM 铺成 AX 元素。
    /// 不在场时 `CopyElementAtPosition` 只肯给到"和窗口一样大的 Group"，
    /// 用户看到的就是「整窗高亮」，智能元素截取在网页上等于没用。
    ///
    /// 打开的办法是给**目标应用**的 AXApplication 元素设两个属性：
    ///   · `AXEnhancedUserInterface` = true —— VoiceOver 在场时系统替它设的那个开关
    ///   · `AXManualAccessibility`  = true —— Chromium 专供辅助工具手动打开的开关
    /// 两个都设（各家认的不一样），设完等它把树建起来再查。
    ///
    /// 每个进程 15 秒内只设一次：这两个属性会改目标应用的行为（它得开始维护
    /// 可访问性树），每次悬停都设一遍属于骚扰。
    /// - Returns: 这次是不是真的设了（调用方据此决定要不要延时补查一次）
    @discardableResult
    static func enableDeepAccess(_ pid: pid_t) -> Bool {
        guard isTrusted, pid > 0 else { return false }
        let now = Date().timeIntervalSince1970
        guard shouldSetDeepAccess(last: deepAccessLastSet[pid], now: now) else { return false }
        deepAccessLastSet[pid] = now
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.25)
        AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString,
                                     kCFBooleanTrue)
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString,
                                     kCFBooleanTrue)
        return true
    }

    /// 纯函数：该不该（重新）给这个进程打开网页辅助功能
    static func shouldSetDeepAccess(last: TimeInterval?, now: TimeInterval) -> Bool {
        guard let last else { return true }
        return now - last >= deepAccessRetryInterval
    }

    /// 请求辅助功能授权（会弹系统对话框）。
    /// 只在用户**主动**点「智能元素截取」时调，别在启动时弹 —— 那属于骚扰。
    @discardableResult
    static func requestAccess() -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    /// 光标底下那个元素。未授权 / 查不到 / 太小 都返回 nil（调用方再退回窗口级）。
    ///
    /// 🔴 **必须按 pid 查，不能用全系统级命中**：遮罩是一块盖满整屏的窗口，
    /// `AXUIElementCreateSystemWide` + `CopyElementAtPosition` 按 z 序命中，永远先碰到
    /// 我们自己的遮罩 —— 用户看到的是"高亮了整个屏幕"。改成对"光标下最上层那个普通窗口"
    /// 的属主进程查，才拿得到底下的按钮。
    static func element(atGlobal point: CGPoint, in pid: pid_t) -> Hit? {
        guard isTrusted, pid > 0 else { return nil }
        let app = AXUIElementCreateApplication(pid)
        // 悬停时每一帧都要问一次；不设超时的话，碰到卡死的目标应用会让遮罩一起卡住
        AXUIElementSetMessagingTimeout(app, 0.25)
        guard let element = deepest(atGlobal: point, in: app) else { return nil }
        guard let hit = describe(element, at: point) else { return nil }
        // 🔴 AX 偶尔会回一个"跟探测点毫无关系"的元素（实测：遮罩刚起来、窗口列表
        // 还在刷新时，问到的是 AXMenuBar 0,0 1710×34）。信的代价是**截错一块区域**，
        // 所以只认"框真的盖住这个点"的命中，否则交给窗口级兜底。
        guard containsPoint(hit.rect, point) else { return nil }
        return hit
    }

    /// 纯函数：这个框是否盖住探测点（容差 2pt，AX 常给 ±1pt 的取整误差）
    static func containsPoint(_ rect: CGRect, _ point: CGPoint, tolerance: CGFloat = 2) -> Bool {
        rect.insetBy(dx: -tolerance, dy: -tolerance).contains(point)
    }

    /// 诊断用：全系统级命中（遮罩没起来时才有意义）
    static func systemElement(atGlobal point: CGPoint) -> Hit? {
        guard isTrusted else { return nil }
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.25)
        guard let element = deepest(atGlobal: point, in: system) else { return nil }
        return describe(element, at: point)
    }

    /// 诊断用：全系统级命中链（遮罩没起来时才有意义）
    static func chainForSystem(atGlobal point: CGPoint) -> [String] {
        guard isTrusted else { return ["未授权"] }
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.25)
        return chain(atGlobal: point, on: system)
    }

    /// 诊断用：从"最低层命中的元素"一路往上打到根，看清 AX 到底给了什么。
    /// 高亮框跟预期不符时，"选错了层"和"AX 本身就这么给"只有打出来才分得清。
    static func chain(atGlobal point: CGPoint, in pid: pid_t) -> [String] {
        guard isTrusted, pid > 0 else { return ["未授权 / pid=0"] }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.25)
        return chain(atGlobal: point, on: app)
    }

    private static func chain(atGlobal point: CGPoint, on target: AXUIElement) -> [String] {
        var found: AXUIElement?
        guard AXUIElementCopyElementAtPosition(target, Float(point.x), Float(point.y), &found) == .success,
              let first = found else { return ["CopyElementAtPosition 失败"] }
        var lines: [String] = []
        var current: AXUIElement? = first
        var depth = 0
        while let element = current, depth < 9 {
            let role = string(of: element, kAXRoleAttribute) ?? "?"
            let rect = frame(of: element)
            let text = text(of: element)
            let sizeText = rect.map { String(format: "%.0f,%.0f %.0f×%.0f",
                                             $0.minX, $0.minY, $0.width, $0.height) } ?? "无 frame"
            lines.append("\(depth) \(role) \(sizeText) \(text.isEmpty ? "" : "「\(text)」")")
            current = parent(of: element)
            depth += 1
        }
        return lines
    }

    /// 窗口级兜底：查不到元素时，至少把整个窗口给他
    static func hit(forWindow window: ScreenWindowInfo) -> Hit {
        var label = "窗口：\(window.ownerName)"
        if let title = window.title, !title.isEmpty {
            label += " · " + (title.count > 20 ? String(title.prefix(20)) + "…" : title)
        }
        return Hit(rect: window.frame, label: label, isWindow: true)
    }

    private static func deepest(atGlobal point: CGPoint, in target: AXUIElement) -> AXUIElement? {

        var found: AXUIElement?
        guard AXUIElementCopyElementAtPosition(target, Float(point.x), Float(point.y), &found) == .success else {
            return nil
        }
        guard let element = found else { return nil }

        // 命中的可能是"一段文字里的某个字"（AXStaticText 的子节点只有几像素），
        // 往上找几层，直到够大为止 —— 用户想截的是那块控件，不是一个字。
        var current = element
        var rect = frame(of: element)
        var depth = 0
        while depth < 6, let r = rect, r.width < 12 || r.height < 12 {
            guard let up = parent(of: current) else { break }
            current = up
            rect = frame(of: up)
            depth += 1
        }
        return current
    }

    /// 把命中元素擦成人话（元素名 + 角色），顺便丢掉太小的
    private static func describe(_ element: AXUIElement, at point: CGPoint) -> Hit? {
        guard let rect = frame(of: element), rect.width >= 4, rect.height >= 4 else { return nil }
        let role = string(of: element, kAXRoleAttribute) ?? ""
        let name = text(of: element)
        return Hit(rect: rect,
                   label: name.isEmpty ? roleTitle(role) : "\(roleTitle(role))：\(name)",
                   isWindow: role == (kAXWindowRole as String))
    }

    /// 元素的全局矩形（左上原点，点）。
    static func frame(of element: AXUIElement) -> CGRect? {
        guard let origin = point(of: element, kAXPositionAttribute),
              let size = size(of: element) else { return nil }
        return CGRect(origin: origin, size: size)
    }

    // ── 纯函数：这块命中是不是"就是整个窗口" ──────────────────
    //
    // 浏览器 / Electron 应用常常不把内容暴露给 AX，`CopyElementAtPosition`
    // 只能给到"和窗口一样大的 Group"。这时按元素说话没意义（用户看到「区域」
    // 三个字），框又确实是整窗 —— 交给调用方换成窗口名。
    // 容差取 2pt：AX 给的矩形常有 ±1pt 的取整误差。
    static func coversWindow(_ rect: CGRect, windowFrame: CGRect, tolerance: CGFloat = 2) -> Bool {
        guard windowFrame.width > 0, windowFrame.height > 0 else { return false }
        return rect.width >= windowFrame.width - tolerance
            && rect.height >= windowFrame.height - tolerance
    }

    /// 纯函数：这个框是不是"粗命中" —— 大到基本等于整片窗口内容区。
    /// 网页的 AX 树是异步长出来的，刚开辅助功能时先返回整页 WebArea，
    /// 这时要再等一等重查，不能把它当成"用户想要的元素"。
    /// 阈值取窗口面积的 60%：正常控件（按钮/链接/输入框）远小于此。
    static func isCoarse(_ rect: CGRect?, windowFrame: CGRect,
                         maxAreaRatio: CGFloat = 0.6) -> Bool {
        guard let rect, windowFrame.width > 0, windowFrame.height > 0,
              rect.width > 0, rect.height > 0 else { return false }
        let windowArea = windowFrame.width * windowFrame.height
        return rect.width * rect.height / windowArea >= maxAreaRatio
    }

    // ── 纯函数：把 AX 给的矩形收成"能截的一块" ──────────────
    //
    // AX 给的框可能跑到屏幕外（元素被滚出可视区、或者窗口被移出屏幕），
    // 也可能小到 1×1（分隔线、焦点框）。这两种都不该截 —— 直接交给窗口级兜底。
    static func sanitized(_ rect: CGRect, displayBounds: CGRect, minSide: CGFloat = 6) -> CGRect? {
        guard rect.width.isFinite, rect.height.isFinite,
              rect.width > 0, rect.height > 0 else { return nil }
        let clamped = rect.intersection(displayBounds)
        guard !clamped.isNull, clamped.width >= minSide, clamped.height >= minSide else { return nil }
        return clamped.integral
    }

    // ── AX 属性读取的小工具 ─────────────────────────────────

    private static func point(of element: AXUIElement, _ attribute: String) -> CGPoint? {
        guard let value = attributeValue(element, attribute),
              CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        guard AXValueGetValue(value as! AXValue, .cgPoint, &point) else { return nil }
        return point
    }

    private static func size(of element: AXUIElement) -> CGSize? {
        guard let value = attributeValue(element, kAXSizeAttribute),
              CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var size = CGSize.zero
        guard AXValueGetValue(value as! AXValue, .cgSize, &size) else { return nil }
        return size
    }

    private static func string(of element: AXUIElement, _ attribute: String) -> String? {
        attributeValue(element, attribute) as? String
    }

    private static func attributeValue(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
            return nil
        }
        return value
    }

    private static func parent(of element: AXUIElement) -> AXUIElement? {
        guard let parent = attributeValue(element, kAXParentAttribute),
              CFGetTypeID(parent) == AXUIElementGetTypeID() else { return nil }
        return (parent as! AXUIElement)
    }

    /// 元素的名字：标题 → 描述 → 值（按钮/输入框各有一个好用的字段）
    static func text(of element: AXUIElement) -> String {
        for attribute in [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute] {
            if let text = string(of: element, attribute), !text.isEmpty {
                return text.count > 24 ? String(text.prefix(24)) + "…" : text
            }
        }
        return ""
    }

    /// AX 角色 → 人话（只翻常用的几个，其余显示原始角色名）
    static func roleTitle(_ role: String) -> String {
        switch role {
        case kAXWindowRole as String:        return "窗口"
        case kAXButtonRole as String:        return "按钮"
        case kAXTextFieldRole as String:     return "输入框"
        case kAXTextAreaRole as String:      return "文本区"
        case kAXStaticTextRole as String:    return "文字"
        case kAXImageRole as String:         return "图片"
        case "AXLink":                       return "链接"
        case kAXCheckBoxRole as String:      return "复选框"
        case kAXRadioButtonRole as String:   return "单选"
        case kAXPopUpButtonRole as String:   return "下拉"
        case kAXMenuItemRole as String:      return "菜单项"
        case kAXListRole as String:          return "列表"
        case kAXRowRole as String:           return "列表行"
        case kAXGroupRole as String:         return "区域"
        case kAXToolbarRole as String:       return "工具条"
        case kAXTabGroupRole as String:      return "标签页"
        case kAXScrollAreaRole as String:    return "滚动区"
        case kAXTableRole as String:         return "表格"
        case kAXOutlineRole as String:       return "大纲"
        case "AXWebArea":                    return "网页"
        case "AXHeading":                    return "标题"
        default:                             return role.isEmpty ? "元素" : role
        }
    }
}
