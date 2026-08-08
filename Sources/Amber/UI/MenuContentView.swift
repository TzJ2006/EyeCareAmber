import AppKit
import SwiftUI

struct MenuContentView: View {
    @ObservedObject var engine: Engine

    /// 高级设置是**独立一页**，不是往主页面下方追加。
    ///
    /// 一开始做成 `if showAdvanced { ... }` 追加在滚动区末尾，结果是主内容本来就撑满了
    /// `maxHeight`，展开后新内容全落在折叠线以下 —— 弹窗高度不变，点齿轮看起来毫无反应。
    /// 换页能保证点击一定有可见反馈。
    private enum Page { case main, advanced }
    @State private var page: Page

    /// 内容区固定高度。两个页面共用，保证切页时窗口尺寸不变。
    private static let contentHeight: CGFloat = 480

    /// `expandAdvanced` 只给 `--render-ui` 诊断用，方便直接截到设置页。
    init(engine: Engine, expandAdvanced: Bool = false) {
        self.engine = engine
        _page = State(initialValue: expandAdvanced ? .advanced : .main)
    }

    private var s: Binding<Settings> { $engine.settings }
    private var language: AppLanguage { engine.settings.language }
    private func tr(_ key: String) -> String { language.text(key) }
    private func tr(_ key: String, _ arguments: CVarArg...) -> String {
        language.format(key, arguments: arguments)
    }

    private func coefficientOutput(cct: Double, coefficient: Double, extraDim: Double) -> String {
        let target = LightTarget(cct: cct, brightness: coefficient,
                                 extraDim: extraDim, phase: .manual)
        let output = ColorScience.metrics(for: target.effectiveGain).photopicRatio
        return tr("control.coefficientOutput", coefficient, output * 100)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()

            // 内容区高度**固定**，不随页面切换变化。
            //
            // 用 `maxHeight` 让它自适应会导致切页时 popover 要重新协商窗口尺寸
            // （主页 630pt ↔ 高级页 355pt），协商过程中内容区会被压成零高度 ——
            // 表现就是点了齿轮只剩头部和页脚。固定高度直接消掉这个协商。
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    switch page {
                    case .main:     mainPage
                    case .advanced: advancedSection
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .frame(height: Self.contentHeight)

            Divider()
            footer
        }
        .frame(width: 340)
        .onAppear { engine.menuIsOpen = true }
        .onDisappear { engine.menuIsOpen = false }
    }

    // MARK: - 主页面

    @ViewBuilder
    private var mainPage: some View {
        modePicker

        if engine.settings.mode == .manual {
            manualControls
        } else {
            smartSummary
        }

        Divider()
        nightSection

        Divider()
        metricsSection
    }

    // MARK: - 顶部

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            SwatchView(gain: engine.target.gain)
                .frame(width: 34, height: 34)

            VStack(alignment: .leading, spacing: 2) {
                Text(statusTitle)
                    .font(.system(size: 13, weight: .semibold))
                Text(statusDetail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Toggle("", isOn: Binding(
                get: { engine.settings.enabled },
                set: { engine.setEnabled($0) }
            ))
            .toggleStyle(.switch)
            .labelsHidden()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    private var statusTitle: String {
        if !engine.settings.enabled { return tr("status.disabled") }
        if engine.isPaused { return tr("status.paused") }
        return engine.target.phase.title(in: language)
    }

    private var statusDetail: String {
        guard engine.settings.enabled else { return tr("status.original") }
        if engine.isPaused, let until = engine.settings.pausedUntil {
            return tr("status.resumeAt", Self.timeFormatter.string(from: until))
        }
        return tr("status.detail", engine.target.cct, engine.metrics.photopicRatio * 100)
    }

    // MARK: - 模式

    private var modePicker: some View {
        Picker("", selection: s.mode) {
            ForEach(OperatingMode.allCases, id: \.self) { mode in
                Text(mode.title(in: language)).tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .disabled(!engine.settings.enabled)
    }

    private var smartSummary: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(tr("main.wake"), systemImage: "sunrise")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
                TimeField(minutes: s.wakeMinutes)
            }
            HStack {
                Label(tr("main.bed"), systemImage: "moon.zzz")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
                TimeField(minutes: s.bedMinutes)
            }

            TimelineStrip(settings: engine.settings, solar: engine.solar)
                .frame(height: 26)

            Text(tr("main.smartExplanation", Int(engine.settings.eveningLeadHours)))
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .disabled(!engine.settings.enabled)
    }

    private var manualControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            SliderRow(title: tr("control.colorTemperature"),
                      value: s.manualCCT,
                      range: Settings.cctRange,
                      display: String(format: "%.0f K", engine.settings.manualCCT),
                      lowLabel: tr("control.amber"), highLabel: tr("control.natural"))

            SliderRow(title: tr("control.brightness"),
                      value: s.manualBrightness,
                      range: Settings.brightnessRange,
                      display: coefficientOutput(cct: engine.settings.manualCCT,
                                                 coefficient: engine.settings.manualBrightness,
                                                 extraDim: engine.settings.globalExtraDim),
                      lowLabel: tr("control.dark"), highLabel: tr("control.full"))

            SliderRow(title: tr("control.extraDim"),
                      value: s.globalExtraDim,
                      range: Settings.dimRange,
                      display: String(format: "%.0f%%", engine.settings.globalExtraDim * 100),
                      lowLabel: tr("control.none"), highLabel: tr("control.strong"),
                      caption: tr("control.extraDim.caption"))
        }
        .disabled(!engine.settings.enabled)
    }

    // MARK: - 夜间助眠

    private var nightSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(isOn: s.nightAssistEnabled) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(tr("night.title")).font(.system(size: 12, weight: .medium))
                    Text(tr("night.subtitle"))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)

            if engine.settings.nightAssistEnabled {
                SliderRow(title: tr("night.colorTemperature"), value: s.nightCCT,
                          range: 1_800...4_500,
                          defaultValue: Settings().nightCCT,
                          recommendedLabel: tr("control.recommended"),
                          display: String(format: "%.0f K", engine.settings.nightCCT),
                          lowLabel: "1800", highLabel: "4500", compact: true)
                SliderRow(title: tr("night.brightness"), value: s.nightBrightness,
                          range: 0.15...0.7,
                          defaultValue: Settings().nightBrightness,
                          recommendedLabel: tr("control.recommended"),
                          display: coefficientOutput(
                            cct: engine.settings.nightCCT,
                            coefficient: engine.settings.nightBrightness,
                            extraDim: max(engine.settings.nightExtraDim,
                                          engine.settings.globalExtraDim)),
                          lowLabel: "15%", highLabel: "70%", compact: true)
            }
        }
        .disabled(!engine.settings.enabled)
    }

    // MARK: - 科学指标

    private var metricsSection: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(tr("metrics.title"))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)

            MetricBar(label: tr("metrics.melanopic"),
                      value: engine.metrics.melanopicRatio,
                      hint: tr("metrics.melanopic.hint"))
            MetricBar(label: tr("metrics.perceivedBrightness"),
                      value: engine.metrics.photopicRatio,
                      hint: tr("metrics.perceivedBrightness.hint"))
            MetricBar(label: tr("metrics.blueAttenuation"),
                      value: engine.metrics.blueAttenuation,
                      hint: tr("metrics.blueAttenuation.hint"))

            Text(tr("metrics.note"))
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - 高级

    private var advancedSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(tr("advanced.title"))
                .font(.system(size: 13, weight: .semibold))

            VStack(alignment: .leading, spacing: 6) {
                Text(tr("advanced.language")).font(.system(size: 11, weight: .medium))
                Picker("", selection: s.language) {
                    ForEach(AppLanguage.allCases, id: \.self) { option in
                        Text(option.title(in: language)).tag(option)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
            }

            Label {
                Text(tr("advanced.autoBrightness.explanation"))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "sun.max")
            }
            .accessibilityLabel(tr("advanced.autoBrightness"))

            VStack(alignment: .leading, spacing: 6) {
                Text(tr("advanced.solarSource")).font(.system(size: 11, weight: .medium))
                Picker("", selection: s.solarSource) {
                    ForEach(SolarSource.allCases, id: \.self) { src in
                        Text(src.title(in: language)).tag(src)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()

                Text(engine.settings.solarSource.explanation(in: language))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                solarSourceStatus
            }

            Toggle(tr("advanced.launchAtLogin"), isOn: s.launchAtLogin)
                .font(.system(size: 12))

            Toggle(isOn: s.forceOverlayMode) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(tr("advanced.forceOverlay")).font(.system(size: 12))
                    Text(tr("advanced.forceOverlay.explanation"))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }

            LabeledContent {
                Text(tr("advanced.displayCount", engine.displayCount))
                    .font(.system(size: 11, design: .monospaced))
            } label: {
                Text(tr("advanced.managedDisplays")).font(.system(size: 11))
            }

            if engine.usingOverlayFallback {
                Label(tr("advanced.overlayFallback"),
                      systemImage: "exclamationmark.triangle")
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private var solarSourceStatus: some View {
        switch engine.settings.solarSource {
        case .systemAppearance:
            if !SolarProvider.systemAppearanceIsAuto {
                Label(tr("solar.autoAppearanceWarning"),
                      systemImage: "info.circle")
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let desc = engine.solar.learnedDescription(in: language) {
                Text(tr("solar.learned", desc))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
            } else {
                Text(tr("solar.waiting"))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }

        case .location:
            HStack(spacing: 8) {
                Button(tr("solar.relocate")) { engine.requestLocation() }
                    .controlSize(.small)
                if let lat = engine.settings.latitude, let lon = engine.settings.longitude {
                    Text(String(format: "%.2f, %.2f", lat, lon))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }

        case .manual:
            HStack(spacing: 6) {
                CoordField(title: tr("solar.latitude"), value: s.latitude, range: -90...90)
                CoordField(title: tr("solar.longitude"), value: s.longitude, range: -180...180)
            }

        case .off:
            EmptyView()
        }
    }

    // MARK: - 底部

    private var footer: some View {
        HStack(spacing: 8) {
            if page == .advanced {
                Button {
                    page = .main
                } label: {
                    Label(tr("footer.back"), systemImage: "chevron.left")
                        .font(.system(size: 11))
                }
                .buttonStyle(.borderless)
            } else if engine.isPaused {
                Button(tr("footer.resume")) { engine.resume() }
                    .controlSize(.small)
            } else {
                Menu(tr("footer.pause")) {
                    Button(tr("footer.30minutes")) { engine.pause(for: 30 * 60) }
                    Button(tr("footer.1hour")) { engine.pause(for: 3_600) }
                    Button(tr("footer.2hours")) { engine.pause(for: 2 * 3_600) }
                    Button(tr("footer.untilTomorrow")) { engine.pauseUntilTomorrow() }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .controlSize(.small)
                .disabled(!engine.settings.enabled)
            }

            Spacer()

            Button {
                page = (page == .advanced) ? .main : .advanced
            } label: {
                Image(systemName: page == .advanced ? "gearshape.fill" : "gearshape")
            }
            .buttonStyle(.borderless)
            .help(page == .advanced ? tr("footer.backHelp") : tr("advanced.title"))

            Button(tr("footer.quit")) { NSApp.terminate(nil) }
                .controlSize(.small)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()
}

// MARK: - 组件

/// 当前色彩的实时色块预览。
private struct SwatchView: View {
    let gain: RGBGain

    var body: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(
                LinearGradient(colors: [color.opacity(0.95), color.opacity(0.65)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
            )
            // 白天色块本身就是白的，边框必须用与背景对比的颜色，否则整块消失。
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(.secondary.opacity(0.35), lineWidth: 0.5)
            )
    }

    /// 用 sRGB 编码域显示，和屏幕上实际看到的效果一致。
    private var color: Color {
        func encode(_ v: Double) -> Double { pow(v.clamped(to: 0...1), 1 / 2.2) }
        return Color(.sRGB, red: encode(gain.r), green: encode(gain.g), blue: encode(gain.b))
    }
}

private struct SliderRow: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var defaultValue: Double? = nil
    var recommendedLabel: String? = nil
    let display: String
    var lowLabel: String = ""
    var highLabel: String = ""
    var caption: String? = nil
    var compact = false

    @State private var isAtDefaultDetent = false

    /// 默认点附近形成一个约占轨道 2.5% 的吸附区；离开吸附区后仍可连续调节。
    private var detentedValue: Binding<Double> {
        Binding(
            get: { value },
            set: { newValue in
                guard let defaultValue else {
                    value = newValue
                    return
                }

                let tolerance = (range.upperBound - range.lowerBound) * 0.025
                let shouldSnap = abs(newValue - defaultValue) <= tolerance
                if shouldSnap && !isAtDefaultDetent {
                    NSHapticFeedbackManager.defaultPerformer.perform(
                        .alignment, performanceTime: .now
                    )
                }
                isAtDefaultDetent = shouldSnap
                value = shouldSnap ? defaultValue : newValue
            }
        )
    }

    private var defaultFraction: Double? {
        guard let defaultValue, range.contains(defaultValue) else { return nil }
        return (defaultValue - range.lowerBound) / (range.upperBound - range.lowerBound)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(title).font(.system(size: compact ? 11 : 12))
                Spacer()
                Text(display)
                    .font(.system(size: compact ? 10 : 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 6) {
                Text(lowLabel).font(.system(size: 9)).foregroundStyle(.tertiary)
                GeometryReader { geo in
                    ZStack {
                        Slider(value: detentedValue, in: range)
                            .controlSize(.small)

                        if let fraction = defaultFraction, let recommendedLabel {
                            let inset: CGFloat = 8
                            let x = inset + (geo.size.width - inset * 2) * fraction
                            VStack(spacing: 0) {
                                Capsule().fill(.orange).frame(width: 2, height: 8)
                                Text(recommendedLabel)
                                    .font(.system(size: 8, weight: .medium))
                                    .foregroundStyle(.orange)
                            }
                            .position(x: x, y: 23)
                            .allowsHitTesting(false)
                        }
                    }
                }
                .frame(height: recommendedLabel == nil ? 18 : 32)
                Text(highLabel).font(.system(size: 9)).foregroundStyle(.tertiary)
            }

            if let caption {
                Text(caption)
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct MetricBar: View {
    let label: String
    let value: Double
    let hint: String

    // 刻意不做「绿=好 / 红=坏」的配色。
    // 白天 melanopic 100% 是文献建议的状态，标红会让人以为出了问题；
    // 同一个数值在不同时段的好坏完全相反，颜色编码只会误导。数字自己说话就够了。
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label).font(.system(size: 11))
                Spacer()
                Text(String(format: "%.0f%%", value * 100))
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule().fill(Color.accentColor)
                        .frame(width: geo.size.width * value.clamped(to: 0...1))
                }
            }
            .frame(height: 4)
            Text(hint).font(.system(size: 9)).foregroundStyle(.tertiary)
        }
    }
}

/// 一天的色温走势缩略图。纯静态绘制，只在菜单打开时算一次。
private struct TimelineStrip: View {
    let settings: Settings
    let solar: SolarProvider

    var body: some View {
        GeometryReader { geo in
            let now = Date()
            let cal = Calendar.current
            let midnight = cal.startOfDay(for: now)
            let steps = max(Int(geo.size.width / 2), 40)
            let events = solar.events(on: now, settings: settings)

            ZStack(alignment: .leading) {
                HStack(spacing: 0) {
                    ForEach(0..<steps, id: \.self) { i in
                        let t = midnight.addingTimeInterval(Double(i) / Double(steps) * 86_400)
                        let r = Schedule.evaluate(at: t, settings: settings, solar: events)
                        Rectangle().fill(swatch(r.target.gain))
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))

                // 「现在」的游标
                let frac = now.timeIntervalSince(midnight) / 86_400
                Rectangle()
                    .fill(.primary)
                    .frame(width: 1.5)
                    .offset(x: geo.size.width * frac)
            }
        }
    }

    private func swatch(_ g: RGBGain) -> Color {
        func encode(_ v: Double) -> Double { pow(v.clamped(to: 0...1), 1 / 2.2) }
        return Color(.sRGB, red: encode(g.r), green: encode(g.g), blue: encode(g.b))
    }
}

private struct TimeField: View {
    @Binding var minutes: Int

    var body: some View {
        DatePicker("", selection: Binding(
            get: {
                Calendar.current.date(bySettingHour: (minutes / 60) % 24,
                                      minute: minutes % 60, second: 0,
                                      of: Date()) ?? Date()
            },
            set: { newDate in
                let c = Calendar.current.dateComponents([.hour, .minute], from: newDate)
                minutes = (c.hour ?? 0) * 60 + (c.minute ?? 0)
            }
        ), displayedComponents: .hourAndMinute)
        .datePickerStyle(.stepperField)
        .labelsHidden()
        // 12 小时制的 "11:30 PM" 比 24 小时制宽，92pt 会把 PM 截掉。
        .frame(width: 116)
    }
}

private struct CoordField: View {
    let title: String
    @Binding var value: Double?
    let range: ClosedRange<Double>

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 9)).foregroundStyle(.tertiary)
            TextField("", value: Binding(
                get: { value ?? 0 },
                set: { value = $0.clamped(to: range) }
            ), format: .number.precision(.fractionLength(2)))
            .textFieldStyle(.roundedBorder)
            .font(.system(size: 11, design: .monospaced))
            .frame(width: 74)
        }
    }
}
