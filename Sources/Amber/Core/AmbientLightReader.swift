import CoreFoundation
import Darwin

/// 环境光传感器的**只读**探针。诊断专用，不参与任何决策。
///
/// ## 为什么它叫 rawLevel 而不是 lux
///
/// HID 报上来的这个字段**单位未经标定**。在本机上它读到 480，量级看着像 lux，
/// 但"看着像"不是证据 —— 暗时读个位数、亮时读上千只能证明单调，证明不了单位。
/// 要当照度用，必须先拿校准过的照度计在同一测量平面、至少两种光谱、至少五个
/// 档位、升降各一遍地比对过，并且结论只对被标定的机型 + macOS 版本成立。
///
/// 在那之前，这个值**不许进入任何公式，也不许在界面上显示成 lux**。
/// 命名里刻意不出现 lux，就是为了让误用在编译期就显眼。
///
/// ## 私有符号，按「随时可能消失」来写
///
/// `IOHIDEventSystemClient*` / `IOHIDServiceClientCopyEvent` / `IOHIDEventGetFloatValue`
/// 都没有文档保证。这里用 `dlopen` / `dlsym` 弱查找，模板与 `AutoBrightness` 一致：
/// 符号缺失就整体退化成「读不到」，App 照常启动。
///
/// `BacklightReader` 用的是 IOKit 的**公开** C API，可以直接调用；这里不是同一类
/// 东西，不能照那个写法。
///
/// ## 只读
///
/// 只 `Create` / `Copy` / `Get`，不设置任何 HID 属性、不改变任何系统状态。
/// 所有 `Create` / `Copy` 拿到的都是 +1，函数返回前逐个 release。
enum AmbientLightReader {

    /// 一次读数。除 `level` 外还带上两路原始通道 —— 标定时需要它们来判断
    /// `level` 到底是派生量，还是某一路的直通。
    struct Sample {
        let level: Double
        let channel1: Double
        let channel2: Double
    }

    // MARK: - 私有符号

    private typealias ClientCreate = @convention(c) (CFAllocator?) -> UnsafeMutableRawPointer?
    private typealias SetMatching  = @convention(c) (UnsafeMutableRawPointer, CFDictionary) -> Void
    private typealias CopyServices = @convention(c) (UnsafeMutableRawPointer) -> UnsafeMutableRawPointer?
    private typealias CopyEvent    = @convention(c)
        (UnsafeMutableRawPointer, Int64, Int32, Int64) -> UnsafeMutableRawPointer?
    private typealias EventFloat   = @convention(c) (UnsafeMutableRawPointer, Int32) -> Double

    /// `kIOHIDEventTypeAmbientLightSensor`。事件字段基址按惯例是 `type << 16`。
    private static let ambientLightEventType: Int64 = 12
    private static let fieldBase: Int32 = 12 << 16

    /// `PrimaryUsagePage` 0xff00 是苹果厂商页，`PrimaryUsage` 4 是环境光。
    /// 这两个数字同样没有文档，匹配不到就当作没有传感器。
    private static let matchingCriteria: CFDictionary =
        ["PrimaryUsagePage": 0xff00, "PrimaryUsage": 4] as CFDictionary

    private static let handle: UnsafeMutableRawPointer? = dlopen(
        "/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY
    )

    private static func lookup<T>(_ name: String, as type: T.Type) -> T? {
        guard let handle, let address = dlsym(handle, name) else { return nil }
        return unsafeBitCast(address, to: T.self)
    }

    private static let createFn = lookup(
        "IOHIDEventSystemClientCreate", as: ClientCreate.self)
    private static let matchingFn = lookup(
        "IOHIDEventSystemClientSetMatching", as: SetMatching.self)
    private static let servicesFn = lookup(
        "IOHIDEventSystemClientCopyServices", as: CopyServices.self)
    private static let copyEventFn = lookup(
        "IOHIDServiceClientCopyEvent", as: CopyEvent.self)
    private static let floatValueFn = lookup(
        "IOHIDEventGetFloatValue", as: EventFloat.self)

    // MARK: - 对外接口

    /// 这台机器上有没有匹配到环境光传感器。
    static var isAvailable: Bool { matchedServiceCount() > 0 }

    /// 读一次。**未标定的原始读数，没有单位。** 读不到返回 nil。
    static func rawLevel() -> Sample? {
        withMatchedServices { services in
            guard let copyEventFn, let floatValueFn else { return nil }
            for service in services {
                guard let event = copyEventFn(service, ambientLightEventType, 0, 0)
                else { continue }
                defer { release(event) }
                return Sample(level: floatValueFn(event, fieldBase),
                              channel1: floatValueFn(event, fieldBase + 1),
                              channel2: floatValueFn(event, fieldBase + 2))
            }
            return nil
        }
    }

    static func matchedServiceCount() -> Int {
        withMatchedServices { $0.count } ?? 0
    }

    // MARK: - 内部

    /// 匹配 ALS 服务，并在**闭包执行期间**保证 client 与 service 数组都活着。
    ///
    /// service 指针是数组借来的，不能逃逸出这个闭包 —— 数组一 release 它们就悬空。
    private static func withMatchedServices<T>(
        _ body: ([UnsafeMutableRawPointer]) -> T?
    ) -> T? {
        guard let createFn, let matchingFn, let servicesFn,
              let client = createFn(kCFAllocatorDefault)
        else { return nil }
        defer { release(client) }

        matchingFn(client, matchingCriteria)

        guard let listPointer = servicesFn(client) else { return nil }
        defer { release(listPointer) }

        let list = Unmanaged<CFArray>.fromOpaque(listPointer).takeUnretainedValue()
        var services: [UnsafeMutableRawPointer] = []
        for index in 0..<CFArrayGetCount(list) {
            guard let element = CFArrayGetValueAtIndex(list, index) else { continue }
            services.append(UnsafeMutableRawPointer(mutating: element))
        }
        return body(services)
    }

    /// 等价于 `CFRelease`。Swift 不导出 `CFRelease`，但 `Unmanaged.release()` 就是它。
    private static func release(_ pointer: UnsafeMutableRawPointer) {
        Unmanaged<AnyObject>.fromOpaque(pointer).release()
    }
}

// MARK: - 事件推送观察器（诊断专用）

extension AmbientLightReader {

    /// 长期持有一个 client 并注册回调，用来回答一个问题：**环境光变化时，
    /// 传感器会不会自己把事件推过来。**
    ///
    /// 这件事必须用实际改变光照来验证。恒定光照下收不到事件，既可能是
    /// 「只在变化时推」（正是我们想要的），也可能是「根本不推」，两者
    /// 在静止状态下无法区分。
    ///
    /// 结论直接决定后续实现：**推不过来的话，任何校正在开启期间就必须固定采样，
    /// 不能拿背光变化通知兜底** —— 系统自动亮度关闭、处于死区、或背光已到边界时，
    /// 环境变了也不会有背光变化。
    ///
    /// 只在 `--ambient --watch` 里使用，正常运行路径不创建它。
    final class Observer {

        private typealias EventCallback = @convention(c) (
            UnsafeMutableRawPointer?, UnsafeMutableRawPointer?,
            UnsafeMutableRawPointer?, UnsafeMutableRawPointer?
        ) -> Void

        private typealias RegisterCallback = @convention(c) (
            UnsafeMutableRawPointer, EventCallback,
            UnsafeMutableRawPointer?, UnsafeMutableRawPointer?
        ) -> Void

        private typealias ScheduleRunLoop = @convention(c) (
            UnsafeMutableRawPointer, CFRunLoop, CFString
        ) -> Void

        private typealias EventType = @convention(c) (UnsafeMutableRawPointer) -> UInt32

        /// 回调是 C 函数指针，捕获不了上下文，只能靠一个进程内的单例转发。
        /// Observer 同一时间只允许存在一个，够诊断用了。
        nonisolated(unsafe) private static weak var active: Observer?

        private let client: UnsafeMutableRawPointer
        private let onSample: (Sample) -> Void

        init?(onSample: @escaping (Sample) -> Void) {
            guard let createFn = AmbientLightReader.createFn,
                  let matchingFn = AmbientLightReader.matchingFn,
                  let registerFn = AmbientLightReader.lookup(
                      "IOHIDEventSystemClientRegisterEventCallback", as: RegisterCallback.self),
                  let scheduleFn = AmbientLightReader.lookup(
                      "IOHIDEventSystemClientScheduleWithRunLoop", as: ScheduleRunLoop.self),
                  let client = createFn(kCFAllocatorDefault)
            else { return nil }

            self.client = client
            self.onSample = onSample

            matchingFn(client, AmbientLightReader.matchingCriteria)
            registerFn(client, Observer.dispatch, nil, nil)
            scheduleFn(client, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
            Observer.active = self
        }

        deinit {
            Observer.active = nil
            AmbientLightReader.release(client)
        }

        private static let dispatch: EventCallback = { _, _, _, event in
            guard let event,
                  let observer = Observer.active,
                  let typeFn = AmbientLightReader.lookup("IOHIDEventGetType", as: EventType.self),
                  let floatValueFn = AmbientLightReader.floatValueFn,
                  typeFn(event) == UInt32(AmbientLightReader.ambientLightEventType)
            else { return }

            observer.onSample(Sample(
                level: floatValueFn(event, AmbientLightReader.fieldBase),
                channel1: floatValueFn(event, AmbientLightReader.fieldBase + 1),
                channel2: floatValueFn(event, AmbientLightReader.fieldBase + 2)))
        }
    }
}
