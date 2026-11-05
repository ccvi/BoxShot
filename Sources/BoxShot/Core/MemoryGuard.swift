import Foundation

// ============================================================
// 内存自愈重启
//
// 用户口径（2026-11-05）：
//   「应用重启：300MB + 空闲 60 秒就自动触发；30 分钟内最多一次；
//     24 小时连续 3 次重启后仍超阈值 → 停用。关闭应用再重新打开就相当于重置以上规则。」
//
// 这套东西分两层：
//   · `MemoryGuard`（本文件的 enum）—— **纯规则**：喂进去"内存多少 / 忙不忙 / 上次重启啥时候 /
//     几次了"，只回答 idle / restart / disabled。全是静态函数，自检能直接验，不用起真进程。
//   · `MemoryGuardRunner` —— 5 秒一跳的驱动，负责读内存、问忙闲、落盘、喊人重启。
// ============================================================

enum MemoryGuard {

    /// 到线阈值 300MB。口径是**物理足迹**（`phys_footprint`），跟活动监视器「内存」列一致；
    /// 不是 `vmmap` 的虚拟大小（那个数字大得没意义，永远超线）。
    static let thresholdBytes: Int64 = 300 * 1024 * 1024

    /// 到线之后还要**连续空闲**这么久才动手。
    /// 为什么不是"到线就重启"：用户可能正在拉选区 / 编辑标注 / 录屏，
    /// 那一刻重启等于把他的活干掉 —— 这是必须避免的，宁可等。
    static let idleSeconds: TimeInterval = 60

    /// 两次自重启之间至少隔 30 分钟
    static let cooldownSeconds: TimeInterval = 30 * 60

    /// 24 小时内最多重开 3 次
    static let maxRestarts = 3
    static let windowSeconds: TimeInterval = 24 * 60 * 60

    // ── 设置页文案（界面 / 自检共用一份，改口径只改这里） ────────

    static var settingTitle: String {
        "占用 \(thresholdBytes / 1024 / 1024)MB 时自动重启"
    }

    static var settingNote: String {
        "空闲 \(Int(idleSeconds)) 秒且内存到线时重开一次自己，把用久了的界面内存还给系统；"
            + "重启前先保存历史。30 分钟内最多一次，24 小时内满 \(maxRestarts) 次仍到线就停用。"
    }

    // ── 状态 ────────────────────────────────────────────────

    /// 落盘的一份小状态（`~/Library/Application Support/BoxShot/memory-guard.json`）
    struct State: Codable, Equatable {
        /// 每次自重启的时间戳（24 小时滚动窗口）
        var restarts: [TimeInterval] = []
        /// 上一次自重启的时间（冷却用）
        var lastRestart: TimeInterval?
        /// 熔断：24 小时内已经重开 3 次、仍到线 → 本次运行不再管了
        var disabled = false
        /// 🔴 **自重启标记**，整套"计数能活过重启、但活不过手动退出"就靠它：
        /// 重启前写成 true；下次启动读到 true 才继承计数，读到 false 一律清零。
        var pendingRelaunch = false

        /// 24 小时内还留着几次重启记录
        func restartCount(now: TimeInterval) -> Int {
            restarts.filter { now - $0 < MemoryGuard.windowSeconds }.count
        }

        /// 丢掉 24 小时以外的老记录（不然重启记录会无限长）
        mutating func prune(now: TimeInterval) {
            restarts.removeAll { now - $0 >= MemoryGuard.windowSeconds }
        }
    }

    /// 该干什么
    enum Decision: String, Equatable {
        /// 条件没到（没到线 / 空闲不够 / 冷却中 / 开关关了 / 正在忙）
        case idle
        /// 重开一次自己
        case restart
        /// 24 小时内已经重开 3 次仍到线 → 本次运行停用
        case disabled
    }

    // ── 规则（纯函数） ───────────────────────────────────────

    /// 只看输入决定该干什么。`candidateSince` = "内存首次到达线的那一刻"，由驱动每跳维护：
    /// 只要中途有人干活或内存掉回线下，它就要被清掉 —— 空闲时长必须**连续**。
    static func decide(enabled: Bool,
                       busy: Bool,
                       footprint: Int64,
                       candidateSince: TimeInterval?,
                       now: TimeInterval,
                       state: State) -> Decision {
        guard enabled else { return .idle }
        guard !state.disabled else { return .disabled }
        // 正在截图 / 编辑 / 录屏：一格都不动。等人闲下来再说。
        guard !busy else { return .idle }
        guard footprint >= thresholdBytes else { return .idle }
        guard let since = candidateSince, now - since >= idleSeconds else { return .idle }
        // 冷却：30 分钟内最多一次
        if let last = state.lastRestart, now - last < cooldownSeconds { return .idle }
        // 熔断：24 小时内已经 3 次了，还到线 → 别再折腾用户了
        guard state.restartCount(now: now) < maxRestarts else { return .disabled }
        return .restart
    }

    /// 执行一次重启之后的新状态（纯函数，自检直接验"记了几次、冷却有没有生效"）
    static func stateAfterRestart(_ state: State, now: TimeInterval) -> State {
        var next = state
        next.restarts.append(now)
        next.prune(now: now)
        next.lastRestart = now
        next.pendingRelaunch = true
        return next
    }

    // ── 落盘 / 读取 ─────────────────────────────────────────

    static var stateURL: URL {
        Support.appSupportRoot.appendingPathComponent("memory-guard.json")
    }

    /// 启动时读状态。
    ///
    /// 🔴 **只有 `pendingRelaunch == true` 才继承**：用户手动 ⌘Q 退出再打开，
    /// 文件里虽然还躺着上次的计数，但那不是"同一次运行"，按用户口径要全部清零。
    static func load(at url: URL, now: TimeInterval) -> State {
        guard let data = try? Data(contentsOf: url),
              let saved = try? JSONDecoder().decode(State.self, from: data),
              saved.pendingRelaunch else {
            return State()
        }
        var state = saved
        state.pendingRelaunch = false
        state.prune(now: now)
        return state
    }

    static func save(_ state: State, at url: URL) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        try? data.write(to: url, options: .atomic)
    }
}

// ============================================================
// 驱动：每 5 秒问一次"现在能不能重开"
// ============================================================

@MainActor
final class MemoryGuardRunner {

    // 由 AppModel 接上的四根线（都跑在主线程，所以标 @MainActor）
    var isEnabled: @MainActor () -> Bool = { false }
    var isBusy: @MainActor () -> Bool = { true }
    var footprint: @MainActor () -> Int64 = { 0 }
    /// 到点要真重启了：调用方负责存盘 + 拉新进程 + 退出
    var onRelaunch: @MainActor (MemoryGuard.State) -> Void = { _ in }
    /// 状态变了（熔断）—— 设置页要显示"本次运行已停用"
    var onStateChange: @MainActor (MemoryGuard.State) -> Void = { _ in }

    private(set) var state: MemoryGuard.State
    private let stateURL: URL
    private var candidateSince: TimeInterval?
    private var timer: Timer?
    /// App Nap 会把 5 秒的定时器并成几十秒一跳 —— 而这里的语义就是"空闲 60 秒"，
    /// 定时器被节流等于语义失效。所以开关打开期间持一张活动票据
    /// （`userInitiatedAllowingIdleSystemSleep`：挡 App Nap，但**不挡系统睡眠**）。
    private var activity: NSObjectProtocol?

    init(stateURL: URL = MemoryGuard.stateURL,
         now: TimeInterval = Date().timeIntervalSince1970) {
        self.stateURL = stateURL
        state = MemoryGuard.load(at: stateURL, now: now)
        // 🔴 读完立刻把 pendingRelaunch 落成 false。
        // 不落的话：自重启后用户马上手动退出，文件里那个 true 还在，
        // 下次启动就会把"上一次运行"的 3 次记录当成这次的 —— 违反"关掉再开就重置"。
        MemoryGuard.save(state, at: stateURL)
    }

    var isDisabled: Bool { state.disabled }

    func start() {
        stop()
        refreshActivity()
        let timer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        // 🔴 只加 `.default` 的话，菜单打开 / 拖动窗口期间定时器不走
        // （1.0.33 拖浮层那次的同一个坑）。
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        if let activity {
            ProcessInfo.processInfo.endActivity(activity)
            self.activity = nil
        }
    }

    /// 设置里拧开关时叫一声：开 → 起票据；关 → 放票据
    func refreshActivity() {
        let wanted = isEnabled()
        if wanted, activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiatedAllowingIdleSystemSleep],
                reason: "BoxShot 内存回收：到线且空闲 60 秒后重开一次自己")
        } else if !wanted, let token = activity {
            ProcessInfo.processInfo.endActivity(token)
            activity = nil
        }
    }

    /// 一跳。`now` 可注入，自检能直接推时间线，不用真的等 30 分钟。
    func tick(now: TimeInterval = Date().timeIntervalSince1970) {
        let busy = isBusy()
        let used = footprint()
        // 有人干活 / 内存掉回线下 → "连续在线"的计时清零
        if busy || used < MemoryGuard.thresholdBytes {
            candidateSince = nil
        } else if candidateSince == nil {
            candidateSince = now
        }

        let decision = MemoryGuard.decide(enabled: isEnabled(), busy: busy,
                                          footprint: used, candidateSince: candidateSince,
                                          now: now, state: state)
        switch decision {
        case .idle:
            return
        case .disabled:
            guard !state.disabled else { return }
            state.disabled = true
            MemoryGuard.save(state, at: stateURL)
            NSLog("[BoxShot][memguard] 24 小时内已重启 %d 次仍到线，本次运行停用",
                  state.restartCount(now: now))
            onStateChange(state)
        case .restart:
            forceRestart(now: now)
        }
    }

    /// 真走一次重启（tick 里到点走这里；诊断入口 `--memguard-restart` 也走这里）。
    /// 拆出来是为了让"诊断能验这条路"和"规则说该重启"共用同一段代码。
    func forceRestart(now: TimeInterval = Date().timeIntervalSince1970) {
        state = MemoryGuard.stateAfterRestart(state, now: now)
        MemoryGuard.save(state, at: stateURL)
        candidateSince = nil
        stop()
        NSLog("[BoxShot][memguard] 内存 ≥ 300MB 且空闲满 60 秒，重开一次自己（24 小时内第 %d 次）",
              state.restartCount(now: now))
        onStateChange(state)
        onRelaunch(state)
    }
}
