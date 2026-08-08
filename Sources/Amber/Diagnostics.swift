import AppKit
import CoreGraphics
import SwiftUI
import Foundation

/// 自检：用 `Amber --selftest` 运行，打印色度学 / 排班计算的关键数值。
///
/// 这些数字可以和已发表的参考值对照，不是「看起来对」而已。
enum Diagnostics {

    static func runIfRequested() -> Bool {
        let args = CommandLine.arguments
        if args.contains("--selftest") {
            run()
            return true
        }
        if let i = args.firstIndex(of: "--apply"), args.count > i + 2,
           let cct = Double(args[i + 1]), let brightness = Double(args[i + 2]) {
            applyProbe(cct: cct, brightness: brightness)
            return true
        }
        if args.contains("--restore-test") {
            restoreFidelityProbe()
            return true
        }
        if args.contains("--compare-presets") {
            comparePresets()
            return true
        }
        if let i = args.firstIndex(of: "--render-ui"), args.count > i + 1 {
            MainActor.assumeIsolated { renderMenuProbe(to: args[i + 1], expandAdvanced: args.contains("--advanced")) }
            return true
        }
        return false
    }

    /// 端到端验证：读基线 → 写 LUT → 读回来比对 → 还原 → 再读一次确认还原干净。
    ///
    /// 用法： Amber --apply 2700 0.62
    private static func applyProbe(cct: Double, brightness: Double) {
        setvbuf(stdout, nil, _IONBF, 0)
        let controller = GammaController()

        print("=== LUT 施加验证：\(Int(cct))K × \(brightness) ===\n")

        func dump(_ label: String) -> [(CGDirectDisplayID, Double, Double, Double)] {
            var out: [(CGDirectDisplayID, Double, Double, Double)] = []
            for id in GammaController.activeDisplays() {
                let cap = CGDisplayGammaTableCapacity(id)
                var r = [CGGammaValue](repeating: 0, count: Int(cap)), g = r, b = r
                var n: UInt32 = 0
                guard CGGetDisplayTransferByTable(id, cap, &r, &g, &b, &n) == .success,
                      n > 1 else { continue }
                let top = Int(n) - 1
                out.append((id, Double(r[top]), Double(g[top]), Double(b[top])))
                print(String(format: "%@  显示器 %u：顶端 R=%.4f G=%.4f B=%.4f",
                             pad(label, 10), id, r[top], g[top], b[top]))
            }
            return out
        }

        let before = dump("原始")
        controller.captureBaselines()

        let target = LightTarget(cct: cct, brightness: brightness, extraDim: 0, phase: .manual)
        let gain = target.gain
        let ok = controller.apply(gain)
        print(String(format: "\n施加线性增益 R=%.4f G=%.4f B=%.4f（编码域 ^1/2.2 后写入）→ %@\n",
                     gain.r, gain.g, gain.b, ok ? "全部成功" : "有显示器失败"))

        let after = dump("施加后")

        print("\n── 比对（实测衰减 vs 理论值）")
        for (b0, a0) in zip(before, after) {
            guard b0.0 == a0.0 else { continue }
            let expected = (pow(gain.r, 1 / 2.2), pow(gain.g, 1 / 2.2), pow(gain.b, 1 / 2.2))
            let measured = (a0.1 / max(b0.1, 1e-9), a0.2 / max(b0.2, 1e-9), a0.3 / max(b0.3, 1e-9))
            print(String(format: "显示器 %u  实测 R=%.4f G=%.4f B=%.4f", b0.0,
                         measured.0, measured.1, measured.2))
            print(String(format: "          理论 R=%.4f G=%.4f B=%.4f", expected.0,
                         expected.1, expected.2))
            let err = max(abs(measured.0 - expected.0),
                          max(abs(measured.1 - expected.1), abs(measured.2 - expected.2)))
            print(String(format: "          最大偏差 %.5f  %@", err,
                         err < 0.002 ? "✓" : "✗ 超出容差"))
        }

        print("\n── 还原")
        controller.restore()
        usleep(200_000)
        let restored = dump("还原后")
        var clean = true
        for (b0, r0) in zip(before, restored) where b0.0 == r0.0 {
            if max(abs(b0.1 - r0.1), max(abs(b0.2 - r0.2), abs(b0.3 - r0.3))) > 0.002 { clean = false }
        }
        print(clean ? "\n✓ 已完全还原到原始校准" : "\n✗ 还原后与原始不一致")
    }

    /// 并排比较两套预设的光度学 / 光生物学后果。
    ///
    /// 调参数最容易犯的错是「按某篇论文的结论改了色温，却没算改完之后的剂量」。
    /// 视觉疲劳文献偏好 4500 K，节律文献要求低 melanopic —— 这两个终点不一样，
    /// 改色温时必须同时看剂量往哪边走。
    private static func comparePresets() {
        setvbuf(stdout, nil, _IONBF, 0)
        print("=== 预设对比：旧预设 (v1) vs 科学预设 (v2) ===\n")

        let rows: [(String, String, Double, Double, Double)] = [
            ("傍晚 / 睡前", "v1", 2_700, 0.62, 0.00),
            ("傍晚 / 睡前", "v2", 4_300, 0.55, 0.00),
            ("深夜助眠",     "v1", 1_900, 0.35, 0.20),
            ("深夜助眠",     "v2", 1_900, 0.45, 0.00),
            ("手动初值",     "v1", 3_400, 0.90, 0.00),
            ("手动初值",     "v2", 4_500, 0.80, 0.00),
        ]

        print(pad("档位", 14) + pad("版本", 6) + pad("色温", 8, right: true)
            + pad("系数", 7, right: true) + pad("调暗", 7, right: true)
            + pad("melanopic", 12, right: true) + pad("相对输出", 11, right: true))

        var previous: (mel: Double, pho: Double)? = nil
        for (name, version, cct, coeff, dim) in rows {
            let m = presetMetrics(cct: cct, coefficient: coeff, extraDim: dim)
            let mel = m.melanopicRatio
            let pho = m.photopicRatio

            var delta = ""
            if version == "v2", let p = previous {
                let dMel = (mel / max(p.mel, 1e-9) - 1) * 100
                let dPho = (pho / max(p.pho, 1e-9) - 1) * 100
                delta = String(format: "   melanopic %+.0f%% · 输出 %+.0f%%", dMel, dPho)
            }

            print(pad(name, 14) + pad(version, 6)
                + String(format: "%7.0fK %6.2f %6.0f%% %11.1f%% %10.1f%%",
                         cct, coeff, dim * 100, mel * 100, pho * 100)
                + delta)
            previous = (mel, pho)
        }

        let evening = presetMetrics(cct: 4_300, coefficient: 0.55, extraDim: 0)
        let night = presetMetrics(cct: 1_900, coefficient: 0.45, extraDim: 0)
        print("\n── 假设系统背光情景（演算值，不是运行时测量）")
        for panelNits in [30.0, 60.0, 120.0, 400.0] {
            print(String(format: "背光 %4.0f nits →  睡前 %6.1f nits   深夜 %6.1f nits%@",
                         panelNits, evening.photopicRatio * panelNits,
                         night.photopicRatio * panelNits,
                         night.photopicRatio * panelNits < 5 ? "   ← 低于 5 nits 情景线" : ""))
        }

        assertSciencePreset(evening: evening, night: night)
        print("\n✓ 最终指标、30 nits 情景线与睡前/深夜剂量关系均符合预期")
    }

    private static func presetMetrics(cct: Double, coefficient: Double,
                                      extraDim: Double) -> ColorScience.Metrics {
        let target = LightTarget(cct: cct, brightness: coefficient,
                                 extraDim: extraDim, phase: .manual)
        return ColorScience.metrics(for: target.effectiveGain)
    }

    private static func assertSciencePreset(evening: ColorScience.Metrics,
                                            night: ColorScience.Metrics) {
        assert(abs(evening.melanopicRatio - 0.328) < 0.003, "睡前 melanopic 偏离 32.8%")
        assert(abs(evening.photopicRatio - 0.426) < 0.003, "睡前相对输出偏离 42.6%")
        assert(abs(night.melanopicRatio - 0.058) < 0.002, "深夜 melanopic 偏离 5.8%")
        assert(abs(night.photopicRatio - 0.175) < 0.002, "深夜相对输出偏离 17.5%")
        assert(night.photopicRatio * 30 >= 5, "30 nits 背光情景下深夜输出低于 5 nits")
        assert(night.melanopicRatio < evening.melanopicRatio * 0.20,
               "深夜 melanopic 必须低于睡前档的 20%")
    }

    /// 把菜单界面离屏渲染成 PNG。
    ///
    /// 编译通过不代表界面能用 —— SwiftUI 的布局问题、约束冲突、空视图都是运行期才暴露的。
    /// 这里把真实的 `MenuContentView` 挂到窗口上跑完整布局再截下来，
    /// 不需要 accessibility 权限，也不用手动点菜单栏。
    @MainActor
    static func renderMenuProbe(to path: String, expandAdvanced: Bool = false) {
        setvbuf(stdout, nil, _IONBF, 0)
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)

        let engine = Engine.shared
        engine.start()
        defer { engine.shutdown() }

        // 必须走 NSHostingController，这是 MenuBarExtra(.window) 真实使用的尺寸路径。
        //
        // 之前用 NSHostingView 并手动把 frame 设成 fittingSize，等于替 SwiftUI 把高度
        // 定死了 —— 结果是 ScrollView 在真实 popover 里被压成零高度的 bug 完全测不出来。
        let controller = NSHostingController(
            rootView: MenuContentView(engine: engine, expandAdvanced: expandAdvanced))
        let window = NSWindow(contentViewController: controller)
        window.styleMask = [.borderless]
        window.orderBack(nil)

        // 让 SwiftUI 完成首次布局
        for _ in 0..<20 { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }

        let host = controller.view
        let size = host.fittingSize
        print("自适应尺寸（popover 实际采用的）：\(Int(size.width)) × \(Int(size.height)) pt")

        // 头部约 56pt + 页脚约 40pt + 两条分隔线。内容区塌陷时总高会落在 110 上下。
        guard size.height > 160 else {
            print("✗ 内容区塌陷 —— popover 里只会看到头部和页脚，中间一片空白")
            return
        }
        guard size.width > 100 else {
            print("✗ 布局宽度异常"); return
        }
        window.setContentSize(size)
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()

        window.setContentSize(size)
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        for _ in 0..<20 { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }

        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            print("✗ 无法创建位图"); return
        }
        host.cacheDisplay(in: host.bounds, to: rep)

        // 统计非空白像素，防止「渲染成功但一片空白」
        var nonBlank = 0
        var total = 0
        let w = rep.pixelsWide, h = rep.pixelsHigh
        for y in stride(from: 0, to: h, by: 4) {
            for x in stride(from: 0, to: w, by: 4) {
                total += 1
                if let c = rep.colorAt(x: x, y: y), c.alphaComponent > 0.05 { nonBlank += 1 }
            }
        }
        let coverage = total > 0 ? Double(nonBlank) / Double(total) : 0
        print(String(format: "有效像素覆盖率：%.1f%%", coverage * 100))

        guard let png = rep.representation(using: .png, properties: [:]) else {
            print("✗ PNG 编码失败"); return
        }
        do {
            try png.write(to: URL(fileURLWithPath: path))
            print("✓ 已写出 \(path)（\(png.count / 1024) KB）")
        } catch {
            print("✗ 写文件失败：\(error.localizedDescription)")
        }
    }

    /// 无损还原验证。
    ///
    /// 先人为写入一条**非线性**的假校准曲线（模拟内建 XDR 屏被系统加载的那种），
    /// 再跑一遍完整的「抓基线 → 施加 → 还原」，最后逐点比对整张表。
    ///
    /// 这是必须的：`CGDisplayRestoreColorSyncSettings()` 在这种情况下会把曲线抹平，
    /// 光看「还原后接近 1.0」是发现不了的 —— 因为线性斜坡的顶端本来就是 1.0。
    static func restoreFidelityProbe() {
        setvbuf(stdout, nil, _IONBF, 0)
        print("=== 无损还原验证 ===\n")

        guard let id = GammaController.activeDisplays().first else {
            print("没有可用显示器"); return
        }
        let size = 256

        // 假校准：明显偏暖 + 带一点 S 形，任何「抹平」都藏不住。
        var fakeR = [CGGammaValue](repeating: 0, count: size)
        var fakeG = fakeR, fakeB = fakeR
        for i in 0..<size {
            let x = Double(i) / Double(size - 1)
            let s = x + 0.04 * sin(x * .pi)          // S 形，线性斜坡没有这个
            fakeR[i] = CGGammaValue(min(s * 0.980, 1))
            fakeG[i] = CGGammaValue(min(s * 0.955, 1))
            fakeB[i] = CGGammaValue(min(s * 0.910, 1))
        }
        guard CGSetDisplayTransferByTable(id, UInt32(size), fakeR, fakeG, fakeB) == .success else {
            print("无法写入测试曲线"); return
        }
        print("已写入假校准曲线（顶端 R=\(String(format: "%.4f", fakeR[size-1])) "
            + "G=\(String(format: "%.4f", fakeG[size-1])) B=\(String(format: "%.4f", fakeB[size-1]))，含 S 形）")

        /// 读回整表，和假曲线按归一化位置逐点比对。
        func deviationFromFake() -> Double {
            let cap = CGDisplayGammaTableCapacity(id)
            var r = [CGGammaValue](repeating: 0, count: Int(cap)), g = r, b = r
            var n: UInt32 = 0
            guard CGGetDisplayTransferByTable(id, cap, &r, &g, &b, &n) == .success, n > 1 else {
                return .infinity
            }
            var worst = 0.0
            for i in 0..<Int(n) {
                let j = Int((Double(i) / Double(Int(n) - 1) * Double(size - 1)).rounded())
                worst = max(worst, Double(abs(r[i] - fakeR[j])))
                worst = max(worst, Double(abs(g[i] - fakeG[j])))
                worst = max(worst, Double(abs(b[i] - fakeB[j])))
            }
            return worst
        }

        // 对照组：不做任何事，只是写进去再读出来。
        // 我们写 256 项、硬件存 1024 项并插值，这一步本身就有重采样误差。
        let baselineNoise = deviationFromFake()
        print(String(format: "对照组（只写入再读回，未经任何处理）：%.6f", baselineNoise))

        let controller = GammaController()
        controller.captureBaselines()
        controller.apply(LightTarget(cct: 2_300, brightness: 0.5,
                                     extraDim: 0, phase: .manual).gain)
        print("已施加 2300K × 0.5")
        controller.restore()
        print("已调用 restore()")

        let afterRestore = deviationFromFake()
        print(String(format: "\n还原后偏差：            %.6f", afterRestore))
        print(String(format: "对照组（重采样噪声）：  %.6f", baselineNoise))
        let attributable = afterRestore - baselineNoise
        print(String(format: "还原本身引入的误差：    %.6f", attributable))

        print(attributable < 0.0005
              ? "\n✓ 还原无损 —— 残差全部来自 256→1024 的表长重采样，与 restore 无关。\n"
              + "  用户的显示器校准不会被破坏。"
              : "\n✗ 还原有损，校准被改动了")

        // 收尾：把假曲线也撤掉，交还给系统
        CGDisplayRestoreColorSyncSettings()
        print("\n（测试曲线已撤除）")
    }

    static func run() {
        setvbuf(stdout, nil, _IONBF, 0)   // 崩了也不丢输出
        print("=== Amber 自检 ===\n")
        localizationCheck()
        migrationCheck()
        sciencePresetCheck()
        colorScience()
        melanopicCurve()
        solarCheck()
        scheduleBoundaryCheck()
        scheduleWalk()
    }

    private static func localizationCheck() {
        let codes = ["en", "fr", "es", "zh-Hans"]
        let tables = codes.map { code -> [String: String] in
            let url = Bundle.module.bundleURL
                .appendingPathComponent("\(code).lproj/Localizable.strings")
            guard let data = try? Data(contentsOf: url),
                  let table = try? PropertyListSerialization.propertyList(from: data,
                                                                           format: nil),
                  let strings = table as? [String: String]
            else { return [:] }
            return strings
        }
        assert(!tables[0].isEmpty, "未找到英文界面资源")
        let reference = Set(tables[0].keys)
        for (code, table) in zip(codes, tables) {
            assert(Set(table.keys) == reference, "\(code) 本地化键与英文不一致")
        }
        assert(AppLanguage.en.format("advanced.displayCount", 2) == "2 displays")
        assert(AppLanguage.zhHans.format("control.coefficientOutput", 0.8, 64.0)
               == "系数 0.80 · 相对输出 64%")
        print("✓ EN / FR / ES / 中文本地化键一致，格式化读数有效\n")
    }

    private static func migrationCheck() {
        let oldJSON: [String: Any] = [
            "manualCCT": 3_400.0, "manualBrightness": 0.90,
            "eveningCCT": 2_700.0, "eveningBrightness": 0.62,
            "nightBrightness": 0.35, "nightExtraDim": 0.20,
            "wakeMinutes": 480, "language": "fr"
        ]
        let data = try! JSONSerialization.data(withJSONObject: oldJSON)
        var old = try! JSONDecoder().decode(Settings.self, from: data)
        assert(old.sciencePresetVersion == 1, "缺少版本字段的配置应视为 v1")
        assert(old.migrateSciencePresetIfNeeded())
        assert(old.manualCCT == 4_500 && old.manualBrightness == 0.80)
        assert(old.eveningCCT == 4_300 && old.eveningBrightness == 0.55)
        assert(old.nightBrightness == 0.45 && old.nightExtraDim == 0)
        assert(old.wakeMinutes == 480 && old.language == .fr, "迁移改动了非预设字段")
        let migrated = old
        assert(!old.migrateSciencePresetIfNeeded() && old == migrated, "迁移不应重复执行")

        var custom = Settings()
        custom.sciencePresetVersion = 1
        custom.manualCCT = 3_200
        custom.manualBrightness = 0.74
        custom.eveningCCT = 2_900
        custom.eveningBrightness = 0.50
        custom.nightBrightness = 0.40
        custom.nightExtraDim = 0.10
        let customValues = custom
        assert(custom.migrateSciencePresetIfNeeded())
        assert(custom.manualCCT == customValues.manualCCT
            && custom.manualBrightness == customValues.manualBrightness
            && custom.eveningCCT == customValues.eveningCCT
            && custom.eveningBrightness == customValues.eveningBrightness
            && custom.nightBrightness == customValues.nightBrightness
            && custom.nightExtraDim == customValues.nightExtraDim,
               "用户改过的字段不应被迁移覆盖")
        print("✓ v1 设置按字段迁移一次，用户自定义值保持不变\n")
    }

    private static func sciencePresetCheck() {
        let evening = presetMetrics(cct: 4_300, coefficient: 0.55, extraDim: 0)
        let night = presetMetrics(cct: 1_900, coefficient: 0.45, extraDim: 0)
        assertSciencePreset(evening: evening, night: night)
        print(String(format: "✓ 科学预设：睡前 melanopic %.1f%% / 输出 %.1f%%；深夜 %.1f%% / %.1f%%\n",
                     evening.melanopicRatio * 100, evening.photopicRatio * 100,
                     night.melanopicRatio * 100, night.photopicRatio * 100))
    }

    /// 按终端显示宽度补齐（CJK 占 2 列）。
    ///
    /// 不能用 `String(format: "%-10s", swiftString)` —— `%s` 要的是 C 字符串，
    /// 传 Swift String 进去会把对象指针当 char* 解引用，直接段错误。
    private static func pad(_ text: String, _ width: Int, right: Bool = false) -> String {
        let displayWidth = text.unicodeScalars.reduce(0) { acc, scalar in
            acc + (scalar.value > 0x1100 && scalar.value < 0xFFF0 ? 2 : 1)
        }
        let spaces = String(repeating: " ", count: max(0, width - displayWidth))
        return right ? spaces + text : text + spaces
    }

    // MARK: - 色温 → 增益

    private static func colorScience() {
        print("── 色温 → 线性通道增益（相对 D65 原生白点）")
        print(pad("CCT", 8, right: true) + "  " + pad("R", 7, right: true)
            + " " + pad("G", 7, right: true) + " " + pad("B", 7, right: true)
            + "   " + pad("melanopic", 10, right: true) + " " + pad("亮度", 10, right: true))
        for cct in [6_500.0, 5_500, 4_500, 3_400, 2_700, 2_300, 1_900] {
            let g = ColorScience.gain(forCCT: cct)
            let m = ColorScience.metrics(for: g)
            print(String(format: "%6.0fK  %7.4f %7.4f %7.4f   %9.1f%% %9.1f%%",
                         cct, g.r, g.g, g.b,
                         m.melanopicRatio * 100, m.photopicRatio * 100))
        }

        // 完整目标（色温 + 亮度），也就是实际写进 LUT 的东西
        print("\n── 实际施加的目标（含亮度衰减）")
        let presets: [(String, Double, Double)] = [
            ("白天",     6_500, 1.00),
            ("睡前",     4_300, 0.55),
            ("深夜助眠", 1_900, 0.45),
        ]
        for (name, cct, brightness) in presets {
            let t = LightTarget(cct: cct, brightness: brightness, extraDim: 0, phase: .day)
            let m = ColorScience.metrics(for: t.effectiveGain)
            print(pad(name, 10) + String(format: " %5.0fK ×%.2f → melanopic %5.1f%% · 相对输出 %5.1f%% · 蓝通道衰减 %5.1f%% · mDER %.3f",
                                         cct, brightness,
                                         m.melanopicRatio * 100, m.photopicRatio * 100,
                                         m.blueAttenuation * 100, m.melanopicDER))
        }

        // 健全性断言
        let d65 = ColorScience.gain(forCCT: 6_504)
        assert(abs(d65.r - 1) < 0.02 && abs(d65.g - 1) < 0.02 && abs(d65.b - 1) < 0.02,
               "6504K 应该是恒等增益，实际 \(d65)")
        let warm = ColorScience.gain(forCCT: 2_700)
        assert(warm.b < warm.g && warm.g < warm.r, "暖色应该 B < G < R，实际 \(warm)")
        print("\n✓ 6504K = 恒等增益；暖色下 B < G < R")
    }

    // MARK: - 黑视素曲线

    private static func melanopicCurve() {
        print("\n── 黑视素相对敏感度（应在 490 nm 附近达到峰值 1.0）")
        var peakNm = 0.0, peakVal = 0.0
        var nm = 400.0
        while nm <= 620 {
            let v = ColorScience.melanopic(nm)
            if v > peakVal { peakVal = v; peakNm = nm }
            if Int(nm) % 20 == 0 {
                let bars = String(repeating: "█", count: Int(v * 40))
                print(String(format: "%5.0f nm  %.3f  %@", nm, v, bars))
            }
            nm += 1
        }
        print(String(format: "峰值：%.0f nm（CIE S 026 参考值 ≈ 490 nm）", peakNm))
        assert(abs(peakNm - 490) < 8, "黑视素峰值偏离过大：\(peakNm)")
        print("✓ 峰值位置符合预期")
    }

    // MARK: - 日出日落

    private static func solarCheck() {
        print("\n── 日出日落（NOAA 算法验算）")
        // 用 UTC 算，结果可以直接和 timeanddate.com 之类的参考源对照。
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!

        let cases: [(String, Double, Double, String)] = [
            ("Greenwich  夏至", 51.4779,   0.0,     "2025-06-21"),
            ("Greenwich  冬至", 51.4779,   0.0,     "2025-12-21"),
            ("北京       春分", 39.9042, 116.4074,  "2025-03-20"),
        ]
        let parser = DateFormatter()
        parser.dateFormat = "yyyy-MM-dd"
        parser.timeZone = TimeZone(identifier: "UTC")!

        for (name, lat, lon, dateStr) in cases {
            guard let day = parser.date(from: dateStr),
                  let e = SolarClock.events(on: day, latitude: lat, longitude: lon, calendar: cal)
            else { print("\(name): 计算失败"); continue }
            let f = DateFormatter()
            f.dateFormat = "HH:mm"
            f.timeZone = TimeZone(identifier: "UTC")!
            print("\(name) \(dateStr)  日出 \(f.string(from: e.sunrise)) UTC · 日落 \(f.string(from: e.sunset)) UTC")
        }
    }

    private static func scheduleBoundaryCheck() {
        print("\n── 调度边界断言")
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let wake = cal.date(from: DateComponents(year: 2026, month: 1, day: 1,
                                                  hour: 7, minute: 30))!

        func target(after minutes: Double, settings: Settings,
                    solar: SolarClock.Events? = nil) -> LightTarget {
            Schedule.evaluate(at: wake.addingTimeInterval(minutes * 60),
                              settings: settings, solar: solar, calendar: cal).target
        }
        func expect(_ target: LightTarget, cct: Double, coefficient: Double,
                    phase: LightTarget.Phase, _ label: String) {
            assert(abs(target.cct - cct) < 1 && abs(target.brightness - coefficient) < 0.001
                && target.phase == phase, "\(label) 边界错误：\(target)")
        }

        var standard = Settings()
        standard.mode = .smart
        standard.solarSource = .off
        standard.wakeMinutes = 7 * 60 + 30
        standard.bedMinutes = 23 * 60 + 30
        expect(target(after: 780, settings: standard), cct: 6_500, coefficient: 1,
               phase: .evening, "睡前 3 小时")
        expect(target(after: 870, settings: standard), cct: 4_300, coefficient: 0.55,
               phase: .evening, "90 分钟渐变结束")
        expect(target(after: 960, settings: standard), cct: 4_300, coefficient: 0.55,
               phase: .night, "就寝")
        expect(target(after: 1_005, settings: standard), cct: 1_900, coefficient: 0.45,
               phase: .night, "就寝后 45 分钟")
        expect(target(after: 1_410, settings: standard), cct: 1_900, coefficient: 0.45,
               phase: .dawn, "拂晓")
        expect(target(after: 1_440, settings: standard), cct: 6_500, coefficient: 1,
               phase: .day, "起床")

        let solar = SolarClock.Events(
            sunrise: wake.addingTimeInterval(-30 * 60),
            sunset: wake.addingTimeInterval(600 * 60),
            duskEnd: wake.addingTimeInterval(630 * 60))
        let dusk = target(after: 780, settings: standard, solar: solar)
        assert(abs(dusk.cct - 5_280) < 10 && abs(dusk.brightness - 0.8425) < 0.001,
               "黄昏过渡应在睡前段起点约为 5280K × 0.84")

        var crossMidnight = standard
        crossMidnight.bedMinutes = 2 * 60
        expect(target(after: 930, settings: crossMidnight), cct: 6_500, coefficient: 1,
               phase: .evening, "跨午夜睡前 3 小时")
        expect(target(after: 1_020, settings: crossMidnight), cct: 4_300, coefficient: 0.55,
               phase: .evening, "跨午夜 90 分钟结束")
        expect(target(after: 1_110, settings: crossMidnight), cct: 4_300, coefficient: 0.55,
               phase: .night, "跨午夜就寝")
        expect(target(after: 1_155, settings: crossMidnight), cct: 1_900, coefficient: 0.45,
               phase: .night, "跨午夜深夜")
        print("✓ 睡前、就寝、深夜、拂晓、黄昏与跨午夜边界正确")
    }

    // MARK: - 一天的排班走查

    private static func scheduleWalk() {
        print("\n── 智能模式 24 小时走查（起床 07:30 / 就寝 23:30）")
        var s = Settings()
        s.mode = .smart
        s.solarSource = .off
        s.wakeMinutes = 7 * 60 + 30
        s.bedMinutes = 23 * 60 + 30

        let cal = Calendar.current
        let midnight = cal.startOfDay(for: Date())
        var wakeCount = 0
        var cursor = midnight
        let end = midnight.addingTimeInterval(86_400)

        let clock = DateFormatter(); clock.dateFormat = "HH:mm"
        print(pad("时刻", 6, right: true) + "  " + pad("阶段", 12)
            + pad("色温", 8, right: true) + pad("系数", 8, right: true)
            + pad("输出", 8, right: true)
            + pad("melanopic", 11, right: true))

        var lastPhase: LightTarget.Phase? = nil
        var lastPrinted = ""
        var longestSleep: TimeInterval = 0
        while cursor < end {
            let r = Schedule.evaluate(at: cursor, settings: s, solar: nil, calendar: cal)
            let m = ColorScience.metrics(for: r.target.effectiveGain)
            let stamp = clock.string(from: cursor)

            if (cal.component(.minute, from: cursor) % 30 == 0 || r.target.phase != lastPhase),
               stamp != lastPrinted {
                lastPrinted = stamp
                print(pad(stamp, 6, right: true) + "  "
                    + pad(r.target.phase.rawValue, 12)
                    + String(format: "%7.0fK %7.0f%% %7.0f%% %10.1f%%", r.target.cct,
                             r.target.brightness * 100, m.photopicRatio * 100,
                             m.melanopicRatio * 100)
                    + (r.isRamping ? "  ↗" : ""))
            }
            lastPhase = r.target.phase
            wakeCount += 1
            longestSleep = max(longestSleep, r.nextUpdate.timeIntervalSince(cursor))

            // 防呆：nextUpdate 必须严格前进，否则这里会死循环。
            guard r.nextUpdate > cursor else {
                print("✗ nextUpdate 没有前进（\(clock.string(from: cursor))）—— 调度器会空转")
                break
            }
            cursor = r.nextUpdate
        }

        print(String(format: "\n✓ 24 小时内定时器唤醒 %d 次（平均每 %.0f 分钟一次，最长一次连睡 %.0f 分钟）",
                     wakeCount, 1_440.0 / Double(wakeCount), longestSleep / 60))
        print("  作为对照：一台空闲的 Mac 每秒就有上千次定时器唤醒。")
    }
}
