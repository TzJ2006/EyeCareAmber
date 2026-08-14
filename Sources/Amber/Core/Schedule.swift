import Foundation

/// 某一时刻应该给屏幕施加的光照目标。
struct LightTarget: Equatable {
    enum Phase: String {
        case day      = "白天"
        case dusk     = "黄昏"
        case evening  = "傍晚"
        case night    = "深夜助眠"
        case dawn     = "拂晓"
        case manual   = "手动"
        case paused   = "已暂停"
        case off      = "已关闭"

        func title(in language: AppLanguage) -> String {
            language.text("phase.\(String(describing: self))")
        }
    }

    var cct: Double         // 色温 K
    var brightness: Double  // LUT 亮度，相对原生满亮度
    var extraDim: Double    // 覆盖层额外调暗 0…1
    var phase: Phase

    static let neutral = LightTarget(cct: 6_500, brightness: 1.0, extraDim: 0, phase: .off)

    /// 最终施加到 LUT 的三通道线性增益。
    var gain: RGBGain {
        ColorScience.gain(forCCT: cct).scaled(by: brightness)
    }

    /// LUT 与覆盖层共同作用后的模型增益，用于所有用户可见指标。
    var effectiveGain: RGBGain {
        gain.scaled(by: 1 - extraDim.clamped(to: 0...1))
    }
}

struct ScheduleResult {
    var target: LightTarget
    /// 下一次需要重算的时刻。平台段可能是几小时后 —— 这就是低功耗的关键。
    var nextUpdate: Date
    var isRamping: Bool
}

/// 把「几点了」翻译成「屏幕该长什么样」。
///
/// 曲线的形状来自这几条证据：
///   • 白天要亮、要有短波光 —— 日间足量光照是稳定生物钟的正向输入，不该无脑加黄。
///   • 就寝前 3 小时开始压 melanopic 剂量（Brown et al. 2022 的共识窗口）。
///   • 光靠改色温不够，必须同时降亮度（Nagare et al. 2019）。
///   • 深夜段保留琥珀光谱，但避免在系统自动亮度之上重复过度压暗。
enum Schedule {

    /// 睡前保护在 90 分钟内到达目标，剩余时间保持稳定。
    private static let eveningFadeMinutes: Double = 90
    /// 从傍晚过渡到深夜所用的时间（分钟）。
    private static let nightFadeMinutes: Double = 45
    /// 起床前多久开始把色温 / 亮度拉回白天状态。
    private static let dawnLeadMinutes: Double = 30
    /// 平台段最长睡眠时间。
    ///
    /// 15 分钟不是为了刷新色温（平台期本来就不变），而是为了定期做两件廉价的事：
    /// 检查 LUT 有没有被别的程序覆写、以及兜住时区 / 夏令时变更。
    /// 一天多醒约 80 次，功耗上完全可以忽略。
    private static let maxSleep: TimeInterval = 15 * 60

    // 斜坡期的步进不用固定间隔，而是「下一次变化大到值得醒来」才醒。
    // 平滑曲线的两端几乎没有变化，固定 60 秒会白白唤醒几十次。
    //
    /// 色温步进阈值（mired，即倒数色温 × 10⁶）。人眼对色温差的感知在 mired 空间才是线性的。
    /// 并排比较的 JND 约 5–10 mired；渐变且无参照物时更钝，取 5 有充分余量。
    private static let cctStepMired: Double = 5
    /// 亮度 / 调暗步进阈值。亮度的 Weber 分数约 1%，全屏渐变、无参照时还要更钝，
    /// 0.8% 一步看不出来。
    private static let levelStep: Double = 0.008
    /// 斜坡期两次唤醒的间隔下限 / 上限。
    private static let minRampInterval: TimeInterval = 20
    private static let maxRampInterval: TimeInterval = 20 * 60

    private struct Key {
        var t: Double  // 距起床的分钟数
        var cct: Double
        var brightness: Double
        var dim: Double
        /// 停在这个关键帧上（平台段）时显示的阶段名。
        var phase: LightTarget.Phase
        /// 从这个关键帧过渡到下一个时显示的阶段名。
        /// 分开是因为「白天 → 傍晚」的过渡本身就叫黄昏，标成任一端都不对。
        var rampPhase: LightTarget.Phase
    }

    /// - Parameter solar: 当天的日出 / 日落。传 nil 就纯按作息锚点排班。
    ///   来源由 `SolarProvider` 决定（系统外观事件 / 定位 / 手填坐标），
    ///   这里刻意不关心 —— 保持这个函数是纯函数，方便验证。
    /// - Parameter backlightNits: 当前系统背光的绝对输出。传 nil（外接屏 / Intel /
    ///   读取失败）就退回纯相对衰减，行为与加入这个参数之前完全一致。
    static func evaluate(at now: Date, settings s: Settings,
                         solar: SolarClock.Events? = nil,
                         backlightNits: Double? = nil,
                         calendar: Calendar = .current) -> ScheduleResult {

        guard s.enabled else {
            return ScheduleResult(target: .neutral, nextUpdate: now.addingTimeInterval(maxSleep),
                                  isRamping: false)
        }

        if let until = s.pausedUntil, until > now {
            var t = LightTarget.neutral
            t.phase = .paused
            return ScheduleResult(target: t, nextUpdate: until, isRamping: false)
        }

        if s.mode == .manual {
            let t = LightTarget(cct: s.manualCCT,
                                brightness: s.manualBrightness,
                                extraDim: s.globalExtraDim,
                                phase: .manual)
            // 手动模式下也尊重夜间助眠：进入深夜窗口就自动切过去。
            if s.nightAssistEnabled, inNightWindow(now, settings: s, calendar: calendar) {
                var night = LightTarget(cct: min(s.nightCCT, s.manualCCT),
                                        brightness: min(s.nightBrightness, s.manualBrightness),
                                        extraDim: max(s.nightExtraDim, s.globalExtraDim),
                                        phase: .night)
                // 深夜档是自动切过去的，不是用户拖出来的，所以同样受下限保护。
                night = liftAboveComfortFloor(night, backlightNits: backlightNits)
                return ScheduleResult(target: night,
                                      nextUpdate: nextBoundary(after: now, settings: s, calendar: calendar),
                                      isRamping: false)
            }
            return ScheduleResult(target: t,
                                  nextUpdate: nextBoundary(after: now, settings: s, calendar: calendar),
                                  isRamping: false)
        }

        // ---- 智能模式 ----
        let wake = mostRecentWake(before: now, settings: s, calendar: calendar)
        let elapsed = (now.timeIntervalSince(wake) / 60).clamped(to: 0...1_439.999)
        let keys = keyframes(settings: s, wakeDate: wake, solar: solar)

        var index = 0
        for i in 0..<(keys.count - 1) where elapsed >= keys[i].t && elapsed < keys[i + 1].t {
            index = i
            break
        }
        let a = keys[index]
        let b = keys[index + 1]

        let flat = a.cct == b.cct && a.brightness == b.brightness && a.dim == b.dim
        let target = liftAboveComfortFloor(sample(elapsed: elapsed, from: a, to: b, settings: s),
                                           backlightNits: backlightNits)

        let segmentEnd = wake.addingTimeInterval(b.t * 60)
        let next: Date
        if flat {
            next = min(segmentEnd, now.addingTimeInterval(maxSleep))
        } else {
            let holdMinutes = holdTime(from: elapsed, current: target, a: a, b: b, settings: s)
            next = min(segmentEnd, now.addingTimeInterval(holdMinutes * 60))
        }

        return ScheduleResult(target: target,
                              nextUpdate: max(next, now.addingTimeInterval(1)),
                              isRamping: !flat)
    }

    // MARK: - 暗环境安全下限

    /// 暗环境舒适下界，cd/m²。
    ///
    /// 文献里「暗环境最优屏幕亮度」的分散度超过 6 倍。已核对原文的三条：
    /// Na & Suk 2015 = 10（初看）/ 40（持续阅读）、Zhou 2021 在 0 lx 下三个终点
    /// 分别是 20.63 / 25.57 / 36.20、Lin 2022 在 1 lx 下 = 63.9。另有 Li 2013 = 11、
    /// 朱念芳 2022 ≈ 50、Ye 2014 = 55 三条是**转引自二手综述、未核对原文**。
    /// 所以这里取的是**下界**而不是最优值：20 落在已核实区间的下沿。
    ///
    /// 这个常数一度引 Yu & Akita 2019 的 9 / 25 cd/m² 作为「屏幕太暗也会疲劳」的
    /// 依据，那是错的 —— 原文摘要里那两个值是**房间**的环境亮度而非屏幕亮度
    /// （"in low ambient luminance of 9cd/m² and 25cd/m²"），被操纵的变量是平板上
    /// 文字的对比度。它支持的是屏幕与房间的**亮度比**，不是屏幕的绝对下限。
    ///
    /// **这个常数只在接近全黑时站得住。** 房间一亮，同一批文献里的说法就翻几倍：
    /// Kim et al. 2017（Optical Engineering 56(1):017110，n=30）在 50 lx 给出的
    /// 舒适**下沿是 113 cd/m²**，而 Zhou 2021 在同样 50 lx 给的是 34.50（低视疲劳）
    /// 与 41.40（高视觉舒适） —— 相差三倍。两者测的不是同一件事（Kim 是眩光与
    /// 可视性的容许边界，Zhou 是傍晚阅读的主观最优），但这个分歧说明**不存在一个
    /// 与环境无关的下界**。要做成随环境走的下沿，前提是先有可信的环境照度读数，
    /// 而那一步至今没有通过标定（见 `AmbientLightReader`）。在那之前保持常数。
    static let comfortFloorNits: Double = 20

    /// 防止 Amber 把屏幕压到比「什么都不做」还难读。
    ///
    /// Amber 施加的是相对衰减，落到多少 nits 完全取决于系统背光。macOS 自动亮度
    /// 在暗环境下会把背光压得很低（本机面板下限约 1 nit），此时再乘一个固定系数
    /// 就是二次压制 —— 傍晚档 ×0.55 在 30 nits 背光下只剩 12.9 nits，深夜档更低。
    ///
    /// 这里的规则很克制：**只抬不降，且绝不超过 1.0**。
    /// `brightness = 1.0` 的含义是「不额外压暗」，色温本身的衰减仍然保留。
    /// 所以最坏情况下 Amber 退化成纯色温滤镜，永远不会比不装它更亮。
    ///
    /// - Parameter backlightNits: nil 时原样返回，行为与没有这个功能时一致。
    static func liftAboveComfortFloor(_ target: LightTarget,
                                      backlightNits: Double?) -> LightTarget {
        guard let nits = backlightNits, nits > 0, target.brightness > 0 else { return target }

        // photopicRatio 与 brightness 严格成正比，所以先取 brightness = 1 时的
        // 单位输出（含色温衰减与覆盖层），再反解需要多少系数才能够到下限。
        let unit = LightTarget(cct: target.cct, brightness: 1,
                               extraDim: target.extraDim, phase: target.phase)
        let unitOutput = ColorScience.metrics(for: unit.effectiveGain).photopicRatio
        guard unitOutput > 0 else { return target }

        let required = comfortFloorNits / (unitOutput * nits)
        guard required > target.brightness else { return target }

        var lifted = target
        lifted.brightness = min(1.0, required)
        return lifted
    }

    // MARK: - 插值与自适应步进

    private static func sample(elapsed: Double, from a: Key, to b: Key,
                               settings s: Settings) -> LightTarget {
        let span = max(b.t - a.t, 0.0001)
        let u = Double.smoothstep(0, 1, (elapsed - a.t) / span)
        let flat = a.cct == b.cct && a.brightness == b.brightness && a.dim == b.dim
        return LightTarget(
            cct: flat ? a.cct : .lerpCCT(a.cct, b.cct, u),
            brightness: a.brightness + (b.brightness - a.brightness) * u,
            extraDim: max(s.globalExtraDim, a.dim + (b.dim - a.dim) * u),
            phase: flat ? a.phase : a.rampPhase
        )
    }

    /// 当前值可以维持多久，直到变化大到肉眼可能察觉。
    ///
    /// 段内 smoothstep 单调，所以「偏差 ≥ 阈值」是单调谓词，可以直接二分。
    /// 曲线平缓的两端能睡十几分钟，最陡的中段才每几十秒醒一次 —— 同样的视觉平滑度，
    /// 唤醒次数比固定 60 秒步进少一个数量级。
    private static func holdTime(from elapsed: Double, current: LightTarget,
                                 a: Key, b: Key, settings s: Settings) -> Double {
        func exceedsThreshold(at t: Double) -> Bool {
            let probe = sample(elapsed: t, from: a, to: b, settings: s)
            let miredDelta = abs(1_000_000 / probe.cct - 1_000_000 / current.cct)
            return miredDelta >= cctStepMired
                || abs(probe.brightness - current.brightness) >= levelStep
                || abs(probe.extraDim - current.extraDim) >= levelStep
        }

        let maxHold = min(b.t - elapsed, maxRampInterval / 60)
        guard maxHold > minRampInterval / 60 else { return maxHold }
        guard exceedsThreshold(at: elapsed + maxHold) else { return maxHold }

        var low = 0.0            // 已知不超阈值
        var high = maxHold       // 已知超阈值
        for _ in 0..<24 {
            let mid = (low + high) / 2
            if exceedsThreshold(at: elapsed + mid) { high = mid } else { low = mid }
        }
        return max(high, minRampInterval / 60)
    }

    // MARK: - 关键帧

    private static func keyframes(settings s: Settings, wakeDate: Date,
                                  solar: SolarClock.Events?) -> [Key] {
        let awakeSpan = awakeMinutes(settings: s)
        let eveningStart = max(30, awakeSpan - s.eveningLeadHours * 60)

        // 深夜段的取值：夜间助眠关掉时就停在傍晚水平，不再继续压暗。
        let nightCCT        = s.nightAssistEnabled ? s.nightCCT : s.eveningCCT
        let nightBrightness = s.nightAssistEnabled ? s.nightBrightness : s.eveningBrightness
        let nightDim        = s.nightAssistEnabled ? s.nightExtraDim : 0

        var keys: [Key] = [
            Key(t: 0, cct: s.dayCCT, brightness: s.dayBrightness, dim: 0,
                phase: .day, rampPhase: .day)
        ]

        // 日落早于「就寝前 3 小时」时，插一段温和的黄昏过渡：
        // 天黑了屏幕还维持正午亮度，是傍晚眼睛最不舒服的来源之一。
        if let solar {
            let sunsetElapsed = (solar.sunset.timeIntervalSince(wakeDate) / 60)
            if sunsetElapsed > 60, sunsetElapsed < eveningStart - 30 {
                keys.append(Key(t: sunsetElapsed, cct: s.dayCCT, brightness: s.dayBrightness,
                                dim: 0, phase: .day, rampPhase: .dusk))
                keys.append(Key(t: eveningStart,
                                cct: .lerpCCT(s.dayCCT, s.eveningCCT, 0.45),
                                brightness: s.dayBrightness + (s.eveningBrightness - s.dayBrightness) * 0.35,
                                dim: 0, phase: .dusk, rampPhase: .evening))
            }
        }

        if keys.last!.t < eveningStart {
            keys.append(Key(t: eveningStart, cct: s.dayCCT, brightness: s.dayBrightness,
                            dim: 0, phase: .day, rampPhase: .evening))
        }

        let eveningReady = min(eveningStart + eveningFadeMinutes, awakeSpan)
        keys.append(Key(t: eveningReady, cct: s.eveningCCT, brightness: s.eveningBrightness,
                        dim: 0, phase: .evening,
                        rampPhase: eveningReady < awakeSpan ? .evening : .night))
        if eveningReady < awakeSpan {
            keys.append(Key(t: awakeSpan, cct: s.eveningCCT, brightness: s.eveningBrightness,
                            dim: 0, phase: .evening, rampPhase: .night))
        }
        keys.append(Key(t: min(awakeSpan + nightFadeMinutes, 1_440 - dawnLeadMinutes - 1),
                        cct: nightCCT, brightness: nightBrightness, dim: nightDim,
                        phase: .night, rampPhase: .night))
        keys.append(Key(t: 1_440 - dawnLeadMinutes,
                        cct: nightCCT, brightness: nightBrightness, dim: nightDim,
                        phase: .night, rampPhase: .dawn))
        keys.append(Key(t: 1_440, cct: s.dayCCT, brightness: s.dayBrightness, dim: 0,
                        phase: .dawn, rampPhase: .day))

        // 保证 t 严格递增，否则插值会除零。
        var cleaned: [Key] = []
        for var k in keys {
            if let last = cleaned.last {
                guard k.t > last.t else { continue }
                k.t = min(k.t, 1_440)
            }
            cleaned.append(k)
        }
        return cleaned
    }

    // MARK: - 时间工具

    /// 清醒时长（分钟）。就寝早于起床时表示跨午夜。
    private static func awakeMinutes(settings s: Settings) -> Double {
        let raw = (s.bedMinutes - s.wakeMinutes + 1_440) % 1_440
        return Double(raw == 0 ? 960 : raw)
    }

    private static func mostRecentWake(before now: Date, settings s: Settings,
                                       calendar: Calendar) -> Date {
        var candidate = calendar.date(bySettingHour: (s.wakeMinutes / 60) % 24,
                                      minute: s.wakeMinutes % 60,
                                      second: 0, of: now) ?? now
        if candidate > now {
            candidate = calendar.date(byAdding: .day, value: -1, to: candidate) ?? candidate
        }
        return candidate
    }

    static func inNightWindow(_ now: Date, settings s: Settings, calendar: Calendar) -> Bool {
        let wake = mostRecentWake(before: now, settings: s, calendar: calendar)
        let elapsed = now.timeIntervalSince(wake) / 60
        return elapsed >= awakeMinutes(settings: s)
    }

    /// 手动模式下只需要在「进 / 出深夜窗口」的时候重算一次。
    private static func nextBoundary(after now: Date, settings s: Settings,
                                     calendar: Calendar) -> Date {
        let wake = mostRecentWake(before: now, settings: s, calendar: calendar)
        let elapsed = now.timeIntervalSince(wake) / 60
        let bed = awakeMinutes(settings: s)
        let boundary = elapsed < bed ? bed : 1_440
        return wake.addingTimeInterval(boundary * 60)
    }
}
