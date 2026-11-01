import AppKit

// ============================================================
// 区域选择遮罩
//
// 全屏透明窗口盖住鼠标所在的那块屏幕：
//   · 半透明暗幕，拖拽出选区后选区外保持暗、选区内透亮
//   · 移动鼠标时高亮所在窗口（CGWindowList 几何命中，智能识别窗口）
//   · 轻点（不拖）= 选中高亮窗口；拖拽 = 自定义区域；Esc 取消
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
    private(set) var isActive = false

    func begin(highlightWindows: Bool, crosshair: Bool) {
        guard !isActive else { return }
        guard window == nil else { return }

        let screen = ScreenCapture.activeScreen()
        displayID = ScreenCapture.display(for: screen)

        let panel = NSWindow(contentRect: screen.frame,
                             styleMask: [.borderless],
                             backing: .buffered,
                             defer: false,
                             screen: screen)
        panel.level = .screenSaver
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = false
        panel.acceptsMouseMovedEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let view = OverlayView(frame: NSRect(origin: .zero, size: screen.frame.size))
        view.selector = self
        view.highlightWindows = highlightWindows
        view.showCrosshair = crosshair
        // 遮罩窗口铺满整块屏幕；视图 isFlipped（左上原点），和 CGWindowList /
        // SCStreamConfiguration 的"左上原点向下"坐标系一致。
        // globalOrigin 用 CGDisplayBounds（左上原点）而不是 screen.frame（左下原点）。
        view.globalOrigin = ScreenCapture.displayBoundsGlobal(ScreenCapture.display(for: screen)).origin
        panel.contentView = view
        // 键盘（回车确认 / 方向键微调 / Esc）要靠 first responder 才收得到，
        // 别指望"窗口一变 key 就会自动指向内容视图"
        panel.makeFirstResponder(view)

        window = panel
        overlayView = view
        isActive = true
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        view.warmUpWindowList()
    }

    func cancel() {
        guard isActive else { return }
        finish()
        MainActor.assumeIsolated { delegate?.regionSelectorDidCancel(self) }
    }

    fileprivate func finish() {
        isActive = false
        overlayView?.stopTracking()
        window?.orderOut(nil)
        window = nil
        overlayView = nil
    }

    // ── 遮罩视图 ─────────────────────────────────────────────

    final class OverlayView: NSView {

        var selector: RegionSelector?
        var highlightWindows = true
        var showCrosshair = true

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
                    // 进入调整阶段：不立刻截图，先让用户拖手柄/方向键微调，回车确认
                    selection = rect
                    phase = .adjusting
                    needsDisplay = true
                } else {
                    needsDisplay = true // 太小视为误触，留在选区模式
                }
            } else {
                // 轻点：选中高亮窗口
                if highlightWindows, let hit = topLevelWindow(at: toGlobal(p)) {
                    let selectorRef = selector
                    let displayID = self.displayID
                    MainActor.assumeIsolated {
                        selectorRef?.finish()
                        selectorRef?.delegate?.regionSelector(selectorRef!, didConfirmWindow: hit, displayID: displayID)
                    }
                }
            }
            dragStart = nil
            dragCurrent = nil
            isDragging = false
        }

        /// 确认选区（视图坐标 = 显示器局部坐标）
        private func confirm(rect: CGRect) {
            guard rect.width >= 8, rect.height >= 8 else { return }
            let selectorRef = selector
            let displayID = self.displayID
            MainActor.assumeIsolated {
                selectorRef?.finish()
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

        override func mouseMoved(with event: NSEvent) {
            let p = convert(event.locationInWindow, from: nil)
            cursorPoint = p
            // 有选区/正在拖拽时不抢高亮（避免视觉干扰）
            if highlightWindows, selection == nil, !isDragging {
                let hit = topLevelWindow(at: toGlobal(p))
                if hit?.windowID != highlightedWindow?.windowID {
                    highlightedWindow = hit
                    needsDisplay = true
                }
            }
            if showCrosshair {
                needsDisplay = true
            }
        }

        override func keyDown(with event: NSEvent) {
            let step: CGFloat = event.modifierFlags.contains(.shift) ? 10 : 1
            switch event.keyCode {
            case 53: // Esc：有选区先撤选区，再按一次退出
                if let sel = selection {
                    selection = nil
                    phase = .idle
                    needsDisplay = true
                } else {
                    let selectorRef = selector
                    MainActor.assumeIsolated {
                        selectorRef?.finish()
                        selectorRef?.delegate?.regionSelectorDidCancel(selectorRef!)
                    }
                }
            case 36: // Return：确认选区（没有选区时确认高亮窗口）
                if let sel = selection {
                    confirm(rect: sel)
                } else if let win = highlightedWindow {
                    let selectorRef = selector
                    let displayID = self.displayID
                    MainActor.assumeIsolated {
                        selectorRef?.finish()
                        selectorRef?.delegate?.regionSelector(selectorRef!, didConfirmWindow: win, displayID: displayID)
                    }
                }
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

            // 暗幕
            ctx.setFillColor(NSColor.black.withAlphaComponent(0.28).cgColor)
            ctx.fill(bounds)

            let selectionRect: CGRect?
            if phase == .dragging, let start = dragStart, let current = dragCurrent {
                selectionRect = constrainedRect(start, current)
            } else if let sel = selection {
                selectionRect = sel
            } else if highlightWindows, let win = highlightedWindow {
                // 高亮窗口：全局 → 视图坐标
                selectionRect = win.frame.offsetBy(dx: -globalOrigin.x, dy: -globalOrigin.y)
            } else {
                selectionRect = nil
            }

            guard let rect = selectionRect else {
                drawCrosshair(ctx)
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

            // 尺寸标签（拖拽/调整时都显示）
            let label = "\(Int(rect.width)) × \(Int(rect.height))"
            drawLabel(label, above: rect, ctx: ctx)

            // 八个手柄（可调整阶段才可拖，但一直画出来提示可调）
            if selection != nil {
                ctx.setFillColor(NSColor.white.cgColor)
                ctx.setStrokeColor(NSColor.controlAccentColor.cgColor)
                ctx.setLineWidth(1)
                for point in Handle.allCases.map({ $0.point(in: rect) }) {
                    let dot = CGRect(x: point.x - 4, y: point.y - 4, width: 8, height: 8)
                    ctx.fillEllipse(in: dot)
                    ctx.strokeEllipse(in: dot)
                }
                drawHint("单击选区内 / 回车 开始截图 · 拖手柄调整 · 方向键微调（⇧ ×10）· Esc 取消", above: rect, ctx: ctx)
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
            var origin = CGPoint(x: rect.minX, y: rect.maxY + 10)
            if origin.y + size.height + 10 > bounds.height { origin.y = rect.minY - size.height - 18 }
            let box = CGRect(x: origin.x, y: origin.y, width: size.width + 16, height: size.height + 8)
            ctx.setFillColor(NSColor.black.withAlphaComponent(0.7).cgColor)
            ctx.addPath(CGPath(roundedRect: box, cornerWidth: 5, cornerHeight: 5, transform: nil))
            ctx.fillPath()
            (text as NSString).draw(at: CGPoint(x: box.minX + 8, y: box.minY + 4), withAttributes: attributes)
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
            let labelRect = CGRect(x: rect.minX, y: rect.minY - size.height - 10,
                                   width: size.width + 16, height: size.height + 8)
            ctx.setFillColor(NSColor.black.withAlphaComponent(0.7).cgColor)
            let path = CGPath(roundedRect: labelRect, cornerWidth: 5, cornerHeight: 5, transform: nil)
            ctx.addPath(path)
            ctx.fillPath()
            (text as NSString).draw(at: CGPoint(x: labelRect.minX + 8, y: labelRect.minY + 4),
                                    withAttributes: attributes)
        }
    }
}
