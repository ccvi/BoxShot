import AppKit
import Foundation

// ============================================================
// 入口
//
// --selftest 必须在 AppKit 事件循环起来之前拦掉（家族约定）。
// ============================================================

if CommandLine.arguments.contains("--selftest") {
    exit(Int32(SelfTest.run()))
}

if CommandLine.arguments.contains("--version") {
    let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0"
    print(version)
    exit(0)
}

// 诊断：直接对一张图跑 OCR 并打印真实输出（不弹任何窗口、不进事件循环）。
// 用户说"识别得不对"时，先看这条，别隔着界面猜。
if let index = CommandLine.arguments.firstIndex(of: "--ocrfile"),
   index + 1 < CommandLine.arguments.count {
    exit(OCREngine.printDiagnostics(forImageAt: CommandLine.arguments[index + 1]))
}

let application = NSApplication.shared
let delegate = MainActor.assumeIsolated { AppDelegate() }
application.delegate = delegate
// 兜底身份：裸可执行文件启动时没有 bundle 的 LSUIElement
application.setActivationPolicy(.accessory)
application.run()
