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
/// - 读的是「macOS 自动亮度决定的背光」，**不是环境光照度**。Amber 依然不碰 ALS，
///   也不会拿它去显示伪造的 lux。
enum BacklightReader {

    /// 当前背光，单位 nits（cd/m²）。读不到返回 nil。
    ///
    /// IORegistry 路径：`AppleARMBacklight` → `IODisplayParameters`
    /// → `BrightnessMilliNits` → `value`（毫尼特整数）。
    static func currentNits() -> Double? {
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
}
