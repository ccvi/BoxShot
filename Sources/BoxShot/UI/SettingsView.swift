import AppKit
import SwiftUI

// ============================================================
// 偏好设置窗口
// ============================================================

@MainActor
final class SettingsWindowController: NSWindowController {

    private let model: AppModel

    init(model: AppModel, initialTab: Int = 0) {
        self.model = model
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 520),
                              styleMask: [.titled, .closable],
                              backing: .buffered, defer: false)
        window.title = "BoxShot 设置"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.contentView = NSHostingView(rootView: SettingsRootView(model: model, initialTab: initialTab))
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func show() {
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

struct SettingsRootView: View {
    @ObservedObject var model: AppModel
    @State private var tab: Int

    init(model: AppModel, initialTab: Int = 0) {
        self.model = model
        _tab = State(initialValue: initialTab)
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                Text("通用").tag(0)
                Text("截图").tag(1)
                Text("贴图").tag(2)
                Text("OCR").tag(3)
                Text("录制").tag(4)
                Text("快捷键").tag(5)
                Text("关于").tag(6)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(12)

            Divider()

            ScrollView {
                Group {
                    switch tab {
                    case 0: GeneralPane(model: model, prefs: model.prefs)
                    case 1: ShotPane(model: model, prefs: model.prefs)
                    case 2: PinPane(model: model, prefs: model.prefs)
                    case 3: OCRPane(model: model, prefs: model.prefs)
                    case 4: RecordPane(model: model, prefs: model.prefs)
                    case 5: ShortcutsPane(model: model, prefs: model.prefs)
                    default: AboutPane()
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
        .frame(width: 640, height: 520)
    }
}

// ── 通用 ─────────────────────────────────────────────────────

private struct GeneralPane: View {
    @ObservedObject var model: AppModel
    /// 🔴 面板必须**直接观察设置本身**。只观察 model 的话，改了设置这边不会重绘：
    /// 勾选框看着回弹、Picker 选完还显示旧值 —— 用户看到的就是"设置无效"。
    @ObservedObject var prefs: PreferencesStore

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("启动设置").frame(width: 90, alignment: .trailing)
                Toggle("隐藏 Dock 图标（菜单栏常驻）", isOn: prefs.binding(\.hideDockIcon))
            }
            HStack {
                Text("提示音").frame(width: 90, alignment: .trailing)
                Toggle("操作完成播放提示音", isOn: prefs.binding(\.playSound))
            }
            HStack {
                Text("").frame(width: 90)
                Picker("", selection: prefs.binding(\.feedbackSound)) {
                    ForEach(SoundFeedback.options, id: \.name) { option in
                        Text(option.title).tag(option.name)
                    }
                }
                .labelsHidden()
                .frame(width: 170)
                .disabled(!prefs.value.playSound)
                Button("试听") { SoundFeedback.preview(name: prefs.value.feedbackSound) }
                    .disabled(!prefs.value.playSound)
            }
            HStack {
                Text("").frame(width: 90)
                Toggle("选区时显示取色十字线", isOn: prefs.binding(\.showCrosshair))
            }
        }
        .font(.body)
    }
}

// ── 截图 ─────────────────────────────────────────────────────

private struct ShotPane: View {
    @ObservedObject var model: AppModel
    @ObservedObject var prefs: PreferencesStore

    /// 「自动保存」真正会落到哪 —— 没设置目录时自动落到桌面（PreferencesStore 里补齐），
    /// 这里把结果显示出来，免得用户以为开关是空的。
    private var effectiveSaveDirectory: String {
        let dir = prefs.value.saveDirectory ?? ""
        return dir.isEmpty ? Support.defaultSaveDirectory.path : dir
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("保存格式").frame(width: 90, alignment: .trailing)
                Picker("", selection: prefs.binding(\.shotFormat)) {
                    ForEach(ShotFormat.allCases) { format in
                        Text(format.title).tag(format)
                    }
                }
                .labelsHidden()
                .frame(width: 100)
                Text(prefs.value.shotFormat == .jpg ? "有损压缩，质量见下" : "无损")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            HStack {
                Text("JPG 质量").frame(width: 90, alignment: .trailing)
                Slider(value: prefs.binding(\.jpgQuality), in: 0.5...1.0, step: 0.05)
                    .frame(width: 200)
                    .disabled(prefs.value.shotFormat != .jpg)
                Text(String(format: "%.2f", prefs.value.jpgQuality))
                    .monospacedDigit()
                    .frame(width: 40)
                    .foregroundStyle(prefs.value.shotFormat == .jpg ? .primary : .secondary)
            }
            Toggle("截图后弹出标注浮层（关闭 = 直接复制到剪贴板）", isOn: prefs.binding(\.openEditorAfterShot))
                .padding(.leading, 90)
            Toggle("智能识别窗口（移动鼠标自动高亮）", isOn: prefs.binding(\.windowHighlight))
                .padding(.leading, 90)
            Toggle("Retina 截图缩小到 1x 再输出", isOn: prefs.binding(\.downscaleRetina))
                .padding(.leading, 90)
            HStack {
                Text("保存目录").frame(width: 90, alignment: .trailing)
                Button("选择目录…") { chooseDirectory() }
                if let dir = prefs.value.saveDirectory {
                    Text(dir).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                } else {
                    Text("每次保存时询问").font(.footnote).foregroundStyle(.secondary)
                }
            }
            Toggle("自动保存（浮层关闭即落盘；保存/滚动截图不再弹面板）", isOn: prefs.binding(\.autoSave))
                .padding(.leading, 90)
            if prefs.value.autoSave {
                Text("落盘到：\(effectiveSaveDirectory)")
                    .font(.footnote).foregroundStyle(.secondary)
                    .padding(.leading, 112)
            }
            HStack {
                Text("截图历史").frame(width: 90, alignment: .trailing)
                Picker("", selection: prefs.binding(\.maxShotHistory)) {
                    Text("不记录").tag(0)
                    Text("10 张").tag(10)
                    Text("20 张").tag(20)
                    Text("50 张").tag(50)
                }
                .labelsHidden()
                .frame(width: 120)
                Button("打开历史面板") { model.showShotHistory() }
                    .disabled(prefs.value.maxShotHistory == 0)
                Spacer()
            }
        }
        .font(.body)
    }

    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        if panel.runModal() == .OK, let url = panel.url {
            prefs.value.saveDirectory = url.path
        }
    }
}

// ── 贴图 ─────────────────────────────────────────────────────

private struct PinPane: View {
    @ObservedObject var model: AppModel
    @ObservedObject var prefs: PreferencesStore

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("双击贴图").frame(width: 90, alignment: .trailing)
                Picker("", selection: prefs.binding(\.pinDoubleClick)) {
                    ForEach(PinDoubleClickAction.allCases) { action in
                        Text(action.title).tag(action)
                    }
                }
                .labelsHidden()
                .frame(width: 120)
            }
            HStack {
                Text("默认不透明度").frame(width: 90, alignment: .trailing)
                Slider(value: prefs.binding(\.pinOpacity), in: 0.3...1.0, step: 0.05)
                    .frame(width: 200)
                Text(String(format: "%.2f", prefs.value.pinOpacity))
                    .monospacedDigit()
                    .frame(width: 40)
            }
            HStack {
                Text("").frame(width: 90)
                Toggle("贴图窗口阴影", isOn: prefs.binding(\.pinShadow))
            }
            HStack {
                Text("历史记录数").frame(width: 90, alignment: .trailing)
                Stepper(value: prefs.binding(\.maxPinHistory), in: 0...100) {
                    Text("\(prefs.value.maxPinHistory)")
                }
                Text("重启后恢复最近贴图")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Text("把任意地方的图片、文本变成便签贴在桌面上，方便查看对比。\n贴图支持拖拽移动、滚轮缩放、右键翻转镜像、双击按设置动作。")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .font(.body)
    }
}

// ── OCR ──────────────────────────────────────────────────────

private struct OCRPane: View {
    @ObservedObject var model: AppModel
    @ObservedObject var prefs: PreferencesStore

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Toggle("保留文字换行", isOn: prefs.binding(\.ocrKeepLineBreaks))
                .padding(.leading, 90)
            HStack {
                Text("换行重叠参数").frame(width: 90, alignment: .trailing)
                Slider(value: prefs.binding(\.ocrLineOverlap), in: 0...0.6, step: 0.05)
                    .frame(width: 200)
                Text(String(format: "%.2f", prefs.value.ocrLineOverlap))
                    .monospacedDigit()
                    .frame(width: 40)
            }
            Toggle("增量累积识别（结果追加进剪贴板）", isOn: prefs.binding(\.ocrIncremental))
                .padding(.leading, 90)
            Toggle("自动打开 QR 识别出的链接", isOn: prefs.binding(\.ocrAutoOpenLink))
                .padding(.leading, 90)
            Text("OCR 由系统 Vision 框架本地完成，图片不会上传。结果窗口全程复用，新识别替换旧内容。")
                .font(.callout).foregroundStyle(.secondary)
        }
        .font(.body)
    }
}

// ── 录制 ─────────────────────────────────────────────────────

private struct RecordPane: View {
    @ObservedObject var model: AppModel
    @ObservedObject var prefs: PreferencesStore

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("声音").frame(width: 90, alignment: .trailing)
                Picker("", selection: prefs.binding(\.recordAudio)) {
                    ForEach(RecordAudioSource.allCases) { source in
                        Text(source.title).tag(source)
                    }
                }
                .labelsHidden()
                .frame(width: 140)
            }
            HStack {
                Text("帧率").frame(width: 90, alignment: .trailing)
                Picker("", selection: prefs.binding(\.recordFPS)) {
                    Text("24").tag(24)
                    Text("30").tag(30)
                    Text("60").tag(60)
                }
                .labelsHidden()
                .frame(width: 90)
            }
            HStack {
                Text("格式").frame(width: 90, alignment: .trailing)
                Picker("", selection: prefs.binding(\.recordFormat)) {
                    ForEach(RecordFileFormat.allCases) { format in
                        Text(format.title).tag(format)
                    }
                }
                .labelsHidden()
                .frame(width: 100)
                Text(prefs.value.recordFormat == .gif ? "动图：无声音、无画中画" : "")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            HStack {
                Text("质量").frame(width: 90, alignment: .trailing)
                Picker("", selection: prefs.binding(\.recordQuality)) {
                    ForEach(RecordQuality.allCases) { quality in
                        Text(quality.title).tag(quality)
                    }
                }
                .labelsHidden()
                .frame(width: 100)
            }
            // 取景框大小就放在「质量」下面（用户指定位置）：
            // 大 / 中（默认）/ 小，中比小大 10%，大比中大 10%
            HStack {
                Text("取景框大小").frame(width: 90, alignment: .trailing)
                Picker("", selection: prefs.binding(\.recordCameraSize)) {
                    ForEach(CameraBubbleSize.allCases) { size in
                        Text(size.title).tag(size)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 150)
                .disabled(!prefs.value.recordCamera)
                // 把当前的边长点数显示出来：三档是绝对值，用户设了 170 就该
                // 能在界面上看到"确实是 170"，而不是靠肉眼看大小猜
                Text(prefs.value.recordCamera
                     ? "当前 \(Int(prefs.value.recordCameraSize.side)) pt"
                     : "先勾选下面的摄像头取景框")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            HStack {
                Text("").frame(width: 90)
                Toggle("录制时显示摄像头取景框（画面右下角，圆形 / 圆角矩形，右键切换）",
                       isOn: prefs.binding(\.recordCamera))
            }
            HStack {
                Text("GIF 帧率").frame(width: 90, alignment: .trailing)
                Picker("", selection: prefs.binding(\.recordGIFPS)) {
                    Text("5").tag(5)
                    Text("10").tag(10)
                    Text("15").tag(15)
                }
                .labelsHidden()
                .frame(width: 90)
                .disabled(prefs.value.recordFormat != .gif)
            }
            Toggle("录制中显示鼠标指针", isOn: prefs.binding(\.recordShowCursor))
                .padding(.leading, 90)
            Toggle("录制完成后在 Finder 中显示文件", isOn: prefs.binding(\.recordRevealInFinder))
                .padding(.leading, 90)
            Text("输出 MP4 / MOV（H.264 + AAC），默认保存到桌面。首次录制需要授权「屏幕录制」与「麦克风」。")
                .font(.callout).foregroundStyle(.secondary)
        }
        .font(.body)
    }
}

// ── 快捷键 ───────────────────────────────────────────────────

private struct ShortcutsPane: View {
    @ObservedObject var model: AppModel
    /// 直接观察设置本身：只观察 model 的话，录完键位这一栏不会刷新
    @ObservedObject var prefs: PreferencesStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("操作").frame(width: 150, alignment: .leading).font(.callout).foregroundStyle(.secondary)
                Text("键值").frame(width: 150, alignment: .leading).font(.callout).foregroundStyle(.secondary)
            }
            ForEach(ShotAction.allCases) { action in
                let spec = prefs.value.spec(for: action)
                HStack {
                    Text(action.title).frame(width: 150, alignment: .leading)
                    ShortcutRecorderView(
                        spec: Binding(
                            get: { prefs.value.spec(for: action) },
                            set: { newValue in
                                if let newValue {
                                    prefs.value.shortcuts[action.rawValue] = newValue
                                } else {
                                    prefs.value.shortcuts.removeValue(forKey: action.rawValue)
                                }
                            }))
                    .frame(width: 150)
                    Button("清除") {
                        prefs.value.shortcuts.removeValue(forKey: action.rawValue)
                    }
                    .font(.footnote)
                    // 录了但不能当全局热键的，当场标出来，别等用户去试
                    if let spec, !spec.isUsableAsGlobal {
                        Text("要加 ⌘/⌥/⌃，或改用 F1–F12")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    } else if let spec, model.failedShortcuts.contains(spec) {
                        Text("被系统占用，注册失败")
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                    Spacer()
                }
            }
            Button("清空全部快捷键") {
                prefs.value.shortcuts = [:]
            }
            .padding(.top, 8)
            Text("F1–F12 功能键可以不带修饰键注册为全局热键；其余按键必须配合 ⌘ / ⌥ / ⌃，否则会和正常打字冲突，系统不会让你注册。录好后点一下别的行生效。")
                .font(.callout).foregroundStyle(.secondary)
        }
        .font(.body)
    }
}

/// 快捷键录制控件：点击进入录制态，按下的第一个键成为新键位
struct ShortcutRecorderView: NSViewRepresentable {

    @Binding var spec: KeySpec?

    func makeNSView(context: Context) -> RecorderButton {
        let button = RecorderButton()
        button.onCapture = { spec = $0 }
        button.updateLabel(spec)
        return button
    }

    func updateNSView(_ view: RecorderButton, context: Context) {
        view.updateLabel(spec)
    }

    final class RecorderButton: NSButton {
        var onCapture: ((KeySpec?) -> Void)?
        private var recording = false
        private var shownSpec: KeySpec?

        init() {
            super.init(frame: .zero)
            bezelStyle = .rounded
            isBordered = true
            setButtonType(.momentaryPushIn)
            // 没这几个字显示不出来；顺手给个最小高度，别让 SwiftUI 把它压扁
            title = "记录快捷键"
            setContentHuggingPriority(.defaultLow, for: .horizontal)
        }

        required init?(coder: NSCoder) { fatalError("not used") }

        /// 🔴 关键：NSButton **默认不接受第一响应者**，点它也不会变成 firstResponder，
        /// 于是 keyDown 永远收不到 —— 这就是"快捷键设置不可用"的根因：
        /// 点进去看着像在等按键，其实键盘事件全被窗口吃了。
        override var acceptsFirstResponder: Bool { true }

        override func mouseDown(with event: NSEvent) {
            // 点一下 = 进入录制态。不要调 super（那会走 momentary 高亮跟踪，
            // 按下的键还是到不了我们这里）。
            window?.makeFirstResponder(self)
        }

        func updateLabel(_ spec: KeySpec?) {
            shownSpec = spec
            guard !recording else { return }
            title = spec?.display ?? "记录快捷键"
        }

        override func becomeFirstResponder() -> Bool {
            recording = true
            title = "按下按键…（Esc 取消，⌫ 清除）"
            return true
        }

        override func resignFirstResponder() -> Bool {
            // 只退出录制态，**不写绑定**——之前在这里回写 nil，
            // 会把刚录好的键位立刻抹掉（"快捷键清除不了"的另一半病因）。
            recording = false
            title = shownSpec?.display ?? "记录快捷键"
            return true
        }

        override func keyDown(with event: NSEvent) {
            if event.keyCode == 53 { // Esc 取消录制
                recording = false
                window?.makeFirstResponder(nil)
                return
            }
            if event.keyCode == 51 { // Delete 清除键位
                onCapture?(nil)
                shownSpec = nil
                recording = false
                window?.makeFirstResponder(nil)
                return
            }
            // 只按住修饰键（⌘/⌥/⌃/⇧）时不该被当成一个键位录下来
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let isPureModifier = flags.subtracting([.command, .shift, .option, .control]).isEmpty
                && [54, 55, 56, 58, 59, 60, 61, 62].contains(Int(event.keyCode))
            if isPureModifier { return }

            let spec = KeySpec.from(event)
            shownSpec = spec
            onCapture?(spec)
            recording = false
            title = spec.display
            window?.makeFirstResponder(nil)
        }
    }
}

// ── 关于 ─────────────────────────────────────────────────────

private struct AboutPane: View {
    var body: some View {
        VStack(alignment: .center, spacing: 14) {
            Spacer()
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
            Text("BoxShot").font(.title2.bold())
            Text("轻量级原生 macOS 截图与录屏工具")
                .foregroundStyle(.secondary)
            let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0"
            Text("版本 \(version)").font(.callout).monospacedDigit()
            Text("作者：ccvi1223 · ccvi1223@qq.com").font(.callout).foregroundStyle(.secondary)
            Text("截图 · 标注 · OCR · 解码 · 测距 · 滚动截图 · 贴图 · 录屏")
                .font(.footnote).foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}
