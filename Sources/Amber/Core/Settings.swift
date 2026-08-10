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
    /// 深夜段的色温 / 亮度。这一对值是「舒适」与「助眠」的均衡点，两者要一起看。
    ///
    /// ## 亮度：先定住屏幕的绝对落点
    ///
    /// 屏幕过暗本身就是视疲劳来源（Yu & Akita 2019：9 cd/m² 引发身体 + 心理 + 视觉
    /// 三类疲劳，25 cd/m² 只剩视觉疲劳），所以先把目标定在约 30% 相对输出 ——
    /// 常见的昏暗房间背光（约 120 nits）下落在 36 cd/m²，正对上 Li et al. 2026
    /// 低 CS 条件的 32.6–38.9 cd/m²，而那一档在 DLMO、皮质醇、主观睡眠、视觉疲劳
    /// 与认知表现上**同时**优于高 CS 条件。这是唯一一个两个终点都变好的实测亮度。
    ///
    /// ## 色温：代价与收益的曲率不同，拐点在 2700 K
    ///
    /// 固定上述亮度后反解各色温（melanopic 与蓝通道增益）：
    ///
    /// | CCT | 系数 | melanopic | 蓝通道 |
    /// |---|---|---|---|
    /// | 4500 K | 0.375 | 23.9% | 0.506 |
    /// | 3400 K | 0.462 | 19.0% | 0.238 |
    /// | 2700 K | 0.560 | 15.3% | 0.101 |
    /// | 1950 K | 0.750 | 10.2% | 0.0037 |
    ///
    /// melanopic 随色温近似线性下降，蓝通道却是断崖式的：从 2700 K 再往下到 1950 K，
    /// melanopic 只再降约 5 个百分点，蓝通道却塌了 27 倍，蓝色界面元素直接变黑。
    /// 往上则是白付 melanopic。所以拐点就在 2700 K。
    ///
    /// 2700 K 同时是**均衡区里唯一有直接人体数据**的点：Nagare, Rea, Plitnick &
    /// Figueiro (2019, J Biol Rhythms) 实测 2700 K 褪黑素抑制 18.4%、6500 K 24.7%。
    /// 3000–4400 K 整段在已核实文献里是空白。
    ///
    /// 反方证据是 Xie, Yu & Chen (2025, IJHCI) 报告 2800 K 视觉疲劳最高。但该研究
    /// 三个色温是否等亮度无法核实，若未配平，2800 K 同时也是最暗条件 —— 而过暗本身
    /// 就致疲劳。Amber 是等亮度设计（2700 K ×0.56 与 1950 K ×0.75 输出同为 30%），
    /// 恰好消掉了这个最可能的混杂因素。
    var nightCCT: Double = 2_700
    var nightBrightness: Double = 0.56
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
    /// 科学预设版本。改动光照默认值时必须同步 +1 并在
    /// `migrateSciencePresetIfNeeded()` 里补一档迁移，否则老用户拿不到修复。
    static let currentPresetVersion = 4
    var sciencePresetVersion = Settings.currentPresetVersion
    var language: AppLanguage = .system
    /// 全局额外调暗（覆盖层），任何时段都叠加。
    var globalExtraDim: Double = 0.0
    /// 暂停到什么时候（nil = 没暂停）。
    var pausedUntil: Date?
    var launchAtLogin = false
    /// 强制用覆盖窗口代替 Gamma LUT（某些外接屏 / 采集卡场景下需要）。
    var forceOverlayMode = false

    // MARK: 取值范围
    /// 下限 1950 K 而非 1800：约 1930 K 以下蓝通道增益已被 clamp 成 0，
    /// 滑杆再往左拖不会有任何可见变化，只会让人以为还能更暖。
    static let cctRange: ClosedRange<Double> = 1_950...6_500
    /// 深夜色温滑杆的独立区间（比手动模式窄）。
    static let nightCCTRange: ClosedRange<Double> = 1_950...4_500
    /// 深夜亮度滑杆的独立区间。
    static let nightBrightnessRange: ClosedRange<Double> = 0.15...1.0

    // 时段微调的区间。刻意比手动模式窄 —— 这几档有明确的证据边界：
    // 白天不该被调暖（Brown et al. 2022：日间短波光是正向输入），
    // 也没有证据支持白天压暗，所以下限只留到 0.6 作为特殊环境的余地。
    static let dayBrightnessRange: ClosedRange<Double> = 0.60...1.0
    static let dayCCTRange: ClosedRange<Double> = 5_000...6_500
    static let eveningBrightnessRange: ClosedRange<Double> = 0.40...0.90
    static let eveningCCTRange: ClosedRange<Double> = 4_000...5_500
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
    /// 科学预设迁移。每一档都只改写**仍等于上一版默认值**的字段 ——
    /// 用户明确调过的参数一律保留。逐档串联，跨版本升级也能正确落地。
    @discardableResult
    mutating func migrateSciencePresetIfNeeded() -> Bool {
        let from = sciencePresetVersion
        guard from < Self.currentPresetVersion else { return false }

        // v1 → v2：傍晚从 2700 K 提到 4300 K（白天/傍晚不该那么暖），
        // 深夜取消覆盖层额外调暗。
        if from < 2 {
            if manualCCT == 3_400 { manualCCT = 4_500 }
            if manualBrightness == 0.90 { manualBrightness = 0.80 }
            if eveningCCT == 2_700 { eveningCCT = 4_300 }
            if eveningBrightness == 0.62 { eveningBrightness = 0.55 }
            if nightBrightness == 0.35 { nightBrightness = 0.45 }
            if nightExtraDim == 0.20 { nightExtraDim = 0 }
        }

        // v2 → v3：深夜不再二次压暗。色温已经贡献了 −61% 光度，
        // 再乘 0.45 会把暗环境下的屏幕推到文献公认的舒适下界以下。
        // 同时把色温下限从 1800 提到 1950 —— 低于约 1930 K 蓝通道已被
        // clamp 成 0，再低不产生任何新效果，只会误导用户。
        if from < 3 {
            if nightBrightness == 0.45 { nightBrightness = 0.75 }
            if nightCCT < 1_950 { nightCCT = 1_950 }
        }

        // v3 → v4：深夜色温从 1950 K 提到 2700 K，系数同步从 0.75 降到 0.56，
        // 使屏幕亮度基本不变（相对输出 29.8% → 30.0%）。
        //
        // 1950 K 低于**所有**被实测过的色温；2700 K 则是有直接褪黑素数据的最暖档
        // （Nagare, Rea, Plitnick & Figueiro 2019, J Biol Rhythms：2700 K 抑制 18.4%，
        // 6500 K 24.7%）。更关键的是代价曲线：从 2700 K 再往下到 1950 K，
        // melanopic 只再降约 5 个百分点，蓝通道增益却从 0.101 塌到 0.0037（27 倍），
        // 蓝色界面元素直接变黑。拐点就在 2700 K。
        if from < 4 {
            if nightCCT == 1_950 { nightCCT = 2_700 }
            if nightBrightness == 0.75 { nightBrightness = 0.56 }
        }

        sciencePresetVersion = Self.currentPresetVersion
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
