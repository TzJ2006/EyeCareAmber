import CoreGraphics
import Foundation

/// 通过显示器的 Gamma 查找表（LUT）施加色温 / 亮度。
///
/// 为什么用 LUT 而不是盖一层半透明窗口：
///   1. **零持续开销**。LUT 写进显示管线之后由扫描输出硬件应用，
///      不参与窗口合成，CPU / GPU 占用真正是 0，不影响电池。
///      半透明覆盖窗口则要求合成器每帧多混合一层全屏图层。
///   2. **真正覆盖一切**。所有屏幕、所有窗口、全屏应用、游戏、视频、
///      甚至菜单栏和 Dock，都在 LUT 之后 —— 没有任何东西能「漏出来」。
///   3. **不破坏对比度**。覆盖层是往画面上「加光」，黑色会变成灰色；
///      LUT 是缩放输出，黑还是黑。
///
/// 代价：截图 / 录屏拍不到效果（这通常反而是优点），以及少数
/// 采集卡 / 虚拟显示器不支持写 LUT —— 那种情况回落到覆盖层。
final class GammaController {

    /// 显示器电光转换函数的近似指数。LUT 存的是编码值，
    /// 想得到线性光域的增益 g，要写入 g^(1/γ)。
    private static let displayGamma: Double = 2.2

    private struct Baseline {
        var red: [CGGammaValue]
        var green: [CGGammaValue]
        var blue: [CGGammaValue]
    }

    /// 各显示器「我们动手之前」的原始 LUT —— 里面含用户的 ColorSync 校准，
    /// 必须在它基础上叠加，不能覆盖掉。
    private var baselines: [CGDirectDisplayID: Baseline] = [:]
    private var appliedGain: RGBGain?

    /// 上一次写入是否有显示器失败（用于自动回落到覆盖层）。
    private(set) var lastApplyFailed = false
    private(set) var isActive = false

    // MARK: - 显示器枚举

    static func activeDisplays() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return [] }
        return Array(ids.prefix(Int(count)))
    }

    // MARK: - 基线

    /// 读取当前 LUT 作为基线。
    /// 只能在「还没施加过」或「刚 restore 过」的时候调用，否则会把我们自己的效果叠进基线。
    func captureBaselines() {
        baselines.removeAll(keepingCapacity: true)
        for id in Self.activeDisplays() {
            captureBaseline(for: id)
        }
    }

    /// 只读取单台显示器的基线，不影响其它已记录的基线。
    /// 用于热插拔：新接上的显示器 LUT 还没被我们动过，单独读是安全的。
    private func captureBaseline(for id: CGDirectDisplayID) {
        let capacity = CGDisplayGammaTableCapacity(id)
        guard capacity > 1 else {
            baselines[id] = Self.identity(size: 256)
            return
        }
        var red = [CGGammaValue](repeating: 0, count: Int(capacity))
        var green = red
        var blue = red
        var sampleCount: UInt32 = 0
        let err = CGGetDisplayTransferByTable(id, capacity, &red, &green, &blue, &sampleCount)
        if err == .success, sampleCount > 1 {
            let n = Int(sampleCount)
            baselines[id] = Baseline(red: Array(red.prefix(n)),
                                     green: Array(green.prefix(n)),
                                     blue: Array(blue.prefix(n)))
        } else {
            baselines[id] = Self.identity(size: Int(capacity))
        }
    }

    private static func identity(size: Int) -> Baseline {
        let n = max(size, 2)
        var ramp = [CGGammaValue](repeating: 0, count: n)
        for i in 0..<n { ramp[i] = CGGammaValue(Double(i) / Double(n - 1)) }
        return Baseline(red: ramp, green: ramp, blue: ramp)
    }

    // MARK: - 施加

    /// 把线性光增益写进所有活动显示器。
    ///
    /// - Parameter force: 忽略「增益没变就跳过」的短路，用于显示器热插拔 / 唤醒后强制重写。
    /// - Returns: 是否全部成功。
    @discardableResult
    func apply(_ gain: RGBGain, force: Bool = false) -> Bool {
        if !force, let applied = appliedGain, applied == gain, isActive {
            return !lastApplyFailed
        }

        let displays = Self.activeDisplays()
        // 补齐还没有基线的显示器（首次运行或热插拔）。必须在写入循环之前做完，
        // 否则中途读基线会把已经写进去的效果当成「原始校准」。
        for id in displays where baselines[id] == nil {
            captureBaseline(for: id)
        }

        // 线性增益 → 编码域增益
        let er = CGGammaValue(pow(max(gain.r, 0), 1 / Self.displayGamma))
        let eg = CGGammaValue(pow(max(gain.g, 0), 1 / Self.displayGamma))
        let eb = CGGammaValue(pow(max(gain.b, 0), 1 / Self.displayGamma))

        var allOK = true
        for id in displays {
            guard let base = baselines[id] else { allOK = false; continue }

            let n = base.red.count
            var red = [CGGammaValue](repeating: 0, count: n)
            var green = red
            var blue = red
            for i in 0..<n {
                red[i]   = base.red[i]   * er
                green[i] = base.green[i] * eg
                blue[i]  = base.blue[i]  * eb
            }
            if CGSetDisplayTransferByTable(id, UInt32(n), red, green, blue) != .success {
                allOK = false
            }
        }

        appliedGain = gain
        lastApplyFailed = !allOK
        isActive = true
        return allOK
    }

    /// 交还控制权：把开机时抓到的原始 LUT 一字不差地写回去。
    ///
    /// 这里**刻意不用** `CGDisplayRestoreColorSyncSettings()`。那个 API 名义上是
    /// 「从 ColorSync 描述文件恢复」，但实测在内建 XDR 屏上会把系统为当前显示预设
    /// 加载的校准曲线直接抹成线性斜坡，并且不会自己长回来 —— 等于永久破坏了
    /// 用户的显示器校准，直到重新登录。
    ///
    /// 写回自己抓的基线是无损的：我们抓的就是动手之前那一份。
    func restore() {
        guard isActive else { return }

        var restoredAll = true
        for id in Self.activeDisplays() {
            guard let base = baselines[id] else { restoredAll = false; continue }
            if CGSetDisplayTransferByTable(id, UInt32(base.red.count),
                                           base.red, base.green, base.blue) != .success {
                restoredAll = false
            }
        }
        // 只有在确实没有基线可写时才退回系统恢复 —— 有损总比停在琥珀色好。
        if !restoredAll {
            CGDisplayRestoreColorSyncSettings()
        }

        appliedGain = nil
        isActive = false
        lastApplyFailed = false
    }

    /// 显示器配置变化（插拔、改分辨率、切主屏）后调用。
    ///
    /// 已知显示器的基线不会因为别的显示器被插拔而改变，所以保留；
    /// 新出现的显示器由 `apply` 里的补齐逻辑单独读取。
    func handleDisplayReconfiguration() {
        let live = Set(Self.activeDisplays())
        baselines = baselines.filter { live.contains($0.key) }
        if let gain = appliedGain {
            apply(gain, force: true)
        }
    }

    /// 从睡眠 / 锁屏唤醒后强制重写 —— WindowServer 有时会把 LUT 恢复成默认。
    func reassert() {
        guard let gain = appliedGain else { return }
        apply(gain, force: true)
    }

    /// 检查 LUT 是否被外部程序覆写（系统「夜览」、其它显示工具、显卡驱动…），
    /// 是的话把对方的表当作新基线重新接管。
    ///
    /// 只读几个采样点，微秒级，可以在每次定时唤醒时顺手做掉。
    /// - Returns: 是否发生了重新接管。
    @discardableResult
    func reassertIfStomped() -> Bool {
        guard isActive, let gain = appliedGain else { return false }

        let er = CGGammaValue(pow(max(gain.r, 0), 1 / Self.displayGamma))
        let eg = CGGammaValue(pow(max(gain.g, 0), 1 / Self.displayGamma))
        let eb = CGGammaValue(pow(max(gain.b, 0), 1 / Self.displayGamma))

        var stompedDisplays: [CGDirectDisplayID] = []
        for id in Self.activeDisplays() {
            guard let base = baselines[id] else { continue }
            let cap = CGDisplayGammaTableCapacity(id)
            var r = [CGGammaValue](repeating: 0, count: Int(cap)), g = r, b = r
            var n: UInt32 = 0
            guard CGGetDisplayTransferByTable(id, cap, &r, &g, &b, &n) == .success,
                  n > 1 else { continue }

            // 取四分之三高度处采样：顶端容易被各种钳位掩盖差异。
            let readIdx = Int(n) * 3 / 4
            let baseIdx = base.red.count * 3 / 4
            let expected = (base.red[baseIdx] * er, base.green[baseIdx] * eg, base.blue[baseIdx] * eb)
            let drift = max(abs(r[readIdx] - expected.0),
                            max(abs(g[readIdx] - expected.1), abs(b[readIdx] - expected.2)))
            if drift > 0.004 { stompedDisplays.append(id) }
        }

        guard !stompedDisplays.isEmpty else { return false }

        // 对方写的表就是新的真相：当作新基线，把我们的增益重新叠上去。
        for id in stompedDisplays {
            baselines.removeValue(forKey: id)
            captureBaseline(for: id)
        }
        apply(gain, force: true)
        return true
    }
}
