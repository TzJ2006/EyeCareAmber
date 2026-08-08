import CoreLocation
import Foundation

enum SolarSource: String, Codable, CaseIterable {
    /// 不用日照信息，纯按作息时间。
    case off
    /// 蹭 macOS「自动」外观切换 —— 系统换深色的那一刻就是当地日落。
    /// 零权限、零功耗，不需要知道你在哪。
    case systemAppearance
    /// 用 CoreLocation 取一次坐标缓存起来，之后全本地算。精度最好。
    case location
    /// 手填经纬度。
    case manual

    func title(in language: AppLanguage) -> String {
        switch self {
        case .off:              return language.text("solar.off")
        case .systemAppearance: return language.text("solar.systemAppearance")
        case .location:         return language.text("solar.location")
        case .manual:           return language.text("solar.manual")
        }
    }

    func explanation(in language: AppLanguage) -> String {
        switch self {
        case .off:
            return language.text("solar.off.explanation")
        case .systemAppearance:
            return language.text("solar.systemAppearance.explanation")
        case .location:
            return language.text("solar.location.explanation")
        case .manual:
            return language.text("solar.manual.explanation")
        }
    }
}

/// 提供某一天的日出 / 日落时刻。
///
/// 三条路径都收敛到同一个出口 `events(on:)`，`Schedule` 完全不需要知道数据从哪来。
final class SolarProvider: NSObject, CLLocationManagerDelegate {

    /// 从系统外观切换学到的日出 / 日落（当地时间的分钟数）。
    private var learnedSunriseMinutes: Int? {
        didSet { persistLearned() }
    }
    private var learnedSunsetMinutes: Int? {
        didSet { persistLearned() }
    }

    private var manager: CLLocationManager?
    private var onCoordinate: ((CLLocationCoordinate2D?) -> Void)?
    private var lastAppearanceIsDark: Bool?

    /// 外观翻转发生时的回调，让引擎立刻重算一次。
    var onSolarInfoChanged: (() -> Void)?

    override init() {
        super.init()
        loadLearned()
        lastAppearanceIsDark = Self.systemIsDark
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(appearanceChanged),
            name: Notification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil
        )
    }

    deinit {
        DistributedNotificationCenter.default().removeObserver(self)
    }

    // MARK: - 出口

    func events(on date: Date, settings: Settings, calendar: Calendar = .current)
        -> SolarClock.Events? {
        switch settings.solarSource {
        case .off:
            return nil

        case .systemAppearance:
            guard let riseM = learnedSunriseMinutes, let setM = learnedSunsetMinutes,
                  let midnight = calendar.startOfDay(for: date) as Date?
            else { return nil }
            let sunrise = midnight.addingTimeInterval(Double(riseM) * 60)
            let sunset = midnight.addingTimeInterval(Double(setM) * 60)
            return SolarClock.Events(sunrise: sunrise,
                                     sunset: sunset,
                                     duskEnd: sunset.addingTimeInterval(30 * 60))

        case .location, .manual:
            guard let lat = settings.latitude, let lon = settings.longitude else { return nil }
            return SolarClock.events(on: date, latitude: lat, longitude: lon, calendar: calendar)
        }
    }

    /// 系统外观是否设为「自动」。不是的话，`.systemAppearance` 收不到任何信号。
    static var systemAppearanceIsAuto: Bool {
        UserDefaults.standard.bool(forKey: "AppleInterfaceStyleSwitchesAutomatically")
    }

    static var systemIsDark: Bool {
        UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark"
    }

    /// 已经学到过日落时刻了吗（用于 UI 提示「还在等今天的第一次切换」）。
    var hasLearnedSchedule: Bool {
        learnedSunriseMinutes != nil && learnedSunsetMinutes != nil
    }

    func learnedDescription(in language: AppLanguage) -> String? {
        guard let r = learnedSunriseMinutes, let s = learnedSunsetMinutes else { return nil }
        return language.format("solar.learnedTimes",
                               Settings.format(minutes: r), Settings.format(minutes: s))
    }

    // MARK: - 系统外观监听

    @objc private func appearanceChanged() {
        let isDark = Self.systemIsDark
        defer { lastAppearanceIsDark = isDark }

        // 只在「自动」模式下，翻转才代表日出 / 日落。手动切深浅色不算。
        guard Self.systemAppearanceIsAuto, lastAppearanceIsDark != isDark else { return }

        let now = Date()
        let cal = Calendar.current
        let minutes = cal.component(.hour, from: now) * 60 + cal.component(.minute, from: now)

        // 防呆：系统的自动切换不会在正午或凌晨发生，出现异常值就忽略。
        if isDark {
            guard (14 * 60)...(23 * 60 + 30) ~= minutes else { return }
            learnedSunsetMinutes = minutes
        } else {
            guard (3 * 60)...(11 * 60) ~= minutes else { return }
            learnedSunriseMinutes = minutes
        }
        onSolarInfoChanged?()
    }

    private func loadLearned() {
        let d = UserDefaults.standard
        if d.object(forKey: Keys.sunrise) != nil {
            learnedSunriseMinutes = d.integer(forKey: Keys.sunrise)
        }
        if d.object(forKey: Keys.sunset) != nil {
            learnedSunsetMinutes = d.integer(forKey: Keys.sunset)
        }
    }

    private func persistLearned() {
        let d = UserDefaults.standard
        if let r = learnedSunriseMinutes { d.set(r, forKey: Keys.sunrise) }
        if let s = learnedSunsetMinutes { d.set(s, forKey: Keys.sunset) }
    }

    private enum Keys {
        static let sunrise = "com.amber.learnedSunrise"
        static let sunset = "com.amber.learnedSunset"
    }

    // MARK: - CoreLocation（一次性）

    private(set) var locationState: LocationState = .idle

    enum LocationState: Equatable {
        case idle
        case requesting
        case denied
        case failed(String)
        case resolved
    }

    /// 请求一次坐标。拿到就立刻停掉 location manager —— 不做持续定位，不耗电。
    func requestCoordinateOnce(completion: @escaping (CLLocationCoordinate2D?) -> Void) {
        let m = manager ?? CLLocationManager()
        manager = m
        m.delegate = self
        m.desiredAccuracy = kCLLocationAccuracyKilometer  // 城市级精度足够
        onCoordinate = { [weak self] coord in
            self?.tearDownLocationManager()
            completion(coord)
        }
        locationState = .requesting

        switch m.authorizationStatus {
        case .notDetermined:
            m.requestWhenInUseAuthorization()   // 授权结果走 delegate
        case .denied, .restricted:
            locationState = .denied
            onCoordinate = nil
            tearDownLocationManager()
            completion(nil)
        default:
            m.requestLocation()
        }
    }

    private func tearDownLocationManager() {
        manager?.stopUpdatingLocation()
        manager?.delegate = nil
        manager = nil
        onCoordinate = nil
    }

    func locationManagerDidChangeAuthorization(_ m: CLLocationManager) {
        switch m.authorizationStatus {
        case .notDetermined:
            break
        case .denied, .restricted:
            locationState = .denied
            let cb = onCoordinate
            tearDownLocationManager()
            cb?(nil)
        default:
            guard locationState == .requesting else { return }
            m.requestLocation()
        }
    }

    func locationManager(_ m: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let coord = locations.last?.coordinate else { return }
        locationState = .resolved
        onCoordinate?(coord)
    }

    func locationManager(_ m: CLLocationManager, didFailWithError error: Error) {
        locationState = .failed(error.localizedDescription)
        let cb = onCoordinate
        tearDownLocationManager()
        cb?(nil)
    }
}
