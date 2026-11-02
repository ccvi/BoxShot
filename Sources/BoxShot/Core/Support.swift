import AppKit
import AVFoundation
import CoreGraphics
import Foundation

// ============================================================
// 零碎工具：目录、开机启动、权限、提示音、剪贴板、文件名
// ============================================================

enum Support {

    /// 数据落盘根目录：~/Library/Application Support/BoxShot
    static var appSupportRoot: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        let url = base.appendingPathComponent("BoxShot", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// 截图/录屏默认落盘目录（用户没改过就是桌面）
    static var defaultSaveDirectory: URL {
        FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
    }

    /// 截图文件名：boxshot20261019113733 —— 与常见截图工具一致的可读时间戳
    static func shotFileName(prefix: String = "boxshot", ext: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyyMMddHHmmss"
        return "\(prefix)\(formatter.string(from: Date())).\(ext)"
    }

    /// 重名自动加 (2) (3)，绝不静默覆盖用户文件
    static func uniqueFileURL(in directory: URL, name: String) -> URL {
        var candidate = directory.appendingPathComponent(name)
        let stem = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var counter = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(stem) (\(counter)).\(ext)")
            counter += 1
        }
        return candidate
    }

    // ── 剪贴板 ──────────────────────────────────────────────

    /// Retina 截图缩回 1x（"缩小到 1x 再输出"设置用）
    static func downscaleTo1x(_ image: CGImage) -> CGImage? {
        scaled(image, to: CGSize(width: max(1, image.width / 2), height: max(1, image.height / 2)))
    }

    /// 等比/不等比缩放到指定像素尺寸（高质量插值）。
    /// 改截图框时要用它把 2x 的裁剪结果缩到 1x 文档尺度。
    static func scaled(_ image: CGImage, to size: CGSize) -> CGImage? {
        let w = max(1, Int(size.width))
        let h = max(1, Int(size.height))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }

    /// 把图片写进剪贴板（PNG + TIFF 双类型：预览/Finder 认 TIFF，程序间认 PNG）
    static func copyImageToClipboard(_ image: CGImage) {
        let bitmap = NSBitmapImageRep(cgImage: image)
        guard let tiff = bitmap.tiffRepresentation,
              let png = bitmap.representation(using: .png, properties: [:]) else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setData(tiff, forType: .tiff)
        pasteboard.setData(png, forType: .png)
    }

    static func copyTextToClipboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    // ── 提示 ────────────────────────────────────────────────

    /// 提示音统一走这里：具体音效由设置里的「提示音」决定（与 BoxPaste 同一套）。
    /// 调用点很多在拿不到 AppModel 的地方（Recorder 的收尾线程等），
    /// 所以名字由调用方传进来，不在这里回头去读全局设置。
    static func playFeedbackSound(named name: String) {
        SoundFeedback.play(name: name)
    }
}

// ── 屏幕录制权限 ─────────────────────────────────────────────

enum ScreenPermission {
    /// 是否已获得屏幕录制授权（预先探测，不弹窗）
    static var isGranted: Bool { CGPreflightScreenCaptureAccess() }

    /// 发起授权请求（首次会弹系统面板；应用需要重启后才真正生效）
    @discardableResult
    static func request() -> Bool { CGRequestScreenCaptureAccess() }
}

// ── 开机启动 ─────────────────────────────────────────────────

enum LoginItem {
    private static var plistURL: URL {
        let base = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library")
        let bundleID = Bundle.main.bundleIdentifier ?? "com.pcxx.boxshot"
        return base.appendingPathComponent("LaunchAgents/\(bundleID).plist")
    }

    private static var appPath: String { Bundle.main.bundlePath }

    static var isEnabled: Bool {
        FileManager.default.fileExists(atPath: plistURL.path)
    }

    static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            guard appPath.hasSuffix(".app") else {
                throw NSError(domain: "BoxShot", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: "当前不是从 .app 里运行，无法设置开机启动（请先打包）",
                ])
            }
            try FileManager.default.createDirectory(at: plistURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            // -g 后台启动，不抢焦点
            let plist: [String: Any] = [
                "Label": Bundle.main.bundleIdentifier ?? "com.pcxx.boxshot",
                "ProgramArguments": ["/usr/bin/open", "-g", appPath],
                "RunAtLoad": true,
                "KeepAlive": false,
            ]
            let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            try data.write(to: plistURL, options: .atomic)
        } else {
            if FileManager.default.fileExists(atPath: plistURL.path) {
                try FileManager.default.removeItem(at: plistURL)
            }
        }
    }
}
