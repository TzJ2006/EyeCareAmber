import Foundation

/// 屏幕三通道线性增益（0…1）。只能衰减，不能增强 —— 显示器已经在满输出了。
struct RGBGain: Equatable {
    var r: Double
    var g: Double
    var b: Double

    static let identity = RGBGain(r: 1, g: 1, b: 1)

    func scaled(by k: Double) -> RGBGain {
        RGBGain(r: r * k, g: g * k, b: b * k)
    }
}

/// 色度学与光生物学计算。
///
/// 全部是纯函数，没有副作用，也不碰任何系统 API —— 方便单独验证。
///
/// 参考：
/// - CIE 1931 2° 色匹配函数：Wyman, Sloan & Shirley (2013), JCGT 2(2)，多峰高斯拟合，误差 < 1%。
/// - 普朗克轨迹：Kim et al. (1996) 三次近似，适用 1667 K – 25000 K。
/// - 黑视素作用光谱：Govardovskii et al. (2000) A1 视色素模板，λmax = 490 nm，
///   用于近似 CIE S 026:2018 的 s_mel(λ)（经晶状体前滤过后在视网膜上的有效峰值约 490 nm）。
enum ColorScience {

    // MARK: - 光谱基础函数

    /// 分段高斯，Wyman 等人用来拟合色匹配函数的基元。
    @inline(__always)
    private static func lobe(_ x: Double, _ mu: Double, _ sigmaLeft: Double, _ sigmaRight: Double) -> Double {
        let t = (x - mu) / (x < mu ? sigmaLeft : sigmaRight)
        return exp(-0.5 * t * t)
    }

    /// CIE 1931 2° 明视觉光效函数 V(λ) = ȳ(λ)。
    static func photopic(_ nm: Double) -> Double {
        0.821 * lobe(nm, 568.8, 46.9, 40.5)
      + 0.286 * lobe(nm, 530.9, 16.3, 31.1)
    }

    /// 黑视素（melanopsin / ipRGC）相对光谱敏感度，峰值归一化到 1。
    ///
    /// ipRGC 是褪黑素抑制与昼夜节律相位偏移的主要输入通道，峰值敏感度在蓝光区，
    /// 这正是「夜间把屏幕调暖」有生理依据的原因。
    static func melanopic(_ nm: Double) -> Double {
        govardovskii(nm, lambdaMax: 490) / govardovskiiPeak
    }

    private static let govardovskiiPeak = govardovskii(490, lambdaMax: 490)

    private static func govardovskii(_ nm: Double, lambdaMax: Double) -> Double {
        let x = lambdaMax / nm
        // α 带
        let a = 0.8795 + 0.0459 * exp(-pow(lambdaMax - 300, 2) / 11_940)
        let alpha = 1 / (exp(69.7 * (a - x))
                       + exp(28.0 * (0.922 - x))
                       + exp(-14.9 * (1.104 - x))
                       + 0.674)
        // β 带
        let betaPeak = 189 + 0.315 * lambdaMax
        let betaWidth = -40.5 + 0.195 * lambdaMax
        let beta = 0.26 * exp(-pow((nm - betaPeak) / betaWidth, 2))
        return alpha + beta
    }

    // MARK: - 色温 → 通道增益

    /// 给定目标相关色温，算出相对于显示器原生白点（D65 ≈ 6504 K）的线性光增益。
    ///
    /// 归一化到最大通道 = 1，因为 LUT 只能衰减。所以「调暖」必然同时降低整体亮度 ——
    /// 这是好事：Nagare et al. (2019) 发现只改色温、不降亮度，对褪黑素抑制几乎没有帮助。
    static func gain(forCCT kelvin: Double) -> RGBGain {
        let target = linearRGB(fromPlanckian: kelvin.clamped(to: 1_600...25_000))
        let reference = linearRGB(fromPlanckian: 6_504)

        var r = target.r / reference.r
        var g = target.g / reference.g
        var b = target.b / reference.b

        let peak = max(r, max(g, b))
        guard peak > 0 else { return .identity }
        r /= peak; g /= peak; b /= peak

        return RGBGain(r: max(0, min(1, r)), g: max(0, min(1, g)), b: max(0, min(1, b)))
    }

    /// 普朗克黑体在给定色温下的线性 sRGB（未归一化，Y = 1）。
    private static func linearRGB(fromPlanckian kelvin: Double) -> RGBGain {
        let t = kelvin
        let t2 = t * t
        let t3 = t2 * t

        // Kim et al. (1996) 普朗克轨迹三次近似
        let x: Double
        if t <= 4_000 {
            x = -0.2661239e9 / t3 - 0.2343589e6 / t2 + 0.8776956e3 / t + 0.179910
        } else {
            x = -3.0258469e9 / t3 + 2.1070379e6 / t2 + 0.2226347e3 / t + 0.240390
        }
        let x2 = x * x
        let x3 = x2 * x

        let y: Double
        if t <= 2_222 {
            y = -1.1063814 * x3 - 1.34811020 * x2 + 2.18555832 * x - 0.20219683
        } else if t <= 4_000 {
            y = -0.9549476 * x3 - 1.37418593 * x2 + 2.09137015 * x - 0.16748867
        } else {
            y =  3.0817580 * x3 - 5.87338670 * x2 + 3.75112997 * x - 0.37001483
        }

        guard y > 1e-6 else { return .identity }

        // xyY (Y = 1) → XYZ → 线性 sRGB (D65)
        let bigX = x / y
        let bigY = 1.0
        let bigZ = (1 - x - y) / y

        return RGBGain(
            r:  3.2404542 * bigX - 1.5371385 * bigY - 0.4985314 * bigZ,
            g: -0.9692660 * bigX + 1.8760108 * bigY + 0.0415560 * bigZ,
            b:  0.0556434 * bigX - 0.2040259 * bigY + 1.0572252 * bigZ
        )
    }

    // MARK: - 显示器光谱模型与 melanopic 指标

    /// 典型 LED 背光 sRGB 显示器的三基色高斯近似。
    ///
    /// 注意：这是**模型估计**，不是对你这块屏幕的实测。绝对 melanopic DER 会随面板
    /// （LCD / OLED / 量子点）而变，但我们只报告「相对原生白点的变化比例」，
    /// 模型误差在取比值时大部分抵消。
    private struct Primary {
        let peak: Double       // nm
        let sigma: Double      // nm
        let luminanceShare: Double  // sRGB 亮度系数
    }

    /// 谱宽取的是「蓝 LED + 荧光粉 + 彩色滤光片」透过后的实际宽度，不是裸 LED 的窄峰。
    /// 用这组参数时原生白点的 melanopic DER 约 1.0，与已发表的笔记本 / 手机屏
    /// 实测区间（约 0.9–1.1）吻合。
    private static let primaries = [
        Primary(peak: 618, sigma: 35, luminanceShare: 0.2126),
        Primary(peak: 538, sigma: 45, luminanceShare: 0.7152),
        Primary(peak: 455, sigma: 28, luminanceShare: 0.0722),
    ]

    /// 每个基色的 melanopic / photopic 效能比。懒加载，进程内只算一次。
    private static let melanopicEfficacy: [Double] = primaries.map { primary in
        var mel = 0.0
        var pho = 0.0
        var nm = 380.0
        while nm <= 780.0 {
            let s = exp(-0.5 * pow((nm - primary.peak) / primary.sigma, 2))
            mel += s * melanopic(nm)
            pho += s * photopic(nm)
            nm += 2.0
        }
        return pho > 0 ? mel / pho : 0
    }

    /// 原生白点（增益全 1）下的 melanopic 输出，作为归一化基准。
    private static let whiteMelanopic: Double = zip(primaries, melanopicEfficacy)
        .reduce(0) { $0 + $1.0.luminanceShare * $1.1 }

    /// 一组增益下，屏幕相对原生白点的光度学 / 光生物学输出。
    struct Metrics {
        /// 明视觉亮度（人眼感到的「亮」），相对原生白点满亮度。0…1
        var photopicRatio: Double
        /// melanopic（褪黑素通道）输出，相对原生白点满亮度。0…1
        /// 这才是决定「会不会压制褪黑素、推迟入睡」的量。
        var melanopicRatio: Double
        /// 蓝色通道衰减比例。这个数是精确的 —— 我们直接控制 LUT。
        var blueAttenuation: Double
        /// melanopic 日光效能比：每一份「亮度」里带多少「昼夜节律刺激」。
        /// 越低说明同样看得清、对生物钟干扰越小。
        var melanopicDER: Double
    }

    static func metrics(for gain: RGBGain) -> Metrics {
        let shares = primaries.map(\.luminanceShare)
        let g = [gain.r, gain.g, gain.b]

        var photopic = 0.0
        var melanopic = 0.0
        for i in 0..<3 {
            photopic += g[i] * shares[i]
            melanopic += g[i] * shares[i] * melanopicEfficacy[i]
        }

        return Metrics(
            photopicRatio: photopic,
            melanopicRatio: whiteMelanopic > 0 ? melanopic / whiteMelanopic : 0,
            blueAttenuation: 1 - gain.b,
            melanopicDER: photopic > 0 ? (melanopic / photopic) : 0
        )
    }
}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}

extension Double {
    /// 平滑插值，避免色温跳变时肉眼可见的「一跳」。
    static func smoothstep(_ edge0: Double, _ edge1: Double, _ x: Double) -> Double {
        guard edge1 > edge0 else { return x < edge0 ? 0 : 1 }
        let t = ((x - edge0) / (edge1 - edge0)).clamped(to: 0...1)
        return t * t * (3 - 2 * t)
    }

    /// 在 Mired（倒数色温）空间插值 —— 这才符合人眼对色温变化的感知线性。
    static func lerpCCT(_ from: Double, _ to: Double, _ t: Double) -> Double {
        let m0 = 1_000_000 / from
        let m1 = 1_000_000 / to
        return 1_000_000 / (m0 + (m1 - m0) * t.clamped(to: 0...1))
    }
}
