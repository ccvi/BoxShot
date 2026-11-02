import AppKit
import Carbon.HIToolbox
import CoreGraphics
import Foundation

// ============================================================
// 自检（--selftest）
//
// 只测**纯逻辑**，不碰屏幕捕获（无授权环境下跑不了，CI/打包机也不该弹窗）：
//   · 键位匹配 / 功能键全局注册资格
//   · 拼接算法：构造已知偏移的合成图，验证能找回偏移
//   · OCR 换行聚类
//   · 偏好解码：缺字段的旧配置要能读
//   · 编辑器渲染管线：马赛克/模糊效果图、文字渲染、像素取色
// ============================================================

enum SelfTest {

    static func run() -> Int {
        // EditorDocument / PinManager 都是 @MainActor：自检从 main 顶层进，
        // 本来就在主线程上，直接 assumeIsolated 打开隔离。
        MainActor.assumeIsolated {
            var failures = 0

            func check(_ name: String, _ condition: Bool) {
                if condition {
                    print("✓ \(name)")
                } else {
                    print("✗ \(name)")
                    failures += 1
                }
            }

        // ── 键位 ──
        let f7 = KeySpec(keyCode: UInt16(kVK_F7), label: "F7")
        check("F7 可注册为全局热键", f7.isUsableAsGlobal)
        let plainA = KeySpec(keyCode: UInt16(kVK_ANSI_A), label: "A")
        check("无修饰字母键不可注册为全局热键", !plainA.isUsableAsGlobal)
        let cmdC = KeySpec(keyCode: UInt16(kVK_ANSI_C), command: true, label: "C")
        check("⌘C 可注册为全局热键", cmdC.isUsableAsGlobal)
        check("F7 键值显示", f7.display == "F7")

        // ── 滚动拼接（1.0.5 重写：逐像素验证"拼出来是连续的"）──
        // 1.0.4 的老用例只检查"高度差不多"，误差 ±8 像素照样通过 ——
        // 而用户看到的正是那几像素的错位（重影、内容错行）。
        // 现在改成：合成一张带随机纹理的"网页"，按已知偏移滚 5 段，
        // 最后把结果与源页面**逐像素**比对，差一个像素就算失败。
        // 调试对齐过程：BOXSHOT_STITCH_DEBUG=1 时往 stderr 打搜索过程
        ImageStitch.debugLog = ProcessInfo.processInfo.environment["BOXSHOT_STITCH_DEBUG"] != nil
        if let page = syntheticPage(width: 480, height: 1600) {
            let viewH = 500
            let steps = [137, 89, 210, 63, 174]
            var visitY = 0
            var lastFrame = page.cropping(to: CGRect(x: 0, y: 0, width: 480, height: viewH))
            var accumulated = lastFrame
            var hint: Int?
            var foundOffsets: [Int] = []
            var failureNotes: [String] = []

            for step in steps {
                visitY += step
                guard let bottom = page.cropping(to: CGRect(x: 0, y: visitY, width: 480, height: viewH)),
                      let top = lastFrame, let canvas = accumulated else {
                    failureNotes.append("第 \(step) 段取帧失败")
                    break
                }
                guard let alignment = ImageStitch.align(top: top, bottom: bottom, hint: hint) else {
                    failureNotes.append("第 \(step) 段没对齐")
                    break
                }
                foundOffsets.append(alignment.offset)
                guard let joined = ImageStitch.append(bottom: bottom, to: canvas, offset: alignment.offset) else {
                    failureNotes.append("第 \(step) 段拼接失败")
                    break
                }
                accumulated = joined
                lastFrame = bottom
                hint = alignment.offset
            }

            check("每段偏移都精确等于滚动量（\(foundOffsets) vs \(steps)）",
                  failureNotes.isEmpty && foundOffsets == steps)
            if !failureNotes.isEmpty { print("    ↳ \(failureNotes.joined(separator: "；"))") }

            let expectedHeight = visitY + viewH
            check("拼接总高度正确（\(accumulated?.height ?? -1) vs \(expectedHeight)）",
                  accumulated?.height == expectedHeight)

            if let acc = accumulated,
               let expected = page.cropping(to: CGRect(x: 0, y: 0, width: 480, height: expectedHeight)) {
                let diff = pixelMismatchRatio(acc, expected, tolerance: 3)
                check(String(format: "拼接结果与源页面逐像素一致（坏点 %.4f%%）", diff * 100), diff < 0.001)
            } else {
                check("拼接结果与源页面逐像素一致（取图失败）", false)
            }

            // 空白画面（纯色）里任何偏移都"像"，必须判失败，否则会瞎拼
            let blankA = solidImage(width: 200, height: 300, color: CGColor(gray: 0.5, alpha: 1))
            let blankB = solidImage(width: 200, height: 300, color: CGColor(gray: 0.5, alpha: 1))
            check("纯色画面拒绝拼接（不瞎拼）", ImageStitch.align(top: blankA, bottom: blankB) == nil)

            // 只滚 2px：要么精确对 2px，要么拒绝（绝不接受一个大偏移）。
            // 基准必须是"上一帧"，不是第一帧——拿第一帧比等于比两段无关内容。
            if let tiny = page.cropping(to: CGRect(x: 0, y: visitY + 2, width: 480, height: viewH)) {
                let result = ImageStitch.align(top: lastFrame ?? page, bottom: tiny)
                check("微小滚动要么对 2px 要么拒绝（\(result?.offset.description ?? "nil")）",
                      result == nil || result!.offset <= 6)
            }

            // 等距重复内容（表格 / 列表）会有多个"完美"候选：137、37、237 全都
            // 逐像素相等。单靠像素无法区分，必须靠上一段的偏移（hint）拉回正确周期，
            // 否则每滚一段就跳一个周期，拼出来的图内容会重复 / 缺段。
            if let periodic = periodicPage(width: 480, height: 1600, period: 100),
               let pTop = periodic.cropping(to: CGRect(x: 0, y: 0, width: 480, height: viewH)),
               let pBottom = periodic.cropping(to: CGRect(x: 0, y: 137, width: 480, height: viewH)) {
                let withHint = ImageStitch.align(top: pTop, bottom: pBottom, hint: 137)
                check("周期性内容靠 hint 拉回正确周期（\(withHint?.offset.description ?? "nil")）",
                      withHint?.offset == 137)
            } else {
                check("周期性内容靠 hint 拉回正确周期（造图失败）", false)
            }

            // 大跳动的边界：滚到只剩 5% 重叠还能对，滚过一屏就该拒绝
            if let far = page.cropping(to: CGRect(x: 0, y: visitY + 475, width: 480, height: viewH)) {
                let near = ImageStitch.align(top: lastFrame ?? page, bottom: far)
                check("滚到只剩 5% 重叠还对得上（\(near?.offset.description ?? "nil")）",
                      near?.offset == 475)
            } else {
                check("滚到只剩 5% 重叠还对得上（造图失败）", false)
            }
            if let over = page.cropping(to: CGRect(x: 0, y: visitY + 560, width: 480, height: viewH)) {
                check("滚过一屏（无重叠）必须拒绝",
                      ImageStitch.align(top: lastFrame ?? page, bottom: over) == nil)
            } else {
                check("滚过一屏（无重叠）必须拒绝（造图失败）", false)
            }

            // 亚像素停靠：触控板 / 平滑滚动停下的位置常带小数（如 137.4px），
            // 两帧各自带着抗锯齿重采样，正确偏移的像素差被抬高 —— 以前会被质量门
            // 当成"没对上"拒掉（用户症状：明明滚得不快却老提示过帧）。
            // 要求：分数偏移能对上，且偏移落在 137…138（真值 137.4 的整数邻域）。
            if let smooth = smoothPage(width: 480, height: 1600),
               let sTop = smooth.cropping(to: CGRect(x: 0, y: 0, width: 480, height: viewH)) {
                // 把页面按小数偏移画进 viewH 高的画布，模拟"停在半像素"的一帧
                func fractionalFrame(_ topFromPageTop: CGFloat) -> CGImage? {
                    guard let ctx = CGContext(data: nil, width: 480, height: viewH,
                                              bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                                | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
                    ctx.interpolationQuality = .high
                    // CG 左下原点：页面底边画在 y0 时，页面第 top 行正好落在画布顶
                    ctx.draw(smooth, in: CGRect(x: 0, y: topFromPageTop - CGFloat(1600 - viewH),
                                                width: 480, height: 1600))
                    return ctx.makeImage()
                }
                if let frac = fractionalFrame(137.4) {
                    // hint=137：真实连续滚动时上一段偏移就在附近；无 hint 的
                    // 强周期页在粗搜里本就无解（同相位候选一大把），那是另一回事
                    let result = ImageStitch.align(top: sTop, bottom: frac, hint: 137)
                    check("半像素停靠也能对上（\(result?.offset.description ?? "nil")）",
                          result.map { (137...138).contains($0.offset) } == true)
                } else {
                    check("半像素停靠也能对上（造图失败）", false)
                }
                // 但纯色 + 无分离度依旧必须拒绝（放宽容忍不能放开"瞎拼"那道门）
                let blankMove = solidImage(width: 480, height: viewH, color: CGColor(gray: 0.5, alpha: 1))
                check("半像素容忍不放走纯色瞎拼",
                      ImageStitch.align(top: sTop, bottom: blankMove) == nil)
            } else {
                check("半像素停靠测试造图失败", false)
            }

            // 取景框几何：选区必须**整个**落在面板的透明区里。
            // 1.0.5 的血案是面板盖在选区上还画了预览，抓帧把自己拍进去了。
            let region = NSRect(x: 300, y: 200, width: 480, height: 500)
            let panel = ScrollCaptureController.panelRect(forRegion: region)
            check("取景框面板把选区包在透明区里（左/右/下各留 2px，上方留状态带）",
                  panel.minX == region.minX - 2
                    && panel.maxX == region.maxX + 2
                    && panel.minY == region.minY - 2
                    && panel.maxY == region.maxY + ScrollFrameView.bandHeight + 2)

            let probe = ScrollFrameView(frame: NSRect(x: 0, y: 0,
                                                      width: region.width + 4,
                                                      height: region.height + ScrollFrameView.bandHeight + 4))
            let inner = probe.regionRect
            check("视图里的选区矩形不贴边（四周至少留 2px 给边框）",
                  inner.minX >= 2 && inner.minY >= 2
                    && inner.maxX <= probe.bounds.width - 2
                    && inner.maxY <= probe.bounds.height - 2)

            check("旋转 90° 尺寸互换", {
                guard let rotated = ImageStitch.rotate90(page) else { return false }
                return rotated.width == 1600 && rotated.height == 480
            }())
        } else {
            check("合成测试页面", false)
        }

        // ── 选区交互 ──
        // 单击（不拖动）确认开始截图；拖一下只是挪选区。两者靠位移阈值区分。
        check("选区内单击算确认（0~2pt）",
              RegionSelector.OverlayView.isTap(from: .zero, to: CGPoint(x: 1, y: 1)))
        check("选区内拖动不算确认（>2pt）",
              !RegionSelector.OverlayView.isTap(from: .zero, to: CGPoint(x: 40, y: 0)))

        // ── OCR 行聚类 ──
        do {
            let observations = [
                OCREngine.TextObservation(text: "订单金额", bounds: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.04)),
                OCREngine.TextObservation(text: "￥128.00", bounds: CGRect(x: 0.5, y: 0.10, width: 0.25, height: 0.04)),
                OCREngine.TextObservation(text: "第二行内容", bounds: CGRect(x: 0.1, y: 0.30, width: 0.4, height: 0.04)),
            ]
            let lines = OCREngine.groupIntoLines(observations, overlapThreshold: 0.2)
            check("OCR 聚类出两行", lines.count == 2)
            check("同行词序按 x 排列", lines.first?.contains("订单金额") == true && lines.first?.contains("￥128.00") == true)
        }

        // ── 偏好解码 ──
        do {
            // 空配置 → 全默认
            let empty = try JSONDecoder().decode(Preferences.self, from: Data("{}".bytes))
            check("空配置解码取默认值", empty.recordFPS == 30 && empty.shotFormat == .png)
            // 带部分字段
            let partial = try JSONDecoder().decode(Preferences.self, from: Data(#"{"shotFormat":"jpg"}"#.bytes))
            check("部分配置解码补默认", partial.shotFormat == .jpg && partial.ocrKeepLineBreaks == true)
            // 提示音：缺字段 / 名字已下线都要落回默认，否则设置页 Picker 显示空白
            check("提示音默认是 Glass", empty.feedbackSound == "Glass")
            let badSound = try JSONDecoder().decode(Preferences.self,
                                                    from: Data(#"{"feedbackSound":"Sosumi"}"#.bytes))
            check("下线音效名回退默认", badSound.feedbackSound == "Glass")
            let goodSound = try JSONDecoder().decode(Preferences.self,
                                                     from: Data(#"{"feedbackSound":"Ping"}"#.bytes))
            check("有效音效名读得回来", goodSound.feedbackSound == "Ping")
            // 取景框大小：默认「中」，且三档名字都认
            check("取景框大小默认中", empty.recordCameraSize == .medium)
            let bigBubble = try JSONDecoder().decode(Preferences.self,
                                                     from: Data(#"{"recordCameraSize":"large"}"#.bytes))
            check("取景框大小读得回来", bigBubble.recordCameraSize == .large)
        } catch {
            check("偏好解码异常：\(error)", false)
        }

        // ── 提示音表 ──
        do {
            let names = SoundFeedback.options.map(\.name)
            check("提示音有 8 档", names.count == 8)
            check("提示音名字不重复", Set(names).count == names.count)
            check("默认音效在可选列表里", names.contains(SoundFeedback.defaultName))
        }

        // ── 自动保存必须补上落盘目录 ──
        do {
            // 「自动保存」原来只在 saveDirectory 非空时才落盘，用户勾了开关却
            // 什么都没发生 —— 症状就是"设置无效"。现在勾上就自动补桌面。
            let suite = "com.pcxx.boxshot.selftest"
            let defaults = UserDefaults(suiteName: suite)!
            defaults.removePersistentDomain(forName: suite)
            let store = PreferencesStore(defaults: defaults)
            store.value.saveDirectory = nil
            store.value.autoSave = true
            check("勾自动保存会自动补落盘目录", (store.value.saveDirectory ?? "").isEmpty == false)
            check("补的目录就是桌面", store.value.saveDirectory == Support.defaultSaveDirectory.path)
            defaults.removePersistentDomain(forName: suite)
        }

        // ── 1x 模式下改截图框的换算 ──
        do {
            // 2x 屏正常截图：文档也是 2x → 比例 1
            check("正常截图：文档尺度 = 1",
                  OverlayEditorController.documentScale(selectionPixelScale: 2, fullDisplayPixelScale: 2) == 1)
            // 开了 Retina 1x：文档 1x、整屏原图 2x → 0.5
            check("Retina 1x：文档尺度 = 0.5",
                  OverlayEditorController.documentScale(selectionPixelScale: 1, fullDisplayPixelScale: 2) == 0.5)
            check("异常倍率不除零",
                  OverlayEditorController.documentScale(selectionPixelScale: 1, fullDisplayPixelScale: 0) == 0)
        }

        // ── 滚动截图缩略图落位 ──
        do {
            let visible = CGRect(x: 0, y: 0, width: 1710, height: 1077)
            let size = ScrollCaptureController.previewSize
            check("缩略图尺寸 180×600", size.width == 180 && size.height == 600)

            // 截图框在左半边 → 贴右边
            let left = CGRect(x: 100, y: 400, width: 600, height: 400)
            let p1 = ScrollCaptureController.previewOrigin(region: left, visible: visible, size: size)
            check("右边有位置就放右边", p1.x == left.maxX + 12)

            // 截图框贴右边缘 → 换左边
            let right = CGRect(x: 1000, y: 400, width: 600, height: 400)
            let p2 = ScrollCaptureController.previewOrigin(region: right, visible: visible, size: size)
            check("右边放不下就放左边", p2.x == right.minX - 12 - size.width)
            check("放左边时不压住选区", p2.x + size.width <= right.minX)

            // 截图框顶边贴屏幕顶 → 缩略图不能超出可见区
            let top = CGRect(x: 100, y: 900, width: 600, height: 170)
            let p3 = ScrollCaptureController.previewOrigin(region: top, visible: visible, size: size)
            check("顶边对齐后不超出屏幕", p3.y + size.height <= visible.maxY - 3)

            // 截图框几乎占满整屏宽 → 左右上下都塞不下，只能贴屏幕右边缘
            // （几何上无解：这种框本来就不该配滚动截图，压住的右边缘会被拍进画面）
            let wide = CGRect(x: 20, y: 300, width: 1670, height: 500)
            let p4 = ScrollCaptureController.previewOrigin(region: wide, visible: visible, size: size)
            check("整屏宽的框：缩略图退到屏幕右边不越界",
                  p4.x + size.width <= visible.maxX - 3 && p4.x >= visible.minX + 3)
        }

        // ── 标注工具条落位（1.0.10 用户口径：下 → 上 → 框内底部，间距 10pt）──
        do {
            let visible = CGRect(x: 0, y: 0, width: 1710, height: 1077)
            let size = CGSize(width: 900, height: 64)
            let gap = OverlayEditorController.toolbarGap
            check("工具条间距 10pt", gap == 10)

            // ① 默认：框下方，底边距框底 10pt
            let roomy = CGRect(x: 100, y: 400, width: 800, height: 400)
            let p1 = OverlayEditorController.toolbarOrigin(selection: roomy, toolbarSize: size, visible: visible)
            check("有位置：工具条在框下方", p1.y + size.height <= roomy.minY)
            check("框下间距正好 10pt", roomy.minY - (p1.y + size.height) == gap)

            // ② 下方贴到可见区底边 → 换上方，底边距框顶 10pt
            let low = CGRect(x: 100, y: 50, width: 800, height: 400)
            let p2 = OverlayEditorController.toolbarOrigin(selection: low, toolbarSize: size, visible: visible)
            check("下方没位置：工具条到框上方", p2.y >= low.maxY)
            check("框上间距正好 10pt", p2.y - low.maxY == gap)

            // ③ 上下都没位置 → 压进框内底部居中
            let tall = CGRect(x: 100, y: 30, width: 800, height: 1020)
            let p3 = OverlayEditorController.toolbarOrigin(selection: tall, toolbarSize: size, visible: visible)
            check("上下都没位置：工具条落在框内底部",
                  p3.y > tall.minY && p3.y + size.height < tall.maxY)
            check("框内底部间距也是 10pt", p3.y - tall.minY == gap)

            // ④ 横向按框中线居中，且不越出可见区
            let narrow = CGRect(x: 1600, y: 400, width: 100, height: 300)
            let p4 = OverlayEditorController.toolbarOrigin(selection: narrow, toolbarSize: size, visible: visible)
            check("工具条不越出屏幕右边", p4.x + size.width <= visible.maxX)
            let centered = CGRect(x: 200, y: 400, width: 800, height: 400)
            let p5 = OverlayEditorController.toolbarOrigin(selection: centered, toolbarSize: size, visible: visible)
            check("工具条按框中线居中", abs((p5.x + size.width / 2) - centered.midX) < 0.5)
        }

        // ── 工具条尺寸（1.0.11：工具条保持原尺寸，只缩「当前颜色」那颗圆点）──
        do {
            check("工具条保持原尺寸（倍率 1.0）",
                  abs(OverlayEditorController.toolbarScale - 1.0) < 0.001)
            check("图标字号还是 19（没跟着缩）",
                  abs(OverlayEditorController.toolbarIconPointSize - 19) < 0.01)
            check("文字工具按钮直接显示「文字」（textformat 字形在中文环境渲染成「格式」）",
                  EditorTool.text.toolbarLabel == "文字"
                    && EditorTool.pen.toolbarLabel == nil)
            // 这几条盯的是"倍率是不是真的只作用在圆点上"：
            // 内边距 / 间距 / 分隔线一旦跟着变，就是又误伤了整个工具条。
            // 容器圆角 2026-11-02 用户口径从 14 改成 10（与颜色面板一致）。
            check("内边距 / 间距 / 按钮圆角都回到原值",
                  abs(OverlayEditorController.toolbarInsetV - 9) < 0.01
                    && abs(OverlayEditorController.toolbarInsetH - 10) < 0.01
                    && abs(OverlayEditorController.toolbarSpacing - 2) < 0.01
                    && abs(OverlayEditorController.toolbarButtonCornerRadius - 6) < 0.01)
            check("容器圆角 = 10（与颜色面板一致，工具条 1 = 工具条 2）",
                  abs(OverlayEditorController.toolbarContainerCornerRadius - 10) < 0.01)
            check("工具条分隔线高度回到 26",
                  abs(OverlayEditorController.toolbarDividerHeight - 26) < 0.01)
            check("「当前颜色」圆点缩到 21（30 的 70%）",
                  abs(OverlayEditorController.colorAnchorSide - 21) < 0.01)
            check("颜色圆点确实比原来小 30%",
                  abs(OverlayEditorController.colorAnchorSide / 30 - 0.7) < 0.001)
        }

        // ── 颜色面板落位（1.0.10：贴在工具条下面，6 个颜色）──
        do {
            let visible = CGRect(x: 0, y: 0, width: 1710, height: 1077)
            let panelSize = CGSize(width: 200, height: 48)
            check("调色板正好 6 个颜色", OverlayEditorController.colorPalette.count == 6)
            check("色卡是 黄绿蓝红橙紫 六色（含色值）",
                  OverlayEditorController.colorPalette.map { $0.hexString }
                    == ["#F8CE43", "#62C563", "#3887FB", "#EB4259", "#F3933D", "#BD3DDD"])
            check("色块是圆形（圆角取半径）", OverlayEditorController.swatchSide > 0)
            // 用户口径：1.0.10「小 20%」→ 1.0.11「再小 10%」：26 × 0.8 × 0.9 = 18.72。
            // 钉死数字，防止以后谁手滑又调回 26
            check("色块直径 18.72pt（26 的 80% 再 90%）",
                  abs(OverlayEditorController.swatchSide - 18.72) < 0.01)
            check("分隔线跟着色块一起缩（不高于色块）",
                  OverlayEditorController.colorPanelDividerHeight <= OverlayEditorController.swatchSide)

            let toolbar = CGRect(x: 300, y: 500, width: 700, height: 64)
            let p1 = OverlayEditorController.colorPanelOrigin(toolbar: toolbar,
                                                              panelSize: panelSize, visible: visible)
            check("颜色面板在工具条下面",
                  p1.y + panelSize.height <= toolbar.minY && p1.y + panelSize.height == toolbar.minY - OverlayEditorController.colorPanelGap)
            check("颜色面板与工具条左对齐", p1.x == toolbar.minX)

            // 工具条贴着可见区底边 → 面板翻到工具条上方
            let lowToolbar = CGRect(x: 300, y: 10, width: 700, height: 64)
            let p2 = OverlayEditorController.colorPanelOrigin(toolbar: lowToolbar,
                                                              panelSize: panelSize, visible: visible)
            check("下面没位置：颜色面板到工具条上方", p2.y >= lowToolbar.maxY)

            // 工具条贴右边缘 → 面板不越界
            let rightToolbar = CGRect(x: 1600, y: 500, width: 100, height: 64)
            let p3 = OverlayEditorController.colorPanelOrigin(toolbar: rightToolbar,
                                                              panelSize: panelSize, visible: visible)
            check("颜色面板不越出屏幕右边", p3.x + panelSize.width <= visible.maxX)
        }

        // ── 高亮工具（1.0.10 取代工具条上的裁剪位）──
        do {
            check("高亮是拖拽工具", EditorTool.highlight.isDragTool)
            // 用户口径（他附的样张）：高亮 = 聚光点亮 —— 块内原样不动，块外压暗。
            // 所以这里断言的是"块内没被染色"和"块外变暗"，跟"染色"刚好相反。
            let white = solidImage(width: 40, height: 40, color: CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
            let hl = AnnotationShape(tool: .highlight,
                                     points: [CGPoint(x: 5, y: 5), CGPoint(x: 35, y: 35)],
                                     color: .red, lineWidth: 0)
            let out = EditorRenderer.render(base: white, shapes: [hl], effects: EffectImages(base: white))
            let inside = out.flatMap { EditorDocument(image: $0).pixelColor(at: CGPoint(x: 20, y: 20)) }
            check("高亮点亮的那块保持原样（不染色）",
                  inside != nil && inside!.red > 0.95 && inside!.green > 0.95 && inside!.blue > 0.95)
            let outside = out.flatMap { EditorDocument(image: $0).pixelColor(at: CGPoint(x: 2, y: 2)) }
            // 白底压 0.6 黑 ≈ 0.4，留点余量判 < 0.5
            check("高亮块外被压暗（聚光）",
                  outside != nil && outside!.red < 0.5 && outside!.green < 0.5 && outside!.blue < 0.5)
            check("压暗强度是 0.6（跟样张量出来的 (102,102,102) 对得上）",
                  abs(EditorRenderer.highlightDimAlpha - 0.6) < 0.001
                    && abs(outside!.red - 0.4) < 0.02)
            check("高亮点得中（命中测试）",
                  hl.hitTest(CGPoint(x: 20, y: 20)) && !hl.hitTest(CGPoint(x: 60, y: 60)))
            check("高亮用的不是「高亮/染色」那套图标与文案",
                  EditorTool.highlight.title.contains("点亮")
                    && !EditorTool.highlight.title.contains("半透明"))
        }

        // ── 编辑窗口色板 = 截图工具条色卡（2026-11-02 用户口径：颜色对应）──
        do {
            check("编辑器与工具条共用同一份调色板（防两处漂移）",
                  RGBColor.palette.map { $0.hexString }
                    == OverlayEditorController.colorPalette.map { $0.hexString })
            check("编辑器色板含橙紫（老色板没有的那两个）",
                  RGBColor.palette.contains(.orange) && RGBColor.palette.contains(.purple))
        }

        // ── 步骤标注（点击放 ①②③，自动递增）──
        do {
            check("步骤标注是单击工具（不是拖拽）", !EditorTool.step.isDragTool)
            let s1 = AnnotationShape(tool: .step, points: [CGPoint(x: 10, y: 10)], color: .red, lineWidth: 0)
            let s2 = AnnotationShape(tool: .step, points: [CGPoint(x: 40, y: 10)], color: .red, lineWidth: 0)
            let s3 = AnnotationShape(tool: .step, points: [CGPoint(x: 70, y: 10)], color: .red, lineWidth: 0)
            let list = [s1, s2, s3]
            check("步骤序号按数组顺序 1/2/3",
                  EditorRenderer.stepNumber(of: s1, in: list) == 1
                    && EditorRenderer.stepNumber(of: s2, in: list) == 2
                    && EditorRenderer.stepNumber(of: s3, in: list) == 3)
            // 删掉第一步 → 后面的自动补号（渲染时按顺序数，不存死序号）
            let remaining = [s2, s3]
            check("删掉一步后序号自动重排",
                  EditorRenderer.stepNumber(of: s2, in: remaining) == 1
                    && EditorRenderer.stepNumber(of: s3, in: remaining) == 2)
            // 渲染出来确实是圆底：圆心偏移处应为标注色
            let white = solidImage(width: 100, height: 100, color: CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
            let stepShape = AnnotationShape(tool: .step, points: [CGPoint(x: 50, y: 50)], color: .red, lineWidth: 0)
            let stepOut = EditorRenderer.render(base: white, shapes: [stepShape], effects: EffectImages(base: white))
            let inBubble = stepOut.flatMap { EditorDocument(image: $0).pixelColor(at: CGPoint(x: 35, y: 50)) }
            check("步骤标注渲染出圆底（标注色）",
                  inBubble != nil && inBubble!.red > 0.7 && inBubble!.green < 0.4)
            let onWhite = stepOut.flatMap { EditorDocument(image: $0).pixelColor(at: CGPoint(x: 5, y: 5)) }
            check("步骤标注外仍是底图",
                  onWhite != nil && onWhite!.red > 0.95)
            check("步骤标注可命中（点选删除用）",
                  stepShape.hitTest(CGPoint(x: 52, y: 52)) && !stepShape.hitTest(CGPoint(x: 90, y: 90)))
        }

        // ── 截图美化（背景 / 圆角 / 阴影 / padding，Xnapper 式套壳）──
        do {
            let white = solidImage(width: 40, height: 40, color: CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
            let effects = EffectImages(base: white)
            var style = BeautifyOptions()
            style.background = .color(.blue)
            style.padding = 20
            style.cornerRadius = 8
            style.shadow = false   // 阴影会污染边角像素，纯色断言关掉它
            let out = EditorRenderer.render(base: white, shapes: [], effects: effects, beautify: style)
            check("美化输出尺寸 = 底图 + 四周 padding",
                  out != nil && out?.width == 80 && out?.height == 80)
            let corner = out.flatMap { EditorDocument(image: $0).pixelColor(at: CGPoint(x: 2, y: 2)) }
            check("padding 区是背景色",
                  corner != nil && corner!.blue > 0.8 && corner!.red < 0.4)
            let center = out.flatMap { EditorDocument(image: $0).pixelColor(at: CGPoint(x: 40, y: 40)) }
            check("底图区域原样保留",
                  center != nil && center!.red > 0.95 && center!.green > 0.95)
            // 不开美化：尺寸不变（老路径零回归）
            let plain = EditorRenderer.render(base: white, shapes: [], effects: effects)
            check("不开美化时渲染尺寸不变",
                  plain != nil && plain?.width == 40 && plain?.height == 40)
            // 默认参数是"能直接用"的：有背景、有边距、开阴影
            check("美化默认参数开箱可用",
                  BeautifyOptions().padding > 0 && BeautifyOptions().shadow)
        }

        // ── OCR 表格 → Markdown ──
        do {
            // 一张"标题行 + 表头 + 一行数据"的合成图（归一化坐标）
            let obs: [OCREngine.TextObservation] = [
                .init(text: "价目表", bounds: CGRect(x: 0.1, y: 0.02, width: 0.1, height: 0.04)),
                .init(text: "名称",   bounds: CGRect(x: 0.10, y: 0.15, width: 0.12, height: 0.04)),
                .init(text: "金额",   bounds: CGRect(x: 0.60, y: 0.15, width: 0.12, height: 0.04)),
                .init(text: "苹果",   bounds: CGRect(x: 0.10, y: 0.30, width: 0.12, height: 0.04)),
                .init(text: "五元",   bounds: CGRect(x: 0.60, y: 0.30, width: 0.12, height: 0.04)),
            ]
            let markdown = OCREngine.tableMarkdown(from: obs)
            check("表格重排出 Markdown", markdown != nil)
            check("表头是第一行", markdown?.contains("| 名称 | 金额 |") == true)
            check("数据行对上列", markdown?.contains("| 苹果 | 五元 |") == true)
            check("有分隔行", markdown?.contains("---") == true)
            // 表上方的标题不混进表格
            check("表外标题没被当进表格", markdown?.contains("价目表") != true)
            // 普通段落（没有多列行）返回 nil
            let paragraph: [OCREngine.TextObservation] = [
                .init(text: "第一段", bounds: CGRect(x: 0.1, y: 0.1, width: 0.5, height: 0.04)),
                .init(text: "第二段", bounds: CGRect(x: 0.1, y: 0.3, width: 0.5, height: 0.04)),
            ]
            check("普通文本不硬拼表格", OCREngine.tableMarkdown(from: paragraph) == nil)
            // 行级包围盒（贴图「选择文字」用）：同行词合并成一个行框，纵向含整行
            let lineBoxes = OCREngine.lineBoxes(from: obs)
            check("行级包围盒数量 = 行数（标题 + 两行表格）", lineBoxes.count == 3)
            check("行框横向含住整行全部词",
                  abs(lineBoxes[1].bounds.minX - 0.10) < 0.001
                    && abs(lineBoxes[1].bounds.maxX - 0.72) < 0.001)
            check("行框纵向含住行的完整高度",
                  lineBoxes[1].bounds.height >= 0.04)
        }

        // ── 取景框两套尺寸 + 两种落位（1.0.20 再改版）──
        do {
            // 区域 / 全屏录制：还原成 200/180/150（贴右下角）
            check("画中画大 = 200pt", CameraBubbleSize.large.side == 200)
            check("画中画中 = 180pt", CameraBubbleSize.medium.side == 180)
            check("画中画小 = 150pt", CameraBubbleSize.small.side == 150)
            // 摄像头录制：600/550/500（居中）
            check("摄像头大 = 600pt", CameraBubbleSize.large.cameraSide == 600)
            check("摄像头中 = 550pt", CameraBubbleSize.medium.cameraSide == 550)
            check("摄像头小 = 500pt", CameraBubbleSize.small.cameraSide == 500)
            check("两套尺寸不相等（别又合并成一套）",
                  CameraBubbleSize.large.side != CameraBubbleSize.large.cameraSide
                    && CameraBubbleSize.medium.side != CameraBubbleSize.medium.cameraSide
                    && CameraBubbleSize.small.side != CameraBubbleSize.small.cameraSide)
            check("取景框三档标题是 大/中/小",
                  CameraBubbleSize.large.title == "大"
                    && CameraBubbleSize.medium.title == "中"
                    && CameraBubbleSize.small.title == "小")

            let frame = CGRect(x: 0, y: 0, width: 1282, height: 721)
            // 摄像头录制：放得下就按设置的来（600 不能被收成别的数）
            check("录制框里 600 原样落地",
                  CameraBubbleController.fittedSide(wanted: 600, anchor: frame, placement: .centered) == 600)
            // 摄像头录制：真的塞不下才收
            check("塞不下时收到框高",
                  CameraBubbleController.fittedSide(wanted: 600,
                                                    anchor: CGRect(x: 0, y: 0, width: 400, height: 300),
                                                    placement: .centered) == 300)
            // 画中画：仍然按短边 45% 收，下限 96
            check("画中画按短边 45% 收",
                  CameraBubbleController.fittedSide(wanted: 200,
                                                    anchor: CGRect(x: 0, y: 0, width: 400, height: 400),
                                                    placement: .bottomTrailing) == 180)
            check("画中画下限 96",
                  CameraBubbleController.fittedSide(wanted: 200,
                                                    anchor: CGRect(x: 0, y: 0, width: 100, height: 100),
                                                    placement: .bottomTrailing) == 96)

            check("摄像头录制默认大 600", Preferences().cameraRecordSize == .large)
            check("摄像头录制尺寸读得回来",
                  (try? JSONDecoder().decode(Preferences.self,
                                             from: Data(#"{"cameraRecordSize":"small"}"#.bytes)))?
                    .cameraRecordSize == .small)

            // 固定录制框：16:9、居中、不出界、放得下 600 的取景框
            if let screen = NSScreen.main {
                let visible = screen.visibleFrame
                let rect = AppModel.fixedRecordFrame(on: screen)
                check("固定框是 16:9", abs(rect.width / rect.height - 16.0 / 9.0) < 0.02)
                check("固定框居中",
                      abs(rect.midX - visible.midX) <= 1 && abs(rect.midY - visible.midY) <= 1)
                check("固定框不出界",
                      rect.minX >= visible.minX - 1 && rect.maxX <= visible.maxX + 1
                        && rect.minY >= visible.minY - 1 && rect.maxY <= visible.maxY + 1)
                check("固定框放得下 600 的取景框",
                      CameraBubbleController.fittedSide(wanted: 600, anchor: rect, placement: .centered) == 600)
            }
        }

        // ── 固定框的坐标换算（AppKit ↔ 显示器局部）──
        do {
            // 🔴 录制框是 NSScreen.visibleFrame（左下原点）算出来的，而 SCStream 的
            // sourceRect 吃的是显示器局部坐标（左上原点）。这里少翻一次 y，
            // 录出来的就是屏幕上完全另一块地方 —— 尺寸照样正确，只有画面是错的。
            let id = CGMainDisplayID()
            let appKit = CGRect(x: 120, y: 200, width: 1505, height: 846)
            let local = ScreenCapture.displayLocalRect(fromAppKit: appKit, displayID: id)
            let back = ScreenCapture.appKitFrame(
                fromGlobalTopLeft: ScreenCapture.globalTopLeftRect(fromDisplayLocal: local, displayID: id))
            check("坐标换算来回不漂",
                  abs(back.minX - appKit.minX) < 0.5 && abs(back.minY - appKit.minY) < 0.5
                    && abs(back.width - appKit.width) < 0.5 && abs(back.height - appKit.height) < 0.5)
            let bounds = ScreenCapture.displayBoundsGlobal(id)
            check("换算结果落在显示器范围内",
                  local.minX >= 0 && local.minY >= 0
                    && local.maxX <= bounds.width + 0.5 && local.maxY <= bounds.height + 0.5)
        }

        // ── 录制帧率档位（1.0.12 新增 48/50/60）──
        do {
            check("帧率档位 8 档", recordFPSOptions == [10, 15, 24, 25, 30, 48, 50, 60])
            check("帧率档位单调递增",
                  zip(recordFPSOptions, recordFPSOptions.dropFirst()).allSatisfy { $0 < $1 })
            // 引擎两头的换算不能把 48/50/60 夹回去：60 得原样传下去
            check("60fps 不被 min(60) 夹掉", min(60, 60) == 60)
            check("默认 30 在档位里", recordFPSOptions.contains(Preferences().recordFPS))
        }

        // ── 渲染管线 ──
        do {
            let base = solidImage(width: 64, height: 64, color: CGColor(srgbRed: 0.2, green: 0.6, blue: 0.9, alpha: 1))
            let effects = EffectImages(base: base)
            check("马赛克效果图生成", effects.pixelated != nil)
            check("模糊效果图生成", effects.blurred != nil)

            // 取色读数
            let doc = EditorDocument(image: base)
            let picked = doc.pixelColor(at: CGPoint(x: 32, y: 32))
            check("像素取色接近底色",
                  picked != nil && abs(picked!.red - 0.2) < 0.08 && abs(picked!.green - 0.6) < 0.08)

            // 渲染一张带全部标注的图
            let shapes: [AnnotationShape] = [
                AnnotationShape(tool: .rect, points: [CGPoint(x: 5, y: 5), CGPoint(x: 30, y: 30)],
                                color: .red, lineWidth: 3),
                AnnotationShape(tool: .marker, points: [CGPoint(x: 2, y: 40), CGPoint(x: 20, y: 44), CGPoint(x: 40, y: 46)],
                                color: .yellow, lineWidth: 8),
                AnnotationShape(tool: .mosaic, points: [CGPoint(x: 40, y: 5), CGPoint(x: 60, y: 25)],
                                color: .black, lineWidth: 0),
                AnnotationShape(tool: .text, points: [CGPoint(x: 4, y: 4)], color: .black, lineWidth: 0, text: "测试", fontSize: 20),
                AnnotationShape(tool: .measure, points: [CGPoint(x: 8, y: 50), CGPoint(x: 30, y: 58)],
                                color: .blue, lineWidth: 2),
                AnnotationShape(tool: .arrow, points: [CGPoint(x: 60, y: 60), CGPoint(x: 40, y: 50)],
                                color: .green, lineWidth: 3),
            ]
            let rendered = EditorRenderer.render(base: base, shapes: shapes, effects: effects)
            check("标注合成渲染输出", rendered != nil && rendered?.width == 64 && rendered?.height == 64)

            // 马赛克/模糊回归（1.0.2）：曾经用两点**直线路径**做 clip——直线零面积，
            // 裁剪后一个像素都画不出来，效果静默消失。这里要求效果区域内
            // 确实有像素相对底图被改变（"输出非 nil"不等于"画出来了"）。
            do {
                let ectx = CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 0,
                                     space: CGColorSpaceCreateDeviceRGB(),
                                     bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
                ectx.setFillColor(CGColor(gray: 1, alpha: 1))
                ectx.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
                ectx.setFillColor(CGColor(gray: 0, alpha: 1))
                ectx.fill(CGRect(x: 20, y: 20, width: 24, height: 24))   // 中央黑块，供效果区域跨边界产生差异
                let edgeBase = ectx.makeImage()!
                let edgeEffects = EffectImages(base: edgeBase)
                for (name, tool) in [("马赛克", EditorTool.mosaic), ("模糊", EditorTool.blur)] {
                    let shape = AnnotationShape(tool: tool, points: [CGPoint(x: 16, y: 16), CGPoint(x: 48, y: 48)],
                                                color: .black, lineWidth: 0)
                    guard let out = EditorRenderer.render(base: edgeBase, shapes: [shape], effects: edgeEffects),
                          let outData = out.dataProvider?.data, let outPtr = CFDataGetBytePtr(outData),
                          let baseData = edgeBase.dataProvider?.data, let basePtr = CFDataGetBytePtr(baseData) else {
                        check("\(name)效果区域有像素变化", false)
                        continue
                    }
                    let bpp = out.bitsPerPixel / 8
                    var changed = 0
                    for py in 16..<48 {
                        for px in 16..<48 {
                            let o = py * out.bytesPerRow + px * bpp
                            let dr = abs(Int(outPtr[o + 2]) - Int(basePtr[o + 2]))
                            let dg = abs(Int(outPtr[o + 1]) - Int(basePtr[o + 1]))
                            let db = abs(Int(outPtr[o]) - Int(basePtr[o]))
                            if max(dr, dg, db) > 8 { changed += 1 }
                        }
                    }
                    check("\(name)效果区域有像素变化（\(changed) px）", changed > 30)
                }
            }

            // 底图方向回归：上白下黑的图渲染后左上角像素应是白
            //（曾经翻转顺序错误导致整图上下颠倒，形状位置对、内容倒）
            do {
                let ctx = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
                                    space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
                ctx.setFillColor(CGColor(gray: 1, alpha: 1))
                ctx.fill(CGRect(x: 0, y: 4, width: 8, height: 4))   // 标准空间 y=4..8 → 画面上半
                ctx.setFillColor(CGColor(gray: 0, alpha: 1))
                ctx.fill(CGRect(x: 0, y: 0, width: 8, height: 4))
                let halfTone = ctx.makeImage()!
                let plain = EditorRenderer.render(base: halfTone, shapes: [], effects: EffectImages(base: halfTone))
                if let plain, let data = plain.dataProvider?.data, let ptr = CFDataGetBytePtr(data) {
                    // 32BGRA 小端：白像素 B=G=R=255
                    let topLeft = ptr[0]
                    let bottomLeft = ptr[(7 * plain.bytesPerRow)]
                    check("底图方向不颠倒（上白下黑）", topLeft == 255 && bottomLeft == 0)
                } else {
                    check("底图方向不颠倒（读不到像素）", false)
                }
            }

            // ── 裁剪（1.0.4）──
            do {
                // 100×80 底图，两个矩形：一个在裁剪区内、一个在区外
                let canvas = solidImage(width: 100, height: 80,
                                        color: CGColor(srgbRed: 0.3, green: 0.3, blue: 0.3, alpha: 1))
                let inside = AnnotationShape(tool: .rect,
                                             points: [CGPoint(x: 20, y: 10), CGPoint(x: 40, y: 30)],
                                             color: .red, lineWidth: 3)
                let outside = AnnotationShape(tool: .rect,
                                              points: [CGPoint(x: 80, y: 60), CGPoint(x: 95, y: 75)],
                                              color: .blue, lineWidth: 3)
                let cropDoc = EditorDocument(image: canvas, shapes: [inside, outside])
                let result = cropDoc.croppedResult(to: CGRect(x: 10, y: 5, width: 50, height: 40))
                check("裁剪输出尺寸正确",
                      result?.image.width == 50 && result?.image.height == 40)
                check("裁剪后只留画面内的标注", result?.shapes.count == 1)
                check("裁剪后标注坐标随原点平移",
                      result?.shapes.first?.points.first == CGPoint(x: 10, y: 5))
                check("裁剪框过小返回 nil",
                      cropDoc.croppedResult(to: CGRect(x: 0, y: 0, width: 4, height: 4)) == nil)
                let cropShape = AnnotationShape(tool: .crop,
                                                points: [CGPoint(x: 0, y: 0), CGPoint(x: 50, y: 50)],
                                                color: .red, lineWidth: 2)
                check("裁剪工具不是标注（不参与命中/显示）",
                      !cropShape.hitTest(CGPoint(x: 10, y: 10)) && cropShape.displayBounds == nil)
            }

            // ── 撤销重做
            doc.commit(shapes[0])
            check("提交后撤销栈可用", doc.canUndo)
            doc.undo()
            check("撤销后形状清空", doc.shapes.isEmpty && doc.canRedo)
            doc.redo()
            check("重做恢复形状", doc.shapes.count == 1)

            // ── 点选 / 移动 / 删除（1.0.3）──
            // shapes[0] = rect (5,5)-(30,30)
            check("命中测试命中矩形", doc.select(at: CGPoint(x: 15, y: 15)) != nil)
            check("命中测试落空取消选中",
                  doc.select(at: CGPoint(x: 70, y: 45)) == nil && doc.selectedID == nil)
            doc.select(at: CGPoint(x: 15, y: 15))
            doc.beginMoveSelected()
            doc.moveSelected(by: CGPoint(x: 10, y: 0))
            doc.endMoveSelected()
            check("拖动后坐标正确", doc.selectedShape?.points[0].x == 15)
            check("移动进了撤销栈", doc.canUndo)
            doc.deleteSelected()
            check("删除选中后清空", doc.shapes.isEmpty && doc.selectedID == nil)
            check("删除可撤销", doc.canUndo)
            doc.undo()
            check("撤销删除恢复形状", doc.shapes.count == 1)
        }

        // ── 箭头几何（1.0.12：用户说"箭头不够尖"）──
        do {
            // 尖不尖 = 顶点张角 + 头长／线宽的比
            check("顶点张角收到 34°（旧版 48°）",
                  abs(2 * EditorRenderer.arrowHeadSpread * 180 / .pi - 34.4) < 0.6)
            check("头长随线宽增长（4pt → 20.8）",
                  abs(EditorRenderer.arrowHeadLength(width: 4) - 20.8) < 0.01)
            check("细线头长有下限 16", EditorRenderer.arrowHeadLength(width: 1) == 16)
            check("头越细长越尖：宽/长 < 0.65",
                  2 * sin(EditorRenderer.arrowHeadSpread) < 0.65)

            let a = CGPoint(x: 0, y: 0), b = CGPoint(x: 100, y: 0)
            let headLen = EditorRenderer.arrowHeadLength(width: 4)
            // 箭杆必须收在尖端后面：留出 round cap 的半径（width/2 = 2）也不该碰到尖
            let stem = EditorRenderer.arrowStemEnd(from: a, to: b, width: 4)
            check("箭杆终点收进头部（离尖端 > 头长一半）", stem.x < b.x - headLen * 0.5)
            check("箭杆终点不会缩到起点之前", stem.x > a.x)

            // 返回顺序： [尖, 左翼, 底边内凹点, 右翼]
            let pts = EditorRenderer.arrowHeadPoints(from: a, to: b, width: 4)
            check("头部是四点多边形", pts.count == 4)
            check("第一点是箭尖（原样落在终点）", pts[0] == b)
            check("两翼左右对称",
                  abs((pts[1].y + pts[3].y) - 2 * b.y) < 0.01
                  && abs(pts[1].x - pts[3].x) < 0.01)
            check("底边内凹（notch 比两翼更靠近尖端）", pts[2].x > pts[1].x)

            // 打开编辑器就该是箭头（用户口径），不是矩形
            let blank = solidImage(width: 8, height: 8,
                                   color: CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
            let fresh = EditorDocument(image: blank)
            check("打开编辑器默认选箭头", fresh.tool == .arrow)
        }

        // ── GIF 已移除（1.0.12）：老配置迁移必须不丢别的设置 ──
        do {
            check("老配置的 gif 格式迁回 mp4",
                  RecordFileFormat.from(legacyRaw: "gif") == .mp4)
            check("未知格式迁不回来（走默认值）",
                  RecordFileFormat.from(legacyRaw: "webm") == nil)
            check("格式档位只剩 MOV / MP4",
                  RecordFileFormat.allCases == [.mov, .mp4])
            // 整包解码：recordFormat 存的是 "gif"（旧 enum 已删），解码必须成功
            // 且不能把快捷键等其它字段一起冲掉 —— 那等于让用户重配一遍设置。
            let legacy = """
            {"recordFormat":"gif","recordFPS":30,"saveDirectory":"/tmp/盒子截图",\
            "shortcuts":{"regionShot":{"keyCode":99,"command":false,"shift":false,\
            "option":true,"control":false,"label":"⌥F3"}}}
            """
            if let data = legacy.data(using: .utf8) {
                do {
                    let decoded = try JSONDecoder().decode(Preferences.self, from: data)
                    check("含 gif 的整包配置解码成功", decoded.recordFormat == .mp4)
                    check("迁移不丢快捷键", decoded.spec(for: .regionShot)?.label == "⌥F3")
                    check("迁移不丢保存目录", decoded.saveDirectory == "/tmp/盒子截图")
                } catch {
                    print("  ↳ 解码错误详情：\(error)")
                    check("含 gif 的整包配置解码成功", false)
                }
            } else {
                check("含 gif 的整包配置解码成功", false)
            }
        }

        // ── 录制暂停状态（1.0.4）──
        do {
            let recorder = RecorderController()
            check("默认非暂停", !recorder.isPaused)
            recorder.setPaused(true)
            check("暂停生效", recorder.isPaused)
            recorder.setPaused(false)
            check("恢复生效", !recorder.isPaused)
        }

        // ── 截图历史（1.0.4）──
        do {
            let store = ShotHistoryStore.shared
            let before = store.items.count
            store.record(solidImage(width: 12, height: 9, color: CGColor(gray: 0.5, alpha: 1)), limit: 50)
            check("历史记录新增一条", store.items.count == before + 1)
            if let item = store.items.first {
                check("历史条目尺寸正确", item.pixelWidth == 12 && item.pixelHeight == 9)
                check("能从历史读回图片", store.image(for: item)?.width == 12)
                store.delete(item)
                check("删除历史条目", store.items.count == before)
            } else {
                check("历史记录新增一条（读不到条目）", false)
            }
        }

        // ── 文本渲染贴图 ──
        do {
            let pinImage = PinManager.renderTextToImage("自检文本贴图\n第二行")
            check("文本渲染成位图", pinImage != nil && pinImage!.width > 20)
        }

        // ── 放大镜：落位 / 坐标口径 / 裁剪 ──
        // 全是纯函数，不用上屏就能验。放大镜最容易错的三处：
        // 贴屏幕右边不翻（盖住光标）、坐标原点算反、裁块越界出空白格。
        do {
            let screen = CGRect(x: 0, y: 0, width: 1000, height: 800)
            let size = Loupe.size
            check("放大镜是 15×15 个源像素 + 74 高信息条",
                  size.width == 150 && size.height == 224)

            let rightDown = Loupe.origin(cursor: CGPoint(x: 100, y: 100), size: size, bounds: screen)
            check("默认落在光标右下方", rightDown.x > 100 && rightDown.y > 100)

            let nearRight = Loupe.origin(cursor: CGPoint(x: 980, y: 100), size: size, bounds: screen)
            check("右边放不下就翻到左边（不盖住光标）",
                  nearRight.x + size.width <= 980)

            let nearBottom = Loupe.origin(cursor: CGPoint(x: 100, y: 790), size: size, bounds: screen)
            check("下面放不下就翻到上面", nearBottom.y + size.height <= 790)

            let corner = Loupe.origin(cursor: CGPoint(x: 999, y: 799), size: size, bounds: screen)
            check("贴角时不越出屏幕",
                  corner.x >= 0 && corner.y >= 0
                  && corner.x + size.width <= screen.width
                  && corner.y + size.height <= screen.height)
        }
        do {
            let display = CGSize(width: 1000, height: 800)
            let p = CGPoint(x: 10, y: 20)
            check("左上角原点：坐标原样",
                  Loupe.displayCoordinate(point: p, origin: .topLeft, displaySize: display) == p)
            let topRight = Loupe.displayCoordinate(point: p, origin: .topRight, displaySize: display)
            check("右上角原点：x 从右边数", topRight.x == 990 && topRight.y == 20)
            let bottomLeft = Loupe.displayCoordinate(point: p, origin: .bottomLeft, displaySize: display)
            check("左下角原点：y 从下边数", bottomLeft.x == 10 && bottomLeft.y == 780)
            let bottomRight = Loupe.displayCoordinate(point: p, origin: .bottomRight, displaySize: display)
            check("右下角原点：两个都反过来", bottomRight.x == 990 && bottomRight.y == 780)
        }
        do {
            let image = CGSize(width: 100, height: 80)
            // 半格 = 7.5，所以中心对齐时是 .5 —— 这是**对的**：
            // 光标正好落在 15 格的正中那格，不偏不倚
            let middle = Loupe.cropOrigin(cursorPixel: CGPoint(x: 50, y: 40),
                                          cellCount: 15, imageSize: image)
            check("裁剪块以光标像素为中心", middle.x == 42.5 && middle.y == 32.5)
            let leftTop = Loupe.cropOrigin(cursorPixel: CGPoint(x: 0, y: 0),
                                           cellCount: 15, imageSize: image)
            check("贴左上角时裁块钳到 0", leftTop.x == 0 && leftTop.y == 0)
            let rightBottom = Loupe.cropOrigin(cursorPixel: CGPoint(x: 99, y: 79),
                                               cellCount: 15, imageSize: image)
            check("贴右下角时裁块钳到图像内",
                  rightBottom.x == 85 && rightBottom.y == 65)
        }

        // ── 放大镜的色值文本 ──
        do {
            let color = RGBColor.srgb(0xD1, 0x8C, 0x72)
            check("镜内显示：两位一组、空格分开",
                  Loupe.display(color, format: .hex, hashPrefix: true) == "#D1 8C 72")
            check("复制出去：紧凑 HEX",
                  Loupe.copyable(color, format: .hex, hashPrefix: true) == "#D18C72")
            check("关掉前缀就不带 #",
                  Loupe.copyable(color, format: .hex, hashPrefix: false) == "D18C72")
            check("复制出去：RGB 写法",
                  Loupe.copyable(color, format: .rgb, hashPrefix: true) == "rgb(209, 140, 114)")
            check("HEX 存进设置再读回来不变",
                  Loupe.hexPairs(Loupe.color(fromHex: "#D18C72")) == "D18C72")
            check("坏 HEX 退回默认蓝",
                  Loupe.hexPairs(Loupe.color(fromHex: "zzz")) == "3B82F6")
        }

        // ── 贴图窗口：初始尺寸必须是 1:1 ──
        // `PinWindow.scale` 曾经初始化成 1/backingScale（0.5），而 applyScale 里
        // 是 baseW × scale —— 窗口一被重排（首次缩放 / 从历史恢复）就只剩一半大。
        do {
            let img = solidImage(width: 200, height: 100,
                                 color: CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
            if let pinWindow = PinWindow(image: img, opacity: 1, shadow: false) {
                let backing = NSScreen.main?.backingScaleFactor ?? 2
                let expectW = 200 / backing
                check("贴图初始宽度 = 图像宽 ÷ 屏缩放（1:1，不折半）",
                      abs(pinWindow.frame.width - expectW) < 1)
                check("贴图初始高度 = 图像高 ÷ 屏缩放",
                      abs(pinWindow.frame.height - 100 / backing) < 1)
                // 缩放 2 倍后再看：应该正好翻倍，而不是变成原来的一半
                pinWindow.zoom(by: 2)
                check("贴图放大 2 倍是原尺寸的 2 倍",
                      abs(pinWindow.frame.width - expectW * 2) < 1)
                pinWindow.close()
            } else {
                check("贴图窗口能建出来", false)
            }
        }

        // ── 贴图：文字可选中 + 置顶按钮 ──
        do {
            let text = "可选中的文字\n第二行"
            if let image = PinManager.renderTextToImage(text),
               let pin = PinWindow(image: image, opacity: 1, shadow: false, text: text) {
                check("文本贴图挂的是可选中的文本视图",
                      pin.contentView is PinTextContentView)
                check("文本贴图能成为 key（否则 ⌘C 复制不了）", pin.canBecomeKey)
                check("贴图默认就是置顶（.floating）", pin.isOnTop)
                pin.toggleOnTop()
                check("点一下取消置顶", !pin.isOnTop)
                pin.toggleOnTop()
                check("再点一下回到置顶", pin.isOnTop)
                pin.close()
            } else {
                check("文本贴图窗口能建出来", false)
            }

            // 图片贴图不该抢 key（会打断用户正在打字的窗口）
            let solid = solidImage(width: 40, height: 30,
                                   color: CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
            if let imagePin = PinWindow(image: solid, opacity: 1, shadow: false) {
                check("图片贴图不抢 key window", !imagePin.canBecomeKey)
                check("两种贴图都带置顶按钮",
                      imagePin.contentView?.subviews.contains { $0 is NSButton } == true)
                imagePin.close()
            } else {
                check("图片贴图窗口能建出来", false)
            }
        }

        // ── 文件名/去重 ──
        do {
            let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            let first = Support.uniqueFileURL(in: dir, name: "boxshot-selftest.png")
            try? Data([0]).write(to: first)
            let second = Support.uniqueFileURL(in: dir, name: "boxshot-selftest.png")
            check("重名文件去重", second != first)
            try? FileManager.default.removeItem(at: first)
        }

        // ── 全局热键的可用性门槛 ──
        // 「快捷键设置不可用」有两条独立的病因：一是录制控件根本收不到键盘
        // （NSButton 默认不接受第一响应者），二是录下来的键不符合注册条件
        // （纯字母会和打字冲突，Carbon 直接拒）。第二条是纯函数，必须能测。
        do {
            let plainLetter = KeySpec(keyCode: 0, label: "A")
            check("纯字母键不能当全局热键", plainLetter.isUsableAsGlobal == false)

            let plainDigit = KeySpec(keyCode: 29, label: "0")
            check("纯数字键不能当全局热键", plainDigit.isUsableAsGlobal == false)

            let withCommand = KeySpec(keyCode: 0, command: true, label: "A")
            check("⌘+字母可以当全局热键", withCommand.isUsableAsGlobal)

            let withOption = KeySpec(keyCode: 0, option: true, label: "A")
            check("⌥+字母可以当全局热键", withOption.isUsableAsGlobal)

            // F7 的虚拟键码是 98（kVK_F7），功能键不带修饰键也该放行
            let plainF7 = KeySpec(keyCode: 98, label: "F7")
            check("F7 不带修饰键也能注册", plainF7.isUsableAsGlobal)

            let plainSpace = KeySpec(keyCode: 49, label: "空格")
            check("空格不能当全局热键", plainSpace.isUsableAsGlobal == false)
        }

        // ── 设置里的键位不回退默认值 ──
        do {
            var prefs = Preferences()
            check("出厂不带任何热键", prefs.spec(for: .regionShot) == nil)
            prefs.shortcuts[ShotAction.regionShot.rawValue] = KeySpec(keyCode: 98, label: "F7")
            check("录过的键位读得回来", prefs.spec(for: .regionShot)?.label == "F7")
            prefs.shortcuts.removeValue(forKey: ShotAction.regionShot.rawValue)
            check("清除后不会回退成默认键", prefs.spec(for: .regionShot) == nil)
        }

        // ── 拖手柄改截图框 ──
        // 这条交互错了就是"一拖框就乱飞"，而且改完要按新框从整屏原图重裁，
        // 坐标一旦镜像，裁出来的是屏幕另一头的内容 —— 纯函数，必须测。
        do {
            let bounds = CGRect(x: 0, y: 0, width: 1000, height: 800)
            let start = CGRect(x: 100, y: 100, width: 300, height: 200)

            let bigger = OverlayEditorView.resizedRect(start, handle: .bottomRight,
                                                       delta: CGPoint(x: 40, y: 30), bounds: bounds)
            check("拖右下角：宽高各加 40/30",
                  bigger.width == 340 && bigger.height == 230)
            check("拖右下角：原点不动", bigger.origin == start.origin)

            let fromTopLeft = OverlayEditorView.resizedRect(start, handle: .topLeft,
                                                            delta: CGPoint(x: 20, y: 10), bounds: bounds)
            check("拖左上角：原点跟着走，尺寸反向变",
                  fromTopLeft.origin == CGPoint(x: 120, y: 110)
                  && fromTopLeft.width == 280 && fromTopLeft.height == 190)

            let leftOnly = OverlayEditorView.resizedRect(start, handle: .right,
                                                         delta: CGPoint(x: -50, y: 999), bounds: bounds)
            check("拖右边缘：只有宽度变", leftOnly.width == 250 && leftOnly.height == 200)

            let squashed = OverlayEditorView.resizedRect(start, handle: .bottomRight,
                                                         delta: CGPoint(x: -999, y: -999), bounds: bounds)
            check("缩到极限仍有 40×40", squashed.width >= 40 && squashed.height >= 40)

            let overflow = OverlayEditorView.resizedRect(start, handle: .bottomRight,
                                                         delta: CGPoint(x: 5000, y: 5000), bounds: bounds)
            check("拖出屏幕会被夹住",
                  overflow.maxX <= bounds.maxX && overflow.maxY <= bounds.maxY)

            // AppKit 左下原点 → 整屏像素左上原点
            let display = CGRect(x: 0, y: 0, width: 200, height: 150)
            let px = OverlayEditorController.pixelRect(for: CGRect(x: 10, y: 20, width: 50, height: 40),
                                                       displayFrame: display, pixelScale: 2)
            check("屏幕框 → 像素矩形（y 轴翻转）",
                  px == CGRect(x: 20, y: 180, width: 100, height: 80))

            // AppKit 的 y=0 是屏幕**底边**，换算到图像里应该是最大 y，别镜像
            let bottom = OverlayEditorController.pixelRect(for: CGRect(x: 0, y: 0, width: 20, height: 10),
                                                           displayFrame: display, pixelScale: 1)
            check("贴屏幕底边的框像素 y = 屏高 − 高",
                  bottom.minY == 140 && bottom.height == 10)
            let top = OverlayEditorController.pixelRect(for: CGRect(x: 0, y: 140, width: 20, height: 10),
                                                        displayFrame: display, pixelScale: 1)
            check("贴屏幕顶边的框像素 y = 0", top.minY == 0)
        }

            print(failures == 0 ? "\n全部通过" : "\n\(failures) 项失败")
            return failures == 0 ? 0 : 1
        }
    }

    // ── 工具 ──

    /// 合成一张"网页"：8×8 随机灰块铺满 + 周期性"文字行" + 逐行细节。
    ///
    /// 🔴 逐行细节（每行一条 1 像素高的随机短线）不是装饰，是必需的：
    /// 8×8 纯色块里连续 8 行完全一样，而对齐采样是"每 6 行取一行"，
    /// 于是 d 和 d+1 会采到同一块里同样的字节，得分**完全相等**——
    /// 1.0.5 调试时就被这个假象骗了，看着像"算法差 1 像素"，
    /// 其实真值 d 的 mad 就是 0，只是并列时取了小者。真实网页有抗锯齿、
    /// 有半像素的笔画，绝不会 8 行一模一样，所以夹具必须有逐行变化。
    private static func syntheticPage(width: Int, height: Int) -> CGImage? {
        guard let ctx = CGContext(data: nil, width: width, height: height,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                    | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))

        var seed: UInt64 = 0x9E37_79B9_7F4A_7C15
        func next() -> UInt64 {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return seed >> 33
        }

        var y = 0
        while y < height {
            var x = 0
            while x < width {
                let shade = Double(next() % 200) / 255.0
                ctx.setFillColor(CGColor(red: shade, green: shade, blue: shade, alpha: 1))
                ctx.fill(CGRect(x: x, y: y, width: 8, height: 8))
                x += 8
            }
            y += 8
        }

        // "文字行"：每 16 行一条，左端缩进随行号变化，避免整页强周期
        ctx.setFillColor(CGColor(gray: 0.12, alpha: 1))
        var lineY = 0
        while lineY < height {
            let indent = CGFloat((lineY * 7) % 40)
            ctx.fill(CGRect(x: indent, y: CGFloat(lineY), width: CGFloat(width) - 60 - indent, height: 2))
            lineY += 16
        }

        // 逐行细节：每行一条 1 像素高的随机短线（模拟文字笔画 / 抗锯齿的逐行差异）
        for row in 0..<height {
            let shade = Double(next() % 180) / 255.0
            ctx.setFillColor(CGColor(red: shade, green: shade, blue: shade, alpha: 1))
            let start = Int(next() % UInt64(max(1, width - 120)))
            let len = 12 + Int(next() % 100)
            ctx.fill(CGRect(x: CGFloat(start), y: CGFloat(row),
                            width: CGFloat(min(len, width - start)), height: 1))
        }
        return ctx.makeImage()
    }

    /// 把合成页面当成"一块瓷砖"按 period 高度重复，做成严格等距重复的长页
    /// （模拟等行高的表格 / 列表：第 0 行和第 100 行长得一模一样）
    /// 中频条纹测试页：8px 明暗横带（模拟 UI 的行 / 文字行）+ 轻微垂直渐变。
    /// 停在半像素时只有带边缘附近的行带重采样误差，正确偏移的 mad 依然很小；
    /// 纯渐变页太平（所有偏移 mad 都趋零、分离度不足），噪声页又太尖（半像素
    /// 直接上百），都造不出"真实 UI 停在半像素"的形态。
    private static func smoothPage(width: Int, height: Int) -> CGImage? {
        guard let ctx = CGContext(data: nil, width: width, height: height,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                    | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
        var y = 0
        while y < height {
            // 5px 周期的横带（3 亮 2 暗）：周期必须与精修行距（≈6）互质，
            // 否则采样行永远落在同一相位，正确 d 与相邻 d 打平、拼界靠先到者
            let band: CGFloat = (y % 5) < 3 ? 0.72 : 0.28
            let tilt = 0.1 * Double(y) / Double(max(1, height - 1))
            let shade = band - CGFloat(tilt)
            ctx.setFillColor(CGColor(red: shade, green: shade, blue: shade, alpha: 1))
            ctx.fill(CGRect(x: 0, y: CGFloat(y), width: CGFloat(width), height: 1))
            y += 1
        }
        // 每 90px 一条 4px 深色"文字行"：8px 横带自身有周期歧义（137±8k 全都像），
        // 90 与 8 不通约，错周期的候选会被文字行杀掉
        ctx.setFillColor(CGColor(gray: 0.08, alpha: 1))
        var line = 90
        while line < height - 4 {
            ctx.fill(CGRect(x: 0, y: CGFloat(line), width: CGFloat(width), height: 4))
            line += 90
        }
        return ctx.makeImage()
    }

    private static func periodicPage(width: Int, height: Int, period: Int) -> CGImage? {
        guard let tile = syntheticPage(width: width, height: period),
              let ctx = CGContext(data: nil, width: width, height: height,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                    | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
        var y = 0
        while y < height {
            ctx.draw(tile, in: CGRect(x: 0, y: CGFloat(y), width: CGFloat(width), height: CGFloat(period)))
            y += period
        }
        return ctx.makeImage()
    }

    /// 两张同尺寸图里"明显不同"的像素占比
    private static func pixelMismatchRatio(_ a: CGImage, _ b: CGImage, tolerance: Int) -> Double {
        guard a.width == b.width, a.height == b.height,
              let da = pixelBytes(a), let db = pixelBytes(b) else { return 1 }
        var bad = 0
        var index = 0
        while index + 2 < da.count {
            let dr = abs(Int(da[index]) - Int(db[index]))
            let dg = abs(Int(da[index + 1]) - Int(db[index + 1]))
            let dbl = abs(Int(da[index + 2]) - Int(db[index + 2]))
            if max(dr, dg, dbl) > tolerance { bad += 1 }
            index += 4
        }
        let total = da.count / 4
        return total > 0 ? Double(bad) / Double(total) : 1
    }

    private static func pixelBytes(_ image: CGImage) -> [UInt8]? {
        let w = image.width, h = image.height
        guard w > 0, h > 0,
              let ctx = CGContext(data: nil, width: w, height: h,
                                  bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                    | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let data = ctx.data else { return nil }
        let ptr = data.bindMemory(to: UInt8.self, capacity: w * h * 4)
        return Array(UnsafeBufferPointer(start: ptr, count: w * h * 4))
    }

    private static func solidImage(width: Int, height: Int, color: CGColor) -> CGImage {
        let ctx = CGContext(data: nil, width: width, height: height,
                            bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
        ctx.setFillColor(color)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()!
    }
}

private extension String {
    var bytes: [UInt8] { Array(utf8) }
}
