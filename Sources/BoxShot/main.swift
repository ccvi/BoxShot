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

let application = NSApplication.shared
let delegate = MainActor.assumeIsolated { AppDelegate() }
application.delegate = delegate
// 兜底身份：裸可执行文件启动时没有 bundle 的 LSUIElement
application.setActivationPolicy(.accessory)
application.run()
