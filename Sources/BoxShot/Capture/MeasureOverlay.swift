import AppKit

// ============================================================
// 屏幕测距遮罩
//
// 第一次轻点定起点，移动鼠标实时显示连线与像素距离，
// 第二次轻点定格并展示结果（可复制），Esc 取消。
// 与 RegionSelector 同一套"左上原点"坐标系。
// ============================================================

final class MeasureOverlay: NSObject {

    var onFinish: ((CGFloat, String) -> Void)?
    /// 是否显示操作提示（设置 measureShowTips；距离读数始终显示）
    var showTips = true

    private var window: NSWindow?
    private var view: MeasureView?
    private(set) var isActive = false

    func begin() {
        guard !isActive else { return }
        let screen = ScreenCapture.activeScreen()
        let panel = NSWindow(contentRect: screen.frame,
                             styleMask: [.borderless],
                             backing: .buffered,
                             defer: false,
                             screen: screen)
        panel.level = .screenSaver
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.acceptsMouseMovedEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let overlayView = MeasureView(frame: NSRect(origin: .zero, size: screen.frame.size))
        overlayView.controller = self
        panel.contentView = overlayView

        window = panel
        view = overlayView
        isActive = true
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func finish(distance: CGFloat?, hex: String?) {
        isActive = false
        window?.orderOut(nil)
        window = nil
        view = nil
        if let distance {
            onFinish?(distance, hex ?? "")
        }
    }

    final class MeasureView: NSView {

        weak var controller: MeasureOverlay?

        private var startPoint: CGPoint?
        private var endPoint: CGPoint?
        private var phase: Phase = .pickingStart
        private var cursor: CGPoint = .zero

        enum Phase { case pickingStart, measuring, done }

        override var acceptsFirstResponder: Bool { true }
        override var isFlipped: Bool { true }

        override func mouseDown(with event: NSEvent) {
            let p = convert(event.locationInWindow, from: nil)
            switch phase {
            case .pickingStart:
                startPoint = p
                cursor = p
                phase = .measuring
                needsDisplay = true
            case .measuring:
                endPoint = p
                phase = .done
                needsDisplay = true
                report()
            case .done:
                controller?.finish(distance: nil, hex: nil)
            }
        }

        private func report() {
            guard let a = startPoint, let b = endPoint else { return }
            // 与编辑器测距统一基准：**物理像素**（Retina 截图像素）。
            // 屏幕点 × backingScale = 截图上对应的像素数；曾经直接用点，
            // 2x 屏下与编辑器里量的差一倍。四舍五入，不再截断。
            let scale = window?.screen?.backingScaleFactor ?? 2
            let distance = hypot(a.x - b.x, a.y - b.y) * scale
            // 先把结果画出来 0.35 秒再拆窗口，让用户看见"已复制"
            Support.copyTextToClipboard("\(Int(distance.rounded())) px")
            controller?.onFinish?(distance, "")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                self?.controller?.finish(distance: nil, hex: nil)
            }
        }

        override func mouseMoved(with event: NSEvent) {
            cursor = convert(event.locationInWindow, from: nil)
            needsDisplay = true
        }

        override func keyDown(with event: NSEvent) {
            if event.keyCode == 53 { // Esc
                controller?.finish(distance: nil, hex: nil)
            } else {
                super.keyDown(with: event)
            }
        }

        override func draw(_ dirtyRect: NSRect) {
            guard let ctx = NSGraphicsContext.current?.cgContext else { return }
            ctx.setFillColor(NSColor.black.withAlphaComponent(0.12).cgColor)
            ctx.fill(bounds)

            ctx.setStrokeColor(NSColor.controlAccentColor.cgColor)
            ctx.setLineWidth(1.5)
            ctx.setFillColor(NSColor.controlAccentColor.cgColor)

            // 十字准星
            for (dx, dy) in [(-14.0, 0.0), (14.0, 0.0), (0.0, -14.0), (0.0, 14.0)] {
                ctx.move(to: CGPoint(x: cursor.x, y: cursor.y))
                ctx.addLine(to: CGPoint(x: cursor.x + dx, y: cursor.y + dy))
            }
            ctx.strokePath()

            guard let a = startPoint else {
                if controller?.showTips != false {
                    drawHUD("轻点确定起点", at: cursor, ctx: ctx)
                }
                return
            }
            let b = phase == .measuring ? cursor : (endPoint ?? cursor)
            ctx.move(to: a)
            ctx.addLine(to: b)
            ctx.strokePath()
            for p in [a, b] {
                ctx.fillEllipse(in: CGRect(x: p.x - 3.5, y: p.y - 3.5, width: 7, height: 7))
            }

            // 读数按物理像素（与编辑器测距、截图像素一致）
            let scale = window?.screen?.backingScaleFactor ?? 2
            let distance = hypot(a.x - b.x, a.y - b.y) * scale
            let dx = (a.x - b.x) * scale, dy = (a.y - b.y) * scale
            let text = "\(Int(distance.rounded())) px"
            if phase == .measuring {
                drawHUD("\(text)   dx \(Int(dx.rounded())) · dy \(Int(dy.rounded()))", at: CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2), ctx: ctx)
            } else {
                drawHUD("\(text) 已复制", at: CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2), ctx: ctx)
            }
        }

        private func drawHUD(_ text: String, at point: CGPoint, ctx: CGContext) {
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium),
                .foregroundColor: NSColor.white,
            ]
            let size = (text as NSString).size(withAttributes: attributes)
            var rect = CGRect(x: point.x + 14, y: point.y + 14, width: size.width + 16, height: size.height + 8)
            if rect.maxX > bounds.width { rect.origin.x = point.x - rect.width - 14 }
            if rect.maxY > bounds.height { rect.origin.y = point.y - rect.height - 14 }
            ctx.setFillColor(NSColor.black.withAlphaComponent(0.75).cgColor)
            ctx.addPath(CGPath(roundedRect: rect, cornerWidth: 6, cornerHeight: 6, transform: nil))
            ctx.fillPath()
            (text as NSString).draw(at: CGPoint(x: rect.minX + 8, y: rect.minY + 4), withAttributes: attributes)
        }
    }
}
