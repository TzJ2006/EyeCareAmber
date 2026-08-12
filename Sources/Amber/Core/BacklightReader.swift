import CoreGraphics
import Darwin
import Foundation
import IOKit

/// 估算内置屏当前的背光输出（nits）。**是模型值，不是实测值。**
///
/// 为什么需要它：Amber 写的是 gamma LUT，做的是**相对衰减**。同一个 0.75 系数，
/// 在 400 nits 背光下是 119 nits（偏亮），在 30 nits 背光下只有 8.9 nits ——
/// 后者已经低于文献公认的暗环境舒适下界。而 macOS 自动亮度**已经**按环境光降过
/// 一次背光，Amber 再降一次就是两个调光环串联，且此前完全不知道第一环已经生效。
///
/// ## 为什么不直接读 IORegistry 报的 nits
///
/// 因为在部分机器上那个数是**开机快照**。Mac16,7 / macOS 26.5.2 实测：遮住环境光
/// 传感器后系统亮度滑杆 1 秒内就响应、肉眼能看见屏幕明暗变化，而
/// `BrightnessMilliNits.value` 连续七小时逐字节不变（381794），`brightness`、
/// `rawBrightness`、`BrightnessMicroAmps` 一同冻结，`CurrentNits` 恒为 0；走 IOReport
/// 的 `backlight report / brightness report` 通道拿到的是同一批死值，整个 IORegistry
/// 再没有第二处发布 nits。该机 `new-backlight-architecture = Yes`，老键已经废弃。
///
/// **读到一个看起来合理的假值比读不到更糟** —— 它会被当成实测数据显示给用户，
/// 并参与舒适下限判断。v1.1.0 就是这么发出去的。
///
/// ## 模型
///
/// 改用两个**活的** `DisplayServices` 标度重建绝对值：
///
/// ```
/// 满量程 = 面板最小亮度 / linear 最小可用值
/// nits   = linear × 满量程
/// ```
///
/// `linear` 与亮度成正比这一点由三条证据支撑：滑杆拉到底时它**精确等于 1.0000**
/// （前提是关掉自动亮度，开着时会被压到约 0.667）；与滑杆在整个行程上同向单调；
/// 以及按上式反解出的满量程 584 nits，与该机标称的 600 nits SDR 上限相差 2.7%。
/// 推导本身也是自洽的：「linear 的最小可用值」和「面板的最小亮度」说的是同一件事。
///
/// 用到的 `BrightnessMilliNits.min` 是**结构性元数据**（面板下限，本来就不会变），
/// 不是那个会冻结的 `value`。
///
/// ## 限制
///
/// - **这是模型值。** 从未与照度计／色度计比对过，界面与文档必须如实标注，不得
///   称之为实测。
/// - **仅 Apple Silicon 内置屏。** `AppleARMBacklight` 在 Intel Mac 和外接屏上不存在；
///   `DisplayServices` 的两个符号也没有文档保证。任何一环对不上就返回 nil，绝不猜。
/// - 读的是「macOS 自动亮度决定的背光」，**不是环境光照度**。决策路径上 Amber 不碰
///   ALS，也不会拿它去显示伪造的 lux（`AmbientLightReader` 只服务于 `--ambient` 诊断，
///   输出的是未标定的原始读数，不参与任何决策）。
enum BacklightReader {

    /// 当前背光的**模型估算值**，单位 nits（cd/m²）。任何一环不自洽就返回 nil。
    static func currentNits() -> Double? {
        guard let linear = linearBrightness(), let scale = fullScaleNits() else { return nil }
        let nits = linear * scale
        // 合理性闸门。真实面板的持续输出落在个位数到四位数 nits 之间；
        // 超出这个范围说明某个符号的含义变了，宁可当作读不到。
        guard nits > 0, nits < 10_000 else { return nil }
        return nits
    }

    /// 面板满量程（nits）。由结构性元数据推出，不依赖会冻结的 `value`。
    static func fullScaleNits() -> Double? {
        guard let minMilliNits = parameterField("BrightnessMilliNits", "min"),
              let lowerBound = linearUsableRange()?.lower
        else { return nil }

        let minNits = minMilliNits / 1_000
        guard minNits > 0, lowerBound > 0 else { return nil }
        let scale = minNits / lowerBound
        // 笔记本与显示器的满量程落在几十到几千 nits；越界说明推导前提不成立。
        guard scale > 50, scale < 5_000 else { return nil }
        return scale
    }

    /// `DisplayServicesGetLinearBrightness`。0–1，与亮度成正比（见类型注释）。
    static func linearBrightness() -> Double? {
        guard let getLinearFn, let display = builtinDisplay() else { return nil }
        var value: Float = -1
        guard getLinearFn(display, &value) == 0, value >= 0, value <= 1 else { return nil }
        return Double(value)
    }

    /// `linear` 的可用区间。下限对应面板的最小亮度，是满量程推导的另一半。
    static func linearUsableRange() -> (lower: Double, upper: Double)? {
        guard let usableRangeFn, let display = builtinDisplay() else { return nil }
        var lower: Float = -1, upper: Float = -1
        guard usableRangeFn(display, &lower, &upper) == 0,
              lower > 0, upper > lower else { return nil }
        return (Double(lower), Double(upper))
    }

    // MARK: - DisplayServices 弱链接

    private typealias GetLinear =
        @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias GetUsableRange = @convention(c) (
        CGDirectDisplayID, UnsafeMutablePointer<Float>, UnsafeMutablePointer<Float>
    ) -> Int32

    private static let handle: UnsafeMutableRawPointer? = dlopen(
        "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY
    )

    private static func lookup<T>(_ name: String, as type: T.Type) -> T? {
        guard let handle, let address = dlsym(handle, name) else { return nil }
        return unsafeBitCast(address, to: T.self)
    }

    private static let getLinearFn = lookup(
        "DisplayServicesGetLinearBrightness", as: GetLinear.self)
    private static let usableRangeFn = lookup(
        "DisplayServicesGetLinearBrightnessUsableRange", as: GetUsableRange.self)

    /// 背光只存在于内置屏，外接屏一律不碰。
    private static func builtinDisplay() -> CGDirectDisplayID? {
        GammaController.activeDisplays().first { CGDisplayIsBuiltin($0) != 0 }
    }

    // MARK: - IORegistry

    /// 整张 `IODisplayParameters`。
    ///
    /// 只有 `min` / `max` 这类**结构性元数据**可信；`value` 在部分机器上是开机快照，
    /// 决策路径已经不再使用它，只在 `--ambient` 里作为对照打印。
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

    /// 从 `IODisplayParameters` 里取某个子标度的某个字段。
    static func parameterField(_ key: String, _ field: String,
                               in parameters: [String: Any]? = nil) -> Double? {
        let source = parameters ?? diagnosticParameters()
        guard let scale = source?[key] as? [String: Any],
              let value = scale[field] as? Int
        else { return nil }
        return Double(value)
    }

    /// IORegistry 直接报出的 nits，**仅供诊断对照**。它可能是开机快照。
    static func registryNitsForDiagnostics() -> Double? {
        parameterField("BrightnessMilliNits", "value").map { $0 / 1_000 }
    }
}
