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
            var hint: Int?
            var foundOffsets: [Int] = []
            var failureNotes: [String] = []
            // 生产路径用的是增量画布（只画新增行），不是 append 整幅重绘
            let firstFrame = lastFrame
            let stitch = ImageStitch.StitchCanvas(width: 480)
            if let firstFrame { _ = stitch?.start(firstFrame) }
            check("增量画布建得起来", stitch?.segments == 1)

            for step in steps {
                visitY += step
                guard let bottom = page.cropping(to: CGRect(x: 0, y: visitY, width: 480, height: viewH)),
                      let top = lastFrame else {
                    failureNotes.append("第 \(step) 段取帧失败")
                    break
                }
                guard let alignment = ImageStitch.align(top: top, bottom: bottom, hint: hint) else {
                    failureNotes.append("第 \(step) 段没对齐")
                    break
                }
                foundOffsets.append(alignment.offset)
                guard stitch?.append(bottom, offset: alignment.offset) == true else {
                    failureNotes.append("第 \(step) 段拼接失败")
                    break
                }
                lastFrame = bottom
                hint = alignment.offset
            }

            check("每段偏移都精确等于滚动量（\(foundOffsets) vs \(steps)）",
                  failureNotes.isEmpty && foundOffsets == steps)
            if !failureNotes.isEmpty { print("    ↳ \(failureNotes.joined(separator: "；"))") }

            let expectedHeight = visitY + viewH
            check("拼接总高度正确（\(stitch?.height ?? -1) vs \(expectedHeight)）",
                  stitch?.height == expectedHeight)

            let accumulated = stitch?.image()
            if let acc = accumulated,
               let expected = page.cropping(to: CGRect(x: 0, y: 0, width: 480, height: expectedHeight)) {
                let diff = pixelMismatchRatio(acc, expected, tolerance: 3)
                check(String(format: "拼接结果与源页面逐像素一致（坏点 %.4f%%）", diff * 100), diff < 0.001)
            } else {
                check("拼接结果与源页面逐像素一致（取图失败）", false)
            }

            // 🔴 性能重构的正确性门：增量画布必须和"整幅重绘"的参考实现逐像素一致。
            // 光测"跟源页面像"抓不到"少画了几行"这类错 —— 高度对、内容整体偏移一像素
            // 也能混过去；跟参考实现对照才锁得住。
            var reference: CGImage? = firstFrame
            var refY = 0
            for step in steps {
                refY += step
                guard let bottom = page.cropping(to: CGRect(x: 0, y: refY, width: 480, height: viewH)),
                      let top = reference,
                      let joined = ImageStitch.append(bottom: bottom, to: top, offset: step) else {
                    reference = nil
                    break
                }
                reference = joined
            }
            if let reference, let accumulated {
                let diff = pixelMismatchRatio(reference, accumulated, tolerance: 0)
                check(String(format: "增量画布与参考实现逐像素一致（坏点 %.4f%%）", diff * 100),
                      diff < 0.0001)
                check("增量画布与参考实现同高（\(reference.height) vs \(accumulated.height)）",
                      reference.height == accumulated.height)
            } else {
                check("增量画布与参考实现逐像素一致（取图失败）", false)
            }

            // 扩容边界：初始容量 1024 行，上面 1173 行一定跨过一次扩容，
            // 跨过之后早期内容不能丢、也不能错位（上面那条逐像素已经锁住，这条守尺寸）
            check("扩容后宽度不变（480）", accumulated?.width == 480)

            // 没滚动（offset = 0）时高度不能变
            if let flat = ImageStitch.StitchCanvas(width: 480), let firstFrame, flat.start(firstFrame) {
                _ = flat.append(firstFrame, offset: 0)
                check("offset=0 不增加高度（\(flat.height)）", flat.height == viewH)
            } else {
                check("offset=0 不增加高度（建画布失败）", false)
            }

            // 超长必须拒绝，不能把画布吃到内存崩掉
            if let capped = ImageStitch.StitchCanvas(width: 480, limit: 1100),
               let firstFrame, capped.start(firstFrame) {
                check("超过行数上限时拒绝追加", capped.append(firstFrame, offset: 900) == false)
            } else {
                check("超过行数上限时拒绝追加（建画布失败）", false)
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

            // 白底稀疏页面（真实网页的样子）：完美解不许被"分离度"误杀（1.0.26）。
            // 旧门比的是窗口内均值（±7px 里每个偏移都"挺像"），mad=0 的完美解
            // 也拉不开 8 的差距 → 慢速滚动频繁提示"这一帧没对上"。
            if let sparse = sparseTextPage(width: 480, height: 1200),
               let spTop = sparse.cropping(to: CGRect(x: 0, y: 0, width: 480, height: viewH)),
               let spBottom = sparse.cropping(to: CGRect(x: 0, y: 137, width: 480, height: viewH)) {
                let r = ImageStitch.align(top: spTop, bottom: spBottom)
                check("白底稀疏页面也能对上（\(r?.offset.description ?? "nil")）", r?.offset == 137)
                check("页面没动判成相同", ImageStitch.isNearlyIdentical(spTop, spTop))
                check("页面滚了就判成不同", !ImageStitch.isNearlyIdentical(spTop, spBottom))
            } else {
                check("白底稀疏页面造图失败", false)
            }

            // 取景框几何：选区必须**整个**落在面板的透明区里。
            // 1.0.5 的血案是面板盖在选区上还画了预览，抓帧把自己拍进去了。
            let region = NSRect(x: 300, y: 200, width: 480, height: 500)
            let inset = ScrollFrameView.panelInset
            let panel = ScrollCaptureController.panelRect(forRegion: region)
            check("取景框面板把选区包在透明区里（四周留 panelInset，上方再加状态带）",
                  panel.minX == region.minX - inset
                    && panel.maxX == region.maxX + inset
                    && panel.minY == region.minY - inset
                    && panel.maxY == region.maxY + ScrollFrameView.bandHeight + inset)

            let probe = ScrollFrameView(frame: NSRect(x: 0, y: 0,
                                                      width: region.width + inset * 2,
                                                      height: region.height + ScrollFrameView.bandHeight + inset * 2))
            let inner = probe.regionRect
            check("视图里的选区矩形与传入的选区一致",
                  inner.width == region.width && inner.height == region.height)
            // 🔴 手柄必须整颗在选区外：面板盖在选区上，画在里侧会被抓进基准帧
            let half = ScrollFrameView.gripSide / 2
            let gripsOutside = ScrollFrameView.gripCenters(in: inner).allSatisfy { _, c in
                c.x + half <= inner.minX || c.x - half >= inner.maxX
                    || c.y + half <= inner.minY || c.y - half >= inner.maxY
            }
            check("8 颗调整手柄都在选区外（不会被拍进画面）", gripsOutside)
            check("手柄也都在面板范围内",
                  ScrollFrameView.gripCenters(in: inner).allSatisfy { _, c in
                      c.x - half >= 0 && c.x + half <= probe.bounds.width
                          && c.y - half >= 0 && c.y + half <= probe.bounds.height
                  })
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

        // ── 尺寸 / 操作提示的落位（用户 2026-11-06：「默认在框上面显示，上面没位置了
        //    才到框下面」）。视图坐标是翻转的（y 往下长），所以"上面"是比 minY 更小的 y。
        do {
            let box: CGFloat = 22      // 11pt 字号 + 上下各 4pt 内边距
            let gap: CGFloat = 10
            // 选区在屏幕中间：提示整块落在选区上方，且不压到选区
            let middle = CGRect(x: 100, y: 400, width: 300, height: 200)
            let aboveY = RegionSelector.OverlayView.hintOriginY(selection: middle, boxHeight: box)
            check("提示默认在选区**上面**", aboveY + box <= middle.minY)
            check("提示与选区之间留 10pt 间隙", abs(middle.minY - (aboveY + box) - gap) < 0.01)
            // 选区贴着屏幕顶（minY=12 放不下 22+10）：落到框下面
            let huggingTop = CGRect(x: 100, y: 12, width: 300, height: 200)
            let belowY = RegionSelector.OverlayView.hintOriginY(selection: huggingTop, boxHeight: box)
            check("上面放不下才落到选区下面",
                  belowY == huggingTop.maxY + gap && belowY > huggingTop.maxY)
            // 临界点：minY 刚好 8(topMargin)+10(gap)+22(box) = 40 时仍在上面；
            // 少 1pt 就翻到下面 —— 边界写错会让提示半截被屏幕顶切掉
            let exact = CGRect(x: 0, y: 40, width: 100, height: 100)
            check("顶边刚好够放时仍然在上面",
                  RegionSelector.OverlayView.hintOriginY(selection: exact, boxHeight: box) == 8)
            let oneLess = CGRect(x: 0, y: 39, width: 100, height: 100)
            check("差 1pt 放不下就翻到下面",
                  RegionSelector.OverlayView.hintOriginY(selection: oneLess, boxHeight: box)
                    == oneLess.maxY + gap)
        }

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
            check("缩略图尺寸 180×700", size.width == 180 && size.height == 700)
            // 预览位图宽度必须跟着面板宽度走，否则 200 宽的框里贴 180 宽的图会发虚
            check("缩略图画布宽度与面板同宽", ScrollCaptureController.previewWidth == Int(size.width))

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

            // 铺满后整幅缩放（1.0.25）：长图高度贴框、宽度按比例缩小；没铺满照旧宽度铺满
            let fit = ScrollCaptureController.previewDocumentSize(imageWidth: 720, imageHeight: 2400,
                                                                  viewWidth: 178, viewHeight: 573)
            check("铺满后高度贴框宽度跟着缩",
                  abs(fit.height - 573) < 0.5 && abs(fit.width - 573.0 * 720.0 / 2400.0) < 0.5)
            let notFull = ScrollCaptureController.previewDocumentSize(imageWidth: 720, imageHeight: 300,
                                                                      viewWidth: 178, viewHeight: 573)
            check("没铺满照旧按宽度铺满",
                  abs(notFull.width - 178) < 0.5 && abs(notFull.height - 178.0 * 300.0 / 720.0) < 0.5)
            let square = ScrollCaptureController.previewDocumentSize(imageWidth: 500, imageHeight: 500,
                                                                     viewWidth: 178, viewHeight: 573)
            check("正方形按宽度铺满且不超高",
                  abs(square.width - 178) < 0.5 && square.height <= 573)

            // 滚动开始前可调选区（1.0.28）：夹进屏幕 + 最小边长
            let clampVisible = CGRect(x: 0, y: 0, width: 1000, height: 800)
            let over = ScrollCaptureController.clampRegion(
                CGRect(x: 900, y: 700, width: 400, height: 300), visible: clampVisible)
            check("拖出屏幕右下会被夹回来",
                  over.maxX <= clampVisible.maxX && over.maxY <= clampVisible.maxY)
            check("夹回来时尺寸不被改小", over.width == 400 && over.height == 300)
            let tiny = ScrollCaptureController.clampRegion(
                CGRect(x: 100, y: 100, width: 10, height: 12), visible: clampVisible)
            check("缩得比下限还小就抬到 80",
                  tiny.width == ScrollCaptureController.minRegionSide
                  && tiny.height == ScrollCaptureController.minRegionSide)
            let offTopLeft = ScrollCaptureController.clampRegion(
                CGRect(x: -200, y: -100, width: 500, height: 400), visible: clampVisible)
            check("拖出左上会被夹回原点", offTopLeft.minX == 0 && offTopLeft.minY == 0)
            check("选区下限是 80", ScrollCaptureController.minRegionSide == 80)

            // 触摸板距离抓帧（1.0.25）：触发距离 = 区域高 × 0.4，再矮也不低于 48pt
            check("距离抓帧按区域高四成",
                  ScrollCaptureController.motionCaptureDistance(regionHeight: 500) == 200)
            check("距离抓帧有 48pt 下限",
                  ScrollCaptureController.motionCaptureDistance(regionHeight: 60) == 48)
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

        // ── 工具条可拖动（1.0.29 用户口径：录屏工具条跟截图工具条一样能拖）──
        do {
            let size = CGSize(width: 602, height: 58)
            let container = RecordToolbarController.makeToolbarContainer(size: size)
            // 改回裸 NSView 不会报任何错，只有用户手上一试才发现拖不动 —— 所以按类型钉住
            check("录屏工具条容器是可拖的那个类（不是裸 NSView）",
                  container.isKind(of: DraggableToolbarContainer.self))
            check("录屏工具条容器：实底 + 圆角 14 + 图层开启",
                  container.wantsLayer
                    && abs((container.layer?.cornerRadius ?? 0) - 14) < 0.01
                    && container.layer?.backgroundColor == ToolbarTheme.background.cgColor)
            check("容器尺寸跟着工具条内容走（602 × 58）", container.frame.size == size)

            // 拖动语义：按下 → 交给窗口的 performDrag（跟系统窗口拖动同一套）。
            // 假窗口把 performDrag 截下来，不进拖动循环，所以脱离界面也能验。
            let probe = DragProbeWindow()
            probe.contentView = container
            var dragCallbacks = 0
            container.onDrag = { dragCallbacks += 1 }
            let event = NSEvent.mouseEvent(with: .leftMouseDown, location: .zero,
                                           modifierFlags: [], timestamp: 0,
                                           windowNumber: probe.windowNumber, context: nil,
                                           eventNumber: 1, clickCount: 1, pressure: 1)
            check("能造出鼠标按下事件（造不出就没法验拖动）", event != nil)
            if let event {
                container.mouseDown(with: event)
                check("按下工具条把拖动交给窗口（performDrag 收到 1 次）",
                      probe.dragCount == 1)
                check("拖过一次会回调 onDrag（切全屏时靠它不再弹回中间）",
                      dragCallbacks == 1)
            }
        }

        // ── 颜色面板落位（1.0.10：贴在工具条下面，6 个颜色）──
        do {
            let visible = CGRect(x: 0, y: 0, width: 1710, height: 1077)
            let panelSize = CGSize(width: 200, height: 48)
            // 2026-11-04 用户口径「颜色增加一个色：黑色」→ 六色后面补黑，共 7 个
            check("调色板正好 7 个颜色（六色 + 黑）",
                  OverlayEditorController.colorPalette.count == 7)
            check("色卡是 黄绿蓝红橙紫黑 七色（含色值）",
                  OverlayEditorController.colorPalette.map { $0.hexString }
                    == ["#F8CE43", "#62C563", "#3887FB", "#EB4259", "#F3933D", "#BD3DDD", "#000000"])
            // 美化背景的纯色预设本来是"色卡 + 白 + 黑 + 灰"，黑色进了调色板之后
            // 不能出现两个一模一样的黑块 —— 靠 filter 去重，这条盯着它
            check("美化预设里没有重复色（黑只出现一次）",
                  Set(BeautifyOptions.solidPresets.map { $0.hexString }).count
                    == BeautifyOptions.solidPresets.count)

            // ── 菜单栏图标（1.0.32 用户口径：实际画出来的图形要 16×16 pt）──
            // 钉的是"墨迹"而不是 `image.size`：设 size = 18×18 时墨迹只有 14×16，
            // 图形自带内边距，光看 size 会以为已经对了。
            if let icon = StatusItemController.menuBarIcon() {
                let ink = SelfTest.inkBounds(icon)
                check("菜单栏图标墨迹 16×16 pt（实测 \(ink.width)×\(ink.height)）",
                      abs(ink.width - 16) <= 0.5 && abs(ink.height - 16) <= 0.5)
                // 画布要跟着墨迹走：pointSize 16 → 20×18，菜单栏 35pt 高绰绰有余
                check("图标画布不超过墨迹 + 4pt（实际 \(icon.size.width)×\(icon.size.height)）",
                      icon.size.width <= 20 && icon.size.height <= 20)
            } else {
                check("取不到 camera.viewfinder 这个 SF Symbol", false)
            }
            check("色块是圆形（圆角取半径）", OverlayEditorController.swatchSide > 0)
            // 用户口径：1.0.10「小 20%」→ 1.0.11「再小 10%」：26 × 0.8 × 0.9 = 18.72。
            // 钉死数字，防止以后谁手滑又调回 26
            check("色块直径 18.72pt（26 的 80% 再 90%）",
                  abs(OverlayEditorController.swatchSide - 18.72) < 0.01)
            check("分隔线跟着色块一起缩（不高于色块）",
                  OverlayEditorController.colorPanelDividerHeight <= OverlayEditorController.swatchSide)

            // 粗细档位：用户 2026-11-04「改为一共 5 项：3 / 6 / 9 / 12 / 15 px」，
            // 随后「把这个做成下拉选项，并注明多少 px，默认落在最近选择的档位上」。
            check("粗细五档是 3 / 6 / 9 / 12 / 15 px",
                  OverlayEditorController.lineWidthOptions == [3, 6, 9, 12, 15])
            check("下拉标题注明 px（\(OverlayEditorController.lineWidthTitle(12))）",
                  OverlayEditorController.lineWidthTitle(12) == "12 px"
                    && OverlayEditorController.lineWidthTitle(3) == "3 px")
            // 形状上的线宽可能是编辑窗口滑杆调出来的 7 / 12.5，取最近一档而不是精确匹配
            check("线宽取最近档位（7 → 第 2 档 6px）",
                  OverlayEditorController.lineWidthIndex(for: 7) == 1)
            check("线宽超范围时夹到两端",
                  OverlayEditorController.lineWidthIndex(for: 0) == 0
                    && OverlayEditorController.lineWidthIndex(for: 999) == 4)
            // 「默认落在最近选择的档位上」：存在 UserDefaults，跨启动还在
            let widthSuite = "com.pcxx.boxshot.selftest.linewidth"
            let widthDefaults = UserDefaults(suiteName: widthSuite)!
            widthDefaults.removePersistentDomain(forName: widthSuite)
            // 历史默认 4px 不在档位表里 → 落到最近的一档（3px）；
            // 下拉显示的东西必须就是实际线宽，不能"显示 3px 实际画 4px"
            check("没选过时落到最近的 3px 档",
                  OverlayEditorController.rememberedLineWidth(widthDefaults) == 3)
            OverlayEditorController.rememberLineWidth(12, widthDefaults)
            check("记住的档位读得回来",
                  OverlayEditorController.rememberedLineWidth(widthDefaults) == 12)
            // 存进去的值不在档位表里（老版本存的 12.5 之类）→ 取最近的一档
            widthDefaults.set(12.5, forKey: OverlayEditorController.lastLineWidthKey)
            check("存的不是档位值时取其最近一档",
                  OverlayEditorController.rememberedLineWidth(widthDefaults) == 12)
            widthDefaults.removePersistentDomain(forName: widthSuite)

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

        // ── 字号下拉 6 档（2026-11-03 用户口径「分 6 个档」）──
        do {
            let options = OverlayEditorController.fontSizeOptions
            check("字号正好 6 档（实际 \(options.count)）", options.count == 6)
            check("字号档位严格递增（\(options.map { Int($0) })）",
                  zip(options, options.dropFirst()).allSatisfy { $0 < $1 })
            // 默认值必须在档位里：否则下拉会显示成"没选中"，用户看一眼以为控件是坏的
            check("默认字号 30 是其中一档", options.contains(EditorDocument(image: solidImage(width: 8, height: 8, color: CGColor(gray: 0.5, alpha: 1))).fontSize))
            check("字号落在一个合理的范围（最小 ≥ 12、最大 ≤ 120）",
                  (options.first ?? 0) >= 12 && (options.last ?? 0) <= 120)
            // 像素 ↔ 点的浮点误差不该影响"显示第几档"
            check("字号取最近档：30→2、31→2、38→3",
                  OverlayEditorController.fontSizeIndex(for: 30) == 2
                    && OverlayEditorController.fontSizeIndex(for: 31) == 2
                    && OverlayEditorController.fontSizeIndex(for: 38) == 3)
            check("字号超出范围时夹到首尾档",
                  OverlayEditorController.fontSizeIndex(for: 4) == 0
                    && OverlayEditorController.fontSizeIndex(for: 400) == options.count - 1)
        }

        // ── 编辑窗口与截图浮层的字号同源（1.0.27 用户口径「两个文字功能不一致」）──
        // 用户原话是"编辑工具的输入文字功能跟截图工具条的输入文字功能不一致，
        // 也没有调整文字大小的功能"。档位和换算一旦各写一份，下次改一边就又不一致了。
        do {
            check("编辑窗口与浮层共用同一份字号档位",
                  EditorDocument.fontSizeOptions == OverlayEditorController.fontSizeOptions)
            // 2x 屏（fitScale 0.5）下 30pt 必须落成 60px —— 跟浮层
            // `doc.fontSize * pixelScale` 是同一个口径，同一张图在两处编辑字号才对得上
            check("字号 30pt @0.5 → 60px",
                  EditorDocument.pixelFontSize(points: 30, fitScale: 0.5) == 60)
            check("字号 60px @0.5 → 30pt（换算来回一致）",
                  EditorDocument.pointFontSize(pixels: 60, fitScale: 0.5) == 30)
            check("1:1 缩放时点与像素相等",
                  EditorDocument.pixelFontSize(points: 30, fitScale: 1) == 30)
            // 窗口刚建、画布还没量出来时 fitScale = 0，不能除出 inf/nan
            check("fitScale 为 0 也算得出有限值",
                  EditorDocument.pixelFontSize(points: 30, fitScale: 0).isFinite
                    && EditorDocument.pointFontSize(pixels: 60, fitScale: 0).isFinite)
        }

        // ── 字号只作用于文字：选着矩形改字号不该动它、更不该白压一个撤销点 ──
        do {
            let base = solidImage(width: 40, height: 40, color: CGColor(gray: 0.9, alpha: 1))
            let rectShape = AnnotationShape(tool: .rect,
                                            points: [CGPoint(x: 4, y: 4), CGPoint(x: 20, y: 20)],
                                            color: .red, lineWidth: 4)
            let rectDoc = EditorDocument(image: base, shapes: [rectShape])
            rectDoc.selectedID = rectShape.id
            rectDoc.applyToSelected(fontSize: 68)
            check("选着矩形改字号：形状不动、也不压撤销点",
                  rectDoc.shapes[0].fontSize == rectShape.fontSize && !rectDoc.canUndo)

            var textShape = AnnotationShape(tool: .text, points: [CGPoint(x: 4, y: 4)],
                                            color: .red, lineWidth: 0, text: "字", fontSize: 30)
            textShape.fontSize = 30
            let textDoc = EditorDocument(image: base, shapes: [textShape])
            textDoc.selectedID = textShape.id
            textDoc.applyToSelected(fontSize: 68)
            check("选着文字改字号：字号变了且可撤销",
                  textDoc.shapes[0].fontSize == 68 && textDoc.canUndo)
            // 同一个档位再点一次不该再压一个点（"没变化就别记"）
            textDoc.applyToSelected(fontSize: 68)
            textDoc.undo()
            check("重复选同一档不重复压点（撤销一次就回到 30）",
                  textDoc.shapes[0].fontSize == 30)
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

        // ── OCR 两遍策略（1.0.33）：没有汉字的图（公式 / 代码 / 英文界面）
        //    再跑一遍 en-US + 关语言纠正，避免"中文优先"把符号改坏 ──
        // 用户拿一张极限公式图问"怎么识别不了"，实测第一遍给出的是
        // `A -0` / `f（n+An） f（z）` / `Az`，第二遍给出
        // `Ax→0` / `f(x+Ax)-f(x)` / `Ax` —— 箭头和半角括号都回来了。
        do {
            func obs(_ text: String) -> OCREngine.TextObservation {
                OCREngine.TextObservation(text: text, bounds: .zero)
            }
            check("汉字判定：中文为真", OCREngine.hasCJK("识别这段中文"))
            check("汉字判定：英文 / 公式为假", !OCREngine.hasCJK("lim f(x+Ax)"))
            check("全角标点不算汉字", !OCREngine.hasCJK("（ ） －"))

            let primaryFormula = [obs("lim"), obs("A -0"), obs("f（n+An） f（z）"), obs("Az")]
            let asciiFormula = [obs("lim"), obs("Ax→0"), obs("f(x+Ax)-f(x)"), obs("Ax")]
            check("公式图（无汉字）采用第二遍",
                  OCREngine.preferASCIIPass(primary: primaryFormula, ascii: asciiFormula))
            check("有汉字时不换（中文断词靠语言纠正）",
                  !OCREngine.preferASCIIPass(primary: [obs("识别结果"), obs("第二行")],
                                             ascii: [obs("A"), obs("B")]))
            check("第二遍少行时不换（宁可留难看的）",
                  !OCREngine.preferASCIIPass(primary: primaryFormula, ascii: [obs("lim")]))
            check("第二遍为空时不换",
                  !OCREngine.preferASCIIPass(primary: primaryFormula, ascii: []))
        }

        // ── 取景框两套尺寸 + 两种落位（1.0.20 再改版）──
        do {
            // 区域 / 全屏录制：200/150/100（贴右下角）
            check("画中画大 = 200pt", CameraBubbleSize.large.side == 200)
            check("画中画中 = 150pt", CameraBubbleSize.medium.side == 150)
            check("画中画小 = 100pt", CameraBubbleSize.small.side == 100)
            // 摄像头录制：680/600/500（居中）
            check("摄像头大 = 680pt", CameraBubbleSize.large.cameraSide == 680)
            check("摄像头中 = 600pt", CameraBubbleSize.medium.cameraSide == 600)
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
            // 摄像头录制：放得下就按设置的来（大档 680 不能被收成别的数）
            check("录制框里 680 原样落地",
                  CameraBubbleController.fittedSide(wanted: 680, anchor: frame, placement: .centered) == 680)
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

            // 画中画贴右下角：边距**可调**（设置 → 录制 → 取景框边距），默认 30
            let anchor = CGRect(x: 100, y: 200, width: 900, height: 600)
            let bubble = CGSize(width: 150, height: 150)
            let corner = CameraBubbleController.bottomTrailingOrigin(anchor: anchor, size: bubble,
                                                                    inset: 30)
            check("取景框边距默认 30pt", Preferences().recordCameraInset == 30)
            check("画中画右边缝 = 边距", (corner.x + bubble.width) == anchor.maxX - 30)
            check("画中画下边缝 = 边距", corner.y == anchor.minY + 30)
            check("画中画两边缝一样宽",
                  (anchor.maxX - corner.x - bubble.width) == (corner.y - anchor.minY))
            // 换个边距也得跟着走（别在哪条路径上写死某个数）
            let wide = CameraBubbleController.bottomTrailingOrigin(anchor: anchor, size: bubble,
                                                                  inset: 48)
            check("边距 48 就按 48 落",
                  (anchor.maxX - wide.x - bubble.width) == 48 && (wide.y - anchor.minY) == 48)
            // 夹紧：离谱值不会把取景框顶到画面中间
            var clamped = Preferences()
            clamped.recordCameraInset = 200
            let high = clamped.recordCameraInsetPoints
            clamped.recordCameraInset = -5
            let low = clamped.recordCameraInsetPoints
            check("边距夹在 0...80", high == 80 && low == 0)
            check("边距读得回来",
                  (try? JSONDecoder().decode(Preferences.self,
                                             from: Data(#"{"recordCameraInset":42}"#.bytes)))?
                    .recordCameraInset == 42)

            check("摄像头录制默认大 680", Preferences().cameraRecordSize == .large)
            check("摄像头录制尺寸读得回来",
                  (try? JSONDecoder().decode(Preferences.self,
                                             from: Data(#"{"cameraRecordSize":"small"}"#.bytes)))?
                    .cameraRecordSize == .small)

            // 完成即关（设置 → 截图，1.0.24）：默认关；开了之后动作成功就收浮层
            check("完成即关默认是关的", Preferences().closeAfterAction == false)
            check("完成即关读得回来",
                  (try? JSONDecoder().decode(Preferences.self,
                                             from: Data(#"{"closeAfterAction":true}"#.bytes)))?
                    .closeAfterAction == true)
            check("完成即关老配置缺字段回退默认",
                  (try? JSONDecoder().decode(Preferences.self, from: Data("{}".bytes)))?
                    .closeAfterAction == false)
            check("完成即关纯函数跟开关走",
                  OverlayEditorController.shouldCloseAfterAction(enabled: true)
                      && !OverlayEditorController.shouldCloseAfterAction(enabled: false))

            // ── 内存回收（用户 2026-11-05 口径）─────────────────────────
            // 「300MB + 空闲 60 秒就自动触发；30 分钟内最多一次；
            //   24 小时连续 3 次重启后仍超阈值 → 停用。关闭应用再重新打开就重置。」
            // 规则全在 `MemoryGuard` 的纯函数里，时间线靠 `now` 注入推 —— 不真等 30 分钟、
            // 也不真重启进程。真重启那条路由诊断 `--memguard-restart` 端到端验。
            do {
                let t0: TimeInterval = 1_000_000
                check("阈值是 300MB", MemoryGuard.thresholdBytes == 300 * 1024 * 1024)
                check("空闲 60 秒 / 冷却 30 分钟 / 24 小时 3 次 / 窗口 24 小时",
                      MemoryGuard.idleSeconds == 60
                        && MemoryGuard.cooldownSeconds == 30 * 60
                        && MemoryGuard.maxRestarts == 3
                        && MemoryGuard.windowSeconds == 24 * 60 * 60)
                check("设置里默认是开的（用户点名要的常驻能力）",
                      Preferences().autoRestartOnMemory == true)
                check("开关读得回来",
                      (try? JSONDecoder().decode(Preferences.self,
                                                 from: Data(#"{"autoRestartOnMemory":false}"#.bytes)))?
                        .autoRestartOnMemory == false)
                check("老配置缺字段按默认（开）",
                      (try? JSONDecoder().decode(Preferences.self, from: Data("{}".bytes)))?
                        .autoRestartOnMemory == true)
                check("设置文案写明 300MB 与空闲 60 秒",
                      MemoryGuard.settingTitle.contains("300MB")
                        && MemoryGuard.settingNote.contains("60 秒")
                        && MemoryGuard.settingNote.contains("3 次"))

                let over = MemoryGuard.thresholdBytes
                let under = MemoryGuard.thresholdBytes - 1
                func decide(_ footprint: Int64, since: TimeInterval?, at now: TimeInterval,
                            state: MemoryGuard.State = .init(), enabled: Bool = true,
                            busy: Bool = false) -> MemoryGuard.Decision {
                    MemoryGuard.decide(enabled: enabled, busy: busy, footprint: footprint,
                                       candidateSince: since, now: now, state: state)
                }
                check("差 1 字节不算到线", decide(under, since: t0, at: t0 + 600) == .idle)
                check("刚好 300MB 就算到线", decide(over, since: t0, at: t0 + 60) == .restart)
                check("到线但只空闲 59 秒 → 继续等", decide(over, since: t0, at: t0 + 59) == .idle)
                check("到线且空闲满 60 秒 → 重启", decide(over, since: t0, at: t0 + 60) == .restart)
                check("没有连续起算点（刚从忙/低内存出来）不重启",
                      decide(over, since: nil, at: t0) == .idle)
                check("忙着（拉选区 / 编辑 / 录屏）就不动",
                      decide(over, since: t0, at: t0 + 600, busy: true) == .idle)
                check("开关关了就不管",
                      decide(over, since: t0, at: t0 + 600, enabled: false) == .idle)

                // 冷却：30 分钟内最多一次
                let now = t0 + 600
                check("刚重启过 29 分钟 → 还在冷却",
                      decide(over, since: t0, at: now,
                             state: .init(restarts: [now - 1740], lastRestart: now - 1740)) == .idle)
                check("满 30 分钟才允许再来一次",
                      decide(over, since: t0, at: now,
                             state: .init(restarts: [now - 1800], lastRestart: now - 1800)) == .restart)

                // 熔断：24 小时内 3 次之后仍到线 → 停用
                let three = MemoryGuard.State(restarts: [now - 5000, now - 3000, now - 2000],
                                              lastRestart: now - 2000)
                check("24 小时内已 3 次仍到线 → 停用", decide(over, since: t0, at: now,
                                                       state: three) == .disabled)
                // 熔断落成 `disabled = true` 之后，多久都不会再动（否则就成了无限重启）
                var fused = three
                fused.disabled = true
                check("熔断落盘后即使冷却到了也不再重启",
                      decide(over, since: t0, at: now + 100000, state: fused) == .disabled)
                // 24 小时以外的老记录不算数（滚动窗口）
                let stale = MemoryGuard.State(restarts: [now - 90_000, now - 8000],
                                              lastRestart: now - 8000)
                check("24 小时外的重启记录不算数", decide(over, since: t0, at: now,
                                                state: stale) == .restart)

                // 执行一次之后的状态
                let after = MemoryGuard.stateAfterRestart(.init(), now: t0)
                check("重启后记一笔、冷却从这一刻起算、并打上自重启标记",
                      after.restarts == [t0] && after.lastRestart == t0 && after.pendingRelaunch)
                // 起算点都取"60 秒前"，这样空闲那一条不会是拦下来的原因 ——
                // 只留下冷却在起作用，验的才是冷却。（两次都写成同一个 now 会变成
                // "空闲不够"造成的 idle，断言照样过，但什么都没验到。）
                check("重启后 29 分 59 秒内不会再重启",
                      decide(over, since: t0 + 1739, at: t0 + 1799, state: after) == .idle)
                check("重启满 30 分钟才允许第二次",
                      decide(over, since: t0 + 1740, at: t0 + 1800, state: after) == .restart)

                // 落盘 / 读取：计数要活过"自己重开"，但要死于"手动退出后再开"
                let tmp = FileManager.default.temporaryDirectory
                    .appendingPathComponent("boxshot-memguard-selftest.json")
                MemoryGuard.save(.init(restarts: [t0, t0 + 10], lastRestart: t0 + 10,
                                       pendingRelaunch: true), at: tmp)
                let inherited = MemoryGuard.load(at: tmp, now: t0 + 20)
                check("自重启后计数被继承（2 次）",
                      inherited.restartCount(now: t0 + 20) == 2)
                check("继承的同时把自重启标记清掉（否则下次手动退出还会带回来）",
                      inherited.pendingRelaunch == false && inherited.lastRestart == t0 + 10)
                MemoryGuard.save(.init(restarts: [t0, t0 + 10, t0 + 20], lastRestart: t0 + 20,
                                       disabled: true, pendingRelaunch: false), at: tmp)
                check("手动退出再打开 = 规则全部重置（次数、熔断都清零）",
                      MemoryGuard.load(at: tmp, now: t0 + 30) == MemoryGuard.State())
                try? FileManager.default.removeItem(at: tmp)
                check("没有状态文件时是干净的一份",
                      MemoryGuard.load(at: tmp, now: t0) == MemoryGuard.State())

                // 重开命令：绝不能 exec .app 里的二进制（那样菜单栏登记会永久失效）
                check("重开命令走 open、且带延迟",
                      AppModel.relaunchCommand(bundlePath: "/Applications/BoxShot.app",
                                               bundleID: "com.pcxx.boxshot")
                        == "sleep 1; /usr/bin/open \"/Applications/BoxShot.app\"")
                check("裸二进制（诊断 / 自检）按 bundle id 找回安装好的那份",
                      AppModel.relaunchCommand(bundlePath: "/tmp/.build/release/BoxShot",
                                               bundleID: "com.pcxx.boxshot")
                        == "sleep 1; /usr/bin/open -b com.pcxx.boxshot")
                check("重开命令里不出现 Contents/MacOS",
                      !AppModel.relaunchCommand(bundlePath: "/Applications/BoxShot.app",
                                                bundleID: "com.pcxx.boxshot")
                        .contains("Contents/MacOS"))
            }

            // 固定录制框：16:9、居中、不出界、放得下 680 的取景框
            if let screen = NSScreen.main {
                let visible = screen.visibleFrame
                let rect = AppModel.fixedRecordFrame(on: screen)
                check("固定框是 16:9", abs(rect.width / rect.height - 16.0 / 9.0) < 0.02)
                check("固定框居中",
                      abs(rect.midX - visible.midX) <= 1 && abs(rect.midY - visible.midY) <= 1)
                check("固定框不出界",
                      rect.minX >= visible.minX - 1 && rect.maxX <= visible.maxX + 1
                        && rect.minY >= visible.minY - 1 && rect.maxY <= visible.maxY + 1)
                check("固定框放得下 680 的取景框",
                      CameraBubbleController.fittedSide(wanted: 680, anchor: rect, placement: .centered) == 680)
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
            check("马赛克效果图生成", effects.pixelated(covering: nil) != nil)
            check("模糊效果图生成", effects.blurred(covering: nil) != nil)
            // 只铺标注框那块：尺寸必须等于请求的区域，不能偷偷做成整幅
            if let cropped = effects.pixelated(covering: CGRect(x: 8, y: 6, width: 20, height: 14)) {
                check("马赛克按区域裁剪（\(cropped.image.width)×\(cropped.image.height) @ \(Int(cropped.rect.minX)),\(Int(cropped.rect.minY))）",
                      cropped.image.width == 20 && cropped.image.height == 14
                        && cropped.rect.minX == 8 && cropped.rect.minY == 6)
            } else {
                check("马赛克按区域裁剪（生成失败）", false)
            }

            // 🔴 裁剪不能改变像素：整幅效果图里对应的那块，必须和"按区域生成"的那块
            // 逐像素相同。否则用户保存出来的马赛克跟预览不一样（块相位错位）。
            let region = CGRect(x: 8, y: 6, width: 20, height: 14)
            if let full = effects.pixelated(covering: nil)?.image,
               let part = effects.pixelated(covering: region)?.image,
               let fullPart = full.cropping(to: region) {
                let diff = pixelMismatchRatio(fullPart, part, tolerance: 0)
                check(String(format: "马赛克裁剪块与整幅同区域逐像素一致（坏点 %.4f%%）", diff * 100),
                      diff < 0.0001)
            } else {
                check("马赛克裁剪块与整幅同区域逐像素一致（取图失败）", false)
            }
            if let full = effects.blurred(covering: nil)?.image,
               let part = effects.blurred(covering: region)?.image,
               let fullPart = full.cropping(to: region) {
                // 高斯模糊是 GPU 浮点算的，子区域的取整会差 1 级（0…255）。
                // 1 级不可见，2 级以上才是真错了。
                let diff = pixelMismatchRatio(fullPart, part, tolerance: 1)
                check(String(format: "模糊裁剪块与整幅同区域一致（差 >1 级的像素 %.4f%%）", diff * 100),
                      diff < 0.0001)
            } else {
                check("模糊裁剪块与整幅同区域一致（取图失败）", false)
            }

            // 🔴 方向门：纯色图测不出上下翻转（翻过来还是同一个颜色）。
            // 用「上黑下白」的渐变图，取**靠上**那块做马赛克 —— 结果必须是暗的。
            // 取子区域时要翻一次 y（标注左上原点 ↔ CI 左下原点），翻错就是
            // "位置看着对、拿的是另一块"，这种错只有带方向信息的图能钉住。
            if let gradient = gradientImage(width: 40, height: 40) {
                let gradientEffects = EffectImages(base: gradient)
                if let top = gradientEffects.pixelated(covering: CGRect(x: 0, y: 0, width: 40, height: 10))?.image,
                   let bottom = gradientEffects.pixelated(covering: CGRect(x: 0, y: 30, width: 40, height: 10))?.image,
                   let topBytes = pixelBytes(top), let bottomBytes = pixelBytes(bottom) {
                    let topLuma = Int(topBytes[1]), bottomLuma = Int(bottomBytes[1])
                    check("马赛克取的是同一 y 侧（上块 \(topLuma) 暗、下块 \(bottomLuma) 亮）",
                          topLuma + 40 < bottomLuma)
                } else {
                    check("马赛克取的是同一 y 侧（取图失败）", false)
                }
            } else {
                check("马赛克取的是同一 y 侧（造图失败）", false)
            }

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

            // ── 撤销栈上限（1.0.21）：编辑一小时不能无限往上爬 ──
            // 连做 undoLimit + 20 次改动，栈里最多留 undoLimit 步；
            // 并且"最近的 N 步"必须还在（截断只能砍最老的，不能砍新的）。
            let countBefore = doc.shapes.count
            for i in 0..<(EditorDocument.undoLimit + 20) {
                var dot = AnnotationShape(tool: .pen, points: [CGPoint(x: CGFloat(i), y: 0)], color: .red, lineWidth: 2)
                dot.points.append(CGPoint(x: CGFloat(i), y: 1))
                doc.commit(dot)
            }
            var undoSteps = 0
            while doc.canUndo { doc.undo(); undoSteps += 1 }
            check("撤销栈最多留 \(EditorDocument.undoLimit) 步（实际 \(undoSteps)）",
                  undoSteps <= EditorDocument.undoLimit)
            check("撤销到底回到最早的可见状态（形状数 \(doc.shapes.count) ≥ \(countBefore)）",
                  doc.shapes.count >= countBefore)

            // ── 标注的可拖节点（1.0.29 用户口径）──
            // 「截图和编辑时，标注的箭头，矩形，椭圆，直线，有修改的节点可以修改」，
            // 附的样张是矩形四角 + 四边中点共 8 个白色方块。几何全在 AnnotationShape
            // 的 handlePoints / adjusting 里，能脱离界面验，所以钉在这里。
            do {
                // 矩形 (10,20)-(90,70)：宽 80、高 50，中点 x=50 / y=45
                let box = AnnotationShape(tool: .rect,
                                          points: [CGPoint(x: 10, y: 20), CGPoint(x: 90, y: 70)],
                                          color: .red, lineWidth: 3)
                let handles = box.handlePoints
                check("矩形给 8 个节点（四角 + 四边中点）", handles.count == 8)
                check("矩形节点落在该落的位置",
                      handles[0] == CGPoint(x: 10, y: 20) && handles[1] == CGPoint(x: 50, y: 20)
                        && handles[2] == CGPoint(x: 90, y: 20) && handles[3] == CGPoint(x: 90, y: 45)
                        && handles[4] == CGPoint(x: 90, y: 70) && handles[5] == CGPoint(x: 50, y: 70)
                        && handles[6] == CGPoint(x: 10, y: 70) && handles[7] == CGPoint(x: 10, y: 45))

                var oval = box
                oval.tool = .ellipse
                check("椭圆跟矩形共用同一套 8 个节点", oval.handlePoints == handles)

                var straight = box
                straight.tool = .line
                check("直线只给 2 个端点",
                      straight.handlePoints == [CGPoint(x: 10, y: 20), CGPoint(x: 90, y: 70)])
                var arrowShape = straight
                arrowShape.tool = .arrow
                check("箭头同样是 2 个端点", arrowShape.handlePoints == straight.handlePoints)

                var penShape = straight
                penShape.tool = .pen
                var highlightShape = box
                highlightShape.tool = .highlight
                var textShape = box
                textShape.tool = .text
                check("其余工具不给节点（画笔 / 高亮 / 文字）",
                      penShape.handlePoints.isEmpty
                        && highlightShape.handlePoints.isEmpty
                        && textShape.handlePoints.isEmpty)

                // 拖右下角：左上角必须钉住，只有右下跟着鼠标
                let dragCorner = box.adjusting(handle: 4, to: CGPoint(x: 120, y: 100))
                check("拖右下角：左上不动、右下跟手",
                      dragCorner.points[0] == CGPoint(x: 10, y: 20)
                        && dragCorner.points[1] == CGPoint(x: 120, y: 100))

                // 拖左边中点：只改 x，哪怕鼠标 y 甩出去也不该动上下两条边
                let dragEdge = box.adjusting(handle: 7, to: CGPoint(x: 30, y: 999))
                check("拖边中点只改一个轴（y 甩到 999 也不动）",
                      dragEdge.points[0] == CGPoint(x: 30, y: 20)
                        && dragEdge.points[1] == CGPoint(x: 90, y: 70))

                // 拖过对角：翻面后必须还是正矩形。负宽高渲染出来是空白的，
                // 所以 min/max 归一这一步不能省。
                let flipped = box.adjusting(handle: 4, to: CGPoint(x: 0, y: 0))
                check("拖过对角翻面也不出负宽高",
                      flipped.points[0] == CGPoint(x: 0, y: 0)
                        && flipped.points[1] == CGPoint(x: 10, y: 20))

                // 从左下往右上拖出来的框（点序反的）节点位置必须一致
                var reversed = box
                reversed.points = [CGPoint(x: 90, y: 70), CGPoint(x: 10, y: 20)]
                check("反向拖出来的框，节点位置一致", reversed.handlePoints == handles)

                check("节点判命中：偏 7px 抓住、偏 11px 不抓",
                      box.handleIndex(near: CGPoint(x: 15, y: 25), tolerance: 8) == 0
                        && box.handleIndex(near: CGPoint(x: 40, y: 40), tolerance: 8) == nil)

                // 翻面后继续按住同一个下标拖：动的仍然是"当初那个角"。
                // 这就是两处 UI 都记 origin、不按当前形状累加的理由。
                let overCorner = box.adjusting(handle: 0, to: CGPoint(x: 150, y: 150))
                check("拖过对角后，原左上角仍跟手（翻面不换角）",
                      overCorner.points[0] == CGPoint(x: 90, y: 70)
                        && overCorner.points[1] == CGPoint(x: 150, y: 150))

                // 拖节点要能撤销：adjustSelected 走 beginMoveSelected / endMoveSelected
                let nodeBase = solidImage(width: 120, height: 90, color: CGColor(gray: 0.9, alpha: 1))
                let nodeDoc = EditorDocument(image: nodeBase)
                nodeDoc.shapes = [box]
                nodeDoc.selectedID = box.id
                nodeDoc.beginMoveSelected()
                nodeDoc.adjustSelected(handle: 4, to: CGPoint(x: 110, y: 80), from: box)
                nodeDoc.endMoveSelected()
                check("拖节点后形状变了", nodeDoc.shapes.first?.points[1] == CGPoint(x: 110, y: 80))
                nodeDoc.undo()
                check("拖节点可撤销回原形状",
                      nodeDoc.shapes.first?.points[1] == CGPoint(x: 90, y: 70))
            }

            // ── 放大镜（1.0.33 用户口径「编辑器加：放大镜，放大倍数 2 倍和 3 倍」）──
            // 语义：points 是取样的**源区域**，画出来的是以它为中心放大 zoom 倍的框；
            // 命中 / 节点 / 选中框全按放大后的框算。几何都是纯函数，能脱离界面验。
            do {
                // 源区域 (100,50)-(200,150)：100×100，中心 (150,100)
                var lens = AnnotationShape(tool: .loupe,
                                           points: [CGPoint(x: 100, y: 50), CGPoint(x: 200, y: 150)],
                                           color: .red, lineWidth: 3)
                check("放大镜默认 2 倍", lens.loupeZoom == 2)
                check("2 倍：输出框 = 源区域 2 倍、与源同心",
                      lens.loupeOutputRect == CGRect(x: 50, y: 0, width: 200, height: 200))
                lens.zoom = 3
                check("3 倍：输出框 = 源区域 3 倍",
                      lens.loupeOutputRect == CGRect(x: 0, y: -50, width: 300, height: 300))
                lens.zoom = 2
                check("放大镜给 8 个节点，且落在放大后的框上",
                      lens.handlePoints.count == 8
                        && lens.handlePoints[0] == CGPoint(x: 50, y: 0))
                // 命中按放大后的框算：源区域之外、输出框之内也算命中
                check("命中按放大后的框算（源区域外但框里也命中）",
                      lens.hitTest(CGPoint(x: 60, y: 10)) && !lens.hitTest(CGPoint(x: 900, y: 900)))
                // 拖右下角到 (450,400)：新框 50,0 → 450,400 共 400×400，源区域 = ÷2
                let stretched = lens.adjusting(handle: 4, to: CGPoint(x: 450, y: 400))
                check("拖节点：源区域按倍数反推（400×400 ÷ 2 = 200×200）",
                      stretched.loupeSourceRect == CGRect(x: 150, y: 100, width: 200, height: 200))
                check("拖节点：放大镜中心不动（250, 200）",
                      stretched.loupeSourceRect?.midX == 250 && stretched.loupeSourceRect?.midY == 200)
                // 倍数要进签名：不然"改倍数"在撤销栈里会被当成没改动
                var zoomed = lens
                zoomed.zoom = 3
                check("倍数进签名（撤销栈去重不会误判）", zoomed.signature != lens.signature)

                // ── 镜面（用户 2026-11-05 追加「矩形 2X，矩形 3X，圆形 2X，圆形 3X」）──
                // 形状与倍数是**正交**的两个字段，界面摊成 4 个组合的下拉。
                check("镜面给两种：矩形 / 圆形",
                      LoupeStyle.allCases == [.rect, .circle])
                check("镜面文案与图标齐全",
                      LoupeStyle.rect.title == "矩形" && LoupeStyle.rect.symbol == "rectangle"
                        && LoupeStyle.circle.title == "圆形" && LoupeStyle.circle.symbol == "circle")
                check("放大镜默认是矩形", lens.loupeStyle == .rect)
                // 矩形：取样就是源区域本身，一点都不裁
                check("矩形取样 = 源区域",
                      lens.loupeSampleRect == CGRect(x: 100, y: 50, width: 100, height: 100))

                // 非正方形源区域 (0,0)-(100,40)：圆形直接塞进圆里只能拉伸或裁边，
                // 所以取短边内切正方形 40×40，中心不动。
                var round = AnnotationShape(tool: .loupe,
                                            points: [CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 40)],
                                            color: .red, lineWidth: 3)
                round.loupeStyle = .circle
                round.zoom = 2
                check("圆形取样 = 短边内切正方形（100×40 → 40×40）",
                      round.loupeSampleRect == CGRect(x: 30, y: 0, width: 40, height: 40))
                check("圆形取样中心不动（50, 20）",
                      round.loupeSampleRect?.midX == 50 && round.loupeSampleRect?.midY == 20)
                check("圆形输出框是正方形（40×40 放大 2 倍 = 80×80）",
                      round.loupeOutputRect == CGRect(x: 10, y: -20, width: 80, height: 80))
                // 方形源区域上，圆形与矩形的取样结果完全一致（不该多裁）
                var squareRound = lens
                squareRound.loupeStyle = .circle
                check("方形源区域上圆形取样不改尺寸",
                      squareRound.loupeSampleRect == lens.loupeSampleRect)
                // 形状要进签名：不然"换镜面"在撤销栈里会被当成没改动
                var recast = lens
                recast.loupeStyle = .circle
                check("镜面进签名（撤销栈去重不会误判）", recast.signature != lens.signature)

                // ── 正圆：拖节点也不能拖成椭圆（用户口径「圆形放大镜是正圆」）──
                // 只靠"取样取短边"能保证画出来是圆，但拖一条边时圆会纹丝不动
                // （源区域变 300×200 → 内切回 200×200），手感像坏掉。
                // out 是 (50,0,200,200)：拖右下角到 (450,300) 时 x 差 400、y 差 300，
                // 取较大者 400 → 正方形 (50,0,400,400)。
                var roundLens = lens
                roundLens.loupeStyle = .circle
                let roundCorner = roundLens.adjusting(handle: 4, to: CGPoint(x: 450, y: 300))
                check("圆形拖角：框仍是正方形（取两个方向里大的那个）",
                      roundCorner.loupeOutputRect == CGRect(x: 50, y: 0, width: 400, height: 400))
                check("圆形拖角：对角固定（左上还是 50,0）",
                      roundCorner.loupeOutputRect?.minX == 50 && roundCorner.loupeOutputRect?.minY == 0)
                // 拖右边缘（节点 3）到 x=400：右边 400、左边固定 50 → 边长 350，
                // 上下以原中心 y=100 对称 → (50, -75, 350, 350)
                let roundEdge = roundLens.adjusting(handle: 3, to: CGPoint(x: 400, y: 999))
                check("圆形拖边：边长跟手（右边缘到 400 → 350）",
                      roundEdge.loupeOutputRect == CGRect(x: 50, y: -75, width: 350, height: 350))
                check("圆形拖边：源区域同步是正方形（175×175）",
                      roundEdge.loupeSourceRect?.width == 175 && roundEdge.loupeSourceRect?.height == 175)
                // 对照组：同样两下拖在矩形镜面上就该是非正方形 —— 否则上面几条证明不了"是圆在起作用"
                let rectEdge = lens.adjusting(handle: 3, to: CGPoint(x: 400, y: 999))
                check("矩形拖边：框跟着变形（对照，不是正方）",
                      rectEdge.loupeOutputRect == CGRect(x: 50, y: 0, width: 350, height: 200))
                // 再拖也回不到"非正方"：任意两点各拖一次都要保持相等
                let roundTwice = roundCorner.adjusting(handle: 1, to: CGPoint(x: 999, y: -40))
                check("圆形连着拖两下仍是正圆",
                      roundTwice.loupeOutputRect.map { $0.width == $0.height } == true)

                // 记忆档位（跟线宽 / 字号同一套口径）
                let zoomSuite = "com.pcxx.boxshot.selftest.loupe"
                let zoomDefaults = UserDefaults(suiteName: zoomSuite)!
                zoomDefaults.removePersistentDomain(forName: zoomSuite)
                check("没选过时是 2×", EditorDocument.rememberedLoupeZoom(zoomDefaults) == 2)
                EditorDocument.rememberLoupeZoom(3, zoomDefaults)
                check("记住的 3× 读得回来", EditorDocument.rememberedLoupeZoom(zoomDefaults) == 3)
                check("没选过镜面时是矩形", EditorDocument.rememberedLoupeStyle(zoomDefaults) == .rect)
                EditorDocument.rememberLoupeStyle(.circle, zoomDefaults)
                check("记住的圆形读得回来", EditorDocument.rememberedLoupeStyle(zoomDefaults) == .circle)
                zoomDefaults.removePersistentDomain(forName: zoomSuite)

                // 只验几何等于没验"画没画出来"：底图是全黑 + 左边缘 3px 白竖条（x 2..5），
                // 源区域取 (0,0)-(10,10) 放大 2 倍 → 输出框 (-5,-5)-(15,15)。
                // 输出里 (0,0) 取到的是源区域的 (2.5,2.5)（白条上），而原图 (0,0) 是黑的；
                // (7,7) 对应源区域 (6,6)（黑）。两条一起才能证明"真的放大且没乱铺"。
                if let base = Self.loupeBaseImage() {
                    let lensDoc = EditorDocument(image: base)
                    var painted = AnnotationShape(tool: .loupe,
                                                  points: [CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 10)],
                                                  color: .red, lineWidth: 0)
                    painted.zoom = 2
                    lensDoc.shapes = [painted]
                    if let rendered = lensDoc.rendered(), let bytes = Self.pixelBytes(rendered) {
                        check("放大镜真的把源区域放大了（(0,0) 取到白条）",
                              Self.brightness(bytes, x: 0, y: 0, width: rendered.width) > 200)
                        check("放大镜不是整块铺白（(7,7) 仍是黑）",
                              Self.brightness(bytes, x: 7, y: 7, width: rendered.width) < 60)
                    } else {
                        check("放大镜能渲染出图", false)
                    }
                } else {
                    check("放大镜验像素用的底图能建出来", false)
                }

                // 「圆形」不能只验几何：椭圆裁切写错（比如仍然走 roundedRect）几何照样对，
                // 但画面会是个矩形。底图 200×200 黑底 + 两块白方块，源区域取左上
                // (0,0)-(100,100)、2 倍放大后输出框 (-50,-50)-(150,150)；椭圆内接于输出框，
                // 所以圆心 (50,50)、半径是 **100**（不是取样半径 50 —— 这里最容易算错）：
                //   · (50,50) 取到源区域正中那块白 (40..60) → 镜内必须有内容
                //   · (140,140) 离圆心 127.3 > 100，在椭圆外、但仍在输出框内（圆角 12，
                //     它的圆角圆心是 (138,138)，(140,140) 距它 2.8 → 算框内）；
                //     它对应的源点是 (95,95)（第二块白 88..100）。
                //     圆形不画 → 留底图黑；(140,140) 本身是黑的，所以圆形下必须是黑。
                // 同一组参数换成矩形就该是白 —— 两条一起才能证明"是形状在起作用"。
                if let styleBase = Self.loupeStyleBaseImage() {
                    for style in LoupeStyle.allCases {
                        let styleDoc = EditorDocument(image: styleBase)
                        var lensShape = AnnotationShape(tool: .loupe,
                                                        points: [CGPoint(x: 0, y: 0),
                                                                 CGPoint(x: 100, y: 100)],
                                                        color: .red, lineWidth: 0)
                        lensShape.zoom = 2
                        lensShape.loupeStyle = style
                        styleDoc.shapes = [lensShape]
                        guard let renderedStyle = styleDoc.rendered(),
                              let styleBytes = Self.pixelBytes(renderedStyle) else {
                            check("放大镜（\(style.title)）能渲染出图", false)
                            continue
                        }
                        check("放大镜（\(style.title)）镜内透出取样内容",
                              Self.brightness(styleBytes, x: 50, y: 50,
                                              width: renderedStyle.width) > 200)
                        let cornerBright = Self.brightness(styleBytes, x: 140, y: 140,
                                                           width: renderedStyle.width)
                        if style == .circle {
                            check("圆形镜面：框角不铺（保持底图黑）", cornerBright < 60)
                        } else {
                            check("矩形镜面：框角同样铺内容（对照组）", cornerBright > 200)
                        }
                    }
                } else {
                    check("放大镜验镜面用的底图能建出来", false)
                }
            }

            // ── 文字原地编辑（所见即所得）的撤销语义 ──
            // 用户口径「输入时就直接看到最终效果，输完确认，之后还能点回来改」。
            // 这套动作全压在三条文档方法上，所以这里只测文档语义，不跑 UI：
            //   1) setLiveText 打字期间**不压栈**（否则敲两行字就把栈刷满，
            //      undoLimit 一截断，之前画的标注全从历史里消失）
            //   2) commitEdit 整段编辑只压**一个**点
            //   3) rollback 连"刚新建的那条空文字"一起回滚
            let editBase = solidImage(width: 120, height: 90, color: CGColor(gray: 0.9, alpha: 1))
            let editDoc = EditorDocument(image: editBase)
            let typeShape = AnnotationShape(tool: .text, points: [CGPoint(x: 10, y: 10)],
                                            color: .black, lineWidth: 0,
                                            text: "A", fontSize: 24)
            editDoc.shapes = [typeShape]
            let editID = typeShape.id
            let editSnapshot = editDoc.shapes
            let widthBefore = editDoc.shapes[0].displayBounds?.width ?? 0

            for typed in ["AB", "ABC", "ABCDEFG"] {
                editDoc.setLiveText(typed, for: editID)
            }
            check("实时改文字不压撤销点", !editDoc.canUndo)
            check("实时改文字后包围盒跟着变宽",
                  (editDoc.shapes.first?.displayBounds?.width ?? 0) > widthBefore)

            editDoc.commitEdit(from: editSnapshot)
            check("整段编辑只压一个撤销点", editDoc.canUndo)
            editDoc.undo()
            check("撤销一次回到编辑前的文字（\(editDoc.shapes.first?.text ?? "nil")）",
                  editDoc.shapes.first?.text == "A")
            check("撤销一步到底（没有残留的中间态）", !editDoc.canUndo)

            // 取消：模拟"点进去、输入、按 Esc"
            let beforeCancel = editDoc.shapes
            let scratch = AnnotationShape(tool: .text, points: [CGPoint(x: 60, y: 60)],
                                          color: .black, lineWidth: 0, text: "临时", fontSize: 24)
            editDoc.shapes.append(scratch)
            editDoc.setLiveText("临时改过的字", for: scratch.id)
            editDoc.rollback(to: beforeCancel)
            check("取消编辑回滚到编辑前（临时文字被撤掉）",
                  editDoc.shapes.count == beforeCancel.count)

            // 点进去又原样退出来，不该留下一步空撤销
            let calm = EditorDocument(image: editBase)
            calm.commitEdit(from: calm.shapes)
            check("没改动就不压空撤销点", !calm.canUndo)
        }

        // ── 图片编码（1.0.21：改走 CGImageDestination，省一次全图拷贝）──
        // 编码路径换了，产出的字节必须还是"能被解码回同一张图"的 PNG/JPEG。
        if let sample = solidImage(width: 40, height: 24, color: CGColor(gray: 0.4, alpha: 1)) as CGImage? {
            if let png = ImageEncode.data(sample, format: .png, jpgQuality: 1.0),
               let source = CGImageSourceCreateWithData(png as CFData, nil),
               let back = CGImageSourceCreateImageAtIndex(source, 0, nil) {
                check("PNG 编码后可解码且尺寸一致（\(back.width)×\(back.height)）",
                      back.width == 40 && back.height == 24)
                check(String(format: "PNG 往返逐像素一致（坏点 %.4f%%）",
                             pixelMismatchRatio(sample, back, tolerance: 0) * 100),
                      pixelMismatchRatio(sample, back, tolerance: 0) < 0.0001)
            } else {
                check("PNG 编码后可解码且尺寸一致（编码失败）", false)
            }
            if let jpg = ImageEncode.data(sample, format: .jpg, jpgQuality: 0.8),
               let source = CGImageSourceCreateWithData(jpg as CFData, nil),
               let back = CGImageSourceCreateImageAtIndex(source, 0, nil) {
                check("JPEG 编码后可解码且尺寸一致（\(back.width)×\(back.height)）",
                      back.width == 40 && back.height == 24)
            } else {
                check("JPEG 编码后可解码且尺寸一致（编码失败）", false)
            }
            check("未知格式不会抛错（PNG 数据非空）",
                  (ImageEncode.data(sample, format: .png, jpgQuality: 1.0)?.isEmpty == false))
        } else {
            check("图片编码用例的样图造不出来", false)
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

        // ── 贴图编辑（1.0.33 用户口径「给贴图的右键加：编辑贴图」）──
        // 链路：右键菜单 → PinWindow.requestEdit → PinManager → AppModel 开编辑器
        // → 关窗写回 PinWindow.replaceImage。菜单本身要 GUI 才验得到，这里钉住
        // "请求转得出去" + "新图真的换上了（尺寸也跟着变）"。
        do {
            let before = solidImage(width: 40, height: 30,
                                    color: CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
            let after = solidImage(width: 80, height: 60,
                                   color: CGColor(srgbRed: 0, green: 1, blue: 0, alpha: 1))
            if let pin = PinWindow(image: before, opacity: 1, shadow: false) {
                var requested: PinWindow?
                pin.onRequestEdit = { requested = $0 }
                pin.requestEdit()
                check("右键「编辑贴图」能把请求转出去", requested === pin)

                if let surface = pin.contentView as? PinSurfaceView {
                    let menu = surface.buildContextMenu()
                    check("图片贴图的右键菜单第一项是「编辑贴图」",
                          menu.items.first?.title == "编辑贴图")
                    // 菜单项必须真的接到 editPin 上（title 对了、action 没接 = 点了没反应）
                    // 用字符串 Selector：`editPin` 是 private @objc，取 #selector 会编译不过。
                    check("菜单项挂着 editPin 动作",
                          menu.items.first?.action == Selector(("editPin")))
                } else {
                    check("贴图内容视图类型没变（右键菜单挂在它上面）", false)
                }

                pin.replaceImage(after)
                check("写回后贴图拿的是新图",
                      pin.pinnedImage.width == 80 && pin.pinnedImage.height == 60)
                let backing = NSScreen.main?.backingScaleFactor ?? 2
                check("写回后窗口按新图重排（不是还按旧尺寸）",
                      abs(pin.frame.width - 80 / backing) < 1)
                pin.close()
            } else {
                check("图片贴图窗口能建出来（编辑贴图用）", false)
            }

            // 文本贴图不给这一项：换成位图就把"文字可选择"弄丢了
            if let text = PinManager.renderTextToImage("不可编辑"),
               let textPin = PinWindow(image: text, opacity: 1, shadow: false, text: "不可编辑") {
                textPin.replaceImage(after)
                check("文本贴图拒绝写回（保住可选中的文字）",
                      textPin.contentView is PinTextContentView)
                if let surface = textPin.contentView as? PinTextContentView {
                    let titles = surface.buildContextMenu().items.map(\.title)
                    check("文本贴图没有「编辑贴图」这一项", !titles.contains("编辑贴图"))
                }
                textPin.close()
            }
        }

        // ── 贴图接线：新建这条路也要能把「编辑贴图」转出去（1.0.33）──
        // 根因记录：从历史恢复那条路以前只接了 onClose，`onRequestEdit` 是 nil →
        // 右键点了什么都不发生。两条路现在都走 `wire(_:)`，这里验新建这条。
        do {
            let manager = PinManager()
            var forwarded: PinWindow?
            manager.onRequestEdit = { forwarded = $0 }
            let image = solidImage(width: 40, height: 30,
                                   color: CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1))
            _ = manager.pinImage(image, opacity: 1, shadow: false)
            if let pin = manager.pinsForDiagnostics.first {
                pin.requestEdit()
                check("新建的贴图也能把「编辑贴图」转出去", forwarded === pin)
            } else {
                check("管理器能建出贴图（接线用）", false)
            }
            manager.closeAll()
        }

        // ── 屏幕测量遮罩的收口（1.0.33 修「每次启动只能量一次」）──
        // 根因是 AppModel 从不把 measureOverlay 置 nil，而 startMeasure 开头
        // `guard measureOverlay == nil`。现在挂在 finish 的 onClose 上，取消也算。
        do {
            let overlay = MeasureOverlay()
            var closed = 0
            overlay.onClose = { closed += 1 }
            overlay.finish(distance: nil, hex: nil)      // Esc / 取消这条路
            overlay.finish(distance: 12, hex: "#FFFFFF") // 量完这条路
            check("测量遮罩收掉时一定通知（取消也算）", closed == 2)
        }

        // ── 保存目录口径（1.0.33 修「录制输出固定桌面」）──
        do {
            var prefs = Preferences()
            prefs.saveDirectory = nil
            check("没设保存目录 → 桌面", prefs.resolvedSaveDirectory == Support.defaultSaveDirectory)
            prefs.saveDirectory = ""
            check("存了空串也当桌面（老配置里可能是空串）",
                  prefs.resolvedSaveDirectory == Support.defaultSaveDirectory)
            prefs.saveDirectory = "/tmp/boxshot-selftest-dir"
            check("设了保存目录就跟着走",
                  prefs.resolvedSaveDirectory.path == "/tmp/boxshot-selftest-dir")
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

        // ── 窗口录制：动作在表里、rawValue 稳定（1.0.27）──
        // 它跟区域录制共用同一根工具条，唯一的新东西就是"这个动作要能被菜单/设置/热键
        // 正常列出来"；rawValue 是写进设置文件的接口，改了就丢用户的热键绑定。
        do {
            check("窗口录制在动作表里",
                  ShotAction.allCases.contains(.recordWindow)
                    && ShotAction.recordWindow.title == "窗口录制")
            check("窗口录制 rawValue 稳定", ShotAction.recordWindow.rawValue == "recordWindow")
        }

        // ── 录制音轨：每种音源最多建一条轨（1.0.27 修「系统声音有回响」）──
        // 回响的根子是两路音频（SCStream 系统音频 + AVCapture 麦克风）同时往一条
        // writer input 上 append。这条断言盯的就是"永远别出现两条轨"。
        do {
            check("音源：系统声音只建系统轨",
                  RecordAudioSource.system.tracks.system && !RecordAudioSource.system.tracks.mic)
            check("音源：麦克风只建麦克风轨",
                  RecordAudioSource.mic.tracks.mic && !RecordAudioSource.mic.tracks.system)
            check("音源：无 不建任何音轨",
                  !RecordAudioSource.none.tracks.system && !RecordAudioSource.none.tracks.mic)
            let doubled = RecordAudioSource.allCases.filter {
                ($0.tracks.system ? 1 : 0) + ($0.tracks.mic ? 1 : 0) > 1
            }
            check("没有任何音源会同时建两条轨（\(doubled.count) 个）", doubled.isEmpty)
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

        // ── 抓帧边界：小数选区对齐 + 透明边裁剪（1.0.29「成品图全是 1px 白线」）──
        // 白线的根因是抓帧回来了 alpha=0 的边行，不是拼接算错。
        do {
            let fractional = CGRect(x: 120.25, y: 620.75, width: 644.5, height: 620.3)
            let snapped = ScreenCapture.snapToDevicePixels(fractional, scale: 2)
            func onGrid(_ v: CGFloat) -> Bool { abs(v * 2 - (v * 2).rounded()) < 0.0001 }
            check("小数选区四条边都对齐到整设备像素",
                  onGrid(snapped.minX) && onGrid(snapped.minY)
                    && onGrid(snapped.maxX) && onGrid(snapped.maxY))
            check("对齐最多挪动 1 个设备像素",
                  abs(snapped.width - fractional.width) <= 0.5
                    && abs(snapped.height - fractional.height) <= 0.5)
            check("已经对齐的矩形原样返回",
                  ScreenCapture.snapToDevicePixels(snapped, scale: 2) == snapped)
            let tiny = ScreenCapture.snapToDevicePixels(
                CGRect(x: 10.2, y: 10.2, width: 0.01, height: 0.01), scale: 2)
            check("对齐后尺寸不会归零", tiny.width >= 0.5 && tiny.height >= 0.5)
        }
        if let withEdge = transparentEdgeImage(width: 40, height: 30) {
            let trimmed = ScreenCapture.trimmingTransparentEdges(withEdge)
            check("透明底行 + 右列都被裁掉（\(trimmed.width)×\(trimmed.height)）",
                  trimmed.width == 39 && trimmed.height == 29)
            let again = ScreenCapture.trimmingTransparentEdges(trimmed)
            check("裁过一次后再裁不会再缩", again.width == 39 && again.height == 29)
        } else {
            check("造透明边测试图", false)
        }
        if let opaque = syntheticPage(width: 40, height: 20) {
            let same = ScreenCapture.trimmingTransparentEdges(opaque)
            check("不透明的图原样返回", same.width == 40 && same.height == 20)
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

    /// 造一张"右列 + 底行全是 alpha=0"的图，模拟 ScreenCaptureKit 少填的那 1 行/1 列。
    /// 缓冲区第 0 行是图像顶部，所以透明的是 y=0 那一行（图像**底边**）与 x=width-1 那一列。
    private static func transparentEdgeImage(width: Int, height: Int) -> CGImage? {
        guard width > 1, height > 1,
              let ctx = CGContext(data: nil, width: width, height: height,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                    | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
        // 只画内部 (width-1) × (height-1)，最右一列与最下一行留成 alpha=0
        ctx.setFillColor(CGColor(red: 0.2, green: 0.35, blue: 0.8, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 1, width: width - 1, height: height - 1))
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

    /// 白底稀疏页面：白背景 + 一行行"文字条"（长短不一、起始位置随机）。
    /// 真实网页就长这样 —— 大片留白，纹理只占一小部分，是"分离度"类判据
    /// 最容易误杀的形态（1.0.26 用它钉住"完美解不许被拒"）。
    private static func sparseTextPage(width: Int, height: Int) -> CGImage? {
        guard let ctx = CGContext(data: nil, width: width, height: height,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                    | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
        ctx.setFillColor(CGColor(gray: 0.16, alpha: 1))
        var seed: UInt64 = 7
        func rnd(_ n: Int) -> Int {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Int((seed >> 33) % UInt64(max(1, n)))
        }
        var y = 10
        while y < height - 20 {
            // 每行画 3 条细笔画（1~2px 高）：真实文字有垂直方向的细结构，
            // 拿实心色块的话上下平移 1px 内部像素完全一样，会出现一堆"完美解"打平
            var x = 30 + rnd(40)
            let end = width - 30 - rnd(60)
            while x < end {
                let w = 6 + rnd(26)
                let h = 1 + rnd(2)
                ctx.fill(CGRect(x: CGFloat(x), y: CGFloat(y + rnd(8)),
                                width: CGFloat(w), height: CGFloat(h)))
                x += w + 5 + rnd(10)
            }
            y += 40
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

    /// 上黑下白的竖向渐变。用来验"取子区域时 y 翻对了" —— 纯色图翻不翻都一样，
    /// 测不出方向错误（这正是本项目反复踩的那类坑）。
    private static func gradientImage(width: Int, height: Int) -> CGImage? {
        guard let ctx = CGContext(data: nil, width: width, height: height,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
        // CG 左下原点：y=0 是底部 → 底部白、顶部黑
        let colors = [CGColor(red: 1, green: 1, blue: 1, alpha: 1),
                      CGColor(red: 0, green: 0, blue: 0, alpha: 1)] as CFArray
        guard let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                        colors: colors, locations: [0, 1]) else { return nil }
        ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: 0),
                               end: CGPoint(x: 0, y: CGFloat(height)), options: [])
        return ctx.makeImage()
    }

    /// 把 NSImage 画进 2x 位图，返回**非透明像素**的外接尺寸（pt）。
    ///
    /// 用来验"菜单栏图标实际画出来多大"—— SF Symbol 的 `image.size` 只改画布，
    /// 图形自带内边距缩在中间，光看 `size` 会以为它真的 18×18（实测墨迹只有 14×16）。
    /// alpha 在 BGRA little-endian 的第 4 个字节上，取错会全 0、断言变成永远通过。
    private static func inkBounds(_ image: NSImage, scale: Int = 2) -> CGSize {
        let w = Int(image.size.width) * scale, h = Int(image.size.height) * scale
        guard w > 0, h > 0,
              let ctx = CGContext(data: nil, width: w, height: h,
                                  bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                    | CGBitmapInfo.byteOrder32Little.rawValue) else { return .zero }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        image.draw(in: CGRect(x: 0, y: 0, width: w, height: h))
        NSGraphicsContext.restoreGraphicsState()
        guard let data = ctx.data else { return .zero }
        let buf = data.bindMemory(to: UInt8.self, capacity: w * h * 4)
        var minX = w, maxX = -1, minY = h, maxY = -1
        for y in 0..<h {
            for x in 0..<w where buf[(y * w + x) * 4 + 3] > 8 {
                if x < minX { minX = x }
                if x > maxX { maxX = x }
                if y < minY { minY = y }
                if y > maxY { maxY = y }
            }
        }
        guard maxX >= 0 else { return .zero }
        return CGSize(width: CGFloat(maxX - minX + 1) / CGFloat(scale),
                      height: CGFloat(maxY - minY + 1) / CGFloat(scale))
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

    /// 放大镜验像素质感的底图：全黑 + 左边缘一条 3px 宽的白竖条（x 2..5）。
    ///
    /// 为什么不能拿纯色图验：纯色图放大前后一个像素都不变，"放大没放大"根本测不出来
    /// （和"渐变图才能验 y 有没有翻错"是同一个道理）。
    private static func loupeBaseImage() -> CGImage? {
        let w = 100, h = 100
        guard let ctx = CGContext(data: nil, width: w, height: h,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                    | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
        ctx.setFillColor(CGColor(gray: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 2, y: 0, width: 3, height: h))
        return ctx.makeImage()
    }

    /// 200×200 黑底 + 两块白方块（40..60 与 88..100）：用来验放大镜的**镜面形状**。
    /// 为什么需要两张：`loupeBaseImage` 是 100×100、白条贴着左边缘，只够验"有没有放大"；
    /// 要分辨"圆 vs 矩形"得让输出框的角上**有东西可铺**，且底图那儿是黑的。
    private static func loupeStyleBaseImage() -> CGImage? {
        let w = 200, h = 200
        guard let ctx = CGContext(data: nil, width: w, height: h,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                    | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
        ctx.setFillColor(CGColor(gray: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        // CG 是左下原点，矩形按"顶部 y"写就得换成 h - (top + height)
        ctx.fill(CGRect(x: 40, y: h - 60, width: 20, height: 20))
        ctx.fill(CGRect(x: 88, y: h - 100, width: 12, height: 12))
        return ctx.makeImage()
    }

    /// 一个像素的亮度（0–255）。`pixelBytes` 是 BGRA（little-endian premultipliedFirst），
    /// 每像素第 1/2/3 个字节是 B / G / R —— 取错位会全 0、断言变成永远通过。
    private static func brightness(_ bytes: [UInt8], x: Int, y: Int, width: Int) -> Int {
        let i = (y * width + x) * 4
        guard i + 2 < bytes.count else { return -1 }
        return (Int(bytes[i]) + Int(bytes[i + 1]) + Int(bytes[i + 2])) / 3
    }
}

private extension String {
    var bytes: [UInt8] { Array(utf8) }
}

/// 自检专用窗口：把 `performDrag(with:)` 截下来只记次数。
///
/// 真窗口的 `performDrag` 会**进入拖动事件循环**，自检里调一次就卡死；
/// 覆写之后既不进循环、又能证明"容器的 mouseDown 确实把活交给了窗口"。
private final class DragProbeWindow: NSWindow {
    private(set) var dragCount = 0

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
                   styleMask: [.borderless], backing: .buffered, defer: false)
        // 程序化窗口默认 close() 会自我释放，跟 ARC 抢着放
        isReleasedWhenClosed = false
    }

    override func performDrag(with event: NSEvent) { dragCount += 1 }
}
