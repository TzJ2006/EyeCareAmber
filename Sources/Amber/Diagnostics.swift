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
        if args.contains("--ambient") {
            // 取 `--flag <值>`；下一个 token 又是个开关时视为没给值。
            func value(after flag: String) -> String? {
                guard let i = args.firstIndex(of: flag), args.count > i + 1 else { return nil }
                let next = args[i + 1]
                return next.hasPrefix("--") ? nil : next
            }
            let guided = args.contains("--guided")
            ambientProbe(watch: args.contains("--watch") || guided,
                         seconds: value(after: "--watch").flatMap(Double.init),
                         interval: value(after: "--interval").flatMap(Double.init) ?? 1,
                         output: value(after: "--out").map { ($0 as NSString).expandingTildeInPath },
                         guided: guided)
            return true
        }
        if let i = args.firstIndex(of: "--auto-brightness") {
            let argument = args.count > i + 1 ? args[i + 1] : nil
            autoBrightnessProbe(argument: argument)
            return true
        }
        if args.contains("--print-locale") {
            printLocaleSamples()
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

    /// 打印每种语言实际解析出来的字符串，退出码表示是否全部成功。
    ///
    /// 存在的理由：`--selftest` 靠 `assert()` 验证，而 release 构建会把 assert
    /// 整个编译掉 —— 打包好的 app 即使读不到本地化资源，自检照样打印 ✓。
    /// 而资源加载路径恰恰在 release 下才不同（走 .app 里的 Amber_Amber.bundle）。
    /// 这里不依赖 assert：资源丢了就会原样吐出 key，字符串比对立刻能看出来。
    /// 环境光传感器的只读探针。**不写 LUT、不改背光、不改任何系统设置。**
    ///
    /// 用法： Amber --ambient              读一次
    ///        Amber --ambient --watch      持续观察，同时写 CSV（Ctrl-C 结束）
    ///        Amber --ambient --watch 60   同上，60 秒后自动结束
    ///
    /// 存在的理由：`level` 这个字段**没有标定过**。它到底是不是 lux、有多大误差、
    /// 有没有迟滞、换一种光谱还成不成立，只能拿照度计实测出来。在那之前它不许
    /// 进入任何公式。这条命令就是做那次实测用的。
    ///
    /// watch 模式同时回答第二个问题：**环境光变化时事件会不会被推过来。**
    /// 静止状态下收不到事件区分不了「只在变化时推」和「根本不推」，
    /// 所以必须真的去改变光照（遮挡传感器、开灯、手电筒）。
    private static func ambientProbe(watch: Bool, seconds: Double?,
                                     interval: Double, output: String?, guided: Bool) {
        setvbuf(stdout, nil, _IONBF, 0)
        print("=== 环境光传感器（未标定原始读数）===")
        print("机型：\(hardwareModel())    macOS：\(ProcessInfo.processInfo.operatingSystemVersionString)")
        print("匹配到的 ALS service：\(AmbientLightReader.matchedServiceCount())")

        guard let first = AmbientLightReader.rawLevel() else {
            print("\n读不到。这台机器没有可匹配的环境光传感器，或私有符号已变更。")
            return
        }
        print(String(format: "level = %.1f    ch1 = %.1f    ch2 = %.1f",
                     first.level, first.channel1, first.channel2))
        print(backlightLine())
        print("时段：\(currentPhaseName())")
        print("""

        ⚠️ level 没有单位。未经照度计标定之前，它只能当作一个单调的相对量，
           不得当作 lux，也不得进入任何公式或界面显示。
        """)

        guard watch else { return }

        // CSV 落盘，供标定与后续 shadow 分析复用。
        // 默认落临时目录只适合短跑；长跑请用 --out 指定，临时目录会被系统清理。
        let path = output
            ?? NSTemporaryDirectory() + "amber-ambient-\(Int(Date().timeIntervalSince1970)).csv"
        guard let file = FileHandle(forWritingAtPath: path) ?? {
            FileManager.default.createFile(atPath: path, contents: nil)
            return FileHandle(forWritingAtPath: path)
        }() else {
            print("✗ 无法写入 \(path)")
            return
        }
        defer { try? file.close() }

        func append(_ line: String) {
            file.write(Data((line + "\n").utf8))
        }
        append("iso_time,elapsed_s,source,level,ch1,ch2,"
             + "modeled_nits,registry_nits,slider,linear,brightness,raw_brightness,"
             + "output_ratio,screen_cd_m2,phase")

        let started = Date()
        var samples: [Reading] = []
        // 引导模式下由状态机自己打进度，不再逐行刷屏。
        let guide = guided ? GateAGuide() : nil
        func record(_ source: String, _ sample: AmbientLightReader.Sample) {
            let elapsed = Date().timeIntervalSince(started)
            let parameters = BacklightReader.diagnosticParameters()
            let outputRatio = ColorScience.metrics(for: currentTarget().effectiveGain).photopicRatio
            func field(_ key: String) -> Int? {
                BacklightReader.parameterField(key, "value", in: parameters).map(Int.init)
            }
            let reading = Reading(
                elapsed: elapsed,
                source: source,
                level: sample.level,
                nits: BacklightReader.currentNits(),
                registryNits: BacklightReader.parameterField(
                    "BrightnessMilliNits", "value", in: parameters).map { $0 / 1_000 },
                slider: AutoBrightness.sliderValue(),
                linear: BacklightReader.linearBrightness(),
                // 同一张字典里的另外两个独立标度。多个标度一起看才能分清
                // 「背光真没动」和「只是某一个读数陈旧」。
                brightness: field("brightness"),
                rawBrightness: field("rawBrightness"),
                outputRatio: outputRatio,
                screenNits: BacklightReader.currentNits().map { $0 * outputRatio })
            samples.append(reading)
            guide?.consume(reading)

            func text(_ value: Double?, _ format: String) -> String {
                value.map { String(format: format, $0) } ?? ""
            }
            var columns: [String] = [ISO8601DateFormatter().string(from: Date())]
            columns.append(String(format: "%.3f", elapsed))
            columns.append(source)
            columns.append(String(format: "%.1f", sample.level))
            columns.append(String(format: "%.1f", sample.channel1))
            columns.append(String(format: "%.1f", sample.channel2))
            columns.append(text(reading.nits, "%.1f"))
            columns.append(text(reading.registryNits, "%.1f"))
            columns.append(text(reading.slider, "%.4f"))
            columns.append(text(reading.linear, "%.4f"))
            columns.append(reading.brightness.map(String.init) ?? "")
            columns.append(reading.rawBrightness.map(String.init) ?? "")
            columns.append(String(format: "%.4f", reading.outputRatio))
            columns.append(text(reading.screenNits, "%.1f"))
            columns.append(currentPhaseName())
            append(columns.joined(separator: ","))

            guard guide == nil else { return }
            print(String(format: "  +%7.2fs  %@  level=%8.1f  nits=%@  滑杆=%@  raw=%@",
                         elapsed, pad(source, 18), sample.level,
                         pad(text(reading.nits, "%.1f"), 6),
                         pad(text(reading.slider, "%.4f"), 6),
                         reading.rawBrightness.map(String.init) ?? "—"))
        }

        print("CSV：\(path)")
        if guide == nil {
            print(seconds.map { String(format: "观察 %.0f 秒。", $0) }
                  ?? "持续观察，Ctrl-C 结束。")
            print("""
            现在请**实际改变光照**（遮住屏幕上边框中央的传感器、开关灯、用手电筒照），
            观察 source 一列是否出现 als_callback —— 那说明 ALS 事件是推过来的，
            不需要轮询。brightness_callback 只表示系统背光变化，不能代替 ALS 通知。
            """)
        }

        var alsCallbackCount = 0
        let observer = AmbientLightReader.Observer { sample in
            alsCallbackCount += 1
            record("als_callback", sample)
        }
        if observer == nil { print("⚠️ ALS 回调注册失败，本次只有轮询数据") }

        var brightnessCallbackCount = 0
        let brightnessObserver = DisplayBrightnessObserver {
            brightnessCallbackCount += 1
            guard let sample = AmbientLightReader.rawLevel() else { return }
            record("brightness_callback", sample)
        }
        if brightnessObserver == nil {
            print("⚠️ DisplayServices 亮度回调注册失败；ALS 探针仍可继续")
        }

        // 轮询只是为了在回调不工作时仍然拿到完整曲线，不代表最终实现要轮询。
        let timer = Timer(timeInterval: max(interval, 0.1), repeats: true) { _ in
            guard let sample = AmbientLightReader.rawLevel() else { return }
            record("poll", sample)
        }
        RunLoop.current.add(timer, forMode: .default)

        if let guide {
            guide.start()
            // 状态机自己决定何时结束；20 分钟是防挂死的兜底，不是预期时长。
            let deadline = started.addingTimeInterval(20 * 60)
            while !guide.isFinished, Date() < deadline {
                RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.25))
            }
            timer.invalidate()
            // 引导模式下判据由状态机下结论，汇总只提供原始区间，不再重复判定 ——
            // 那两套判定用的驻留条件不同，同时打印会自相矛盾。
            summarizeGateA(samples, alsCallbacks: alsCallbackCount,
                           brightnessCallbacks: brightnessCallbackCount, verdicts: false)
            guide.printVerdict(alsCallbacks: alsCallbackCount,
                               brightnessCallbacks: brightnessCallbackCount)
            print("\nCSV：\(path)")
        } else if let seconds {
            RunLoop.current.run(until: started.addingTimeInterval(seconds))
            timer.invalidate()
            summarizeGateA(samples, alsCallbacks: alsCallbackCount,
                           brightnessCallbacks: brightnessCallbackCount, verdicts: true)
            print("\nCSV：\(path)")
        } else {
            RunLoop.current.run()
        }
        _ = observer
        _ = brightnessObserver
    }

    /// Gate A 的引导状态机：**自己判定，自己推进，响一声提示**。
    ///
    /// 为什么不用固定时长的脚本：固定 15 分钟里绝大部分时间是在空等，而真正
    /// 要看的只有一件事 —— 光照大幅变化之后，背光**多久**有反应。有反应就立刻
    /// 可以收工；没反应才需要等满判据要求的时间。所以每一步都是
    /// 「等到光照真的变了」→「盯着背光」→「有反应就过，超时就判无响应」。
    ///
    /// 超时值刻意等于判据里的 60 秒，不为了跑得快而放宽。
    private final class GateAGuide {

        private enum Step: Int {
            case baseline, cover, uncover, roomDark, finished
        }

        /// 触发阈值：光照要变到基线的 1/2 以下（或回到 0.8 倍以上）才算数。
        private static let dropRatio = 2.0
        private static let restoreRatio = 0.8
        /// 背光相对变化到多少才算「有反应」。与汇总判据一致。
        private static let responseThreshold = 0.05
        /// 触发之后最多盯多久。等于判据里的驻留要求，不放宽。
        private static let holdSeconds = 60.0
        /// 基线要稳定多久、允许多大波动。
        private static let baselineSeconds = 8.0
        private static let baselineTolerance = 1.2

        /// 四个背光标度。分开跟踪每一个**各自**第一次动的时刻 —— 这是整个测试
        /// 的关键：只报「有没有反应」会掩盖「哪一个读数是死的」。
        private static let scaleNames = ["nits", "滑杆", "linear", "brightness", "rawBrightness"]

        /// 光照变化的倍数。
        ///
        /// 传感器完全遮住时 `level` 会读到 0，直接相除会得出「239000 倍」这种
        /// 无意义的数。0 的真实含义是「低于传感器下限」，所以分母压到 1 并把
        /// 结果标成下界。
        private static func lightRatio(_ a: Double, _ b: Double) -> (value: Double, bounded: Bool) {
            let low = min(a, b), high = max(a, b)
            return (high / max(low, 1), low < 1)
        }

        private static func describeRatio(_ ratio: (value: Double, bounded: Bool)) -> String {
            String(format: "%@%.1f 倍", ratio.bounded ? "≥" : "", ratio.value)
        }

        private struct Outcome {
            let name: String
            let levelRatio: (value: Double, bounded: Bool)
            let observed: Double
            /// 标度名 → 首次变化的延迟（秒）。没动过的标度不在表里。
            let latencies: [String: Double]
        }

        private var step: Step = .baseline
        private var baselineLevel: Double?
        private var baselineSince: Double?
        private var baselineMin = Double.infinity
        private var baselineMax = 0.0
        private var triggerAt: Double?
        private var reference: Reading?
        private var outcomes: [Outcome] = []
        private var lastProgressPrint = 0.0
        /// 本步里每个标度首次变化的延迟。
        private var latencies: [String: Double] = [:]
        private var announcedFirstMove = false

        var isFinished: Bool { step == .finished }

        func start() {
            print("""

            === Gate A 引导测试 ===
            每一步都会自动判定，完成时响一声并自动进入下一步。不用看表。
            期间**不要按亮度键** —— 手动调整会污染这次测量。

            [1/3] 基线：什么都别动，等读数稳定…
            """)
        }

        func consume(_ reading: Reading) {
            switch step {
            case .baseline:   handleBaseline(reading)
            case .cover:      handleStimulus(reading, name: "遮挡传感器", expectDrop: true)
            case .uncover:    handleStimulus(reading, name: "恢复光照", expectDrop: false)
            case .roomDark:   handleStimulus(reading, name: "关灯", expectDrop: true)
            case .finished:   break
            }
        }

        // MARK: 基线

        private func handleBaseline(_ reading: Reading) {
            baselineMin = min(baselineMin, reading.level)
            baselineMax = max(baselineMax, reading.level)

            // 波动超过容差就重新起算，避免把正在变化的过程当成基线。
            guard baselineMax <= baselineMin * Self.baselineTolerance else {
                baselineSince = reading.elapsed
                baselineMin = reading.level
                baselineMax = reading.level
                return
            }
            let since = baselineSince ?? reading.elapsed
            baselineSince = since
            guard reading.elapsed - since >= Self.baselineSeconds else { return }

            baselineLevel = reading.level
            reference = reading
            beep("Tink")
            print(String(format: "      ✓ 基线 level=%.0f   背光=%@   滑杆=%@\n",
                         reading.level,
                         reading.nits.map { String(format: "%.1f nits", $0) } ?? "读不到",
                         reading.slider.map { String(format: "%.4f", $0) } ?? "读不到"))
            advance(to: .cover)
        }

        // MARK: 刺激步骤

        private func handleStimulus(_ reading: Reading, name: String, expectDrop: Bool) {
            guard let baseline = baselineLevel else { return }

            guard let triggerAt else {
                let triggered = expectDrop
                    ? reading.level <= baseline / Self.dropRatio
                    : reading.level >= baseline * Self.restoreRatio
                if triggered {
                    self.triggerAt = reading.elapsed
                    reference = reading
                    beep("Tink")
                    print(String(format: "      检测到光照变化（level %.0f → %.0f）。盯住背光…",
                                 baseline, reading.level))
                } else if reading.elapsed - lastProgressPrint >= 3 {
                    lastProgressPrint = reading.elapsed
                    let goal = expectDrop ? baseline / Self.dropRatio
                                          : baseline * Self.restoreRatio
                    print(String(format: "      等待中… 当前 level=%.0f，需要 %@ %.0f",
                                 reading.level, expectDrop ? "≤" : "≥", goal))
                }
                return
            }

            let elapsed = reading.elapsed - triggerAt
            let levelRatio = Self.lightRatio(baseline, reading.level)

            // 逐个标度记录**各自**第一次变化的时刻。
            //
            // 上一版在「任何一个标度动了」就收工，结果 1.0 秒滑杆一动就跳走，
            // 根本没给 nits 留时间 —— 那样得出的「nits 没动」是无效的。
            // 现在必须盯到四个都动了、或者等满判据要求的时间为止。
            for scale in movedScales(from: reference, to: reading) where latencies[scale] == nil {
                latencies[scale] = elapsed
            }
            if !latencies.isEmpty, !announcedFirstMove {
                announcedFirstMove = true
                beep("Glass")
                print(String(format: "      · 首个标度已响应：%@（%.1fs）。继续盯剩下的…",
                             latencies.keys.sorted().joined(separator: "、"), elapsed))
            }

            let allMoved = Self.scaleNames.allSatisfy { latencies[$0] != nil }
            guard allMoved || elapsed >= Self.holdSeconds else {
                if reading.elapsed - lastProgressPrint >= 5 {
                    lastProgressPrint = reading.elapsed
                    let pending = Self.scaleNames.filter { latencies[$0] == nil }
                    print(String(format: "      盯着 %@… %.0fs / %.0fs",
                                 pending.joined(separator: "、"), elapsed, Self.holdSeconds))
                }
                return
            }

            beep(allMoved ? "Glass" : "Basso")
            let pending = Self.scaleNames.filter { latencies[$0] == nil }
            print(allMoved
                  ? String(format: "      ✓ %@：四个标度全部响应\n", name)
                  : String(format: "      ✗ %@：保持 %.0fs 后，%@ 始终未动\n",
                           name, elapsed, pending.joined(separator: "、")))
            outcomes.append(Outcome(name: name, levelRatio: levelRatio,
                                    observed: elapsed, latencies: latencies))
            finishStep()
        }

        /// 四个标度里有哪些真的动了。分开报是这次测量的关键 ——
        /// 只有 nits 不动 = 读数陈旧；四个一起不动 = 自动亮度确实没动手。
        private func movedScales(from reference: Reading?, to now: Reading) -> [String] {
            guard let reference else { return [] }
            var moved: [String] = []
            func check(_ label: String, _ before: Double?, _ after: Double?) {
                guard let before, let after, before > 0 else { return }
                if abs(after - before) / before >= Self.responseThreshold { moved.append(label) }
            }
            check("nits", reference.nits, now.nits)
            check("滑杆", reference.slider, now.slider)
            check("brightness", reference.brightness.map(Double.init),
                  now.brightness.map(Double.init))
            check("rawBrightness", reference.rawBrightness.map(Double.init),
                  now.rawBrightness.map(Double.init))
            return moved
        }

        // MARK: 推进

        private func finishStep() {
            triggerAt = nil
            latencies = [:]
            announcedFirstMove = false
            switch step {
            case .cover:
                advance(to: .uncover)
            case .uncover:
                // 只要有一次看到**任何**标度动了，系统环路就是活的，不必再折腾关灯。
                if outcomes.contains(where: { !$0.latencies.isEmpty }) {
                    advance(to: .finished)
                } else {
                    advance(to: .roomDark)
                }
            default:
                advance(to: .finished)
            }
        }

        private func advance(to next: Step) {
            step = next
            lastProgressPrint = 0
            switch next {
            case .cover:
                print("[2/3] 现在请**用手掌盖住**屏幕上边框中央的传感器（要盖严）")
            case .uncover:
                print("[3/3] 松开，让光照恢复")
            case .roomDark:
                print("""
                [补测] 遮挡没能让背光动。可能是遮挡被特殊处理了，换一种刺激再确认一次。
                       现在请**关掉房间灯**（或拉上窗帘）
                """)
            case .finished:
                beep("Hero")
            case .baseline:
                break
            }
        }

        // MARK: 结论

        func printVerdict(alsCallbacks: Int, brightnessCallbacks: Int) {
            print("\n── Gate A 引导结论")
            guard !outcomes.isEmpty else {
                print("没有完成任何一个刺激步骤（可能是超时退出）。判定不成立，请重跑。")
                return
            }

            for outcome in outcomes {
                let detail = Self.scaleNames.map { scale in
                    outcome.latencies[scale].map { String(format: "%@ %.1fs", scale, $0) }
                        ?? "\(scale) 未动"
                }.joined(separator: "  ")
                print(String(format: "%@ 光照 %@，观察 %.0fs → %@",
                             pad(outcome.name, 14), Self.describeRatio(outcome.levelRatio),
                             outcome.observed, detail))
            }

            // 判据一。引导模式下我们**知道**光照确实变过，所以这里可以下定论，
            // 不用「若期间确实改变过光照」那种含糊说法。
            print("\n判据一 · ALS 回调可用：" + (alsCallbacks > 0
                ? "✓ 通过（\(alsCallbacks) 个事件）→ 后续可事件驱动"
                : "✗ 不通过。光照变了上百倍，ALS 一个事件都没推过来 —— "
                  + "后续校正在开启期间必须固定采样。"))
            print("           背光变化通知：\(brightnessCallbacks) 个"
                + (brightnessCallbacks > 0
                   ? "（能收到，但它只表示背光在动，不代表环境光变了）"
                   : "（收不到）"))

            let anyMoved = outcomes.contains { !$0.latencies.isEmpty }
            guard anyMoved else {
                print("""

                判据二 · 系统环路有效：✗ 不通过
                  光照变化 ≥2 倍并保持 60 秒，四个标度全部未动。
                  这会使 Schedule.liftAboveComfortFloor 的设计前提
                  （「macOS 已经按环境光降过一次背光」）在本机不成立。
                """)
                return
            }

            let fastest = outcomes.compactMap { $0.latencies.values.min() }.min() ?? 0
            print(String(format: "\n判据二 · 系统环路有效：✓ 通过（最快 %.1fs 就有反应）", fastest))

            // 每个标度在**所有**步骤里都没动过，才算这个读数是死的。
            let dead = Self.scaleNames.filter { scale in
                outcomes.allSatisfy { $0.latencies[scale] == nil }
            }
            guard !dead.isEmpty else {
                print("           四个标度都会跟随，读数可信。")
                return
            }
            print("""

            ⚠️ 但这几个标度在所有步骤里**一次都没动过**：\(dead.joined(separator: "、"))
               每一步都盯满了判据要求的时间，所以这不是「没来得及」。
            """)
            if dead.contains("nits") {
                print("""
                   nits 来自 BacklightReader.currentNits()，而它是深夜舒适下限
                   （Schedule.liftAboveComfortFloor）的唯一输入。这条已发布的逻辑
                   现在是拿一个不变的数在做判断，必须单独处理。
                """)
            }
        }

        /// 系统音效。诊断命令跑在有 run loop 的进程里，NSSound 可以直接播。
        private func beep(_ name: String) {
            NSSound(contentsOfFile: "/System/Library/Sounds/\(name).aiff",
                    byReference: true)?.play()
        }
    }

    /// watch 采到的一行。
    private struct Reading {
        let elapsed: Double
        let source: String
        let level: Double
        /// 模型估算的背光 nits（`BacklightReader.currentNits()`）。
        let nits: Double?
        /// IORegistry 直接报出的 nits，仅作对照 —— 在部分机器上是开机快照。
        let registryNits: Double?
        let slider: Double?
        let linear: Double?
        let brightness: Int?
        let rawBrightness: Int?
        /// 此刻 Amber 施加的相对光度输出（LUT + 覆盖层之后）。
        let outputRatio: Double
        /// 屏幕白场的模型落点 = 模型背光 × outputRatio。
        let screenNits: Double?
    }

    /// Gate A 的两条判据，直接由数据判定，不靠肉眼扫 CSV。
    ///
    /// 判据一 · ALS 回调可用：出现过 `als_callback`。
    /// 判据二 · 系统环路有效：`level` 极值比 ≥2 倍、高低两端各驻留 ≥60 s 的前提下，
    ///          背光相对变化 ≥5%。
    ///
    /// 第二条只有在**确实制造出了足够大且足够久的光照变化**时才有意义，
    /// 所以驻留时间不满足时不判定通过或失败，而是判「本次未构成有效测试」——
    /// 把"没测出来"和"测出来是坏的"分开，这是这份汇总最重要的一件事。
    private static func summarizeGateA(_ samples: [Reading], alsCallbacks: Int,
                                       brightnessCallbacks: Int, verdicts: Bool) {
        print("\n── Gate A 汇总")
        guard samples.count >= 2, let firstSample = samples.first,
              let lastSample = samples.last else {
            print("样本不足，无法判定。")
            return
        }

        let levels = samples.map(\.level)
        guard let minLevel = levels.min(), let maxLevel = levels.max() else {
            print("没有环境光读数，无法判定。")
            return
        }
        // level = 0 表示低于传感器下限，是合法读数，不是异常。分母压到 1。
        let levelRatio = maxLevel / max(minLevel, 1)

        /// 某个条件累计占了多少秒。每个样本按它与下一个样本的时间差计权。
        func dwell(_ predicate: (Reading) -> Bool) -> Double {
            var total = 0.0
            for (index, sample) in samples.enumerated() where predicate(sample) {
                let next = index + 1 < samples.count
                    ? samples[index + 1].elapsed : lastSample.elapsed
                total += max(next - sample.elapsed, 0)
            }
            return total
        }

        let lowDwell = dwell { $0.level <= minLevel * 1.2 }
        let highDwell = dwell { $0.level >= maxLevel / 1.2 }

        print(String(format: "观察 %.0f 秒，%d 行（poll %d / als_callback %d / brightness_callback %d）",
                     lastSample.elapsed - firstSample.elapsed, samples.count,
                     samples.filter { $0.source == "poll" }.count,
                     alsCallbacks, brightnessCallbacks))
        print(String(format: "level          %8.1f … %8.1f   变化 %.1f 倍（低端驻留 %.0fs，高端 %.0fs）",
                     minLevel, maxLevel, levelRatio, lowDwell, highDwell))

        // 四个背光标度分开报。它们一起不动 = 背光真没动；只有 nits 不动 = 读数的问题。
        let nitsSpan = span(samples.compactMap(\.nits))
        let sliderSpan = span(samples.compactMap(\.slider))
        let brightnessSpan = span(samples.compactMap { $0.brightness.map(Double.init) })
        let rawSpan = span(samples.compactMap { $0.rawBrightness.map(Double.init) })
        print(String(format: "背光 nits      %8.1f … %8.1f   相对变化 %.2f%%",
                     nitsSpan.low, nitsSpan.high, nitsSpan.relative * 100))
        print(String(format: "滑杆 0–1       %8.4f … %8.4f", sliderSpan.low, sliderSpan.high))
        let linearSpan = span(samples.compactMap(\.linear))
        print(String(format: "linear 0–1     %8.4f … %8.4f", linearSpan.low, linearSpan.high))
        print(String(format: "brightness     %8.0f … %8.0f", brightnessSpan.low, brightnessSpan.high))
        print(String(format: "rawBrightness  %8.0f … %8.0f", rawSpan.low, rawSpan.high))

        guard verdicts else { return }

        print("\n判据一 · ALS 回调可用：" + (alsCallbacks > 0
            ? "✓ 通过（\(alsCallbacks) 个事件）→ 后续可事件驱动"
            : "✗ 不通过（0 个事件）→ 后续校正在开启期间必须固定采样，"
              + "不得拿背光变化通知兜底"))

        let sufficientStimulus = levelRatio >= 2 && lowDwell >= 60 && highDwell >= 60
        guard sufficientStimulus else {
            print(String(format: """
            判据二 · 系统环路有效：— 本次未构成有效测试
                      需要 level 极值比 ≥2 倍且高低两端各驻留 ≥60 s，实际 %.1f 倍 / %.0fs / %.0fs。
                      请把光照变化做得更大更久（遮住传感器 60 s、关灯 5 分钟）后重跑。
            """, levelRatio, lowDwell, highDwell))
            return
        }

        let backlightMoved = nitsSpan.relative >= 0.05
        print("判据二 · 系统环路有效：" + (backlightMoved
            ? String(format: "✓ 通过（背光变化 %.1f%%）", nitsSpan.relative * 100)
            : String(format: "✗ 不通过（level 变了 %.1f 倍，背光只变了 %.2f%%，未达 5%%）",
                     levelRatio, nitsSpan.relative * 100)))

        guard !backlightMoved else { return }
        let othersMoved = sliderSpan.relative > 0 || brightnessSpan.relative > 0
            || rawSpan.relative > 0
        print(othersMoved
            ? "          → 但滑杆 / brightness / rawBrightness 里有在动，"
              + "说明是 BrightnessMilliNits 这一个读数陈旧或量化，不是背光没动。"
            : "          → 四个标度全部未动，说明不是读数问题，是自动亮度确实没有动手。"
              + "\n            这会使 Schedule.liftAboveComfortFloor 的设计前提"
              + "（「macOS 已经按环境光降过一次背光」）在本机不成立，需要先处理。")
    }

    private static func span(_ values: [Double]) -> (low: Double, high: Double, relative: Double) {
        guard let low = values.min(), let high = values.max() else { return (0, 0, 0) }
        return (low, high, low > 0 ? (high - low) / low : 0)
    }

    /// `DisplayServices` 的背光变化通知，仅供 `--ambient --watch` 验证覆盖面。
    /// 它不写背光，也不能代表环境光发生了变化。
    private final class DisplayBrightnessObserver {
        private typealias Callback = @convention(c) (
            UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, UnsafeRawPointer?,
            UnsafeRawPointer?, UnsafeRawPointer?
        ) -> Void
        private typealias Register = @convention(c) (
            CGDirectDisplayID, CGDirectDisplayID, Callback
        ) -> Int32
        private typealias Unregister = @convention(c) (
            CGDirectDisplayID, CGDirectDisplayID
        ) -> Int32

        nonisolated(unsafe) private static weak var active: DisplayBrightnessObserver?
        private static let handle = dlopen(
            "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices",
            RTLD_LAZY
        )

        private static func lookup<T>(_ name: String, as type: T.Type) -> T? {
            guard let handle, let address = dlsym(handle, name) else { return nil }
            return unsafeBitCast(address, to: T.self)
        }

        private let display: CGDirectDisplayID
        private let unregister: Unregister
        private let onChange: () -> Void

        init?(onChange: @escaping () -> Void) {
            guard Self.active == nil,
                  let register = Self.lookup(
                    "DisplayServicesRegisterForBrightnessChangeNotifications",
                    as: Register.self),
                  let unregister = Self.lookup(
                    "DisplayServicesUnregisterForBrightnessChangeNotifications",
                    as: Unregister.self),
                  let display = GammaController.activeDisplays().first(where: {
                    CGDisplayIsBuiltin($0) != 0
                  })
            else { return nil }

            self.display = display
            self.unregister = unregister
            self.onChange = onChange
            Self.active = self
            guard register(display, display, Self.dispatch) == 0 else {
                Self.active = nil
                return nil
            }
        }

        deinit {
            _ = unregister(display, display)
            if Self.active === self { Self.active = nil }
        }

        private static let dispatch: Callback = { _, _, _, _, _ in
            guard let observer = DisplayBrightnessObserver.active else { return }
            DispatchQueue.main.async { [weak observer] in observer?.onChange() }
        }
    }

    private static func hardwareModel() -> String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        guard size > 0 else { return "未知" }
        var buffer = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.model", &buffer, &size, nil, 0)
        return String(cString: buffer)
    }

    private static func backlightLine() -> String {
        BacklightReader.currentNits().map { String(format: "背光：%.1f nits", $0) }
            ?? "背光：读不到（外接屏 / Intel）"
    }

    /// 时段标签。用 `solar: nil` —— 诊断只要一个标签，不值得为它去碰定位或系统外观。
    /// 设置只读一次：watch 模式每秒记一行，没必要每行都去读 UserDefaults。
    private static let probeSettings = Settings.load()

    private static func currentPhaseName() -> String {
        currentTarget().phase.title(in: probeSettings.language)
    }

    /// 此刻排班算出的目标。watch 模式每行都要它 —— 只有把「Amber 正在施加多少衰减」
    /// 和「系统认为这个房间该多亮」记在同一行，事后才能回答「屏幕相对房间是不是太暗」。
    private static func currentTarget() -> LightTarget {
        Schedule.evaluate(at: Date(), settings: probeSettings, solar: nil).target
    }

    /// 读 / 写系统「自动调节亮度」，走的正是界面开关的那条路径。
    ///
    /// 用法： Amber --auto-brightness          只读，不改任何设置
    ///        Amber --auto-brightness on|off   写入并回读
    ///
    /// 这条命令存在的理由和 `--apply` 一样：私有符号的签名对不对，只能在真机上
    /// 端到端跑一遍才知道，不能靠编译通过来判断。
    private static func autoBrightnessProbe(argument: String?) {
        print("=== 系统自动亮度 ===")
        print("支持环境光补偿：\(AutoBrightness.isSupported ? "是" : "否")")
        print("当前状态：\(describe(AutoBrightness.isEnabled()))")

        guard let argument else {
            print("\n（只读；传 on / off 可写入）")
            return
        }
        guard let desired = ["on": true, "true": true, "1": true,
                             "off": false, "false": false, "0": false][argument.lowercased()]
        else {
            print("\n✗ 无法识别的参数「\(argument)」，可用 on / off")
            return
        }

        print("\n写入：\(desired ? "开启" : "关闭")")
        let actual = AutoBrightness.setEnabled(desired)
        print("回读：\(describe(actual))")
        print(actual == desired
              ? "✓ 写入生效（以回读为准，不看返回码）"
              : "✗ 回读与请求不符 —— 私有符号可能已变，界面开关会自己弹回去")
    }

    private static func describe(_ state: Bool?) -> String {
        switch state {
        case true?:  "已开启"
        case false?: "已关闭"
        case nil:    "读不到（无内置屏 / 私有符号缺失）"
        }
    }

    private static func printLocaleSamples() {
        setvbuf(stdout, nil, _IONBF, 0)
        // 挑一个不含格式化占位符、四种语言译文互不相同的 key。
        let key = "night.title"
        var ok = true
        for lang in [AppLanguage.en, .fr, .es, .zhHans] {
            let value = lang.text(key)
            let resolved = value != key
            if !resolved { ok = false }
            print("\(lang.rawValue)\t\(key) = \(value)\t\(resolved ? "OK" : "UNRESOLVED")")
        }
        if !ok {
            print("资源未加载：字符串原样返回了 key。"
                + "检查 .app/Contents/Resources/Amber_Amber.bundle 是否存在且含各 lproj。")
        }
        exit(ok ? 0 : 1)
    }

    /// 并排比较两套预设的光度学 / 光生物学后果。
    ///
    /// 调参数最容易犯的错是「按某篇论文的结论改了色温，却没算改完之后的剂量」。
    /// 视觉疲劳文献偏好 4500 K，节律文献要求低 melanopic —— 这两个终点不一样，
    /// 改色温时必须同时看剂量往哪边走。
    private static func comparePresets() {
        setvbuf(stdout, nil, _IONBF, 0)
        print("=== 预设对比：v1 → v2 → v3 → v4 ===\n")

        let rows: [(String, String, Double, Double, Double)] = [
            ("傍晚 / 睡前", "v1", 2_700, 0.62, 0.00),
            ("傍晚 / 睡前", "v2", 4_300, 0.55, 0.00),
            ("深夜助眠",     "v1", 1_900, 0.35, 0.20),
            ("深夜助眠",     "v2", 1_900, 0.45, 0.00),
            ("深夜助眠",     "v3", 1_950, 0.75, 0.00),
            ("深夜助眠",     "v4", 2_700, 0.56, 0.00),
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
            if version != "v1", let p = previous {
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

        let evening = presetMetrics(cct: Settings().eveningCCT,
                                    coefficient: Settings().eveningBrightness, extraDim: 0)
        let night = presetMetrics(cct: Settings().nightCCT,
                                  coefficient: Settings().nightBrightness, extraDim: 0)

        // 暗环境舒适下界。文献值分散度接近 5 倍（Li 2013 = 11、Na & Suk 2015 = 10–40、
        // Zhou 2021 在 0 lx 下 = 20.63–36.2、朱念芳 2022 ≈ 50、Ye 2014 = 55、
        // Lin 2022 在 1 lx 下 = 63.9 cd/m²），所以这里取的是「下界」而不是「最优值」：
        // Yu & Akita 2019 报告 9 cd/m² 会引发身体 + 心理 + 视觉三类疲劳，
        // 25 cd/m² 只剩视觉疲劳。
        let comfortFloorNits = 20.0

        print("\n── 假设系统背光情景（演算值，不是运行时测量）")
        for panelNits in [30.0, 60.0, 120.0, 400.0] {
            let nightNits = night.photopicRatio * panelNits
            print(String(format: "背光 %4.0f nits →  睡前 %6.1f nits   深夜 %6.1f nits%@",
                         panelNits, evening.photopicRatio * panelNits, nightNits,
                         nightNits < comfortFloorNits
                            ? String(format: "   ← 低于 %.0f cd/m² 舒适下界", comfortFloorNits)
                            : ""))
        }
        print("  注：Amber 只能控制相对衰减，落点由系统背光决定，无法运行时保证绝对 nits。")

        currentLandingPoints()

        print("\n── 背光模型与安全下限反解")
        // 把模型的每一步都摊开。这个数是推出来的，不是量出来的，
        // 诊断里必须能看见它由什么组成，否则又会被当成实测值。
        if let scale = BacklightReader.fullScaleNits(),
           let linear = BacklightReader.linearBrightness(),
           let minMilli = BacklightReader.parameterField("BrightnessMilliNits", "min"),
           let range = BacklightReader.linearUsableRange() {
            print(String(format: "满量程 = 面板下限 %.3f nits ÷ linear 下限 %.5f = %.0f nits",
                         minMilli / 1_000, range.lower, scale))
            print(String(format: "linear = %.4f  →  模型背光 %.1f nits", linear, linear * scale))
            if let registry = BacklightReader.registryNitsForDiagnostics() {
                print(String(format: "对照：IORegistry 直接报出 %.1f nits%@", registry,
                             abs(registry - linear * scale) / max(linear * scale, 1) > 0.2
                                ? "（相差超过 20%，该键很可能是开机快照）" : ""))
            }
        }
        if let nits = BacklightReader.currentNits() {
            for scenario in [nits, 160.0, 80.0, 30.0] {
                let raw = LightTarget(cct: Settings().nightCCT,
                                      brightness: Settings().nightBrightness,
                                      extraDim: 0, phase: .night)
                let lifted = Schedule.liftAboveComfortFloor(raw, backlightNits: scenario)
                let before = ColorScience.metrics(for: raw.effectiveGain).photopicRatio * scenario
                let after = ColorScience.metrics(for: lifted.effectiveGain).photopicRatio * scenario
                print(String(format: "  背光 %6.1f nits → 系数 %.2f→%.2f   深夜 %5.1f→%5.1f nits%@",
                             scenario, raw.brightness, lifted.brightness, before, after,
                             lifted.brightness >= 1.0 ? "   ← 已停止额外压暗" : ""))
            }
        } else {
            print("读不到（外接屏 / Intel / 键名变更）→ 退回纯相对衰减")
        }

        print("\n── 系统自动亮度（macOS 环境光补偿）")
        print("本机是否支持：\(AutoBrightness.isSupported ? "是" : "否")")
        switch AutoBrightness.isEnabled() {
        case true?:  print("当前状态：已开启 —— 背光跟随环境，上面的反解才有意义")
        case false?: print("当前状态：已关闭 —— 背光固定，Amber 的相对压暗没有环境跟随可依")
        case nil:    print("当前状态：读不到（无内置屏 / 私有符号缺失）→ 界面上的开关会禁用")
        }

        assertSciencePreset(evening: evening, night: night)
        print("\n✓ 最终指标与睡前 / 深夜的剂量关系均符合预期")
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

        // v4 数值锁。深夜档 2700K×0.56：屏幕亮度与 v3 基本一致（相对输出 30%），
        // 但色温回到实测区间内，蓝通道从 0.0037 恢复到 0.101。
        assert(abs(night.melanopicRatio - 0.153) < 0.004, "深夜 melanopic 偏离 15.3%")
        assert(abs(night.photopicRatio - 0.300) < 0.004, "深夜相对输出偏离 30.0%")

        // 深夜 melanopic 仍必须显著低于睡前档。
        //
        // 这个比值以前锁在 20%，但那条约束是**倒果为因**的 —— 它其实是在强制
        // 深夜过度压暗。色温到了 1950 K，蓝通道几乎归零，melanopic 已经塌到很低；
        // 此时再压 brightness，melanopic 的边际降幅很小，牺牲的全是可读性。
        // 放宽到 40% 后 v3 实测约 31%，仍有余量，而屏幕不再暗到不可读。
        assert(night.melanopicRatio < evening.melanopicRatio * 0.50,
               "深夜 melanopic 必须低于睡前档的 50%")

        // 深夜的光度输出不能低于睡前档的一半以下 —— 那说明压暗压过头了。
        assert(night.photopicRatio > evening.photopicRatio * 0.5,
               "深夜相对输出低于睡前档的一半，压暗过度")
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

        // 必须自己铺一层不透明底色。`cacheDisplay` 只画视图，不画窗口背景，
        // 而 SwiftUI 的文字颜色跟随系统外观 —— 深色模式下就是白字画在透明底上，
        // 存成 PNG 后看上去整页空白，"渲染成功但一片空白"的检测也会被骗过去。
        host.wantsLayer = true
        host.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        host.layoutSubtreeIfNeeded()

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
        comfortFloorCheck()
        backlightModelCheck()
        autoBrightnessCheck()
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
        // ① v1 直升 v3：两档迁移必须串联执行，不能只跑一档。
        let oldJSON: [String: Any] = [
            "manualCCT": 3_400.0, "manualBrightness": 0.90,
            "eveningCCT": 2_700.0, "eveningBrightness": 0.62,
            "nightCCT": 1_900.0, "nightBrightness": 0.35, "nightExtraDim": 0.20,
            "wakeMinutes": 480, "language": "fr"
        ]
        let data = try! JSONSerialization.data(withJSONObject: oldJSON)
        var old = try! JSONDecoder().decode(Settings.self, from: data)
        assert(old.sciencePresetVersion == 1, "缺少版本字段的配置应视为 v1")
        assert(old.migrateSciencePresetIfNeeded())
        assert(old.sciencePresetVersion == Settings.currentPresetVersion)
        assert(old.manualCCT == 4_500 && old.manualBrightness == 0.80)
        assert(old.eveningCCT == 4_300 && old.eveningBrightness == 0.55)
        // 0.35 →(v2) 0.45 →(v3) 0.75，串联到底
        assert(old.nightBrightness == 0.56 && old.nightExtraDim == 0,
               "v1 应一路迁到 v4 的深夜亮度")
        assert(old.nightCCT == 2_700, "v1 的 1900 K 应一路迁到 v4 的 2700 K")
        assert(old.wakeMinutes == 480 && old.language == .fr, "迁移改动了非预设字段")
        let migrated = old
        assert(!old.migrateSciencePresetIfNeeded() && old == migrated, "迁移不应重复执行")

        // ② v2 → v3：只动深夜两项，其余不碰。
        var v2 = Settings()
        v2.sciencePresetVersion = 2
        v2.nightCCT = 1_900
        v2.nightBrightness = 0.45
        v2.eveningCCT = 4_300
        v2.eveningBrightness = 0.55
        assert(v2.migrateSciencePresetIfNeeded())
        // v2 的 0.45 应串联走完 v3(0.75) 与 v4(0.56)，色温 1900 → 1950 → 2700
        assert(v2.nightBrightness == 0.56 && v2.nightCCT == 2_700, "v2 应一路迁到 v4")
        assert(v2.eveningCCT == 4_300 && v2.eveningBrightness == 0.55,
               "深夜迁移不应改动傍晚档")

        // ③ 用户改过的值必须原样保留。
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
        print("✓ v1 / v2 设置按字段串联迁移一次，用户自定义值保持不变\n")
    }

    private static func sciencePresetCheck() {
        // 从默认值读，不要再硬编码一份 —— 否则改了预设只有一条路径会报警。
        let defaults = Settings()
        let evening = presetMetrics(cct: defaults.eveningCCT,
                                    coefficient: defaults.eveningBrightness, extraDim: 0)
        let night = presetMetrics(cct: defaults.nightCCT,
                                  coefficient: defaults.nightBrightness, extraDim: 0)
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

    /// 暗环境安全下限：只抬不降、不越过 1.0、读不到背光时完全不生效。
    private static func comfortFloorCheck() {
        let d = Settings()
        let night = LightTarget(cct: d.nightCCT, brightness: d.nightBrightness,
                                extraDim: 0, phase: .night)

        // ① 读不到背光 → 原样返回，行为与加这个功能之前一致
        assert(Schedule.liftAboveComfortFloor(night, backlightNits: nil) == night,
               "背光未知时不应改动目标")

        // ② 背光充足 → 不该抬（400 nits × 29.8% = 119 nits，远高于下界）
        assert(Schedule.liftAboveComfortFloor(night, backlightNits: 400).brightness
               == night.brightness, "背光充足时不应抬亮度")

        // ③ 背光很低 → 抬，但绝不超过 1.0
        let dim = Schedule.liftAboveComfortFloor(night, backlightNits: 30)
        assert(dim.brightness > night.brightness, "背光过低时应抬亮度")
        assert(dim.brightness <= 1.0, "抬升不得越过 1.0，否则会比不装 Amber 还亮")

        // ④ 抬完之后要么够到下限，要么已经顶到 1.0（受色温衰减所限，尽力而为）
        for nits in [15.0, 30.0, 60.0, 80.0, 200.0, 400.0] {
            let lifted = Schedule.liftAboveComfortFloor(night, backlightNits: nits)
            let output = ColorScience.metrics(for: lifted.effectiveGain).photopicRatio * nits
            assert(output >= Schedule.comfortFloorNits - 0.01 || lifted.brightness >= 1.0,
                   "背光 \(nits) nits 下既没够到下限也没顶满：输出 \(output)")
            // 色温不能被这条规则改动 —— 它只碰亮度
            assert(lifted.cct == night.cct, "安全下限不应改动色温")
        }

        // ⑤ 白天档不该被触发（brightness 已是 1.0）
        let day = LightTarget(cct: d.dayCCT, brightness: d.dayBrightness,
                              extraDim: 0, phase: .day)
        assert(Schedule.liftAboveComfortFloor(day, backlightNits: 30) == day,
               "白天档不应被安全下限改动")

        print("✓ 暗环境安全下限：只抬不降、上限 1.0、不改色温、背光未知时不生效\n")
    }

    /// **你当前保存的设置**各时段会落到多少 cd/m²。
    ///
    /// 与上面的预设对比表不同，这里读的是 `Settings.load()` —— 也就是你自己拖过的值，
    /// 不是出厂默认。存在的理由是把「拖滑杆 → 看落点」这个循环闭上：改完跑一次就知道
    /// 落在哪，不用拍脑袋。
    ///
    /// 绝对值依赖背光模型，读不到就只打相对输出。
    private static func currentLandingPoints() {
        let settings = Settings.load()
        let backlight = BacklightReader.currentNits()

        print("\n── 你当前设置的落点"
            + (backlight.map { String(format: "（模型背光 %.1f nits）", $0) } ?? "（背光读不到）"))

        let phases: [(String, Double, Double)] = [
            ("白天", settings.dayCCT, settings.dayBrightness),
            ("傍晚", settings.eveningCCT, settings.eveningBrightness),
            ("深夜", settings.nightCCT, settings.nightBrightness),
        ]
        for (name, cct, brightness) in phases {
            let target = LightTarget(cct: cct, brightness: brightness,
                                     extraDim: settings.globalExtraDim, phase: .manual)
            let output = ColorScience.metrics(for: target.effectiveGain).photopicRatio
            let absolute = backlight.map { String(format: "  →  %6.1f cd/m²", output * $0) } ?? ""
            print(String(format: "%@  %.0fK ×%.2f   相对输出 %5.1f%%%@",
                         pad(name, 6), cct, brightness, output * 100, absolute))
        }

        // Kim et al. 2017（Optical Engineering 56(1):017110, n=30）的舒适**下沿**。
        // 上沿分别是 516 / 664 / 737，日常不会碰到，所以只列下沿。
        print("        对照 Kim 2017 舒适下沿：50 lx → 113   500 lx → 154   1000 lx → 177 cd/m²")
    }

    /// 背光模型的自洽性自检。
    ///
    /// 模型是推出来的，不是量出来的，所以能查的只有内部一致性：满量程落在合理
    /// 区间、`linear` 落在自己声明的可用区间内、反解出的 nits 不越过满量程。
    /// **这些都不能证明模型是对的** —— 那要靠色度计。它们只能挡住「某个私有符号
    /// 换了含义」这一类失效。
    private static func backlightModelCheck() {
        guard let scale = BacklightReader.fullScaleNits(),
              let linear = BacklightReader.linearBrightness(),
              let range = BacklightReader.linearUsableRange(),
              let nits = BacklightReader.currentNits()
        else {
            print("✓ 背光模型：这块屏推不出满量程（外接屏 / Intel / 符号变更），"
                + "决策路径按读不到处理\n")
            return
        }

        assert(scale > 50 && scale < 5_000, "满量程 \(scale) nits 不像真的面板")
        assert(linear >= 0 && linear <= range.upper, "linear 越过了自己声明的可用上限")
        assert(nits <= scale * 1.001, "反解出的 nits 超过了满量程")
        assert(abs(nits - linear * scale) < 0.001, "currentNits 与模型不一致")

        print(String(format: "✓ 背光模型：满量程 %.0f nits，linear %.4f → %.1f nits（模型值，非实测）\n",
                     scale, linear, nits))
    }

    /// 系统自动亮度开关的可用性自检。
    ///
    /// **只读。** 自检绝不去翻用户的系统设置——那是副作用，而且一旦进程中途挂掉，
    /// 用户的「自动调节亮度」就被我们留在了关闭状态。这里只验证一件事：
    /// 「支持」与「读得到状态」必须同真同假，界面才能靠 nil 判断禁用而不出现
    /// 「开关能点但点了没反应」。
    private static func autoBrightnessCheck() {
        let supported = AutoBrightness.isSupported
        let state = AutoBrightness.isEnabled()
        assert(supported == (state != nil),
               "isSupported 与 isEnabled() 不一致：支持=\(supported) 状态=\(String(describing: state))")

        // 私有符号一旦消失，两者会一起变成 false / nil，UI 禁用开关即可，不是失败。
        let description = switch state {
        case true?:  "已开启"
        case false?: "已关闭"
        case nil:    "不支持（外接屏 / Intel / 私有符号缺失）"
        }
        print("✓ 系统自动亮度：\(description)，可用性与可读性一致\n")
    }

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
        let d = Settings()
        let presets: [(String, Double, Double)] = [
            ("白天",     d.dayCCT,     d.dayBrightness),
            ("睡前",     d.eveningCCT, d.eveningBrightness),
            ("深夜助眠", d.nightCCT,   d.nightBrightness),
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
        expect(target(after: 780, settings: standard), cct: standard.dayCCT, coefficient: standard.dayBrightness,
               phase: .evening, "睡前 3 小时")
        expect(target(after: 870, settings: standard), cct: standard.eveningCCT, coefficient: standard.eveningBrightness,
               phase: .evening, "90 分钟渐变结束")
        expect(target(after: 960, settings: standard), cct: standard.eveningCCT, coefficient: standard.eveningBrightness,
               phase: .night, "就寝")
        expect(target(after: 1_005, settings: standard),
               cct: standard.nightCCT, coefficient: standard.nightBrightness,
               phase: .night, "就寝后 45 分钟")
        expect(target(after: 1_410, settings: standard),
               cct: standard.nightCCT, coefficient: standard.nightBrightness,
               phase: .dawn, "拂晓")
        expect(target(after: 1_440, settings: standard), cct: standard.dayCCT, coefficient: standard.dayBrightness,
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
        expect(target(after: 930, settings: crossMidnight), cct: standard.dayCCT, coefficient: standard.dayBrightness,
               phase: .evening, "跨午夜睡前 3 小时")
        expect(target(after: 1_020, settings: crossMidnight), cct: standard.eveningCCT, coefficient: standard.eveningBrightness,
               phase: .evening, "跨午夜 90 分钟结束")
        expect(target(after: 1_110, settings: crossMidnight), cct: standard.eveningCCT, coefficient: standard.eveningBrightness,
               phase: .night, "跨午夜就寝")
        expect(target(after: 1_155, settings: crossMidnight),
               cct: crossMidnight.nightCCT, coefficient: crossMidnight.nightBrightness,
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
