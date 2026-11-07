import AppKit

// ============================================================
// 区域选择遮罩
//
// 全屏透明窗口盖住鼠标所在的那块屏幕：
//   · 半透明暗幕，拖拽出选区后选区外保持暗、选区内透亮
//   · 移动鼠标时高亮所在窗口（CGWindowList 几何命中，智能识别窗口）
//   · 轻点（不拖）= 选中高亮窗口；拖拽 = 自定义区域
//   · Esc / 右键 = 强制结束整个截图流程（不截图、不弹窗）
//
// 关于 Esc 的反复：1.0.6 是"Esc 退出"，1.0.7 因为怕误触改成"只撤选区"，
// 1.0.9 用户明确要求"全局按 Esc 强制结束截屏"，于是恢复成一次到底。
// 两次右键/Esc 都保留 —— 出口多一个总比被困住好，画面上也一直有提示。
//
// 为什么盖单屏不盖全部屏：1.0.0 先把单屏做到稳；跨屏拼接留给后续版本。
// 为什么要独立 NSWindow 而不是 NSOverlayContentView：窗口级别用
// .screenSaver，保证盖在所有普通窗口（包括贴图）之上。
// ============================================================

@MainActor
protocol RegionSelectionDelegate: AnyObject {    /// 用户确认了区域（rect 为显示器局部坐标，点单位）
    func regionSelector(_ selector: RegionSelector, didConfirmRegion rect: CGRect, displayID: CGDirectDisplayID)
    /// 用户轻点选中了一个窗口
    func regionSelector(_ selector: RegionSelector, didConfirmWindow window: ScreenWindowInfo, displayID: CGDirectDisplayID)
    /// 用户按 Esc 取消
    func regionSelectorDidCancel(_ selector: RegionSelector)
}

final class RegionSelector: NSObject {

    weak var delegate: (RegionSelectionDelegate & AnyObject)?

    private var window: NSWindow?
    private var overlayView: OverlayView?
    private var displayID: CGDirectDisplayID = 0
    /// Esc 的兜底监听：面板万一没拿到 key window（无边框窗口的老毛病），
    /// 按键事件还是本应用收到的，本地监听能先一步接住。
    private var escMonitor: Any?
    private(set) var isActive = false
    /// 诊断用（--wintest 伪造窗口确认时要带 displayID）
    var currentDisplayID: CGDirectDisplayID { displayID }
    /// 诊断用：等价于"用户确认后收起遮罩"（finish 是 fileprivate）
    /// 默认**保住底图**：诊断走的是"窗口已关闭"兜底路径，底图被清了就裁不出东西。
    func finishForDiagnostics(keepBackdrop: Bool = true) { finish(keepBackdrop: keepBackdrop) }

    /// 诊断用：元素模式下当前高亮的是什么
    var elementPickReport: String { overlayView?.elementPickReport ?? "遮罩未开" }
    /// 诊断用：绕过事件层直接查一次元素
    func probeElementForDiagnostics(atGlobal p: CGPoint) {
        overlayView?.probeElementForDiagnostics(atGlobal: p)
    }

    /// 放大镜设置快照（nil / enabled=false 就不抓底图、也不画）
    private var loupeConfig: Loupe.Config?
    /// 整屏原图（**没有遮罩**的那一份），放大镜从它里面取像素
    private var sourceImage: CGImage?
    private var pixelScale: CGFloat = 2
    /// 智能元素截取模式（抓底图的 Task 是异步的，参数得先存下来再传给视图）
    private var pendingElementPick = false
    /// 元素模式下要挂在空态提示里的一句话（例如"未授权辅助功能，已退化为窗口级"）
    private var pendingElementNote: String?

    /// 🔴 顺序：**先抓底图，再上遮罩**。
    /// 反过来（先 show 再抓）抓到的是"已经被自己压暗 28%"的画面，放大镜里的
    /// 色值会整体偏暗、拿去做设计全是错的。代价是遮罩晚 ~100ms 出现。
    /// - Parameter needBackdrop: 即使不开放大镜也要抓底图（窗口点选模式要它兜底，
    ///   见 `cropBackdrop`）
    /// - Parameter elementPick: 智能元素截取模式（光标一动就命中 AX 元素并高亮，
    ///   单击即确认）。它和窗口点选互斥使用，但**拖动拉框仍然有效** ——
    ///   用户在这个模式下想自己框一块时不该被挡住。
    func begin(highlightWindows: Bool, crosshair: Bool, loupe: Loupe.Config?,
               needBackdrop: Bool = false, elementPick: Bool = false,
               elementNote: String? = nil) {
        guard !isActive else { return }
        guard window == nil else { return }

        let screen = ScreenCapture.activeScreen()
        displayID = ScreenCapture.display(for: screen)
        loupeConfig = loupe
        self.pendingElementPick = elementPick
        self.pendingElementNote = elementNote
        // 先占住 isActive：抓图期间再按一次热键不该叠出第二个遮罩
        isActive = true

        Task { @MainActor in
            var image: CGImage?
            if loupe?.enabled == true || needBackdrop {
                let started = Date()
                image = try? await ScreenCapture.captureDisplay(self.displayID)
                // 这张图两个用途：放大镜取像素 / 窗口截图的兜底裁剪
                NSLog("[BoxShot] 选区底图 %.0fms %@",
                      Date().timeIntervalSince(started) * 1000,
                      image == nil ? "失败" : "\(image!.width)×\(image!.height)")
            }
            // 抓图期间用户按了 Esc / 换了动作 → 直接放弃这次展示
            guard self.isActive, self.window == nil else { return }
            self.present(screen: screen,
                         highlightWindows: highlightWindows,
                         crosshair: crosshair,
                         image: image,
                         elementPick: self.pendingElementPick,
                         elementNote: self.pendingElementNote)
        }
    }

    private func present(screen: NSScreen,
                         highlightWindows: Bool,
                         crosshair: Bool,
                         image: CGImage?,
                         elementPick: Bool = false,
                         elementNote: String? = nil) {
        sourceImage = image
        pixelScale = image.map { CGFloat($0.width) / max(1, screen.frame.width) }
            ?? ScreenCapture.scaleFactor(for: displayID)

        let panel = KeyableWindow(contentRect: screen.frame,
                             styleMask: [.borderless],
                             backing: .buffered,
                             defer: false,
                             screen: screen)
        panel.level = .screenSaver
        // 遮罩窗口铺满整屏，它的 CA backing store 是**按窗口的色彩空间定格式**的：
        // 不指定时系统按显示器走广色域 16 位（实测 `vmmap` 里是
        // `3420x2214 (RGhA) 57.8M 'CA Whippet Drawable'`），一成 8 位就只要一半。
        // 截图本身是 sRGB 8 位的像素，画进去不会丢信息；标注颜色也都是 sRGB 定义的。
        panel.colorSpace = .sRGB
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = false
        panel.acceptsMouseMovedEvents = true
        // 程序化窗口默认 close() 会自我释放，和 ARC 抢着放 → 随机闪退
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let view = OverlayView(frame: NSRect(origin: .zero, size: screen.frame.size))
        view.selector = self
        view.highlightWindows = highlightWindows
        view.elementPick = elementPick
        view.elementNote = elementNote
        view.showCrosshair = crosshair
        view.loupeConfig = loupeConfig
        view.sourceImage = sourceImage
        view.pixelScale = pixelScale
        // 遮罩窗口铺满整块屏幕；视图 isFlipped（左上原点），和 CGWindowList /
        // SCStreamConfiguration 的"左上原点向下"坐标系一致。
        // globalOrigin 用 CGDisplayBounds（左上原点）而不是 screen.frame（左下原点）。
        view.globalOrigin = ScreenCapture.displayBoundsGlobal(ScreenCapture.display(for: screen)).origin
        panel.contentView = view
        // 键盘（回车确认 / 方向键微调 / Esc）要靠 first responder 才收得到，
        // 别指望"窗口一变 key 就会自动指向内容视图"
        panel.makeFirstResponder(view)

        // 光标位置先喂给放大镜：不喂的话用户不动鼠标就什么都看不到，
        // 会以为「放大镜没做」。NSEvent.mouseLocation 是全局左下原点，
        // 视图是"屏幕内左上原点"，所以 x 减屏左边、y 用屏顶减。
        let mouse = NSEvent.mouseLocation
        view.primeCursor(CGPoint(x: mouse.x - screen.frame.minX,
                                 y: screen.frame.maxY - mouse.y))

        window = panel
        overlayView = view
        isActive = true
        // 🔴 顺序不能反：**先激活应用，再让窗口成为 key**。
        // 反过来写（先 makeKeyAndOrderFront 再 activate）在本应用还没 active 时，
        // AppKit 会把 "become key" 推后到激活之后才做，中间那段时间窗口是
        // "看得见但收不到键盘"——表现就是"按 Esc 没反应"，而这恰好是最难靠
        // 读代码发现的（代码里明明写了两句）。再补一次 makeKey() 兜底。
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        panel.makeKey()
        view.warmUpWindowList()
        installEscMonitor()
    }

    /// 🔴 双保险。第一条路是让面板真的成为 key window（KeyableWindow），
    /// keyDown 直接进视图；第二条路就是这个本地监听 —— 就算窗口因为系统原因
    /// 没拿到焦点，只要应用在收键盘事件，Esc 一样能结束截图。
    /// 用户反馈"全局按 Esc 强制结束截屏没生效"就是因为以前只有第一条路，
    /// 而它从来没通。
    private func installEscMonitor() {
        escMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.isActive, event.keyCode == 53 else { return event }
            self.cancel()
            return nil
        }
    }

    func cancel() {
        guard isActive else { return }
        finish()
        MainActor.assumeIsolated { delegate?.regionSelectorDidCancel(self) }
    }

    /// - Parameter keepBackdrop: 窗口点选那条路要**留着整屏底图** ——
    ///   它要在 SCK 查不到窗口之后按框裁一块兜底。其余路径（拖框确认 / Esc 取消）
    ///   一旦收起遮罩就再也用不到它了，当场放掉。
    ///
    ///   🔴 为什么值得单独放：底图是整屏原图（2880×1864×4 ≈ 20.5MB）。
    ///   拖框确认之后马上要抓一张同尺寸的成图，两张会短暂叠在一起；
    ///   取消更是彻底用不上。早点放掉能把这条路径的峰值削掉一块。
    fileprivate func finish(keepBackdrop: Bool = false) {
        isActive = false
        if !keepBackdrop {
            sourceImage = nil
            overlayView?.sourceImage = nil
        }
        if let escMonitor { NSEvent.removeMonitor(escMonitor) }
        escMonitor = nil
        let view = overlayView
        let panel = window
        overlayView = nil
        window = nil
        view?.stopTracking()
        panel?.orderOut(nil)
        // 🔴 别在这里就把最后两个强引用放掉。finish() 绝大多数时候是在
        // OverlayView 自己的 mouseUp / keyDown 里被调进来的：View 和 Window
        // 当场析构，我们自己的方法还在栈上继续跑（mouseUp 末尾还要写
        // dragStart = nil），等于是 use-after-free。崩溃栈长这样：
        //   objc_release ← __RELEASE_OBJECTS_IN_THE_ARRAY__ ← -[__NSArrayM dealloc]
        //    ← objc_autoreleasePoolPop ← -[NSApplication run]
        // 所以推迟到下一轮 runloop 再释放，那时 AppKit 已经从事件里退出来了。
        DispatchQueue.main.async {
            // 🔴 **光 orderOut 不够，必须 close()**。orderOut 只是"不显示"，
            // 窗口还登记在 NSApp.windows 上，它那层铺满整屏的 CA drawable 也一直挂着：
            // `vmmap` 里看得见 —— `SurfaceID: 0xe8  3420x2214 (RGhA) 57.8M
            // 'CA Whippet Drawable'`。用户看到的现象就是「截完图、浮层都关掉了，
            // 活动监视器里还常驻 ~98MB」（2026-11-07 反馈，1.0.34/1.0.35 都一样）。
            // close() 让 AppKit 把窗口摘掉、把那层 surface 还给系统。
            // 注意窗口建的时候 `isReleasedWhenClosed = false`，所以 close() 不会
            // 跟我们抢着释放，真正的 dealloc 还是下一行的作用域结束。
            panel?.close()
            _ = view
            _ = panel
        }
    }

    /// 按"全局左上原点"的矩形，从**遮罩出现之前**抓的那张整屏底图里裁一块。
    ///
    /// 用在窗口截图的兜底：Edge「扫描 QR 码」这类瞬态弹窗在应用失焦时会自己关掉，
    /// 我们的全屏遮罩一 `NSApp.activate` 它可能就没了 —— 这时按 windowID 去
    /// `SCShareableContent` 查是查不到的（报「目标窗口已关闭或不可截取」）。
    /// 底图是遮罩出现前抓的，那一刻窗口还在，裁出来正好是用户点选时看到的画面。
    func cropBackdrop(globalRect: CGRect) -> CGImage? {
        guard let image = sourceImage else { return nil }
        let displayOrigin = ScreenCapture.displayBoundsGlobal(displayID).origin
        let rect = CGRect(x: (globalRect.minX - displayOrigin.x) * pixelScale,
                          y: (globalRect.minY - displayOrigin.y) * pixelScale,
                          width: globalRect.width * pixelScale,
                          height: globalRect.height * pixelScale).integral
        let clamped = rect.intersection(CGRect(x: 0, y: 0,
                                               width: CGFloat(image.width),
                                               height: CGFloat(image.height)))
        guard clamped.width >= 8, clamped.height >= 8 else { return nil }
        return image.cropping(to: clamped)
    }

    // ── 遮罩视图 ─────────────────────────────────────────────

    final class OverlayView: NSView {

        var selector: RegionSelector?
        var highlightWindows = true
        /// 智能元素截取模式：光标一动就查 AX 元素并高亮，单击即确认
        var elementPick = false
        /// 空态提示里追加的一句话（nil = 不加）
        var elementNote: String?
        private var hoveredElement: ElementProbe.Hit?
        /// AX 查询有成本（跨进程），鼠标高频移动时按 40ms 节流 —— 不节流会在
        /// 快速划过一屏时把主线程排满，遮罩跟着一顿一顿的
        private var lastElementProbe: TimeInterval = 0
        /// 当前这个 pid 是否已经排过一次"粗命中补查"（避免每帧都排）
        private var coarseProbePID: pid_t = 0
        private var coarseProbeScheduled = false
        var showCrosshair = true
        /// 放大镜设置（nil = 不画）
        var loupeConfig: Loupe.Config?
        /// 整屏原图（无遮罩），放大镜取像素用
        var sourceImage: CGImage?
        /// 1 点对应多少源像素
        var pixelScale: CGFloat = 2
        /// 复制色值后的临时提示
        private var copiedHint: String?
        private var hintSeq = 0
        /// 鼠标是否已经进过这块屏幕（没进过就别画放大镜，否则左上角先冒一个 0,0 的镜）
        private var hasCursor = false

        /// 刚上遮罩时把放大镜直接摆到当前光标处：用户不动鼠标也该看得见
        /// （只认落在本屏内的点，鼠标在副屏时不画）
        func primeCursor(_ point: CGPoint) {
            guard bounds.contains(point) else { return }
            cursorPoint = point
            hasCursor = true
        }

        /// 本窗口左上角在"全局（左上原点）坐标系"里的位置
        var globalOrigin: CGPoint = .zero

        private var dragStart: CGPoint?
        private var dragCurrent: CGPoint?
        private var isDragging = false
        private var highlightedWindow: ScreenWindowInfo?
        private var windows: [ScreenWindowInfo] = []

        // ── 选区调整阶段（1.0.4：手柄拖拽 / 方向键微调 / Shift 约束）──
        enum Phase { case idle, dragging, adjusting, movingSelection, resizing }
        enum Handle: CaseIterable {
            case topLeft, top, topRight, left, right, bottomLeft, bottom, bottomRight
            func point(in rect: CGRect) -> CGPoint {
                switch self {
                case .topLeft:     return CGPoint(x: rect.minX, y: rect.minY)
                case .top:         return CGPoint(x: rect.midX, y: rect.minY)
                case .topRight:    return CGPoint(x: rect.maxX, y: rect.minY)
                case .left:        return CGPoint(x: rect.minX, y: rect.midY)
                case .right:       return CGPoint(x: rect.maxX, y: rect.midY)
                case .bottomLeft:  return CGPoint(x: rect.minX, y: rect.maxY)
                case .bottom:      return CGPoint(x: rect.midX, y: rect.maxY)
                case .bottomRight: return CGPoint(x: rect.maxX, y: rect.maxY)
                }
            }
        }
        private var phase: Phase = .idle
        private var selection: CGRect?
        private var activeHandle: Handle?
        private var resizeOrigin: CGRect?
        private var resizeStart: CGPoint?
        private var moveOrigin: CGRect?
        private var moveStart: CGPoint?

        /// 视图坐标 → 全局坐标（左上原点）
        private func toGlobal(_ p: CGPoint) -> CGPoint {
            CGPoint(x: p.x + globalOrigin.x, y: p.y + globalOrigin.y)
        }

        func warmUpWindowList() {
            windows = ScreenCapture.onScreenWindows()
        }

        func stopTracking() {
            // 摘掉本地事件监听（如果有）
        }

        override var acceptsFirstResponder: Bool { true }
        override var isFlipped: Bool { true }

        private var cursorPoint: CGPoint = .zero
        /// 放大镜上一次的矩形：局部重绘要把它和新位置一起抹掉
        private var lastLoupeRect: CGRect = .zero

        /// 视图坐标 → 全局坐标（左上原点）。globalOrigin 已是 CGDisplayBounds.origin，
        /// 所以全局-显示局部 = 视图坐标本身。

        override func mouseDown(with event: NSEvent) {
            let p = convert(event.locationInWindow, from: nil)

            // 调整阶段：手柄缩放 / 选区内拖动移动 / 点外面重新框选
            if phase == .adjusting, let sel = selection {
                if let handle = handleHit(at: p, in: sel) {
                    phase = .resizing
                    activeHandle = handle
                    resizeOrigin = sel
                    resizeStart = p
                    return
                }
                if sel.insetBy(dx: -1, dy: -1).contains(p) {
                    phase = .movingSelection
                    moveOrigin = sel
                    moveStart = p
                    return
                }
                selection = nil
            }

            phase = .dragging
            dragStart = p
            dragCurrent = p
            isDragging = false
            highlightedWindow = nil
            needsDisplay = true
        }

        override func mouseDragged(with event: NSEvent) {
            let p = convert(event.locationInWindow, from: nil)
            cursorPoint = p
            hasCursor = true

            switch phase {
            case .resizing:
                guard let origin = resizeOrigin, let handle = activeHandle, let start = resizeStart else { return }
                selection = resized(origin, handle: handle, delta: CGPoint(x: p.x - start.x, y: p.y - start.y),
                                    square: event.modifierFlags.contains(.shift))
                needsDisplay = true
            case .movingSelection:
                guard let origin = moveOrigin, let start = moveStart else { return }
                var rect = origin.offsetBy(dx: p.x - start.x, dy: p.y - start.y)
                // 不越出屏幕
                rect.origin.x = min(max(0, rect.origin.x), bounds.width - rect.width)
                rect.origin.y = min(max(0, rect.origin.y), bounds.height - rect.height)
                selection = rect
                needsDisplay = true
            default:
                guard let start = dragStart else { return }
                if !isDragging && hypot(p.x - start.x, p.y - start.y) > 4 { isDragging = true }
                dragCurrent = p
                needsDisplay = true
            }
        }

        override func mouseUp(with event: NSEvent) {
            let p = convert(event.locationInWindow, from: nil)
            switch phase {
            case .resizing:
                phase = .adjusting
                activeHandle = nil
                resizeOrigin = nil
                resizeStart = nil
                needsDisplay = true
                return
            case .movingSelection:
                // 🔴 选区内**单击**（没有拖动）= 确认开始截图。
                // 以前要双击，用户明确说不要双击 —— 单击最顺手，而且拖动手柄 /
                // 拖动选区都还能用（只有位移 ≤2pt 才算单击）。
                let start = moveStart ?? p
                let sel = selection
                phase = .adjusting
                moveOrigin = nil
                moveStart = nil
                needsDisplay = true
                if Self.isTap(from: start, to: p), let sel { confirm(rect: sel) }
                return
            default:
                break
            }

            guard let start = dragStart else { return }
            if isDragging {
                let rect = normalizedRect(start, dragCurrent ?? p)
                if rect.width >= 8 && rect.height >= 8 {
                    // 松开鼠标 = 立刻截（1.0.10 用户要求去掉"单击选区内 / 回车开始"
                    // 这一步确认）。框能调大小这件事已经搬到截完的浮层里做，
                    // 选区阶段不再需要"调整态"。
                    confirm(rect: rect)
                    dragStart = nil
                    dragCurrent = nil
                    isDragging = false
                    return
                } else {
                    needsDisplay = true // 太小视为误触，留在选区模式
                }
            } else {
                // 轻点：元素模式下截"光标下那个元素"；否则选中高亮窗口
                if elementPick {
                    // 按点击点重查一次：手快时高亮可能还停在上一帧的元素上
                    probeElement(at: toGlobal(p), force: true)
                }
                if elementPick, let element = hoveredElement,
                   let clamped = ElementProbe.sanitized(element.rect,
                                                        displayBounds: displayGlobalBounds) {
                    confirm(rect: clamped.offsetBy(dx: -globalOrigin.x, dy: -globalOrigin.y))
                } else if highlightWindows, let hit = topLevelWindow(at: toGlobal(p)) {
                    let selectorRef = selector
                    let displayID = self.displayID
                    MainActor.assumeIsolated {
                        selectorRef?.finish(keepBackdrop: true)
                        selectorRef?.delegate?.regionSelector(selectorRef!, didConfirmWindow: hit, displayID: displayID)
                    }
                }
            }
            dragStart = nil
            dragCurrent = nil
            isDragging = false
        }

        /// 右键 = 主动取消（于是 Esc 可以从"退出流程"这个职责上退下来）
        override func rightMouseDown(with event: NSEvent) {
            let selectorRef = selector
            MainActor.assumeIsolated {
                selectorRef?.cancel()
            }
        }

        /// 确认选区（视图坐标 = 显示器局部坐标）
        private func confirm(rect: CGRect) {
            guard rect.width >= 8, rect.height >= 8 else { return }
            let selectorRef = selector
            let displayID = self.displayID
            MainActor.assumeIsolated {
                // 拖框确认走的是"重新抓这一块"，底图用不上了：当场放掉 20.5MB，
                // 别让它跟紧接着的成图抓取叠在一起。
                selectorRef?.finish(keepBackdrop: false)
                selectorRef?.delegate?.regionSelector(selectorRef!, didConfirmRegion: rect, displayID: displayID)
            }
        }

        /// 选区内"单击"（没拖动）的判定：位移 ≤ 2pt 就算单击 = 确认开始截图。
        /// 抽成静态函数是为了 --selftest 能测 —— 这条阈值同时决定了
        /// "点一下就截"和"拖一下只是挪选区"，弄错任何一个都很难受。
        static func isTap(from start: CGPoint, to end: CGPoint) -> Bool {
            hypot(end.x - start.x, end.y - start.y) <= 2
        }

        private func handleHit(at p: CGPoint, in rect: CGRect) -> Handle? {
            let tolerance: CGFloat = 9
            return Handle.allCases.first { handle in
                let hp = handle.point(in: rect)
                return abs(p.x - hp.x) <= tolerance && abs(p.y - hp.y) <= tolerance
            }
        }

        /// 按手柄 + 位移算新选区；Shift 时角手柄保持正方形
        private func resized(_ origin: CGRect, handle: Handle, delta: CGPoint, square: Bool) -> CGRect {
            var minX = origin.minX, maxX = origin.maxX
            var minY = origin.minY, maxY = origin.maxY
            switch handle {
            case .topLeft:     minX += delta.x; minY += delta.y
            case .top:         minY += delta.y
            case .topRight:    maxX += delta.x; minY += delta.y
            case .left:        minX += delta.x
            case .right:       maxX += delta.x
            case .bottomLeft:  minX += delta.x; maxY += delta.y
            case .bottom:      maxY += delta.y
            case .bottomRight: maxX += delta.x; maxY += delta.y
            }
            var rect = CGRect(x: min(minX, maxX), y: min(minY, maxY),
                              width: abs(maxX - minX), height: abs(maxY - minY))
            if square, rect.width > 0, rect.height > 0 {
                // 角手柄：取较大边做成正方形；边中点手柄：另一边跟随
                let side = max(rect.width, rect.height)
                switch handle {
                case .topLeft, .topRight, .bottomLeft, .bottomRight:
                    let anchorX = (handle == .topLeft || handle == .bottomLeft) ? rect.maxX : rect.minX
                    let anchorY = (handle == .topLeft || handle == .topRight) ? rect.maxY : rect.minY
                    rect = CGRect(x: (handle == .topLeft || handle == .bottomLeft) ? anchorX - side : anchorX,
                                  y: (handle == .topLeft || handle == .topRight) ? anchorY - side : anchorY,
                                  width: side, height: side)
                default:
                    rect.size.height = rect.width
                }
            }
            rect.origin.x = min(max(0, rect.origin.x), max(0, bounds.width - max(8, rect.width)))
            rect.origin.y = min(max(0, rect.origin.y), max(0, bounds.height - max(8, rect.height)))
            return CGRect(x: rect.minX, y: rect.minY,
                          width: max(8, rect.width), height: max(8, rect.height))
        }

        private var displayID: CGDirectDisplayID {
            selector?.displayID ?? 0
        }

        /// 这块屏幕的全局矩形（左上原点）。AX 给的矩形也是全局的，
        /// 要先按它夹一次，再换成视图坐标。
        private var displayGlobalBounds: CGRect {
            CGRect(origin: globalOrigin, size: bounds.size)
        }

        /// 诊断用：当前高亮的是什么。合成鼠标事件能不能真的驱动 AX 探测，
        /// 只有把这个字符串打出来才知道。
        var elementPickReport: String {
            guard elementPick else { return "非元素模式" }
            guard let e = hoveredElement else { return "未命中" }
            return "\(e.isWindow ? "窗口级" : "元素级")「\(e.label)」"
                + String(format: " 框=%.0f,%.0f %.0f×%.0f",
                         e.rect.minX, e.rect.minY, e.rect.width, e.rect.height)
        }

        /// 诊断用：绕过事件层直接查一次（用来区分"事件没送到"和"AX 查不到"）
        func probeElementForDiagnostics(atGlobal p: CGPoint) {
            lastElementProbe = 0
            probeElement(at: p)
        }

        /// 查光标底下的元素。查不到（未授权 / 桌面空白）就清空 ——
        /// 这时画面不画高亮，但拖动拉框照样能用。
        /// - Parameter force: 跳过 40ms 节流（单击确认时用：手快的时候
        ///   高亮框可能还停在上一帧的元素上，按点击点重查一次才不会截错）
        private func probeElement(at global: CGPoint, force: Bool = false) {
            let now = Date().timeIntervalSince1970
            guard force || now - lastElementProbe >= 0.04 else { return }
            lastElementProbe = now

            // 先找"光标下最上层的普通窗口"（窗口列表里没有我们自己的遮罩：
            // 它 layer=screenSaver，不是 0），再只在这个应用里查元素。
            // 查不到元素就退到窗口级 —— 用户至少能截到那个窗口。
            guard let window = topLevelWindow(at: global) else {
                if hoveredElement != nil {
                    hoveredElement = nil
                    needsDisplay = true
                }
                return
            }
            let pid = window.ownerPID ?? 0
            // 传窗口框进去：命中"粗到像整块区域"时，ElementProbe 会自己下钻找更小的节点
            var hit = ElementProbe.element(atGlobal: global, in: pid, windowFrame: window.frame)
                ?? ElementProbe.hit(forWindow: window)
            // 浏览器这类应用（不把网页内容暴露给 AX 时）只肯给到"和窗口一样大的 Group"，
            // 打出来是「区域」，用户根本不知道截的是什么。框既然就是整个窗口，
            // 就把名字换成窗口名 —— 框不变，只是把话说清楚。
            let frame = ElementProbe.sanitized(hit.rect, displayBounds: displayGlobalBounds)
            let coversAll = frame.map { ElementProbe.coversWindow($0, windowFrame: window.frame) } ?? true
            if !hit.isWindow, coversAll {
                hit = ElementProbe.hit(forWindow: window)
            }
            // 🔴 **网页的 AX 树是"长"出来的**：Chromium 收到"打开辅助功能"后先给一个
            // 整页 WebArea，过一两秒才把 DOM 铺满。所以"粗命中"要再补查两次，
            // 不能只认第一帧 —— 用户看到的会一直是"整个网页 / 整个窗口"，
            // 而智能元素截取主要就是给网页用的。
            let coarse = coversAll || ElementProbe.isCoarse(frame, windowFrame: window.frame)
            if coarse {
                if coarseProbePID != pid {
                    coarseProbePID = pid
                    coarseProbeScheduled = false
                }
                if !coarseProbeScheduled {
                    coarseProbeScheduled = true
                    // 顺带把网页辅助功能打开（幂等 + 自带 15 秒节流）
                    ElementProbe.enableDeepAccess(pid)
                    scheduleDeepAccessReprobe(at: global, pid: pid)
                }
            } else {
                // 拿到真正的元素了 → 这个窗口下次再粗起来可以重新排补查
                coarseProbePID = 0
                coarseProbeScheduled = false
            }
            guard hit != hoveredElement else { return }
            hoveredElement = hit
            needsDisplay = true
        }

        /// 刚给目标应用打开"网页辅助功能"后，它会**异步**把 DOM 铺成 AX 元素树
        /// （Chromium 大页面实测 0.3~1 秒）。这期间光标可能一动不动，
        /// 光靠 mouseMoved 触发是等不到的 → 自己按两档延时补查。
        private func scheduleDeepAccessReprobe(at global: CGPoint, pid: pid_t) {
            for delay in [0.35, 0.9, 1.8] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    guard let self, self.elementPick, self.selection == nil, !self.isDragging else { return }
                    guard let window = self.topLevelWindow(at: global),
                          (window.ownerPID ?? 0) == pid else { return }
                    self.lastElementProbe = 0
                    self.probeElement(at: global)
                    // 仍只有整窗就先续着画整窗，用户继续动鼠标还会再查
                    if let hovered = self.hoveredElement, !hovered.isWindow {
                        self.needsDisplay = true
                    }
                }
            }
        }

        override func mouseMoved(with event: NSEvent) {
            let p = convert(event.locationInWindow, from: nil)
            cursorPoint = p
            hasCursor = true
            // 有选区/正在拖拽时不抢高亮（避免视觉干扰）
            if elementPick, selection == nil, !isDragging {
                probeElement(at: toGlobal(p))
            } else if highlightWindows, selection == nil, !isDragging {
                let hit = topLevelWindow(at: toGlobal(p))
                if hit?.windowID != highlightedWindow?.windowID {
                    highlightedWindow = hit
                    needsDisplay = true
                }
            }
            if let config = loupeConfig, config.enabled, !showCrosshair {
                // 🔴 只重绘放大镜自己那块（旧位置 ∪ 新位置）。
                // 以前光标一动就 `needsDisplay = true` 整屏重画 —— 5K 下一次
                // 750 万像素，光标悬停就能吃满一核。十字线要跨全屏没法局部化，
                // 那条路只能保持整屏；只开放大镜时走这条窄路。
                let newRect = loupeFrame(at: p)
                setNeedsDisplay(lastLoupeRect.union(newRect).insetBy(dx: -8, dy: -8))
                lastLoupeRect = newRect
            } else if showCrosshair || loupeConfig?.enabled == true {
                // 放大镜必须跟着光标走：不重绘它就会钉在第一次出现的位置
                needsDisplay = true
            }
        }

        /// 放大镜的屏幕矩形（局部重绘用）
        private func loupeFrame(at p: CGPoint) -> CGRect {
            CGRect(origin: Loupe.origin(cursor: p, size: Loupe.size, bounds: bounds),
                   size: Loupe.size)
        }

        override func keyDown(with event: NSEvent) {
            let step: CGFloat = event.modifierFlags.contains(.shift) ? 10 : 1
            switch event.keyCode {
            case 53: // Esc：强制结束整个截图流程（用户 1.0.9 要求）
                // 历史：1.0.6 是"Esc 直接退出"，1.0.7 改成"只撤选区不退流程"，
                // 用户明确反馈"全局按 Esc 强制结束截屏没生效"，所以恢复成一次到底。
                // 注意 Esc 是主动取消：这里**不截图、不弹窗**，直接收起遮罩回 idle。
                let selectorRef = selector
                MainActor.assumeIsolated { selectorRef?.cancel() }
            case 36: // Return：确认选区（没有选区时确认高亮窗口）
                if let sel = selection {
                    confirm(rect: sel)
                } else if let win = highlightedWindow {
                    let selectorRef = selector
                    let displayID = self.displayID
                    MainActor.assumeIsolated {
                        selectorRef?.finish(keepBackdrop: true)
                        selectorRef?.delegate?.regionSelector(selectorRef!, didConfirmWindow: win, displayID: displayID)
                    }
                }
            case 8: // C：把光标下的色值复制到剪贴板（用户样张要求）
                // keyCode 8 就是 C（大小写同码位），加 Shift 也走这里
                guard hasCursor, let source = sourceImage,
                      let config = loupeConfig, config.enabled else {
                    super.keyDown(with: event)
                    return
                }
                let cursorPixel = CGPoint(x: (cursorPoint.x * pixelScale).rounded(.down),
                                          y: (cursorPoint.y * pixelScale).rounded(.down))
                let color = Loupe.sampleColor(in: source, pixel: cursorPixel)
                let text = Loupe.copyable(color, format: config.format,
                                          hashPrefix: config.hashPrefix)
                Support.copyTextToClipboard(text)
                showCopiedHint("已复制 \(text)")
            case 123, 124, 125, 126: // 方向键微调（Shift ×10）
                guard let sel = selection else { return }
                var rect = sel
                switch event.keyCode {
                case 123: rect.origin.x -= step
                case 124: rect.origin.x += step
                case 125: rect.origin.y += step
                default:  rect.origin.y -= step
                }
                rect.origin.x = min(max(0, rect.origin.x), bounds.width - rect.width)
                rect.origin.y = min(max(0, rect.origin.y), bounds.height - rect.height)
                selection = rect
                needsDisplay = true
            default:
                super.keyDown(with: event)
            }
        }

        private func topLevelWindow(at globalPoint: CGPoint) -> ScreenWindowInfo? {
            windows.first { $0.frame.contains(globalPoint) }
        }

        private func normalizedRect(_ a: CGPoint, _ b: CGPoint) -> CGRect {
            CGRect(x: min(a.x, b.x), y: min(a.y, b.y),
                   width: abs(a.x - b.x), height: abs(a.y - b.y))
        }

        // ── 绘制 ────────────────────────────────────────────

        override func draw(_ dirtyRect: NSRect) {
            guard let ctx = NSGraphicsContext.current?.cgContext else { return }
            // 主体（暗幕 / 选区 / 标签 / 手柄）先画，放大镜和提示最后叠在最上层
            drawContents(ctx)
            drawLoupe(ctx)
            drawCopiedHint(ctx)
        }

        private func drawContents(_ ctx: CGContext) {
            // 暗幕
            ctx.setFillColor(NSColor.black.withAlphaComponent(0.28).cgColor)
            ctx.fill(bounds)

            let selectionRect: CGRect?
            if phase == .dragging, let start = dragStart, let current = dragCurrent {
                selectionRect = constrainedRect(start, current)
            } else if let sel = selection {
                selectionRect = sel
            } else if elementPick, let element = hoveredElement {
                // 智能元素：AX 给的也是全局左上原点，换成视图坐标
                selectionRect = element.rect.offsetBy(dx: -globalOrigin.x, dy: -globalOrigin.y)
            } else if highlightWindows, let win = highlightedWindow {
                // 高亮窗口：全局 → 视图坐标
                selectionRect = win.frame.offsetBy(dx: -globalOrigin.x, dy: -globalOrigin.y)
            } else {
                selectionRect = nil
            }

            guard let rect = selectionRect else {
                drawCrosshair(ctx)
                // 冷启动时屏幕上只有一个暗幕，没有任何提示会让人以为卡住了。
                // 元素模式的光标常常正停在桌面空白上，一句"拖动框选"会让人以为模式不对。
                let base = elementPick
                    ? "移到要截的元素上 · 单击截取 · 也能拖框 · Esc 或右键取消"
                    : "拖动框选区域 · 松手即截图 · Esc 或右键取消"
                drawCenteredHint(elementNote.map { "\($0) · \(base)" } ?? base, ctx: ctx)
                return
            }

            // 挖亮选区：先抠洞再画边框
            ctx.saveGState()
            ctx.setBlendMode(.clear)
            ctx.fill(rect)
            ctx.restoreGState()

            ctx.setStrokeColor(NSColor.controlAccentColor.cgColor)
            ctx.setLineWidth(2)
            ctx.stroke(rect)

            // 尺寸标签 + 操作提示（1.0.10：拖完松手就截，没有"调整态"了）
            let label = "\(Int(rect.width)) × \(Int(rect.height))"
            if phase == .dragging {
                drawHint("\(label)   ·   松手即截图   ·   Esc / 右键取消", above: rect, ctx: ctx)
            } else if elementPick, let element = hoveredElement {
                // 元素名要跟着走：用户得先确认"框住的是我要的那个按钮"
                drawHint("\(label)   ·   单击截取「\(element.label)」   ·   Esc / 右键取消",
                         above: rect, ctx: ctx)
            } else {
                drawLabel(label, above: rect, ctx: ctx)
            }

            // 八个手柄：1.0.10 起选区不再停留（松手就截），这段只在
            // 有"残留选区"时才可能画到，留着是为了别把老逻辑改出一堆空洞
            if selection != nil {
                ctx.setFillColor(NSColor.white.cgColor)
                ctx.setStrokeColor(NSColor.controlAccentColor.cgColor)
                ctx.setLineWidth(1)
                for point in Handle.allCases.map({ $0.point(in: rect) }) {
                    let dot = CGRect(x: point.x - 4, y: point.y - 4, width: 8, height: 8)
                    ctx.fillEllipse(in: dot)
                    ctx.strokeEllipse(in: dot)
                }
                drawHint("Esc 或右键取消截图",
                         above: rect, ctx: ctx)
            }
        }

        // ── 放大镜 ──────────────────────────────────────────

        /// 画在光标旁。**注意它读的是 `sourceImage`（上遮罩之前抓的整屏原图）**，
        /// 不是当前窗口的截图 —— 否则取到的像素已经被自己压暗 28%，色值全是错的。
        private func drawLoupe(_ ctx: CGContext) {
            guard hasCursor,
                  let config = loupeConfig, config.enabled,
                  let source = sourceImage else { return }
            Loupe.draw(in: ctx,
                       source: source,
                       cursor: cursorPoint,
                       bounds: bounds,
                       displaySize: bounds.size,
                       pixelScale: pixelScale,
                       lineColor: config.lineColor,
                       origin: config.origin,
                       format: config.format,
                       hashPrefix: config.hashPrefix)
        }

        /// 按 C 复制色值后的绿底小提示，贴在放大镜下面（放不下就翻上面）
        private func drawCopiedHint(_ ctx: CGContext) {
            guard let text = copiedHint else { return }
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
                .foregroundColor: NSColor.white,
            ]
            let size = (text as NSString).size(withAttributes: attributes)
            let loupeTopLeft = Loupe.origin(cursor: cursorPoint, size: Loupe.size, bounds: bounds)
            var y = loupeTopLeft.y + Loupe.size.height + 6
            if y + size.height + 10 > bounds.height {
                y = loupeTopLeft.y - size.height - 14
            }
            var x = loupeTopLeft.x
            x = min(max(4, x), max(4, bounds.width - size.width - 20))
            let box = CGRect(x: x, y: y, width: size.width + 16, height: size.height + 8)
            ctx.setFillColor(NSColor.systemGreen.withAlphaComponent(0.92).cgColor)
            ctx.addPath(CGPath(roundedRect: box, cornerWidth: 6, cornerHeight: 6, transform: nil))
            ctx.fillPath()
            (text as NSString).draw(at: CGPoint(x: box.minX + 8, y: box.minY + 4),
                                    withAttributes: attributes)
        }

        /// 提示 1.4 秒后自己消失。用序号而不是 Timer 句柄：连按几次 C 时
        /// 前一个定时器到点不该把后一次的提示擦掉。
        private func showCopiedHint(_ text: String) {
            copiedHint = text
            hintSeq += 1
            let seq = hintSeq
            needsDisplay = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.hintSeq == seq else { return }
                    self.copiedHint = nil
                    self.needsDisplay = true
                }
            }
        }

        /// 拖拽时按 Shift 约束正方形
        private func constrainedRect(_ start: CGPoint, _ current: CGPoint) -> CGRect {
            guard NSEvent.modifierFlags.contains(.shift) else {
                return normalizedRect(start, current)
            }
            let dx = current.x - start.x
            let dy = current.y - start.y
            let side = max(abs(dx), abs(dy))
            let end = CGPoint(x: start.x + (dx < 0 ? -side : side),
                              y: start.y + (dy < 0 ? -side : side))
            return normalizedRect(start, end)
        }

        private func drawHint(_ text: String, above rect: CGRect, ctx: CGContext) {
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 11, weight: .regular),
                .foregroundColor: NSColor.white.withAlphaComponent(0.92),
            ]
            let size = (text as NSString).size(withAttributes: attributes)
            let boxHeight = size.height + 8
            let origin = CGPoint(x: rect.minX,
                                 y: Self.hintOriginY(selection: rect, boxHeight: boxHeight))
            let box = CGRect(x: origin.x, y: origin.y, width: size.width + 16, height: boxHeight)
            ctx.setFillColor(NSColor.black.withAlphaComponent(0.7).cgColor)
            ctx.addPath(CGPath(roundedRect: box, cornerWidth: 5, cornerHeight: 5, transform: nil))
            ctx.fillPath()
            (text as NSString).draw(at: CGPoint(x: box.minX + 8, y: box.minY + 4), withAttributes: attributes)
        }

        /// 尺寸 / 操作提示框的 y 坐标（视图坐标是翻转的：y 往下长）。
        ///
        /// 用户口径（2026-11-06）：**默认在选区上面**，上面没位置了才到框下面。
        /// 以前是反的（先贴 maxY 往下走，撞到底边才翻到上面），于是框一拉出来提示就压在
        /// 选区下方的画面上 —— 而那通常是用户更想看清楚的那块内容。
        ///
        /// `topMargin` 留 8：框贴着 y=0 会被屏幕边 / 刘海吃掉一半，看着像没画。
        /// 抽成纯函数是为了自检能直接验"上下两档 + 临界点"，不用真起遮罩。
        static func hintOriginY(selection: CGRect, boxHeight: CGFloat,
                                topMargin: CGFloat = 8, gap: CGFloat = 10) -> CGFloat {
            let above = selection.minY - gap - boxHeight
            if above >= topMargin { return above }
            // 上面放不下（选区贴着屏幕顶）：落到框下面
            return selection.maxY + gap
        }

        /// 底部居中提示条（没有选区时显示，告诉用户还能怎么退出）
        private func drawCenteredHint(_ text: String, ctx: CGContext) {
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 12, weight: .regular),
                .foregroundColor: NSColor.white.withAlphaComponent(0.95),
            ]
            let size = (text as NSString).size(withAttributes: attributes)
            let box = CGRect(x: (bounds.width - size.width) / 2 - 12,
                             y: bounds.height - size.height - 44,
                             width: size.width + 24,
                             height: size.height + 12)
            ctx.setFillColor(NSColor.black.withAlphaComponent(0.68).cgColor)
            ctx.addPath(CGPath(roundedRect: box, cornerWidth: 7, cornerHeight: 7, transform: nil))
            ctx.fillPath()
            (text as NSString).draw(at: CGPoint(x: box.minX + 12, y: box.minY + 6),
                                    withAttributes: attributes)
        }

        private func drawCrosshair(_ ctx: CGContext) {
            guard showCrosshair else { return }
            let p = cursorPoint
            ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.6).cgColor)
            ctx.setLineWidth(1)
            ctx.move(to: CGPoint(x: p.x, y: 0)); ctx.addLine(to: CGPoint(x: p.x, y: bounds.height))
            ctx.move(to: CGPoint(x: 0, y: p.y)); ctx.addLine(to: CGPoint(x: bounds.width, y: p.y))
            ctx.strokePath()
        }

        private func drawLabel(_ text: String, above rect: CGRect, ctx: CGContext) {
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
                .foregroundColor: NSColor.white,
            ]
            let size = (text as NSString).size(withAttributes: attributes)
            let boxHeight = size.height + 8
            // 和 drawHint 同一套落位：默认在选区上面，上面放不下才到下面
            let labelRect = CGRect(x: rect.minX,
                                   y: Self.hintOriginY(selection: rect, boxHeight: boxHeight),
                                   width: size.width + 16, height: boxHeight)
            ctx.setFillColor(NSColor.black.withAlphaComponent(0.7).cgColor)
            let path = CGPath(roundedRect: labelRect, cornerWidth: 5, cornerHeight: 5, transform: nil)
            ctx.addPath(path)
            ctx.fillPath()
            (text as NSString).draw(at: CGPoint(x: labelRect.minX + 8, y: labelRect.minY + 4),
                                    withAttributes: attributes)
        }
    }
}
