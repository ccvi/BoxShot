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

        // ── 颜色面板落位（1.0.10：贴在工具条下面，6 个颜色）──
        do {
            let visible = CGRect(x: 0, y: 0, width: 1710, height: 1077)
            let panelSize = CGSize(width: 200, height: 48)
            check("调色板正好 6 个颜色", OverlayEditorController.colorPalette.count == 6)

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
            let white = solidImage(width: 40, height: 40, color: CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
            let hl = AnnotationShape(tool: .highlight,
                                     points: [CGPoint(x: 5, y: 5), CGPoint(x: 35, y: 35)],
                                     color: .red, lineWidth: 0)
            let out = EditorRenderer.render(base: white, shapes: [hl], effects: EffectImages(base: white))
            let px = out.flatMap { EditorDocument(image: $0).pixelColor(at: CGPoint(x: 20, y: 20)) }
            check("高亮块真的把区域染了色",
                  px != nil && px!.green < 0.9 && px!.blue < 0.9)
            let outside = out.flatMap { EditorDocument(image: $0).pixelColor(at: CGPoint(x: 2, y: 2)) }
            check("高亮块不越出拖出来的矩形",
                  outside != nil && outside!.green > 0.95)
            check("高亮点得中（命中测试）",
                  hl.hitTest(CGPoint(x: 20, y: 20)) && !hl.hitTest(CGPoint(x: 60, y: 60)))
        }

        // ── 取景框档位 ──
        do {
            // 用户口径（1.0.9 修订）：绝对值 大 170 / 中 150 / 小 140
            check("取景框大 = 170pt", CameraBubbleSize.large.side == 170)
            check("取景框中 = 150pt", CameraBubbleSize.medium.side == 150)
            check("取景框小 = 140pt", CameraBubbleSize.small.side == 140)
            check("取景框三档递增", CameraBubbleSize.small.side < CameraBubbleSize.medium.side
                  && CameraBubbleSize.medium.side < CameraBubbleSize.large.side)
            check("取景框三档标题是 大/中/小",
                  CameraBubbleSize.large.title == "大"
                  && CameraBubbleSize.medium.title == "中"
                  && CameraBubbleSize.small.title == "小")
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

        // ── GIF 帧序列编码（1.0.4）──
        do {
            let frames = (0..<3).map { index in
                solidImage(width: 32, height: 32,
                           color: CGColor(srgbRed: 0, green: Double(index) / 4, blue: 1, alpha: 1))
            }
            let url = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("boxshot-selftest.gif")
            try? FileManager.default.removeItem(at: url)
            RecorderController.writeGIF(frames: frames, interval: 0.1, to: url)
            let count = CGImageSourceCreateWithURL(url as CFURL, nil).map { CGImageSourceGetCount($0) } ?? 0
            check("GIF 写出 3 帧（实际 \(count)）", count == 3)
            try? FileManager.default.removeItem(at: url)
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
