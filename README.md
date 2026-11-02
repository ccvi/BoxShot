# BoxShot

原生 macOS 截图与录屏工具，一个菜单栏图标搞定 13 个动作：区域截图、滚动截图、OCR、二维码、屏幕测量、区域/全屏录制、贴图。

零第三方依赖——截图走 ScreenCaptureKit，识别走 Vision，热键走 Carbon，编码走 AVFoundation。

- 当前版本：**1.0.11**
- 作者：ccvi1223 · ccvi1223@qq.com
- 工程最低版本：`.macOS(.v14)`（`Package.swift`）
- 常驻形态：`LSUIElement = true`，只在菜单栏，不占 Dock

---

## 功能（1.0.12 已实现）

| 区域 | 能力 |
| --- | --- |
| 截图 | 区域截图（**拖完松手就截**，尺寸微调搬到截完的浮层里）、截图直进剪贴板、重复上次区域、全屏（鼠标所在屏）、窗口（轻点选窗口，窗口模式下强制高亮）；选区时**光标旁常驻放大镜**（15×15 源像素、坐标/区域/色值三行，**按 C 复制色值**） |
| 历史 | 最近 N 张截图落盘留档（默认 20），菜单「截图历史…」网格重看，可重开标注 / 复制 / 贴图 / Finder 定位 |
| 滚动截图 | 手动滚动自动抓帧拼接，横向/竖向都能拼，「缩略图」窗口实时跟着长 |
| 识别 | OCR（中英混排，可保留换行、可追加到剪贴板）、二维码/条形码 11 种码制 |
| 屏幕测量 | 全屏遮罩拉框测距，按**物理像素**报数 |
| 录屏 | 区域/全屏录制，工具条带计时、**暂停/恢复**、麦克风/系统声音切换、格式（MOV / MP4 / **GIF**）与质量选项、**摄像头取景框**（圆形 / 圆角矩形，可随时关掉） |
| 贴图 | 从截图/剪贴板/Finder 贴图，滚轮缩放、双向翻转、双击动作可选、历史可恢复；**文本贴图的文字可以直接选中**，每张贴图右上角有**置顶按钮**（悬停才出现） |
| 标注 | 13 种工具：选择、箭头、画笔、矩形、椭圆、直线、文字、马克笔、马赛克、模糊、测距、取色、**高亮**（1.0.11 起裁剪从工具条和 `⋯` 里都拿掉了）；**截图框可随时拖手柄改大小**（扩出去的部分从截屏那一刻的整屏原图里取） |
| 设置 | 7 个页签：通用、截图、贴图、OCR、录制、快捷键、关于 |

工具条从左到右：选择 → 箭头 → 画笔 → 矩形 → 椭圆 → 直线 → 文字 → 马克笔 → 马赛克 → 模糊 → 测距 → 取色 → **当前颜色圆点** → 撤销 → 重做 → **高亮** → OCR → 解码 → **贴图** → 复制 → 保存 → 关闭。

截图浮层的工具条按参考图重排成**一行图标**（选择 → 箭头 → 画笔 → 矩形 → 椭圆 → 直线 → 文字 → 马克笔 → 马赛克 → 模糊 → 测距 → 取色），颜色和粗细收进左边那颗"当前颜色"圆点的弹出层。1.0.11 起 **`⋯` 菜单取消**：里面的 OCR / 解码 / 贴图 三个动作全部摊到工具条上，"复制到剪贴板"那条本来就和工具条上的 📋 重复，一并去掉。之前 6 色 + 3 档粗细平铺，工具条能撑到 1300pt宽。工具条始终贴着截图框（优先放下方，放不下放上方，上下都放不下压进框内底部），框改完尺寸会跟着重新落位 —— 见下文「工具条落位」。

### 颜色面板：贴在工具条下面，6 个颜色

点工具条上那颗「当前颜色」圆点，会在工具条**下方**展开一块面板：**6 个圆形色块**（黄 `#F8CE43` / 绿 `#62C563` / 蓝 `#3887FB` / 红 `#EB4259` / 橙 `#F3933D` / 紫 `#BD3DDD`，`OverlayEditorController.colorPalette`，直径 **18.72pt**（26 的 80% 再 ×90%，用户口径 1.0.10「小 20%」→ 1.0.11「再小 10%」）、圆角取半径）+ 3 档粗细。色值是照用户给的色卡逐像素取的，自检里连顺序一起钉住。以前是 `NSPopover`，弹在圆点旁边、压住截图内容，位置还跟着圆点跑；现在是一块独立浮层，贴工具条下沿 8pt，横向与工具条左对齐（下面放不下就翻到工具条上方）。

色块一路缩下来（26 → 20.8 → 18.72），面板高度从 48 → 37 → **35pt**。两个连带项不能漏：分隔线（`colorPanelDividerHeight = 18`）和那 3 颗粗细按钮 —— 后者原来是 27×32 硬编码，比色块高，面板就被它撑住不跟着缩（而且 32 高塞进 21 高的行里会被裁成"一条虚线"）。现在它的高 = 色块直径、宽 = 直径 × 1.3，示意线也按这个尺寸重画。诊断脚本里那颗合成点击的坐标是按 `swatchSide` 算的，改直径不用动它。

两个坑都出在同一件事上 —— **`NSStackView` 只认 `intrinsicContentSize`**：

- 色块是"空标题 + `layer.backgroundColor` 上色"的 `NSButton`，没有任何内容能算尺寸，于是宽高都是 0，整排色块被压成 0 宽 —— 面板看着是**空的**（`fittingSize` 也只有那几个有图标的粗细按钮那么宽）。修法：给色块 / 粗细 / 分隔线各加显式的宽高约束。
- 同一颗「当前颜色」圆点更早就中过这个招：它在工具条里，尺寸一直是 0，用户根本**看不见**有这个东西可点。1.0.10 一起补上约束。

另外非 key 窗口里的 `NSButton` 默认 `acceptsFirstMouse = false`，点颜色要连点两次才生效，所以色块用的是 `FirstMouseButton`（一律接受首击），面板本身也做成能成为 key 的窗口。

### 高亮：聚光点亮，不是染色

用户把工具条上原来那个「裁剪」位置要走了，换成**高亮**。第一版做成了"荧光笔染色"（`multiply` + 38% alpha 铺一层颜色），用户随后附样张纠正：他要的是**聚光**——拖出的矩形**一个像素都不动**（文字仍是最深的黑、底色仍是原色），把图里其余部分压暗 60%。

量他样张得到的口径：框外 `(102,102,102)`、框内纯白、框内文字最暗 18 —— 也就是"框内完全没被覆盖"。所以现在的实现是：

```swift
ctx.addRect(canvas)            // 整幅画布
ctx.addRect(spot)              // 要点亮的那块
ctx.clip(using: .evenOdd)      // 只剩"矩形外面"
ctx.setFillColor(CGColor(gray: 0, alpha: 0.6))
ctx.fill(canvas)
```

三个坑记在这里：

- **不要用 `shape.color`**：聚光没有"颜色"这个概念，跟当前选的颜色无关，恒定用黑色压暗。改动前那版是按颜色染，才会出现"选白色 = 什么都看不见"。
- **alpha 0.6 是从样张量出来的**，不是随手定的（白底 → 102 灰）。自检里钉了这条。
- SwiftUI 侧（独立编辑窗口）同样的效果必须**包一层 `drawLayer`**：`GraphicsContext` 是值类型，直接在 `context` 上 `clip` 会把后面所有标注一起裁掉（症状是"画了高亮，别的标注全不见了"）。

它和「马克笔」也不是一回事 —— 马克笔是**半透明的笔画**（跟着手走），高亮是**一块面**（拉框，只点亮这块）。

### 工具条尺寸：倍率开关 + 只缩「当前颜色」圆点

工具条的尺寸全部从一个倍率推出来（`OverlayEditorController.toolbarScale`）：图标字号 / 圆角 /
间距 / 内边距 / 分隔线高度 / 容器圆角。**当前值 1.0 = 原尺寸**，实测 **514×32pt**
（原来是 523×32，少的 9pt 就是颜色圆点从 30 缩到 21）。

用户 1.0.11 的原话是「工具条那个控制颜色的小圆按钮缩小 30%」。第一版我把整个工具条按
0.7 缩了 —— 他说的是**那颗圆点**。所以现在：

```swift
static let toolbarScale: CGFloat = 1.0            // 工具条原样
static let colorAnchorSide: CGFloat = 30 * 0.7    // 只有这颗圆点缩 30% → 21pt
```

🔴 **不要给工具条按钮加显式宽高约束**：这类"空标题 + 图片"的按钮，内禀尺寸来自图片本身，
给约束反而会把它钉死。而且原来那句 `frame = 40×38` **从来没生效过**
（`NSStackView` 只认 `intrinsicContentSize`，真实按钮约 24×32）—— 如果照着 40×38 去算
"缩 30%"，会得出 596×39，比原尺寸还大。**改比例之前先量基准**：
诊断浮层启动时会打一行 `[BoxShot][toolbar] frame=`，直接读，不要靠截图目测。

例外是「当前颜色」圆点：它只有 `layer.backgroundColor`、没有图片，内禀尺寸是 0，
显式约束不能省（省了会被压成 0 宽、整个圆点看不见）。

### 工具条落位：下 → 上 → 框内底部，间距 10pt

三步口径（`OverlayEditorController.toolbarOrigin(selection:toolbarSize:visible:)`，纯函数，自检里有 9 条断言）：

| 顺序 | 条件 | 落点 |
| --- | --- | --- |
| ① | 框下方放得下（默认） | 工具条**底边**比框底边低 **10pt** |
| ② | 下方顶到可见区底边 | 工具条**底边**比框顶边高 **10pt** |
| ③ | 上下都不够（框高顶满整屏） | **压进框内底部居中**，底边距框底 10pt；框比工具条还矮时竖直居中 |

横向一律按框中线居中，再夹进可见区。

两个坑：间距以前是 8pt（用户要求 10pt）；「放上方」那支以前写的是 `selectionFrame.maxY + barHeight + 8` —— `barHeight`（30）是图内那条刻度带的高度，跟工具条毫无关系，于是往上放时会凭空多出 30pt 空隙，看着像"跑偏了"。

③ 这条基本只在框很高时才出现，真机上很难手动复现，所以顺手加了 `--show-overlay-tall`（用一个 520×1020 的合成框开浮层）专门看它。


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

## 框完就截：选区阶段没有"调整态"了

1.0.10 起，拖完**松开鼠标就是截图**。之前要再「单击选区内」或按 ⏎ 确认一次，用户看到那行提示的反应是「我以为还没截」，多一步还容易以为卡住了。

- 阈值照旧：宽或高 < 8pt 视为误触，留在选区模式，不产生一张 3×5 的废图。
- **代价是选区阶段的八向手柄、方向键微调、Shift 约束正方形一起下线**（它们都挂在"调整态"上）。改尺寸这件事本来就在截完的浮层里做，那里有真手柄、能拖框、能扩出去从整屏原图取内容，比在遮罩上调更完整。
- 提示文案跟着改成「拖动框选区域 · 松手即截图 · Esc 或右键取消」，拖拽中显示「W × H · 松手即截图」。
- 验收用 `--dragtest`：合成 10 步 `leftMouseDragged` 后再 `leftMouseUp`，判定「遮罩自己收掉 + 浮层按拖出来的框打开」。实测拖 560×420，浮层 `frame=(420, 387, 560, 420)`（AppKit 左下原点，`1107-720=387` 对得上）。

## 参数接进来却没人用：窗口截图等于普通截图

`startRegionShot(copyDirectly:windowPickMode:pipeline:)` 里的 `windowPickMode` **一直是只进不出**——签名收了这个参数，函数体里没人读，于是「窗口截图」和「开始截图」行为完全一样；除非用户碰巧在设置里开了「窗口高亮」，否则点窗口根本没有可点的目标，看起来就是"这个动作没生效"。

现在：`highlightWindows: windowPickMode || prefs.value.windowHighlight`，且窗口模式下**关掉十字线**（要的是点窗口，不是拉框）。验收用 `--windowtest`：合成一次单击，检查浮层框明显小于全屏（实测拿到 `(0, 58, 855, 1015)`，正是当时那个前台窗口）。

## 窗口截图：框不能动，也得能改大小

窗口截图走的是另一条路：它不重新截整屏，而是用 `SCContentFilter(desktopIndependentWindow:)` 单独抓那个窗口（被遮住也能抓到干净内容）。1.0.9 之前它**不带整屏原图**，于是两个毛病一起冒：

1. `canResize = fullDisplay != nil` → 窗口截图的框**拖不动**（用户："也可以调整大小"）；
2. 浮层窗口的尺寸是"窗口框 + 上下留白"（上面还要放 30pt 的刻度带）。框一高就顶出屏幕，AppKit 在 orderFront 时会调 `constrainFrameRect(_:to:)` 把它推回来 —— **整张图跟着下移**，和真实窗口错位（用户："自动捕捉大窗口时，截图框不要移动"）。

现在也给窗口截图一份 `FullDisplay`：**裁切基准**是「窗口图 + 窗口框」（`commitResize` 会 intersection 到这个框，所以只能往里收、扩不出去），**浮层范围**是整块屏幕（`panelFrameAppKit`）。浮层铺满屏就不会再被 constrain 推走。

实测（`--windowtest`）：窗口框 `(0,58,855,1015)`、浮层 `(0,0,1710,1107)` 与屏幕完全一致；拖右下角手柄向内 120pt 后变成 `(0,178,735,895)`。

> 教训：加参数先搜一遍它在函数体里出现过几次。`swift build` 不会为「未使用的形参」报警（它本来也允许），这种洞只有端到端跑一遍才露出来。


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


录制时把自己家的浮条 / 工具条 / 贴图放进 `excludingWindows`，它们不会进画面。过滤条件按 **pid** 认自己，不按 `bundleIdentifier`：裸二进制调试时后者是 nil，过滤结果恒为空，等于没排除。

🔴 **但按 pid 一刀切会把「本意要录进去」的窗口一起排掉** —— 摄像头取景框就在同一个进程里。1.0.9 的用户反馈「录制生成的视频没有摄像头的影像」就是这条：取景框明明在屏幕上，却被自己的排除名单干掉了。现在 `Recorder` 多一个白名单：

```swift
var keepVisibleWindowNumbers: Set<Int> = []   // 工具条把取景框的 windowNumber 塞进来
let ownWindows = content.windows.filter {
    $0.owningApplication?.processID == ownPID && !keep.contains(Int($0.windowID))
}
```

并且每次开录都留一行 `lastExclusionReport`（`排除 N 个 · 保留 M 个 · 本进程窗口 K 个`）—— 这类问题只能靠这三个数字判断错在哪一侧，光看画面分不清是「没上屏」还是「被排掉了」。实测：`排除 0 个 · 保留 1 个`，成片抽帧右下角能看到人像。

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

## 放大镜：先抓底图，再上遮罩

选区时在光标旁常驻一块放大镜（`Capture/Magnifier.swift`），15×15 个源像素放大到 150pt、一格 = 一个像素，下面接 74pt 的信息条：坐标 / 区域 / 色值，色值前带 14×13 的小色块。**按 C 把色值复制走**（显示用 `#64 9E 60` 这种两位一组带空格的写法，复制出去是紧凑的 `#649E60`，两个场景要的东西不一样）。

四个踩过的点：

- 🔴 **顺序：先 `captureDisplay` 抓整屏原图，再建遮罩窗口**。反过来（先 show 再抓）抓到的是已经被自己压暗 28% 的那一屏，色值整体偏暗、拿去做设计全是错的。代价是遮罩晚约 100ms 出现；抓图期间用 `isActive = true` 占位，避免热键连按叠出第二个遮罩。
- **放大镜画在遮罩视图里，不另开窗口**。另开一个透明置顶窗意味着又要处理「非 key 窗口收不到事件 / 落位 / 多屏」一整套问题，而遮罩本来就铺满整屏、本来就在收鼠标事件。代价是每次 `mouseMoved` 都要重绘整屏（放大镜必须跟着光标走），`needsDisplay` 只在开启放大镜时才置位。
- **落位先翻再夹**：默认光标右下 16pt；右边放不下翻左、下边放不下翻上，最后才整体夹进屏幕。夹在翻之后 —— 顺序反了贴边时镜会压住光标。
- **捕捉原点可选**（左上 / 右上 / 左下 / 右下），坐标按用户选的那个角数；默认左下角，照用户给的样张定。

验收不用真去拖选区：`--loupetest` 把放大镜离屏渲染成 PNG。源图刻意做成「顶部一条红、底部一条蓝」，光标压在红条下沿 —— 镜里红条在上就是对的，跑到下面就是翻面了。

## 贴图：文本贴图的文字可选，每张都有置顶按钮

贴图窗是 `NSPanel([.borderless, .nonactivatingPanel])`，默认 `level = .floating`，双击和滚轮交互全在内容视图里。历史落盘在 `~/Library/Application Support/BoxShot/pins/`，索引 `pins.json`，启动时按 `maxPinHistory` 恢复。

1.0.12 起分成两种内容视图，公共部分（拖拽 / 滚轮缩放 / 双击 / 右键菜单 / 置顶按钮）抽到 `PinSurfaceView`：

- **图片贴图** = `PinContentView`，照旧把 `CGImage` 画上去。
- **文本贴图** = `PinTextContentView`：不再把文字当图看，里面是**可选中的 `NSTextView`**（`isEditable = false, isSelectable = true`）。位图仍然保留——「复制图片」和历史落盘还要用它，`PinRecord` 多一个 `text` 字段，恢复时按文字重建文本视图。

两个必须注意的地方：

- 🔴 **文字的拖拽边界**：文字区域整块交给 NSTextView 选字，拖窗口只认四周 12pt 留白；想在文字上直接拖就按住 **⌘**（`PinSelectableTextView` 在 ⌘ 按下时不调 super，改走窗口移动）。选字优先是有意的——不能为了好拖把「可选」做回假的。
- 🔴 **`canBecomeKey` 必须对文本贴图返回 true**：返回 false 的话 NSTextView 拿不到 first responder，字能拖蓝但 **⌘C 复制不走**。图片贴图仍然返回 false（不抢用户正在打字的窗口）。

置顶按钮钉在右上角，**鼠标移进贴图才显示**（常驻会切掉画面一角），点一下在 `.floating` ↔ `.normal` 之间切。按钮是 `FirstMouseButton`（`acceptsFirstMouse` 为 true），否则非 key 窗口里第一下点击会被吞掉，看着像「按钮按不了」。

1.0.11 一次修掉三个：

- **贴图是倒的**：`PinContentView.isFlipped = true`（左上原点、y 向下），在这个坐标系里直接 `ctx.draw(cgImage)` 画出来就是上下颠倒。和截图浮层、滚动拼接一样要走标准配方——先 `translateBy(0, h)` + `scaleBy(1, -1)` 翻回 y 向上的标准空间再画。**这一步必须在镜像（`flippedH`/`flippedV`）之前**，否则"垂直翻转"的含义会跟着反。
- **拖不动**：`mouseDragged` 拿的是**增量** `event.deltaX/deltaY`，却加在 `mouseDown` 记下的原点上（原点之后没更新），于是每帧都把窗口摆回"起点 + 一点点"。改成用**屏幕坐标差**（`NSEvent.mouseLocation` 减按下时的位置）：既不受原点不更新的影响，也不受"窗口自己在动导致 `locationInWindow` 漂移"的影响。另外 `acceptsFirstMouse` 必须返回 true —— 非 key 窗口默认把第一下点击吞掉。
  🔴 顺带一个验证坑：**合成事件（CGEvent）里 `deltaX/deltaY` 恒为 0**，所以靠 delta 的实现无论修没修好都测不出来；换成屏幕坐标差之后 `--pintest` 的 Δy 才等于投出去的 80pt。
- **恢复出来的贴图小一半**：`scale` 的语义是"相对 1:1 的倍数"（`applyScale` 里 `baseW × scale`），初始值却写成 `1/backingScale`（0.5）。窗口一旦被重排（首次缩放 / 从历史恢复）就只剩一半。初始值改 1.0，`PinRecord` 加 `v` 字段（旧记录没有 → 按 1:1 恢复）。

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

## 🔴 无边框窗口一个键都收不到（1.0.10 才找到）

用户连着两版报「全局按 Esc 强制结束截屏没生效，截图、窗口截图都没生效」。前两次都在改**判断**（Esc 该退到哪一层、要不要只撤选区），而真正的病根是**按键从来没进过这个进程**：

`NSWindow` / `NSPanel` 的 **`canBecomeKey` 默认是 `false`**（无边框窗口尤其）。窗口不是 key window，`keyDown` 就一个键都收不到 —— `makeKeyAndOrderFront(nil)` 叫了也白叫，`NSApp.keyWindow` 甚至是 nil，而代码看上去两句都在。修法是子类覆写：

```swift
final class KeyableWindow: NSWindow   { override var canBecomeKey: Bool { true }; override var canBecomeMain: Bool { false } }
final class KeyablePanel:  NSPanel    { override var canBecomeKey: Bool { true }; override var canBecomeMain: Bool { false } }
```

选区遮罩、标注浮层、滚动截图的取景框都换成了这两个类。

**还有第二条，顺序不能反**：先 `NSApp.activate(ignoringOtherApps: true)`，再 `makeKeyAndOrderFront` + `makeKey()`。反过来写时应用还没 active，AppKit 会把「become key」推后到激活之后，中间那段时间窗口**看得见但收不到键盘**。

最后再挂一条 `NSEvent.addLocalMonitorForEvents(matching: .keyDown)` 兜住 Esc —— 只要应用收到键盘，就算窗口因为系统原因没拿到焦点也能退出。

### 验证 Esc 要投真键，不能只投自己的队列

`NSApp.postEvent` 只是往**自己的**事件队列里塞一个事件，绕不过窗口服务器，所以它通过并不代表用户按下去也能过。1.0.9 就是被这条骗过去的。真正的等价物是 HID 层投放：

```swift
let src = CGEventSource(stateID: .hidSystemState)
CGEvent(keyboardEventSource: src, virtualKey: 53, keyDown: true)?.post(tap: .cghidEventTap)
```

⚠️ 这需要本进程有辅助功能授权（`AXIsProcessTrusted()`），否则 `post` 是往空气里发、日志里只会看到「没生效」，很容易误判。1.0.10 的实测结论：`AX=true` 时 HID Esc 立刻收掉遮罩；`AX=false` 时同一份代码两条路都失败。


## 提示音：和 BoxPaste 同一套系统音效

八档（Blow / Bottle / Funk / Glass / Hero / Morse / Ping / Purr），中文名照搬 BoxPaste，旁边有「试听」。播放点统一走 `AppModel.playFeedbackSound()`（开关和音效名都在设置里）；录制收尾那条在 `Recorder` 里拿不到 model，改由工具条注入 `finishedSoundName` —— 顺手修掉「关了提示音，录完还是会叮一声」。

### 什么时候才响（用户口径：截完了才响）

"完成"= 这件事有了结果：**OCR 出字、识别码出内容、复制进剪贴板、保存成文件**。

抓下画面本身**不算**完成 —— 以前 `routeCapturedImage` 一开头就响，后面复制/保存再响一次，一张图能叮两声，听着莫名其妙。现在那一声挪到"直接复制"分支里（那条路径确实是完成），其余各控制器（浮层、独立编辑窗、滚动截图、历史面板、录制收尾）各自在自己完成的那一刻响。

存量配置里可能记着已下线的音效名，解码时校验一遍并落回 `Glass`，否则设置页 Picker 会显示空白。

## 摄像头取景框：三档尺寸（绝对值）

设置 → 录制 → 质量下面：**大 170 / 中（默认）150 / 小 140**（pt，圆形取直径、圆角矩形取宽度）。

一开始做的是"相对倍数"（跟着选区短边算），用户明确要"我说多大就多大"，于是改成绝对值。只在选区**短边的一半**放不下时才收一收 —— `min(档位, max(96, 短边 × 0.45))`：170pt 的圆压在 300×200 的选区上会把要录的内容盖掉大半，这种极端情况按比例缩，正常尺寸完全照设置的数值来。

## Retina 1x 与「改截图框」的冲突

开了「缩小到 1x 再输出」后，文档是 1x、整屏原图是 2x，两边倍率不同。1.0.7 的处理是直接不允许改尺寸 —— 而且守卫是静默 `return`，用户看到的就是"拖手柄没反应"。现在按 `documentScale = 1/2` 换算：裁剪结果缩到 1x、标注位移乘 0.5，两个功能可以同时开。

## 工程结构

```
Sources/BoxShot/
├── main.swift              诊断参数必须抢在 NSApplication.run() 之前
├── App/                    AppDelegate（窗口/菜单装配）、AppModel（13 个动作的调度）、SelfTest
├── Capture/                RegionSelector（截图前遮罩）、Magnifier（选区放大镜：几何+文本+绘制，纯函数化）、
│                           KeyablePanel（能成为 key 的无边框窗口/面板）、OverlayEditor（截图后原位浮层）、
│                           ScrollCaptureController、Recorder、RecordToolbar、CameraBubble、MeasureOverlay
├── Core/                   ScreenCapture、Stitch、OCR、Shortcuts、HotKeyCenter、Preferences、
│                           SoundFeedback、Support、ShotHistory
├── Editor/                 AnnotationModels（数据模型 + 渲染器）、EditorView、EditorWindow
├── Pin/                    PinController（贴图窗 + 历史；图片贴图 / 文本贴图两种内容视图）
└── UI/                     StatusItemController、SettingsView、ResultWindow、HistoryWindow

Resources/
├── icon-master.png         图标母版（1024×1024 RGBA，图形 824 居中）
├── icon-master.jpg         同一张的 JPEG 备份
└── Info.plist              打包时注入版本号
```

### 换图标只换母版

`build-app.sh` 每次都从 `Resources/icon-master.png` 重新生成整套 iconset → icns（同母版同字节，可复现）。所以换图标**只改这一个文件**，别去动 icns：新图先按 macOS 的图标网格处理成 1024×1024、图形 824 居中、四周透明，再覆盖母版。

抠图别用"颜色接近白就透明"—— 这枚图标主体本身就是白色的字母 S，会被抠出洞。做法是从**四角泛洪**只吃掉与边缘连通的白色，再给 alpha 加 0.9px 高斯羽化（JPEG 的硬边直接抠会留一圈白线）。

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
| 开机自启 | 已下线（1.0.9 按用户要求整项去掉）。存量机器上的 `~/Library/LaunchAgents/com.pcxx.boxshot.plist` 由启动流程清掉，否则会留一个界面里关不掉的自动启动项 |
| 默认截图目录 | 桌面（`saveDirectory` 为 nil 时每次弹面板问） |

配置解码是手写的，每个字段 `decodeIfPresent ?? 默认值`——新增字段不能让旧配置整份作废，否则升级一次设置全丢。

## 版本规则与自检

版本号唯一来源是根目录 `VERSION`，打包时按源码指纹（`Package.swift` + `build-app.sh` + `Sources` + `Resources` 全部文件 sha256 后排序再 sha256）决定是否 patch +1。**源码没变就不涨**——版本号在一个只有补丁位的方案里是用掉就回不来的，虚涨不可逆。

自检在 `build-app.sh` 里是硬门禁，不过就 `exit 1` 不产出 `.app`：

```bash
.build/release/BoxShot --selftest
```

当前 153 处断言，覆盖键位资格判定（含纯字母/空格不能当全局热键、F7 可以这几条）、拖手柄改截图框的几何（含屏幕框 → 像素矩形的 y 轴翻转）、工具条三条落位分支与 10pt 间距、**工具条尺寸 6 条（倍率 1.0 原尺寸 / 字号 19 / 内边距·间距·圆角·分隔线回到原值 / 颜色圆点 21 / 圆点=30×0.7）**、颜色面板 9 条（6 色名单与色值 / 圆形 / **直径 18.72pt** / 分隔线不高于色块 / 贴工具条下方 / 左对齐 / 翻上方 / 不越界）、高亮 6 条（**块内不染色 / 块外压暗 / 0.6 强度 / 命中 / 拖拽 / 文案不是"半透明"**）、拼接找回 60px 偏移、OCR 行聚类、偏好解码兜底、提示音八档名单、取景框三档绝对值、滚动缩略图 180×600 与四条落位几何、渲染管线（含「效果区域真的改了像素」和「底图没有上下颠倒」这两条）、撤销/重做、点选移动删除、文本贴图、**贴图窗口 1:1 尺寸与 2 倍缩放（3 条）**、**贴图文字可选与置顶 8 条（文本用文本视图 / 能成为 key / 默认置顶 / 切两次 / 图片贴图不抢 key / 两种都带按钮）**、**放大镜 14 条（落位四向 + 四角不越界 / 四个原点口径 / 裁块居中与钳边 / HEX·RGB 文本 / HEX 往返 / 坏输入兜底）**、文件名去重。只测纯逻辑，不碰屏幕捕获——无授权环境下跑不了，打包机也不该弹窗。

## 诊断

| 参数 | 作用 |
| --- | --- |
| `--selftest` | 跑自检，退出码即结果 |
| `--version` | 打印版本号 |
| `--show-overlay` | 延迟 0.6s 用**合成渐变图**打开标注浮层并预置四条标注，不走截图权限，配合 `screencapture -R` 核对浮层有没有真的把图画出来 |
| `--show-overlay-tall` | 同上，但用一个 520×1020 的**高框**，专门看工具条「上下都没位置 → 压进框内底部居中」那条分支 |
| `/tmp/boxshot-showoverlay-tall.trigger` | 同上，标记文件触发 |
| `--show-overlay-color` | 同上，并自动展开**颜色面板**，再合成一次点击选黑色，日志写 `/tmp/boxshot-overlaycolor.log`（面板 frame / 是否 key / 命中测试 / 换色前后）。验"颜色面板能不能点"就靠它 |
| `/tmp/boxshot-showoverlay-color.trigger` | 同上，标记文件触发 |
| `--show-history` | 延迟 0.6s 打开截图历史面板；历史为空时先塞三张合成图（会**真的写进**历史目录，看完记得删） |
| `--show-settings` | 延迟 0.8s 弹出设置窗口。触发文件里可以写页号（`0` 通用 / `1` 截图 / `2` 贴图 / `3` OCR / `4` 录制 / `5` 快捷键 / `6` 关于），直接落到要核对的那一页 |
| `/tmp/boxshot-showsettings.trigger` | 同上，标记文件触发；文件内容是页号 |
| `--scrolltest` | 延迟 0.8s 直接开一次滚动截图（固定选区 120,120,900×620，不用人拖），用来核对常驻缩略图面板的位置 / 尺寸 / 实时刷新 |
| `/tmp/boxshot-scrolltest.trigger` | 同上，标记文件触发 |
| `--recordtest` | 不开界面，直接跑 3 秒真实录制（320×240 / MP4 / 无声），过程逐行写 `/tmp/boxshot-recordtest.log`，结束后自行退出。用于判断「点了录制没反应」是引擎起不来还是界面没接上 |
| `/tmp/boxshot-recordtest.trigger` | 同上，但靠**标记文件**触发：`touch` 之后正常启动应用即可。某些环境下 `open -a App --args …` 不会把参数传进 `CommandLine.arguments`（实测 LaunchServices 按原 argv 起进程），只能走这条 |
| `--esctest` | 开遮罩 → **HID 层真按键** Esc → 看遮罩收没收。日志 `/tmp/boxshot-esctest.log`，会先打印 `keyWindow` 类名和 `AXIsProcessTrusted()`；AX 未授权时 `CGEvent.post` 等于发空气，会退到 `postEvent` 再试一次并注明"只有 postEvent 生效" |
| `/tmp/boxshot-esctest.trigger` | 同上，标记文件触发 |
| `--escwait` | 开遮罩后**什么都不投**，纯等 15 秒外部真按键（人手按 / 带授权的 `osascript`），逐条记录收到的 `keyDown`。用来区分「代码没接住」和「按键根本没进来」 |
| `/tmp/boxshot-escwait.trigger` | 同上，标记文件触发 |
| `--dragtest` | 开遮罩 → 合成 10 步左键拖动 + 松手 → 判定遮罩收起且浮层按拖出来的框打开。验「松手即截」，日志 `/tmp/boxshot-dragtest.log` |
| `/tmp/boxshot-dragtest.trigger` | 同上，标记文件触发 |
| `--windowtest` | 走「窗口截图」动作 → 合成一次单击 → 检查拿到的框是否明显小于全屏（小于 = 真的点到了某个窗口，等于全屏 = 点到的是自家遮罩）。日志 `/tmp/boxshot-windowtest.log` |
| `/tmp/boxshot-windowtest.trigger` | 同上，标记文件触发 |
| `--recordcamera` | 上屏取景框 → 全屏录 4 秒 → 从成片里抽 2.0s 处一帧存 `/tmp/boxshot-recordcamera-frame.jpg`。日志里带 `排除 N 个 · 保留 M 个` 的排除报告，验「录出来的视频有没有摄像头画面」只能靠它 |
| `/tmp/boxshot-recordcamera.trigger` | 同上，标记文件触发 |
| `--pintest` | 钉一张「上红下蓝」的 400×200 合成图 → 记窗口 frame → 投一次 80pt 的 HID 拖拽 → 比对 Δy。日志 `/tmp/boxshot-pintest.log`，同时验证"朝向对不对"（截图看红条在上面）和"能不能拖" |
| `--loupetest` | 把放大镜**离屏**渲染成 `/tmp/boxshot-loupe.png`：不用截图权限、不用真拖选区。源图刻意做成「顶部一条红、底部一条蓝」，红条跑到下面就是翻面了（对称图案看不出来） |
| `--menutest` | 打印菜单栏每一项的 `isEnabled`。**菜单项 target/action 写错不报错、只会变灰**，只有打出来才看得见（`/tmp/boxshot-menutest.log`） |

## 已知问题（待修）

- **屏幕测量每次启动只能用一次**：`measureOverlay` 赋值后从不置 nil，而 `startMeasure` 里 `guard measureOverlay == nil` 直接 return（`AppModel.swift:340-347`）。
- **录制输出固定桌面**，不跟「保存目录」设置（`Recorder.swift:67-69`）。
- **文本贴图的文字区域不能直接拖窗口**，要抓四周留白或按住 ⌘。选字优先是刻意的取舍，但如果用户反馈拖着别扭，可以在文字上按「有选区就选字、没选区就拖窗」再分一次。
