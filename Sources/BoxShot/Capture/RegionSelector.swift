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
        private var magnifierSnapshot: CGImage?

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
            dragStart = p
            dragCurrent = p
            isDragging = false
            highlightedWindow = nil
            needsDisplay = true
        }

        override func mouseDragged(with event: NSEvent) {
            guard let start = dragStart else { return }
            let p = convert(event.locationInWindow, from: nil)
            if !isDragging && hypot(p.x - start.x, p.y - start.y) > 4 {
                isDragging = true
            }
            dragCurrent = p
            needsDisplay = true
        }

        override func mouseUp(with event: NSEvent) {
            guard let start = dragStart else { return }
            let p = convert(event.locationInWindow, from: nil)
            if isDragging {
                let rect = normalizedRect(start, p)
                if rect.width >= 8 && rect.height >= 8 {
                    // 视图坐标（左上原点，相对本显示器）就是显示器局部坐标
                    let selectorRef = selector
                    let displayID = self.displayID
                    MainActor.assumeIsolated {
                        selectorRef?.finish()
                        selectorRef?.delegate?.regionSelector(selectorRef!, didConfirmRegion: rect, displayID: displayID)
                    }
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
                } else {
                    dragStart = nil
                    dragCurrent = nil
                    needsDisplay = true
                }
            }
            dragStart = nil
        }

        private var displayID: CGDirectDisplayID {
            selector?.displayID ?? 0
        }

        override func mouseMoved(with event: NSEvent) {
            let p = convert(event.locationInWindow, from: nil)
            cursorPoint = p
            if highlightWindows {
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
            if event.keyCode == 53 { // Esc
                let selectorRef = selector
                MainActor.assumeIsolated {
                    selectorRef?.finish()
                    selectorRef?.delegate?.regionSelectorDidCancel(selectorRef!)
                }
            } else if event.keyCode == 36 { // Return：确认当前高亮窗口
                let selectorRef = selector
                if let win = highlightedWindow {
                    let displayID = self.displayID
                    MainActor.assumeIsolated {
                        selectorRef?.finish()
                        selectorRef?.delegate?.regionSelector(selectorRef!, didConfirmWindow: win, displayID: displayID)
                    }
                }
            } else {
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
            if isDragging, let start = dragStart, let current = dragCurrent {
                selectionRect = normalizedRect(start, current)
            } else if let start = dragStart {
                selectionRect = normalizedRect(start, dragCurrent ?? start)
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
            ctx.fill(rect.insetBy(dx: 0, dy: 0))
            ctx.restoreGState()

            ctx.setStrokeColor(NSColor.controlAccentColor.cgColor)
            ctx.setLineWidth(2)
            ctx.stroke(rect)

            // 尺寸标签（拖拽时）
            if isDragging {
                let label = "\(Int(rect.width)) × \(Int(rect.height))"
                drawLabel(label, above: rect, ctx: ctx)
            }

            // 八个手柄
            ctx.setFillColor(NSColor.white.cgColor)
            for point in handlePoints(of: rect) {
                ctx.fillEllipse(in: CGRect(x: point.x - 4, y: point.y - 4, width: 8, height: 8))
            }
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

        private func handlePoints(of rect: CGRect) -> [CGPoint] {
            [
                CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.midX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
                CGPoint(x: rect.minX, y: rect.midY), CGPoint(x: rect.maxX, y: rect.midY),
                CGPoint(x: rect.minX, y: rect.maxY), CGPoint(x: rect.midX, y: rect.maxY), CGPoint(x: rect.maxX, y: rect.maxY),
            ]
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
