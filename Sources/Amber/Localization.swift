import Foundation

enum AppLanguage: String, CaseIterable, Codable {
    case system, en, fr, es, zhHans

    private static let resourceBundle: Bundle = {
        if let url = Bundle.main.url(forResource: "Amber_Amber", withExtension: "bundle"),
           let bundle = Bundle(url: url) {
            return bundle
        }
        return .module
    }()

    /// 必须匹配**构建产物**里的 lproj 目录名，不是源码里的。
    ///
    /// 源码目录是 `Resources/zh-Hans.lproj`，但 SwiftPM 打进
    /// `Amber_Amber.bundle` 时会把名字转成小写 `zh-hans.lproj`。
    /// `Bundle.path(forResource:ofType:)` 按精确字符串匹配它缓存的资源表，
    /// 即使卷本身大小写不敏感，传 `"zh-Hans"` 也会返回 nil，
    /// 界面会静默退化成原始 key。所以这里必须是小写的 `zh-hans`。
    ///
    /// `Scripts/check-localization.py` 会对着构建产物核对这一点。
    private var localizationCode: String {
        if self != .system {
            return self == .zhHans ? "zh-hans" : rawValue
        }
        let preferred = Locale.preferredLanguages.first?.lowercased() ?? "en"
        if preferred.hasPrefix("zh") { return "zh-hans" }
        if preferred.hasPrefix("fr") { return "fr" }
        if preferred.hasPrefix("es") { return "es" }
        return "en"
    }

    var locale: Locale { Locale(identifier: localizationCode) }

    func title(in currentLanguage: AppLanguage) -> String {
        switch self {
        case .system: return currentLanguage.text("language.system")
        case .en:     return "English"
        case .fr:     return "Français"
        case .es:     return "Español"
        case .zhHans: return "简体中文"
        }
    }

    func text(_ key: String) -> String {
        guard let path = Self.resourceBundle.path(forResource: localizationCode, ofType: "lproj"),
              let bundle = Bundle(path: path)
        else { return key }
        return bundle.localizedString(forKey: key, value: key, table: "Localizable")
    }

    func format(_ key: String, _ arguments: CVarArg...) -> String {
        format(key, arguments: arguments)
    }

    func format(_ key: String, arguments: [CVarArg]) -> String {
        String(format: text(key), locale: locale, arguments: arguments)
    }
}
