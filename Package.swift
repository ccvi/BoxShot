// swift-tools-version: 5.10
import PackageDescription

// BoxShot —— 轻量级原生 macOS 截图与录屏工具。
//
// platform 写 .v14 而不是 .v26：家族约定（见 BoxPaste Package.swift 头注释）。
// 本项目用到的能力（ScreenCaptureKit / SCScreenshotManager / Vision / Carbon 热键 /
// AVAssetWriter）在 macOS 14 上都齐了；26 特有的只是外观细节，走 if #available。
// 目标机是 M5 + macOS 26，但在 14/15 上也能跑。
//
// 无第三方依赖：
//   · 截图/录屏走 ScreenCaptureKit（系统框架）
//   · OCR / QR 解码走 Vision
//   · 全局热键走 Carbon RegisterEventHotKey（不需要辅助功能授权）
//   · 录音（麦克风）走 AVCaptureSession 的音频数据输出，产 CMSampleBuffer 直写 writer
let package = Package(
    name: "BoxShot",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "BoxShot", targets: ["BoxShot"])
    ],
    targets: [
        .executableTarget(
            name: "BoxShot",
            path: "Sources/BoxShot"
        )
    ]
)

// 不声明 testTarget（家族约定：本机只有 Command Line Tools，声明了会因缺 XCTest
// 连主程序都编不过）。自检走应用内 --selftest，build-app.sh 拿它当发布门禁。
