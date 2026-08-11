import AppKit
import Combine
import CoreGraphics
import CoreLocation
import ServiceManagement

/// 应用大脑：算目标 → 写 LUT → 安排下一次唤醒。
///
/// 功耗设计（这是整个 app 最重要的部分）：
///   • **没有轮询循环**。用单个 `DispatchSourceTimer`，下一次触发时刻由 `Schedule`
///     算出来。平台期可以一睡几小时，斜坡期才每 60 秒醒一次。
///   • **给足 leeway**。让内核把我们的唤醒和其它进程的定时器合并（timer coalescing），
///     避免为了一次几十微秒的工作把 CPU 从空闲状态整个拉起来。
///   • **增益不变就不写**。同一个值重复写 LUT 没有意义。
///   • **UI 只在菜单打开时才更新**。菜单收起后不发布任何变化。
///   • 没有 CVDisplayLink、没有逐帧回调、没有后台线程常驻。
///
/// 稳态下（比如整个白天）这个进程的实际状态是：一个休眠的定时器 + 几个通知观察者，
/// CPU 占用为 0.0%，唤醒次数接近 0。
@MainActor
final class Engine: ObservableObject {

    static let shared = Engine()

    // MARK: 发布给 UI 的状态
    @Published private(set) var target: LightTarget = .neutral
    @Published private(set) var metrics = ColorScience.metrics(for: .identity)
    @Published private(set) var nextUpdate: Date?
    @Published private(set) var usingOverlayFallback = false
    @Published private(set) var displayCount = 0
    /// 内置屏当前背光（nits）。外接屏 / Intel / 读取失败时为 nil。
    @Published private(set) var backlightNits: Double?
    /// 系统「自动调节亮度」是否开启。这块屏不支持环境光补偿时为 nil。
    @Published private(set) var autoBrightnessEnabled: Bool?
    @Published var settings: Settings {
        didSet {
            guard settings != oldValue else { return }
            settings.save()
            if settings.launchAtLogin != oldValue.launchAtLogin {
                syncLoginItem()
            }
            refresh(force: true)
        }
    }

    /// 菜单打开时才为 UI 做额外的状态推送。
    var menuIsOpen = false {
        didSet { if menuIsOpen { refresh() } }
    }

    // MARK: 依赖
    private let gamma = GammaController()
    private let overlay = OverlayController()
    let solar = SolarProvider()

    private var timer: DispatchSourceTimer?
    private var started = false

    private init() {
        settings = Settings.load()
    }

    // MARK: - 生命周期

    func start() {
        guard !started else { return }
        started = true

        gamma.captureBaselines()
        solar.onSolarInfoChanged = { [weak self] in
            Task { @MainActor in self?.refresh(force: true) }
        }

        registerSystemObservers()
        syncLoginItem()
        refresh(force: true)
    }

    func shutdown() {
        timer?.cancel()
        timer = nil
        overlay.teardown()
        gamma.restore()
    }

    // MARK: - 主循环（其实没有循环）

    func refresh(force: Bool = false) {
        let now = Date()

        // 暂停到期了就自动清掉
        if let until = settings.pausedUntil, until <= now {
            settings.pausedUntil = nil   // didSet 会再触发一次 refresh
            return
        }

        let events = solar.events(on: now, settings: settings)
        // 内置屏能读到绝对背光，用它兜住「暗环境被压得过暗」的下限。
        // 外接屏 / Intel 读不到，返回 nil，退回纯相对衰减。
        backlightNits = BacklightReader.currentNits()
        // 顺带把系统自动亮度的开关状态刷新一次：用户可能刚在「系统设置」里改过。
        // 只读一个布尔，比这次唤醒本身还便宜。
        autoBrightnessEnabled = AutoBrightness.isEnabled()
        let result = Schedule.evaluate(at: now, settings: settings, solar: events,
                                       backlightNits: backlightNits)

        // 顺手确认没被别的程序（系统「夜览」、其它显示工具）抢走 LUT。
        // 只读几个采样点，比一次定时器唤醒本身还便宜。
        let stomped = !settings.forceOverlayMode && gamma.reassertIfStomped()
        applyToDisplays(result.target, force: force || stomped)

        target = result.target
        metrics = ColorScience.metrics(for: result.target.effectiveGain)
        nextUpdate = result.nextUpdate
        displayCount = GammaController.activeDisplays().count

        scheduleNextWake(at: result.nextUpdate, ramping: result.isRamping)
    }

    private func applyToDisplays(_ t: LightTarget, force: Bool) {
        let gain = t.gain

        if settings.forceOverlayMode {
            gamma.restore()
            overlay.update(dim: t.extraDim, tint: gain)
            usingOverlayFallback = true
            return
        }

        let ok = gamma.apply(gain, force: force)

        if ok {
            // LUT 负责颜色和主要亮度，覆盖层只做「硬件最低亮度以下」的额外压暗。
            usingOverlayFallback = false
            overlay.update(dim: t.extraDim, tint: nil)
        } else {
            // 有显示器写不进 LUT，让覆盖层把颜色也接管过去。
            usingOverlayFallback = true
            overlay.update(dim: max(t.extraDim, 0.05), tint: gain)
        }
    }

    private func scheduleNextWake(at date: Date, ramping: Bool) {
        timer?.cancel()

        let delay = max(date.timeIntervalSinceNow, 1)
        // 斜坡期精度要求高一点；平台期给 5 分钟余量，让内核尽量合并唤醒。
        let leeway: DispatchTimeInterval = ramping ? .seconds(5) : .seconds(300)

        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + delay, leeway: leeway)
        t.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.refresh() }
        }
        t.resume()
        timer = t
    }

    // MARK: - 系统事件

    private func registerSystemObservers() {
        let workspace = NSWorkspace.shared.notificationCenter

        // 唤醒 / 解锁后 WindowServer 可能已经把 LUT 复位了，强制重写。
        for name: NSNotification.Name in [
            NSWorkspace.didWakeNotification,
            NSWorkspace.screensDidWakeNotification,
            NSWorkspace.sessionDidBecomeActiveNotification,
        ] {
            workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.gamma.reassert()
                    self?.refresh(force: true)
                }
            }
        }

        workspace.addObserver(forName: NSWorkspace.willSleepNotification,
                              object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.timer?.cancel() }
        }

        // 显示器插拔 / 改分辨率 / 换色彩描述文件
        CGDisplayRegisterReconfigurationCallback({ _, flags, _ in
            let interesting: CGDisplayChangeSummaryFlags = [
                .addFlag, .removeFlag, .enabledFlag, .disabledFlag,
                .setModeFlag, .setMainFlag, .desktopShapeChangedFlag,
            ]
            guard !flags.intersection(interesting).isEmpty else { return }
            // 回调在 CG 的线程上，切回主线程再动状态。
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    Engine.shared.handleDisplayChange()
                }
            }
        }, nil)

        // 系统时区 / 时间被改（跨时区飞行、手动改时间）
        NotificationCenter.default.addObserver(
            forName: .NSSystemClockDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh(force: true) }
        }
        NotificationCenter.default.addObserver(
            forName: .NSSystemTimeZoneDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh(force: true) }
        }
    }

    private func handleDisplayChange() {
        gamma.handleDisplayReconfiguration()
        refresh(force: true)
    }

    // MARK: - 用户操作

    func setEnabled(_ on: Bool) {
        settings.enabled = on
        if !on {
            overlay.teardown()
            gamma.restore()
            gamma.captureBaselines()
        }
    }

    func pause(for interval: TimeInterval) {
        settings.pausedUntil = Date().addingTimeInterval(interval)
    }

    func pauseUntilTomorrow() {
        let cal = Calendar.current
        let wake = settings.wakeMinutes
        var next = cal.date(bySettingHour: (wake / 60) % 24, minute: wake % 60,
                            second: 0, of: Date()) ?? Date()
        if next <= Date() {
            next = cal.date(byAdding: .day, value: 1, to: next) ?? next
        }
        settings.pausedUntil = next
    }

    func resume() {
        settings.pausedUntil = nil
    }

    var isPaused: Bool {
        if let until = settings.pausedUntil { return until > Date() }
        return false
    }

    /// 把绝对亮度交回给 macOS 的环境光环路（或收回来）。
    ///
    /// 写完立刻回读，UI 显示的永远是系统里的事实而不是我们请求的值——写失败时
    /// 开关会自己弹回去，这比假装成功要好。写不进去也不改本地设置：Amber 没有
    /// 「我以为的自动亮度状态」这种影子状态。
    func setSystemAutoBrightness(_ on: Bool) {
        guard let actual = AutoBrightness.setEnabled(on) else { return }
        autoBrightnessEnabled = actual
        // 背光会随之变化，让下一帧的读数和舒适下限判断跟上。
        refresh(force: true)
    }

    func requestLocation() {
        solar.requestCoordinateOnce { [weak self] coord in
            Task { @MainActor in
                guard let self else { return }
                if let coord {
                    self.settings.latitude = coord.latitude
                    self.settings.longitude = coord.longitude
                    self.settings.solarSource = .location
                } else if self.settings.solarSource == .location {
                    self.settings.solarSource = .systemAppearance
                }
            }
        }
    }

    // MARK: - 登录项

    private func syncLoginItem() {
        do {
            if settings.launchAtLogin {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else {
                if SMAppService.mainApp.status == .enabled {
                    try SMAppService.mainApp.unregister()
                }
            }
        } catch {
            NSLog("Amber: 登录项设置失败 - \(error.localizedDescription)")
        }
    }
}
