# BoxShot

原生 macOS 截图与录屏工具，一个菜单栏图标搞定 13 个动作：区域截图、滚动截图、OCR、二维码、屏幕测量、区域/全屏录制、贴图。

零第三方依赖——截图走 ScreenCaptureKit，识别走 Vision，热键走 Carbon，编码走 AVFoundation。

- 当前版本：**1.0.9**
- 作者：ccvi1223 · ccvi1223@qq.com
- 工程最低版本：`.macOS(.v14)`（`Package.swift`）
- 常驻形态：`LSUIElement = true`，只在菜单栏，不占 Dock

---

## 功能（1.0.9 已实现）

| 区域 | 能力 |
| --- | --- |
| 截图 | 区域截图（**拖出后不立刻截**：八向手柄可调、方向键微调 ⇧×10、Shift 约束正方形，⏎ 或选区内单击确认）、截图直进剪贴板、重复上次区域、全屏（鼠标所在屏）、窗口（轻点选窗口，可高亮） |
| 历史 | 最近 N 张截图落盘留档（默认 20），菜单「截图历史…」网格重看，可重开标注 / 复制 / 贴图 / Finder 定位 |
| 滚动截图 | 手动滚动自动抓帧拼接，横向/竖向都能拼，「缩略图」窗口实时跟着长 |
| 识别 | OCR（中英混排，可保留换行、可追加到剪贴板）、二维码/条形码 11 种码制 |
| 屏幕测量 | 全屏遮罩拉框测距，按**物理像素**报数 |
| 录屏 | 区域/全屏录制，工具条带计时、**暂停/恢复**、麦克风/系统声音切换、格式（MOV / MP4 / **GIF**）与质量选项、**摄像头取景框**（圆形 / 圆角矩形，可随时关掉） |
| 贴图 | 从截图/剪贴板/Finder 贴图，滚轮缩放、双向翻转、双击动作可选、历史可恢复 |
| 标注 | 13 种工具：选择、钢笔、马克笔、矩形、椭圆、直线、箭头、文字、马赛克、模糊、测距、取色、裁剪；**截图框可随时拖手柄改大小**（扩出去的部分从截屏那一刻的整屏原图里取） |
| 设置 | 7 个页签：通用、截图、贴图、OCR、录制、快捷键、关于 |

截图浮层的工具条按参考图重排成**一行图标**（选择 → 箭头 → 画笔 → 矩形 → 椭圆 → 直线 → 文字 → 马克笔 → 马赛克 → 模糊 → 测距 → 取色），颜色和粗细收进左边那颗"当前颜色"圆点的弹出层，OCR / 贴图这类低频动作收进 `⋯`。之前 6 色 + 3 档粗细平铺，工具条能撑到 1300pt宽。工具条始终贴着截图框（优先放下方，放不下放上方），框改完尺寸会跟着重新落位。

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

全工程没有一个 `CGEvent`。做法是装全局 + 本地两个 `scrollWheel` 监听（滚轮事件不需要辅助功能授权），用户自己滚，程序负责抓帧。

- **边滚边抓（节流 200ms）**：一次快速滑动就能滚掉一屏多，只等「停手后抓一帧」会拿到两帧几乎不重叠的画面，对不上就整段废掉。滚动过程中按 200ms 节流抓，步子小才稳。
- **尾部补一帧**：停手 180ms 后再抓一次，确保最后停留的位置一定被截到。
- **忙时不丢帧**：抓帧期间又滚了，置 `pendingGrab`，当前帧回来后补抓一次。
- 每帧都是重新走一遍 `SCScreenshotManager`，不是 `SCStream` 连续流。

### 缩略图：强制打开、不能关闭、180 × 600

滚动截图一开始就把缩略图面板建出来（`showPreview()`），跟着整个流程存在：无边框、没有标题栏、没有关闭按钮，也不接收鼠标事件（`ignoresMouseEvents`）—— 鼠标从它上面滚过去时滚轮事件直接落到下面的页面，不会把用户"卡"在缩略图里。标题实时显示累计像素尺寸。

落位是纯几何函数 `ScrollCaptureController.previewOrigin(region:visible:size:)`（可以脱离界面喂数字验，自检里有四条）：优先贴截图框**右侧**，右边放不下换**左侧**，竖直方向顶边对齐框顶边并夹进可见区。**不能被自己的取景框拍到**是硬约束 —— 重合了每帧都会把缩略图录进画面（同下面第 1 条坑）。左右上下都塞不下（截图框几乎占满整屏宽）时只能退到屏幕右边缘，这种框本来也不该配滚动截图。

### 取景框绝不能在选区里画东西

取景框是一圈**画在选区外侧**的边框 + 选区上方一条状态带（`ScrollFrameView`），选区内部全透明。原因见下面第 1 条坑：指望 ScreenCaptureKit 把自家窗口排除掉是靠不住的。顺带的好处是用户能看着页面滚，不至于对着一帧冻结的图猜「到底截没截上」。已捕获段数和本段位移写在状态带上。

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

固定表头 / 底栏在两帧里位置不变，会把最优解往 d≈0 拖，所以比较时跳过当前帧顶部 10% + 底部 4%（跳过量会被压到重叠区的 1/4 以内 —— 重叠只剩几十行时按帧高算的 50 行比重叠区还大，会把比较区削成负数，明明能对上却返回 nil）。搜索上界按「至少留 5% 重叠」算，不是写死 8%。两帧宽度差 1px 会累积错位，先统一到 `min(topW, bottomW)`；重叠区取上方帧的内容（下方帧可能带输入法候选框或滚动条闪烁）。横向滚动把图顺时针转 90° 复用同一套算法，拼完再转回来。

### 四个坑（都写进了注释）

1. **取景框被拍进了画面**（用户看到「不连续」的真凶）。取景框浮在选区正上方，框里还画着上一次的拼接预览 → 每帧截到的都是上一帧的预览。
   **`SCContentFilter(display:excludingWindows:)` 救不了**：我们的面板在 `.floating` / `.statusBar` 层，而 `SCShareableContent.windows` 基本只列 layer-0 的普通窗口，按 pid 过滤出来是空数组，excluding 成了空操作。诊断办法：把 `accumulated` 存盘看一眼 —— 第一帧顶部赫然烧着状态胶囊，就是自己的框被拍进去了。
   现在的做法是**取景框不在选区里画任何东西**（四条实心边框条 + 上方状态带，都落在选区外），不依赖那个 API。
2. **`CGContext` 位图缓冲是 top-down**。绘制坐标系是左下原点，但缓冲区第 0 行就是图像最上面一行，`CGImage.cropping(to:)` 的 y 也从顶部算。曾经「顺手翻转成 top-down」，等于两张图同时上下颠倒，正偏移 d 在数学上永远对不上（只有 `d = -offset` 成立），粗搜全落随机水平。
3. **`append` 的新高度是「已有高度 + offset」**，不是「top + bottom − 重叠」。写成后者等于把 bottom 的重叠部分又加了一遍：1173 行的页面拼出 2330 行，内容全是重复的。
4. **一帧对不上就永久卡死**。原来失败时只留一句提示、基准不动 —— 用户接着往下滚只会离基准更远，于是每一帧都失败，表现就是「只截了一次，之后怎么滚都不动」。现在：失败先反着对一次（判「往回滚」），连续 3 次失败就换基准从当前画面接着截（状态条上明说中间可能有缺口）。


## 标注渲染的三次翻车

三条都是「画了但看不见」级别的问题，注释里都留着原文：

1. **马赛克用直线路径裁剪 = 零面积**。`clip` 只认闭合区域，直线裁剪之后什么都画不出来。现在按「拖拽起止点围成的矩形」clip。
2. **`ctx.scaleBy` 方向反了**。标注存的是图像像素坐标，回到视图坐标要乘 `1/pixelScale`；曾经乘成 `pixelScale`，结果标注整体放大 4 倍画到图像区域外。
3. **画底图的顺序反了**。必须先在不翻转的标准空间画底图（那里 `CGImage` 方向才是正的），再 `translate + scaleBy(1, -1)` 翻成左上原点画标注。顺序反了底图整体上下颠倒——形状位置对、内容倒，特别迷惑。

标注一律存**图像像素坐标**，不存视图坐标。编辑器有缩放，保存/复制/贴图用的却是原始分辨率，坐标换算只该发生一次。撤销/重做是整数组快照（`undoStack: [[AnnotationShape]]`），没有上限也没有 NSUndoManager。

## 录屏：会话起点必须是第一帧视频的 PTS

`SCStream` + `AVAssetWriter`，H.264，码率 = `像素宽 × 像素高 × fps × 系数`（高 0.12 / 中 0.06 / 低 0.03 bpp）。

关键时序：`startSession(atSourceTime:)` 统一取**第一帧视频的 PTS**，音频帧在会话开始前到达就直接丢。丢零点几秒开头的声音，比留一个 PTS 早于会话起点的坏文件强。

声音是三选一互斥枚举（无 / 系统声 / 麦克风），**没有系统声 + 麦克风同时录的路径**。默认麦克风。没有「暂停过 + 无摄像头」时 `sampleBuffer` 零拷贝直通到 writer。

### 摄像头取景框：所见即所得，不在编码端合成

右下角那个圆形 / 圆角矩形小窗（`CameraBubble`）是一个**真的屏幕窗口**，进视频的方式就是被 ScreenCaptureKit 拍到，编码端**不再**合成画中画。

原因很硬：想让「窗口在屏幕上可见、但不进录像」只有一条路 —— 把它塞进 `SCContentFilter.excludingWindows`。可我们的面板在 `.floating` / `.statusBar` 层，而 `SCShareableContent.windows` 基本只列 layer-0 普通窗口，压根拿不到它，excluding 是空操作（滚动截图取景框那次已经踩过一模一样的坑，见上文）。所以选「屏幕上什么样，视频里就什么样」：

- 圆 / 圆角矩形右键切换，✕ 或工具条上的 📷 关掉，录制中也能开关（只是显示 / 隐藏一个窗口，视频管线完全不动）；
- 预览层自拍镜像，不然用户看到自己的手是反的；
- 因为不再合成，`AVAssetWriterInputPixelBufferAdaptor` 那条合成路径现在只服务「暂停后重编时间戳」。


录制时把自己的窗口放进 `excludingWindows`，浮条和贴图不会进画面。过滤条件按 **pid** 认自己，不按 `bundleIdentifier`：裸二进制调试时后者是 nil，过滤结果恒为空，等于没排除。

### 三个把「点录制」直接干掉的坑

1. 🔴 **`AVVideoAverageBitRateKey` 不能放在 `outputSettings` 顶层**。那是老写法，macOS 26 的 `AVAssetWriterInput` 当场抛
   `NSInvalidArgumentException: Output settings dictionary contains one or more invalid keys: AverageBitRate`，
   而这是 **ObjC 异常，Swift 的 `try/catch` 接不住** —— 进程直接 SIGABRT。
   表现就是「点一下录制，应用从菜单栏消失」，一行日志都留不下。码率必须塞进
   `AVVideoCompressionPropertiesKey` 字典里（`AVVideoExpectedSourceFrameRateKey` 一并放进去）。
   这个 bug 活了三个版本，因为它是**必崩**而不是偶发：`Recorder.swift` 里从前没有一行代码跑到过。
2. **H.264 要求宽高是偶数**：选区是随手拖的，501×301 之类很常见，像素宽高统一向下取偶。
3. **麦克风授权只问一次**：`requestMicThenCapture()` 以前被连着写了两遍，于是每次录音建两个
   `AVCaptureSession`，第二个把第一个顶掉、第一个继续失控地占着麦克风，两路音频还同时往同一个
   writer input 上 append。

启动是**异步**的（`SCStream` 还要等系统把显示器/窗口列表给回来），所以工具条在按钮已变成"停止"、
计时器已经在走之后才可能收到失败。失败必须把界面退回去（`startingUp` 标记），否则用户看到的是
"正在录"，实际一个字节都没写。麦克风/摄像头缺失走 **`onWarning`** 而不是 `onError` —— 少一路声音
不该把好好的录制退回去。

## 选区调整：拖出来先别截，等确认

两段式：拖出范围 → `.adjusting` 阶段（八向手柄 / 方向键 / ⇧ 正方形）→ **在选区内单击一下**（或回车）才真正截图。

- 🔴 **不要双击**。1.0.4 要求双击确认，用户明确否掉了 —— 单击最顺手。判定就一条：按下到松开的位移 ≤ 2pt 算单击（`RegionSelector.OverlayView.isTap`），超过就是"拖动选区"，手柄拖拽更不受影响。
- **Esc 不是出口**。用户要求「截图没完成，或没主动点击取消，都不能结束截图」：选区遮罩里 Esc 只撤当前选区，标注浮层里 Esc 只撤"正在画的那一笔"或待确认的裁剪，都不结束流程。要退出选区就**右键**（画面上常驻提示「拖动框选区域 · 右键取消」），要关标注浮层就点 ✕。在此之前 Esc 会直接把整条流程/整张标好的图丢掉。
- 截图浮层（标注工具栏那个）**点框外不会关闭**。原来点一下外面就把浮层关了、标注一起丢，属于"没主动取消却被结束"。
- `finish()` 里**不能当场把遮罩窗口和视图释放掉** —— 它在 `OverlayView.mouseUp` 的栈上被调用，当场析构就是 use-after-free（崩溃栈 `objc_release ← -[__NSArrayM dealloc] ← objc_autoreleasePoolPop`，随机闪退）。现在的做法是先 `orderOut`，强引用交给下一轮 runloop 再放。同理，所有程序化创建的 `NSPanel` 都设了 `isReleasedWhenClosed = false`，否则 `close()` 和 ARC 会抢着释放同一个窗口。

- **状态机是显式的**（`idle / dragging / adjusting / movingSelection / resizing`），而不是靠一堆布尔变量互相猜。滚动截图、录屏、OCR 共用同一个遮罩，改一处全部受益。
- **手柄容差 9pt**：太小点不中，太大又会把手柄拖拽变成移动选区。
- **移动时夹在屏内**（`bounds` 是这块屏幕），否则选区会跑到看不见的地方，截图请求直接失败。
- 方向键微调 **1px / ⇧ 10px**：对着像素做人眼校准，步长必须是 1。

## 标注阶段随时改截图框：整屏原图 + 关掉重开

截图框不是截完就钉死了。浮层的八个手柄都能拖，拖的时候画虚线预览框 + 框外压暗，松手才提交。

- **得多存一张整屏原图**。要把框拉大，扩出去的那块内容只有两个来源：重新截屏（会把我们自己的浮层拍进去，内容也可能已经变了）或者截屏那一刻的整屏原图。所以区域截图会额外抓一张 `SCDisplay` 全图，跟着浮层一起传下去。
- **窗口铺满整块屏幕**。窗口要是只比图大一圈，往外拖的预览框会被窗口裁掉，看着像没反应。现在图像面板 = 整个显示器，其余部分透明（透过去就是桌面，观感跟参考图一致）。
- **提交时"关掉自己、按新尺寸重开"**，和裁剪同一套：从整屏原图按新框 `cropping`，标注按 `旧原点 − 新原点` 平移，然后重开。坐标换算永远只有一套，不会留下半个旧状态。
- 🔴 **y 轴必须翻**：AppKit 是左下原点，整屏原图是左上原点，`pixelRect(for:displayFrame:pixelScale:)` 里 `y = 显示框.maxY − 框.maxY`。弄反了就是"拖框裁出屏幕另一头的内容"，而且自检看得见 —— 这条有断言。
- 🔴 **"关掉自己"必须推到下一轮 runloop**：`commitResize` 是被自己视图的 `mouseUp` 调起来的，而 `close()` 会让 AppModel 清掉 `overlayEditor` —— 控制器只剩视图里那个 `unowned` 引用，于是**在方法执行途中被释放**，下一行读 `self.model` 就是野指针（`RegionSelector.finish()` 当初崩四次同款）。做法：要用的值（裁好的图 / 新框 / 平移后的标注）先全部取成局部量 → `orderOut` 把旧框当场藏起来（别让用户看见弹回旧尺寸）→ `DispatchQueue.main.async` 里再 `close()` + 重开，并用局部强引用把控制器活到闭包结束。
- 「Retina 缩小到 1x」开着时文档是 1x、整屏原图是 2x，两边倍率对不上，标注没法平移，这时候直接不允许改尺寸（宁可不给，也不给错位的结果）。

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

🔴 **录制控件必须自己抢第一响应者**。`NSButton` 默认 `acceptsFirstResponder == false`，点它不会变成
firstResponder，`keyDown` 永远收不到 —— 界面上看着像在等按键，其实键盘事件全被窗口吃了，
这就是「快捷键设置不可用」的根因。现在 `RecorderButton` 覆写 `acceptsFirstResponder` 返回 true，
并在 `mouseDown` 里显式 `window?.makeFirstResponder(self)`（不调 `super`，否则走 momentary 高亮跟踪，
按键还是到不了）。

注册失败必须能被看见：`AppModel.failedShortcuts` 收着被系统拒掉的键位，设置页每行对号入座地标
「要加 ⌘/⌥/⌃，或改用 F1–F12」/「被系统占用，注册失败」。以前只 NSLog，用户录了个纯字母键，
看着"设置成功了"，实际一次都不会触发。

应用内的快捷键（⌘Z / ⌘C / ⌘S / Esc）是 NSEvent local monitor，只在浮层窗口是 key window 时生效，文字输入时不抢。

## 设置面板：三个"看着有效、其实空转"的坑

用户 1.0.9 的原话是「红框那些设置都无效」，查下来是三类不同的问题：

- **面板没观察设置本身**。`SettingsRootView` 只观察 `AppModel`，而设置是另一个 `PreferencesStore`（也是 ObservableObject）。改设置时 model 不发通知，面板就不重绘：勾选框看着回弹、Picker 选完还显示旧值。修法：每页都加 `@ObservedObject var prefs: PreferencesStore` 直接观察设置（快捷键页当初就是因为这个单独加过一次）。
- **「自动保存」没有目录就什么都不做**。原来 `guard prefs.autoSave, let dirPath = prefs.saveDirectory` —— 用户没选过目录时，开关打开了也是空转。现在 `PreferencesStore` 在 autoSave 变 true 且目录为空时当场补成桌面，界面把实际落盘目录显示出来。
- **编码失败静默返回**。`write()` 里 `guard let data = … else { return }`：JPG 编码万一失败，点「保存」什么都不发生也不报错，看着就像"保存格式这个设置没用"。现在会 flash 一句提示。

## Esc 的口径（改过三次，别再改回去）

1.0.6「Esc 退出」→ 1.0.7 改成「只撤选区」→ 1.0.9 用户明确要求「全局按 Esc 强制结束截屏」，恢复成一次到底：

| 阶段 | Esc 的行为 |
| --- | --- |
| 选区遮罩 | `cancel()`：整条流程收掉，不截图、不弹窗 |
| 标注浮层 | 第一次撤掉正在进行的动作（待确认裁剪 / 正在画的那一笔），再按一次关闭浮层（走 `close()`，自动保存开着照常落盘） |
| 滚动截图 | 直接结束，不返回图片 |
| 录制工具条 | 录制中 / 启动中**不响应**（防止误停），停止靠 ✕ 或工具条的停止按钮 |

## 提示音：和 BoxPaste 同一套系统音效

八档（Blow / Bottle / Funk / Glass / Hero / Morse / Ping / Purr），中文名照搬 BoxPaste，旁边有「试听」。播放点统一走 `AppModel.playFeedbackSound()`（开关和音效名都在设置里）；录制收尾那条在 `Recorder` 里拿不到 model，改由工具条注入 `finishedSoundName` —— 顺手修掉「关了提示音，录完还是会叮一声」。

存量配置里可能记着已下线的音效名，解码时校验一遍并落回 `Glass`，否则设置页 Picker 会显示空白。

## 摄像头取景框：三档尺寸

设置 → 录制 → 质量下面：大 / 中（默认）/ 小。**是相对倍数不是绝对值**（小 = 1.0，中 = 1.1，大 = 1.21），因为基准边长必须跟着选区走（选区只有 300pt 宽时，固定 200pt 的圆会挡掉半个画面）：`min(200, max(96, 短边 / 4)) × 档位`。用户口径是"现在这个大小算小"。

## Retina 1x 与「改截图框」的冲突

开了「缩小到 1x 再输出」后，文档是 1x、整屏原图是 2x，两边倍率不同。1.0.7 的处理是直接不允许改尺寸 —— 而且守卫是静默 `return`，用户看到的就是"拖手柄没反应"。现在按 `documentScale = 1/2` 换算：裁剪结果缩到 1x、标注位移乘 0.5，两个功能可以同时开。

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

当前 94 处断言，覆盖键位资格判定（含纯字母/空格不能当全局热键、F7 可以这几条）、拖手柄改截图框的几何（含屏幕框 → 像素矩形的 y 轴翻转）、拼接找回 60px 偏移、OCR 行聚类、偏好解码兜底、渲染管线（含「效果区域真的改了像素」和「底图没有上下颠倒」这两条）、撤销/重做、点选移动删除、文本贴图、文件名去重。只测纯逻辑，不碰屏幕捕获——无授权环境下跑不了，打包机也不该弹窗。

## 诊断

| 参数 | 作用 |
| --- | --- |
| `--selftest` | 跑自检，退出码即结果 |
| `--version` | 打印版本号 |
| `--show-overlay` | 延迟 0.6s 用**合成渐变图**打开标注浮层并预置四条标注，不走截图权限，配合 `screencapture -R` 核对浮层有没有真的把图画出来 |
| `--show-history` | 延迟 0.6s 打开截图历史面板；历史为空时先塞三张合成图（会**真的写进**历史目录，看完记得删） |
| `--show-settings` | 延迟 0.8s 弹出设置窗口。触发文件里可以写页号（`0` 通用 / `1` 截图 / `2` 贴图 / `3` OCR / `4` 录制 / `5` 快捷键 / `6` 关于），直接落到要核对的那一页 |
| `/tmp/boxshot-showsettings.trigger` | 同上，标记文件触发；文件内容是页号 |
| `--scrolltest` | 延迟 0.8s 直接开一次滚动截图（固定选区 120,120,900×620，不用人拖），用来核对常驻缩略图面板的位置 / 尺寸 / 实时刷新 |
| `/tmp/boxshot-scrolltest.trigger` | 同上，标记文件触发 |
| `--recordtest` | 不开界面，直接跑 3 秒真实录制（320×240 / MP4 / 无声），过程逐行写 `/tmp/boxshot-recordtest.log`，结束后自行退出。用于判断「点了录制没反应」是引擎起不来还是界面没接上 |
| `/tmp/boxshot-recordtest.trigger` | 同上，但靠**标记文件**触发：`touch` 之后正常启动应用即可。某些环境下 `open -a App --args …` 不会把参数传进 `CommandLine.arguments`（实测 LaunchServices 按原 argv 起进程），只能走这条 |

## 已知问题（待修）

- **贴图拖不动**：`mouseDragged` 里拿的是本次事件的增量 `event.deltaX/deltaY`，却加在 `mouseDown` 记下的原点上，于是每次拖拽位移只等于最后一次事件的增量（`PinController.swift:415-419`）。
- **屏幕测量每次启动只能用一次**：`measureOverlay` 赋值后从不置 nil，而 `startMeasure` 里 `guard measureOverlay == nil` 直接 return（`AppModel.swift:340-347`）。
- **录制输出固定桌面**，不跟「保存目录」设置（`Recorder.swift:67-69`）。
