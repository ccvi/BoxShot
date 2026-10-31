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

        // ── 拼接算法 ──
        do {
            // 合成图：240×160，画三条横线
            func synthetic(_ seed: Int) -> CGImage {
                let ctx = CGContext(data: nil, width: 240, height: 160,
                                    bitsPerComponent: 8, bytesPerRow: 0,
                                    space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue)!
                ctx.setFillColor(grayValue(0.9))
                ctx.fill(CGRect(x: 0, y: 0, width: 240, height: 160))
                for (index, shade) in [0.2, 0.5, 0.75].enumerated() {
                    ctx.setFillColor(grayValue(shade))
                    // CG 左下原点：三条横线分布在不同高度
                    let y = CGFloat(20 + index * 50 + seed)
                    ctx.fill(CGRect(x: 10, y: y, width: 220, height: 14))
                }
                return ctx.makeImage()!
            }
            func grayValue(_ v: Double) -> CGColor {
                CGColor(srgbRed: v, green: v, blue: v, alpha: 1)
            }

            // 页面向上滚 60px：新帧内容 = 旧帧从第 60 行起
            let scrollPx = 60
            let shifted = cropTop(synthetic(0), droppingTop: scrollPx)
            let grayA = ImageStitch.GrayImage(image: synthetic(0))
            let grayB = ImageStitch.GrayImage(image: shifted)
            let found = ImageStitch.findScrollOffset(top: grayA, bottom: grayB)
            // 灰度图按宽度 240 采样，1:1 尺度
            check("拼接算法找回滚动偏移(\(scrollPx)px → \(found ?? -1))",
                  found != nil && abs(found! - scrollPx) <= 6)

            let stitched = ImageStitch.stitchVertical(top: synthetic(0), bottom: shifted)
            // 新高度 = top(160) + bottom(100) - offset(60) = 200
            check("拼接输出高度正确",
                  stitched != nil && abs(stitched!.height - 200) <= 8)
            check("旋转 90° 尺寸互换", {
                guard let rotated = ImageStitch.rotate90(synthetic(0)) else { return false }
                return rotated.width == 160 && rotated.height == 240
            }())
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
        } catch {
            check("偏好解码异常：\(error)", false)
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

            // 撤销重做
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

            print(failures == 0 ? "\n全部通过" : "\n\(failures) 项失败")
            return failures == 0 ? 0 : 1
        }
    }

    // ── 工具 ──

    private static func cropTop(_ image: CGImage, droppingTop pixels: Int) -> CGImage {
        let rect = CGRect(x: 0, y: pixels, width: image.width, height: image.height - pixels)
        return image.cropping(to: rect)!
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
