import Foundation

enum OperatingMode: String, CaseIterable, Codable {
    case smart   // 智能：跟着时间走
    case manual  // 手动：用户自己拉滑块

    func title(in language: AppLanguage) -> String {
        switch self {
        case .smart:  return language.text("mode.smart")
        case .manual: return language.text("mode.manual")
        }
    }
}

/// 所有用户可调项。整体存进 UserDefaults 的一个 JSON blob，改动少、读写快。
struct Settings: Codable, Equatable {

    // MARK: 总开关
    var enabled = true
    var mode: OperatingMode = .smart

    // MARK: 手动模式
    /// 手动色温 (K)。越低越黄。
    var manualCCT: Double = 4_500
    /// 手动 LUT 系数；系统背光仍由 macOS 管理。
    var manualBrightness: Double = 0.80

    // MARK: 智能模式作息锚点（分钟数，从当地 0:00 起算）
    var wakeMinutes: Int = 7 * 60 + 30
    var bedMinutes: Int = 23 * 60 + 30

    // MARK: 夜间助眠
    var nightAssistEnabled = true
    /// 深夜段的色温 / 亮度。
    var nightCCT: Double = 1_900
    var nightBrightness: Double = 0.45
    /// 深夜额外调暗（覆盖层）。v2 科学预设不再额外调暗。
    var nightExtraDim: Double = 0.0

    // MARK: 白天基准
    /// 白天不做暖色处理 —— 日间充足的短波光对生物钟是有益的（Brown et al. 2022）。
    var dayCCT: Double = 6_500
    var dayBrightness: Double = 1.00

    // MARK: 傍晚段
    var eveningCCT: Double = 4_300
    var eveningBrightness: Double = 0.55
    /// 就寝前多少小时开始进入傍晚段。文献共识是 3 小时。
    var eveningLeadHours: Double = 3.0

    // MARK: 日照信息来源
    /// 默认蹭系统「外观 - 自动」的切换事件：不要定位权限、不耗电。
    var solarSource: SolarSource = .systemAppearance
    /// `.location` 取到后缓存于此；`.manual` 由用户填写。
    var latitude: Double?
    var longitude: Double?

    // MARK: 其它
    var sciencePresetVersion = 2
    var language: AppLanguage = .system
    /// 全局额外调暗（覆盖层），任何时段都叠加。
    var globalExtraDim: Double = 0.0
    /// 暂停到什么时候（nil = 没暂停）。
    var pausedUntil: Date?
    var launchAtLogin = false
    /// 强制用覆盖窗口代替 Gamma LUT（某些外接屏 / 采集卡场景下需要）。
    var forceOverlayMode = false

    // MARK: 取值范围
    static let cctRange: ClosedRange<Double> = 1_800...6_500
    static let brightnessRange: ClosedRange<Double> = 0.15...1.0
    static let dimRange: ClosedRange<Double> = 0.0...0.70

    // MARK: 持久化

    private static let defaultsKey = "com.amber.settings.v1"

    static func load() -> Settings {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              var decoded = try? JSONDecoder().decode(Settings.self, from: data)
        else { return Settings() }
        if decoded.migrateSciencePresetIfNeeded() { decoded.save() }
        return decoded
    }

    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        UserDefaults.standard.set(data, forKey: Self.defaultsKey)
    }
}

extension Settings {
    /// v1 → v2：只迁移仍等于旧默认值的光照字段，保留用户明确调过的参数。
    @discardableResult
    mutating func migrateSciencePresetIfNeeded() -> Bool {
        guard sciencePresetVersion < 2 else { return false }
        if manualCCT == 3_400 { manualCCT = 4_500 }
        if manualBrightness == 0.90 { manualBrightness = 0.80 }
        if eveningCCT == 2_700 { eveningCCT = 4_300 }
        if eveningBrightness == 0.62 { eveningBrightness = 0.55 }
        if nightBrightness == 0.35 { nightBrightness = 0.45 }
        if nightExtraDim == 0.20 { nightExtraDim = 0 }
        sciencePresetVersion = 2
        return true
    }
}

// MARK: - 时间工具

extension Settings {
    var wakeDescription: String { Self.format(minutes: wakeMinutes) }
    var bedDescription: String { Self.format(minutes: bedMinutes) }

    static func format(minutes: Int) -> String {
        String(format: "%02d:%02d", (minutes / 60) % 24, minutes % 60)
    }
}

// MARK: - 宽容解码
//
// 合成的 Decodable 要求每个键都存在，那样一升级加字段，用户的设置就全被重置了。
// 这里逐字段回退到默认值，老配置能平滑升级。
extension Settings {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Settings()
        func v<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            ((try? c.decodeIfPresent(T.self, forKey: key)) ?? nil) ?? fallback
        }

        self.init()
        enabled            = v(.enabled, d.enabled)
        mode               = v(.mode, d.mode)
        manualCCT          = v(.manualCCT, d.manualCCT)
        manualBrightness   = v(.manualBrightness, d.manualBrightness)
        wakeMinutes        = v(.wakeMinutes, d.wakeMinutes)
        bedMinutes         = v(.bedMinutes, d.bedMinutes)
        nightAssistEnabled = v(.nightAssistEnabled, d.nightAssistEnabled)
        nightCCT           = v(.nightCCT, d.nightCCT)
        nightBrightness    = v(.nightBrightness, d.nightBrightness)
        nightExtraDim      = v(.nightExtraDim, d.nightExtraDim)
        dayCCT             = v(.dayCCT, d.dayCCT)
        dayBrightness      = v(.dayBrightness, d.dayBrightness)
        eveningCCT         = v(.eveningCCT, d.eveningCCT)
        eveningBrightness  = v(.eveningBrightness, d.eveningBrightness)
        eveningLeadHours   = v(.eveningLeadHours, d.eveningLeadHours)
        solarSource        = v(.solarSource, d.solarSource)
        sciencePresetVersion = v(.sciencePresetVersion, 1)
        language           = v(.language, d.language)
        globalExtraDim     = v(.globalExtraDim, d.globalExtraDim)
        launchAtLogin      = v(.launchAtLogin, d.launchAtLogin)
        forceOverlayMode   = v(.forceOverlayMode, d.forceOverlayMode)
        latitude           = try? c.decode(Double.self, forKey: .latitude)
        longitude          = try? c.decode(Double.self, forKey: .longitude)
        pausedUntil        = try? c.decode(Date.self, forKey: .pausedUntil)
    }
}
