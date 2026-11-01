# BoxShot

原生 macOS 截图与录屏工具，一个菜单栏图标搞定 13 个动作：区域截图、滚动截图、OCR、二维码、屏幕测量、区域/全屏录制、贴图。

零第三方依赖——截图走 ScreenCaptureKit，识别走 Vision，热键走 Carbon，编码走 AVFoundation。

- 当前版本：**1.0.5**
- 作者：ccvi1223 · ccvi1223@qq.com
- 工程最低版本：`.macOS(.v14)`（`Package.swift`）
- 常驻形态：`LSUIElement = true`，只在菜单栏，不占 Dock

---

## 功能（1.0.5 已实现）

| 区域 | 能力 |
| --- | --- |
| 截图 | 区域截图（**拖出后不立刻截**：八向手柄可调、方向键微调 ⇧×10、Shift 约束正方形，⏎ 或双击确认）、截图直进剪贴板、重复上次区域、全屏（鼠标所在屏）、窗口（轻点选窗口，可高亮） |
| 历史 | 最近 N 张截图落盘留档（默认 20），菜单「截图历史…」网格重看，可重开标注 / 复制 / 贴图 / Finder 定位 |
| 滚动截图 | 手动滚动自动抓帧拼接，横向/竖向都能拼，实时预览累积图 |
| 识别 | OCR（中英混排，可保留换行、可追加到剪贴板）、二维码/条形码 11 种码制 |
| 屏幕测量 | 全屏遮罩拉框测距，按**物理像素**报数 |
| 录屏 | 区域/全屏录制，工具条带计时、**暂停/恢复**、麦克风/系统声音切换、格式（MOV / MP4 / **GIF**）与质量选项、摄像头画中画 |
| 贴图 | 从截图/剪贴板/Finder 贴图，滚轮缩放、双向翻转、双击动作可选、历史可恢复 |
| 标注 | 13 种工具：选择、钢笔、马克笔、矩形、椭圆、直线、箭头、文字、马赛克、模糊、测距、取色、裁剪 |
| 设置 | 7 个页签：通用、截图、贴图、OCR、录制、快捷键、关于 |

**出厂没有任何全局热键**（1.0.1 起）。所有动作都要在「设置 → 快捷键」里自己录一遍，不录就是没有——见下文「快捷键」一节。

## 快速开始

```bash
./build-app.sh --install        # 构建 + 自检门禁 + 安装到 /Applications
swift build --disable-sandbox   # 只编译（本机 sandbox-exec 受限，必须带这个参数）
```

首次使用必须先去「系统设置 → 隐私与安全性 → 屏幕录制」勾上 BoxShot 并重启应用，否则选区窗口打不开——所有截图入口都会先弹这个提示。

## 截图只走 ScreenCaptureKit

`SCScreenshotManager.captureImage` 单帧截图，`CGDisplayCreateImage` / `CGWindowListCreateImage` 全工程零调用。`CGWindowListCopyWindowInfo` 仍然用，但**只枚举窗口几何**做「智能识别窗口」的高亮——它不读窗口内容，因此不依赖屏幕录制授权。

多显示器只做**单屏**：选区窗口和全屏截图都锁定 `NSEvent.mouseLocation` 命中的那块屏。跨屏拼接没有实现。

### 三套坐标系，别混

| 坐标系 | 原点 | 谁在用 |
| --- | --- | --- |
| CGWindowList / NSEvent 全局坐标 | 主屏左上角，y 向下 | 窗口枚举、鼠标位置 |
| `SCStreamConfiguration.sourceRect` | 目标显示器左上角，y 向下 | 截图请求 |
| AppKit | 主屏左下角，y 向上 | 所有窗口/视图布局 |

全局 → 显示器局部是减去该屏 `CGDisplayBounds().origin`；AppKit ← 全局是 `y = 主屏高 - rect.maxY`。像素换算不在截图侧做：`captureImage` 直接吃点的 `sourceRect`、吐像素尺寸的 `CGImage`，点→像素的换算只发生在 UI 层（标注那一步）。

## 滚动截图：听用户的滚轮，不合成事件

全工程没有一个 `CGEvent`。做法是装全局 + 本地两个 `scrollWheel` 监听（滚轮事件不需要辅助功能授权），用户自己滚，程序只负责在停手后抓帧。

- **250ms 静默去抖**：每来一个滚轮事件就重置计时器，停手 250ms 才抓一帧。
- **忙时不丢帧**：抓帧期间又滚了，置 `pendingGrab`，当前帧回来后补抓一次。
- 每帧都是重新走一遍 `SCScreenshotManager`，不是 `SCStream` 连续流。

拼接（`Stitch.swift`）是纯函数，可以脱离界面跑，`--selftest` 里有逐像素断言。

1.0.5 重写后的三段式（1.0.4 那版拼出来「不连续、全错」）：

| 阶段 | 做什么 | 为什么 |
| --- | --- | --- |
| 粗搜 | 240 宽灰度，步长 2 行 | 只负责「大概滚了多少」，毫秒级扫完几百个候选 |
| 选窗口 | 取粗搜前 6 名 + 离 hint 最近的那个 | 等距内容有多个「完美」候选，正确周期可能排在后面 |
| 精修 | 每个窗口在原分辨率（宽 = 图宽）逐像素搜 | 1 像素精度靠这一步，粗搜的亚像素得分纯属噪声 |
| 择优 | 多个解都逐像素相等时取离 hint 最近 | 等距列表 / 表格靠这条才不跳周期 |

质量门两条，缺一就拒绝本帧（宁可不拼也不瞎拼）：

- **`mad ≤ 6`**：正确偏移的重叠区几乎一模一样，只容忍亚像素重采样的误差。
- **分离度 ≥ 8**：最优解的 mad 要明显低于窗口内其他候选的均值。纯色 / 空白画面里每个候选都是 0，最优解毫无意义 —— 判「分离度」跟画面亮不亮、有没有细节都无关。1.0.4 用 `texture >= 1 || mad <= 1.5` 兜底，纯色恰好走后者，把「什么都不像」当成「完美匹配」拼了进去。

**不用特征匹配**：滚动对齐只在一维上，暴力搜几百个候选就是毫秒级，鲁棒性反而比特征点稳（网页上重复的图标 / 文字会让特征匹配乱跳）。

固定表头 / 底栏在两帧里位置不变，会把最优解往 d≈0 拖，所以比较时跳过当前帧顶部 10% + 底部 4%。两帧宽度差 1px 会累积错位，先统一到 `min(topW, bottomW)`；重叠区取上方帧的内容（下方帧可能带输入法候选框或滚动条闪烁）。横向滚动把图顺时针转 90° 复用同一套算法，拼完再转回来。

### 三个坑（都写进了注释）

1. **取景框被拍进了画面**（用户看到「不连续」的真凶）。取景框浮在选区正上方，框里还画着上一次的拼接预览 → 每帧截到的都是上一帧的预览。修法：抓帧走 `SCContentFilter(display:excludingWindows:)`，按 pid 排除本应用全部窗口（裸二进制没有 bundle id，不能按 bundle id 认）。
2. **`CGContext` 位图缓冲是 top-down**。绘制坐标系是左下原点，但缓冲区第 0 行就是图像最上面一行，`CGImage.cropping(to:)` 的 y 也从顶部算。曾经「顺手翻转成 top-down」，等于两张图同时上下颠倒，正偏移 d 在数学上永远对不上（只有 `d = -offset` 成立），粗搜全落随机水平。
3. **`append` 的新高度是「已有高度 + offset」**，不是「top + bottom − 重叠」。写成后者等于把 bottom 的重叠部分又加了一遍：1173 行的页面拼出 2330 行，内容全是重复的。


## 标注渲染的三次翻车

三条都是「画了但看不见」级别的问题，注释里都留着原文：

1. **马赛克用直线路径裁剪 = 零面积**。`clip` 只认闭合区域，直线裁剪之后什么都画不出来。现在按「拖拽起止点围成的矩形」clip。
2. **`ctx.scaleBy` 方向反了**。标注存的是图像像素坐标，回到视图坐标要乘 `1/pixelScale`；曾经乘成 `pixelScale`，结果标注整体放大 4 倍画到图像区域外。
3. **画底图的顺序反了**。必须先在不翻转的标准空间画底图（那里 `CGImage` 方向才是正的），再 `translate + scaleBy(1, -1)` 翻成左上原点画标注。顺序反了底图整体上下颠倒——形状位置对、内容倒，特别迷惑。

标注一律存**图像像素坐标**，不存视图坐标。编辑器有缩放，保存/复制/贴图用的却是原始分辨率，坐标换算只该发生一次。撤销/重做是整数组快照（`undoStack: [[AnnotationShape]]`），没有上限也没有 NSUndoManager。

## 录屏：会话起点必须是第一帧视频的 PTS

`SCStream` + `AVAssetWriter`，H.264，码率 = `像素宽 × 像素高 × fps × 系数`（高 0.12 / 中 0.06 / 低 0.03 bpp）。

关键时序：`startSession(atSourceTime:)` 统一取**第一帧视频的 PTS**，音频帧在会话开始前到达就直接丢。丢零点几秒开头的声音，比留一个 PTS 早于会话起点的坏文件强。

声音是三选一互斥枚举（无 / 系统声 / 麦克风），**没有系统声 + 麦克风同时录的路径**。默认麦克风。无摄像头时 `sampleBuffer` 零拷贝直通，有摄像头时合成 CIImage 再走 pixelBufferPool。

录制时把自己的窗口放进 `excludingWindows`，浮条和贴图不会进画面。

## 选区调整：拖出来先别截，等确认

1.0.4 把选区从「松手即截」改成两段式：拖出范围 → `.adjusting` 阶段（八向手柄 / 方向键 / ⇧ 正方形）→ ⏎ 或双击才真正截图。

- **状态机是显式的**（`idle / dragging / adjusting / movingSelection / resizing`），而不是靠一堆布尔变量互相猜。滚动截图、录屏、OCR 共用同一个遮罩，改一处全部受益。
- **手柄容差 9pt**：太小点不中，太大又会把手柄拖拽变成移动选区。
- **移动时夹在屏内**（`bounds` 是这块屏幕），否则选区会跑到看不见的地方，截图请求直接失败。
- 方向键微调 **1px / ⇧ 10px**：对着像素做人眼校准，步长必须是 1。

## 裁剪：不改文档，改成"重开一个"

裁剪没有原地改 `EditorDocument.baseImage`。原因：浮层的 `imageRect`、手柄、面板尺寸都是 `init` 时定死的，原地改会留下半个旧状态（布局按旧尺寸、标注按新尺寸）。

做法是 `croppedResult(to:)` 产出一份「裁好的底图 + 平移到新原点的标注」，然后**关掉当前浮层 / 窗口，按新尺寸重开一个**：

- 坐标换算永远只有一套（`imageRect` ↔ 图像像素），不会出现两套并存；
- 被裁掉的标注直接丢弃（`displayBounds` 与裁剪区不相交），不会留下"看不见但还在"的幽灵；
- 重开期间 `suppressAutosave`，否则自动保存会把**裁剪前**的图落盘一份。

## GIF 与暂停：GIF 不走 AVAssetWriter

- **GIF 单独一条路**：不建 writer，按目标帧率（5/10/15）抽帧成 `CGImage`，收工用 `CGImageDestination` 一次性编码（循环 0 = 无限播放）。最长 **600 帧**，且最长边压到 1000px —— GIF 每帧都是完整位图，4K 原尺寸能做出几十 MB 的怪物。
- **暂停不能真停流**：停了恢复时首帧要等几百毫秒，writer 的会话起点也要重算。做法是照旧收帧全部丢弃，恢复后把这段空隙从后续 PTS 里减掉（`pausedTotal`）。
- 🔴 **时间轴补偿必须用 PTS 算，不能用墙钟**：SCStream 的 PTS 来自主机时钟，两者刻度不同，混用会得出离谱的偏移量。
- 暂停期间音频也要丢，恢复后的音频缓冲用 `CMSampleBufferCreateCopyWithNewTiming` 重编时间戳；视频侧只要有过暂停就走 `CVPixelBuffer` 合成路径（零拷贝直通无法改时间戳），所以 `CIContext` 现在一律创建，不再只在开摄像头时才建。

## 贴图：文本也先光栅化成位图

文本 / HTML 贴图在**创建时**渲染成 2x 位图，之后和图片贴图走同一条窗口链路（拖拽、滚轮缩放、双击、翻转）。代价是文字不可选中，换来的是一份交互代码管所有贴图。

贴图窗是 `NSPanel([.borderless, .nonactivatingPanel])`，`level = .floating`，`canBecomeKey` 恒 false——双击和滚轮交互全在内容视图里，窗口本身不抢焦点。历史落盘在 `~/Library/Application Support/BoxShot/pins/`，索引 `pins.json`，启动时按 `maxPinHistory` 恢复。

## 快捷键：Carbon，且只提供「整批替换」

`RegisterEventHotKey` 注册系统级热键，签名 `'BSHT'`。API 是 `replaceAll(with:)` 这个形状的，不是 `register()`——早期版本 `register()` 内部先 `unregisterAll()`，注册第二个键时把第一个清掉了，热键静默失效。**这个接口形状让那类 bug 写不出来，别改回去。**

能不能当全局热键有门槛：必须有 ⌘/⌥/⌃，或者无修饰键时必须是 F1–F12。其余无修饰的组合一律拒绝，否则打字时应用会被频繁误触。

读取设置是**严格读取**：设置里没录就是 `nil`，不回退默认值。曾经回退默认值，导致点「清除」之后界面又显示回 F7。

应用内的快捷键（⌘Z / ⌘C / ⌘S / Esc）是 NSEvent local monitor，只在浮层窗口是 key window 时生效，文字输入时不抢。

## 工程结构

```
Sources/BoxShot/
├── main.swift              诊断参数必须抢在 NSApplication.run() 之前
├── App/                    AppDelegate（窗口/菜单装配）、AppModel（13 个动作的调度）、SelfTest
├── Capture/                RegionSelector（截图前遮罩）、OverlayEditor（截图后原位浮层）、
│                           ScrollCaptureController、Recorder、RecordToolbar、MeasureOverlay
├── Core/                   ScreenCapture、Stitch、OCR、Shortcuts、HotKeyCenter、Preferences、Support、ShotHistory
├── Editor/                 AnnotationModels（数据模型 + 渲染器）、EditorView、EditorWindow
├── Pin/                    PinController（贴图窗 + 历史）
└── UI/                     StatusItemController、SettingsView、ResultWindow、HistoryWindow
```

### 几个不能改坏的约束

- **自检只能跑 `.build` 下的裸产物**，绝不 exec `.app/Contents/MacOS/` 里那个二进制。macOS 26 上那样做会让这个 bundle id 的状态栏登记永久失效，之后图标再也摆不上菜单栏。
- **`LSUIElement` 应用必须程序化建一份最小主菜单**，否则设置页里的文本框按不出 ⌘C/⌘V。
- **动作 `rawValue` 是接口**，写进设置文件里，不要改字符串。
- **保存文件重名自动加 `(2)` `(3)`**，绝不静默覆盖用户文件。
- **写盘失败必须报错**：滚动截图和保存都曾经 `try?` 静默吞错，用户毫无感知。
- **不声明 testTarget**：本机只有 Command Line Tools，声明了会因缺 XCTest 连主程序都编不过。

## 数据位置

| 用途 | 路径 |
| --- | --- |
| 设置 | `UserDefaults["com.pcxx.boxshot.preferences"]`，JSON 编码的 `Preferences`（29 个字段） |
| 贴图历史 | `~/Library/Application Support/BoxShot/pins/` + `pins.json` |
| 截图历史 | `~/Library/Application Support/BoxShot/History/` + `history.json`（PNG 原图 + 清单；删条目连文件一起删） |
| 开机自启 | `~/Library/LaunchAgents/com.pcxx.boxshot.plist`（`/usr/bin/open -g`，不是 SMAppService） |
| 默认截图目录 | 桌面（`saveDirectory` 为 nil 时每次弹面板问） |

配置解码是手写的，每个字段 `decodeIfPresent ?? 默认值`——新增字段不能让旧配置整份作废，否则升级一次设置全丢。

## 版本规则与自检

版本号唯一来源是根目录 `VERSION`，打包时按源码指纹（`Package.swift` + `build-app.sh` + `Sources` + `Resources` 全部文件 sha256 后排序再 sha256）决定是否 patch +1。**源码没变就不涨**——版本号在一个只有补丁位的方案里是用掉就回不来的，虚涨不可逆。

自检在 `build-app.sh` 里是硬门禁，不过就 `exit 1` 不产出 `.app`：

```bash
.build/release/BoxShot --selftest
```

当前 32 处断言，覆盖键位资格判定、拼接找回 60px 偏移、OCR 行聚类、偏好解码兜底、渲染管线（含「效果区域真的改了像素」和「底图没有上下颠倒」这两条）、撤销/重做、点选移动删除、文本贴图、文件名去重。只测纯逻辑，不碰屏幕捕获——无授权环境下跑不了，打包机也不该弹窗。

## 诊断

| 参数 | 作用 |
| --- | --- |
| `--selftest` | 跑自检，退出码即结果 |
| `--version` | 打印版本号 |
| `--show-overlay` | 延迟 0.6s 用**合成渐变图**打开标注浮层并预置四条标注，不走截图权限，配合 `screencapture -R` 核对浮层有没有真的把图画出来 |
| `--show-history` | 延迟 0.6s 打开截图历史面板；历史为空时先塞三张合成图（会**真的写进**历史目录，看完记得删） |

## 已知问题（待修）

- **贴图拖不动**：`mouseDragged` 里拿的是本次事件的增量 `event.deltaX/deltaY`，却加在 `mouseDown` 记下的原点上，于是每次拖拽位移只等于最后一次事件的增量（`PinController.swift:415-419`）。
- **屏幕测量每次启动只能用一次**：`measureOverlay` 赋值后从不置 nil，而 `startMeasure` 里 `guard measureOverlay == nil` 直接 return（`AppModel.swift:340-347`）。
- **录制输出固定桌面**，不跟「保存目录」设置（`Recorder.swift:67-69`）。
