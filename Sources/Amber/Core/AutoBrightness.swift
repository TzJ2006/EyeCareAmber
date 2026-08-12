import CoreGraphics
import Darwin

/// 读写 macOS 的「自动调节亮度」（环境光补偿）。
///
/// 为什么 Amber 需要它：整个设计的前提是**分工**——绝对亮度由 macOS 按环境光决定，
/// Amber 只在其上做颜色和相对衰减（见 `BacklightReader`）。这个开关就是那条前提本身。
/// 关掉它，背光会钉死在某个固定值，Amber 的相对压暗便失去了它所依赖的环境跟随；
/// 而此前用户想确认或打开它，只能自己去「系统设置 → 显示器」翻。
///
/// ## 只读一个「开关」，仍然不碰环境光
///
/// 这里读写的是那个**布尔设置**，不是照度。决策路径上 Amber 不读 ALS、不显示任何 lux，
/// 也**不直接控制背光**——写背光会和 macOS 的自动亮度环互相打架。
///
/// ## 私有符号，因此按「随时可能消失」来写
///
/// `DisplayServices` 的这三个符号没有任何文档保证。用 `dlopen` / `dlsym` 弱查找而
/// 不是链接它：
///   - 符号哪天不见了，本类型整体退化成「不支持」，App 照常启动、其余功能不受影响；
///   - 不引入对私有框架的链接期依赖。
/// 写入一律**写后回读**校验，不以返回码为准。
///
/// 已在 macOS 26.5.2 / Apple Silicon 内置屏实测：读值与「系统设置 → 显示器 →
/// 自动调节亮度」一致，写入同步生效且立即可回读，无需 root 或额外 entitlement。
/// 外接屏没有环境光补偿能力，`isSupported` 为 false。
enum AutoBrightness {

    // MARK: - 私有符号

    private typealias HasCompensation = @convention(c) (CGDirectDisplayID) -> Bool
    private typealias GetCompensation =
        @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Bool>) -> Int32
    private typealias SetCompensation = @convention(c) (CGDirectDisplayID, Bool) -> Int32

    private static let handle: UnsafeMutableRawPointer? = dlopen(
        "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices",
        RTLD_LAZY
    )

    private static func lookup<T>(_ name: String, as type: T.Type) -> T? {
        guard let handle, let address = dlsym(handle, name) else { return nil }
        return unsafeBitCast(address, to: T.self)
    }

    private static let hasFn = lookup(
        "DisplayServicesHasAmbientLightCompensation", as: HasCompensation.self)
    private static let getFn = lookup(
        "DisplayServicesAmbientLightCompensationEnabled", as: GetCompensation.self)
    private static let setFn = lookup(
        "DisplayServicesEnableAmbientLightCompensation", as: SetCompensation.self)

    // MARK: - 对外接口

    /// 有没有一块屏具备环境光补偿能力。没有就别在界面上给出这个开关。
    static var isSupported: Bool { compensatingDisplay() != nil }

    /// 系统「自动调节亮度」当前是否开启。不支持 / 读不到时为 nil。
    static func isEnabled() -> Bool? {
        guard let getFn, let display = compensatingDisplay() else { return nil }
        var enabled = false
        guard getFn(display, &enabled) == 0 else { return nil }
        return enabled
    }

    /// 开启或关闭系统「自动调节亮度」。
    ///
    /// 返回**回读之后**的实际状态，而不是返回码——真正决定 UI 该显示什么的是屏幕
    /// 上的事实。读不到就返回 nil，让调用方保持原样而不是假装成功。
    @discardableResult
    static func setEnabled(_ on: Bool) -> Bool? {
        guard let setFn, let display = compensatingDisplay() else { return nil }
        _ = setFn(display, on)
        return isEnabled()
    }

    /// 亮度滑杆当前值（0–1），**诊断专用**。读不到返回 nil。
    ///
    /// 这是「系统设置 → 显示器」那根滑杆本身的位置，与 `BacklightReader` 读的
    /// 面板输出是**两个不同的标度**。自动亮度动手时动的是这根滑杆，所以它是
    /// 判断「系统环路有没有在工作」的最直接证据：滑杆不动 = 自动亮度没动手。
    static func sliderValue() -> Double? {
        guard let getBrightnessFn, let display = compensatingDisplay() else { return nil }
        var value: Float = -1
        guard getBrightnessFn(display, &value) == 0, value >= 0 else { return nil }
        return Double(value)
    }

    // MARK: - 内部

    private typealias GetBrightness =
        @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32

    private static let getBrightnessFn = lookup(
        "DisplayServicesGetBrightness", as: GetBrightness.self)

    /// 挑一块真的支持环境光补偿的屏。传感器在内置屏上，所以只找内置屏；
    /// 外接屏即使 `has` 意外返回真也不碰，避免把设置写到一块没有 ALS 的屏上。
    private static func compensatingDisplay() -> CGDirectDisplayID? {
        guard let hasFn else { return nil }
        for id in GammaController.activeDisplays()
        where CGDisplayIsBuiltin(id) != 0 && hasFn(id) {
            return id
        }
        return nil
    }
}
