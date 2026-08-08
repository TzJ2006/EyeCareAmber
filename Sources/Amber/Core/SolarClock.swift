import Foundation

/// 日出 / 日落 / 民用暮光计算（NOAA Solar Calculator 算法）。
///
/// 纯数学，不用 CoreLocation：不申请定位权限、不唤醒 GPS/WiFi 定位、零后台功耗。
/// 用户在设置里填一次经纬度就行（精度到 0.1° 完全够用，误差 < 1 分钟）。
enum SolarClock {

    struct Events {
        var sunrise: Date
        var sunset: Date
        /// 民用暮光结束（太阳低于地平线 6°）—— 天真正黑下来的时刻。
        var duskEnd: Date
    }

    /// 太阳中心天顶角：官方日出日落用 90.833°（含大气折射 + 太阳视半径）。
    private static let sunriseZenith = 90.833
    /// 民用暮光天顶角。
    private static let civilZenith = 96.0

    static func events(on date: Date, latitude: Double, longitude: Double,
                       calendar: Calendar = .current) -> Events? {
        let comps = calendar.dateComponents([.year, .month, .day], from: date)
        guard let year = comps.year, let month = comps.month, let day = comps.day,
              let midnight = calendar.startOfDay(for: date) as Date?
        else { return nil }

        let jd = julianDay(year: year, month: month, day: day)
        let t = (jd - 2_451_545.0) / 36_525.0

        let meanLong = normalizeDegrees(280.46646 + t * (36_000.76983 + t * 0.0003032))
        let meanAnom = 357.52911 + t * (35_999.05029 - 0.0001537 * t)
        let eccentricity = 0.016708634 - t * (0.000042037 + 0.0000001267 * t)

        let m = radians(meanAnom)
        let center = sin(m) * (1.914602 - t * (0.004817 + 0.000014 * t))
                   + sin(2 * m) * (0.019993 - 0.000101 * t)
                   + sin(3 * m) * 0.000289

        let trueLong = meanLong + center
        let omega = radians(125.04 - 1_934.136 * t)
        let apparentLong = radians(trueLong - 0.00569 - 0.00478 * sin(omega))

        let obliquitySeconds: Double = 21.448 - t * (46.815 + t * (0.00059 - t * 0.001813))
        let meanObliquity: Double = 23.0 + (26.0 + obliquitySeconds / 60.0) / 60.0
        let obliquity = radians(meanObliquity + 0.00256 * cos(omega))

        let declination = asin(sin(obliquity) * sin(apparentLong))

        // 时差（真太阳时 − 平太阳时），分钟
        let y = pow(tan(obliquity / 2), 2)
        let l0 = radians(meanLong)
        let eqTime = 4 * degrees(
            y * sin(2 * l0)
          - 2 * eccentricity * sin(m)
          + 4 * eccentricity * y * sin(m) * cos(2 * l0)
          - 0.5 * y * y * sin(4 * l0)
          - 1.25 * eccentricity * eccentricity * sin(2 * m)
        )

        let tzMinutes = Double(calendar.timeZone.secondsFromGMT(for: date)) / 60
        let solarNoon = 720 - 4 * longitude - eqTime + tzMinutes  // 本地时间的分钟数

        func hourAngle(zenith: Double) -> Double? {
            let latRad = radians(latitude)
            let cosH = (cos(radians(zenith)) - sin(latRad) * sin(declination))
                     / (cos(latRad) * cos(declination))
            guard cosH >= -1, cosH <= 1 else { return nil }  // 极昼 / 极夜
            return degrees(acos(cosH))
        }

        guard let h = hourAngle(zenith: sunriseZenith) else { return nil }
        let hCivil = hourAngle(zenith: civilZenith) ?? h

        func instant(minutesAfterMidnight m: Double) -> Date {
            midnight.addingTimeInterval(m * 60)
        }

        return Events(
            sunrise: instant(minutesAfterMidnight: solarNoon - 4 * h),
            sunset:  instant(minutesAfterMidnight: solarNoon + 4 * h),
            duskEnd: instant(minutesAfterMidnight: solarNoon + 4 * hCivil)
        )
    }

    // MARK: - 工具

    private static func julianDay(year: Int, month: Int, day: Int) -> Double {
        var y = year, m = month
        if m <= 2 { y -= 1; m += 12 }
        let a = floor(Double(y) / 100)
        let b = 2 - a + floor(a / 4)
        return floor(365.25 * Double(y + 4_716))
             + floor(30.6001 * Double(m + 1))
             + Double(day) + b - 1_524.5
    }

    private static func radians(_ d: Double) -> Double { d * .pi / 180 }
    private static func degrees(_ r: Double) -> Double { r * 180 / .pi }
    private static func normalizeDegrees(_ d: Double) -> Double {
        let x = d.truncatingRemainder(dividingBy: 360)
        return x < 0 ? x + 360 : x
    }
}
