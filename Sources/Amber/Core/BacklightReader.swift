import Foundation
import IOKit

/// 读取内置屏当前的**绝对**背光输出（nits）。
///
/// 为什么需要它：Amber 写的是 gamma LUT，做的是**相对衰减**。同一个 0.75 系数，
/// 在 400 nits 背光下是 119 nits（偏亮），在 30 nits 背光下只有 8.9 nits ——
/// 后者已经低于文献公认的暗环境舒适下界。而 macOS 自动亮度**已经**按环境光降过
/// 一次背光，Amber 再降一次就是两个调光环串联，且此前完全不知道第一环已经生效。
///
/// 有了这个读数，就能只在「屏幕还不够暗」时才压暗，而不是无条件乘一个系数。
///
/// ## 限制
///
/// - **仅 Apple Silicon 内置屏。** `AppleARMBacklight` 在 Intel Mac 和任何外接屏上
///   都不存在，此时返回 nil，调用方必须能降级。
/// - **非公开 API。** 键名没有任何文档保证，macOS 大版本升级可能改。所有解析步骤
///   都是可失败的，任何一环对不上就返回 nil，绝不猜。
/// - **在部分机器上这个键根本不更新**，返回的是开机快照。这不是理论风险，是实测
///   （见 `currentNits()`）。所以有一道实时性闸门：读数被证明会跟随之前一律
///   当作读不到。**这个功能当初只凭一次「看着合理」的读数就发版了，闸门就是
///   为了不再发生同样的事。**
/// - 读的是「macOS 自动亮度决定的背光」，**不是环境光照度**。决策路径上 Amber 不碰
///   ALS，也不会拿它去显示伪造的 lux（`AmbientLightReader` 只服务于 `--ambient` 诊断，
///   输出的是未标定的原始读数，不参与任何决策）。
enum BacklightReader {

    /// 当前背光，单位 nits（cd/m²）。**读数被证明会跟随之前一律返回 nil。**
    ///
    /// ## 为什么要有这道闸门
    ///
    /// 这个键在部分机器上根本不更新。Mac16,7 / macOS 26.5.2 实测：环境光遮到
    /// 传感器读数归零、系统滑杆 1 秒内就响应、肉眼能看见屏幕明暗变化，而
    /// `BrightnessMilliNits` 连续七小时逐字节不变（381794），`brightness`、
    /// `rawBrightness`、`BrightnessMicroAmps` 同样冻结，`CurrentNits` 恒为 0。
    /// 走 IOReport 的 `backlight report / brightness report` 通道拿到的是同一批
    /// 死值。该机的 `new-backlight-architecture = Yes`，老键很可能已被废弃。
    ///
    /// 这不是「读不到」，是**读到一个看起来合理的假值** —— 比读不到更糟，因为
    /// 它会被当成实测数据显示给用户、并参与舒适下限判断。
    ///
    /// ## 闸门规则
    ///
    /// 只有在本进程内**观察到至少两个不同的值**之后，才认为这块屏的读数是活的。
    /// 在那之前返回 nil，调用方按「读不到」降级。代价是读数正常的机器上功能会
    /// 晚一点生效（要等背光第一次变化），换来的是**任何时候都不会报出未经证实的
    /// 绝对亮度**。方向选择是刻意的：宁可少一个功能，不可多一个假数。
    static func currentNits() -> Double? {
        guard let nits = rawNits() else { return nil }
        noteObservation(nits)
        return isProvenLive ? nits : nil
    }

    /// 这块屏的背光读数是否已被证明会跟随。
    static private(set) var isProvenLive = false

    /// 未经闸门的原始读数，**仅供诊断**。它可能是开机快照。
    static func rawNitsForDiagnostics() -> Double? { rawNits() }

    /// 全部只在主线程调用（Engine 是 @MainActor，诊断是单线程命令）。
    nonisolated(unsafe) private static var firstObserved: Double?

    private static func noteObservation(_ nits: Double) {
        guard !isProvenLive else { return }
        guard let first = firstObserved else {
            firstObserved = nits
            return
        }
        // 一个毫尼特的整数刻度就够了；这里要的是「到底动没动」，不是幅度。
        if abs(nits - first) > 0.0005 { isProvenLive = true }
    }

    /// IORegistry 路径：`AppleARMBacklight` → `IODisplayParameters`
    /// → `BrightnessMilliNits` → `value`（毫尼特整数）。
    private static func rawNits() -> Double? {
        guard let matching = IOServiceMatching("AppleARMBacklight") else { return nil }

        let service = IOServiceGetMatchingService(kIOMainPortDefault, matching)
        guard service != IO_OBJECT_NULL else { return nil }
        defer { IOObjectRelease(service) }

        guard let raw = IORegistryEntryCreateCFProperty(
                service, "IODisplayParameters" as CFString, kCFAllocatorDefault, 0
              )?.takeRetainedValue(),
              let parameters = raw as? [String: Any],
              let milliNits = parameters["BrightnessMilliNits"] as? [String: Any],
              let value = milliNits["value"] as? Int
        else { return nil }

        let nits = Double(value) / 1_000
        // 合理性闸门。真实面板的持续输出落在个位数到四位数 nits 之间；
        // 超出这个范围说明键的含义变了，宁可当作读不到。
        guard nits > 0, nits < 10_000 else { return nil }
        return nits
    }

    /// 整张 `IODisplayParameters`，**诊断专用**，决策路径不碰它。
    ///
    /// 存在的理由：`BrightnessMilliNits.value` 在本机上连续六小时读到同一个
    /// 381794，而环境光变了三倍。那有两种可能 —— 自动亮度确实没动，或者这一个
    /// 键的读数是陈旧/量化的。同一张字典里还有 `brightness`（0–65536）与
    /// `rawBrightness`（0–2047）两个独立标度，一起看就能分辨是哪一种：
    /// 三者一起不动 = 背光真没动；只有 milliNits 不动 = 是读数的问题。
    static func diagnosticParameters() -> [String: Any]? {
        guard let matching = IOServiceMatching("AppleARMBacklight") else { return nil }

        let service = IOServiceGetMatchingService(kIOMainPortDefault, matching)
        guard service != IO_OBJECT_NULL else { return nil }
        defer { IOObjectRelease(service) }

        guard let raw = IORegistryEntryCreateCFProperty(
                service, "IODisplayParameters" as CFString, kCFAllocatorDefault, 0
              )?.takeRetainedValue()
        else { return nil }
        return raw as? [String: Any]
    }

    /// 从 `diagnosticParameters()` 里取某个子标度的 `value`。
    static func diagnosticValue(_ key: String, in parameters: [String: Any]?) -> Int? {
        (parameters?[key] as? [String: Any])?["value"] as? Int
    }
}
