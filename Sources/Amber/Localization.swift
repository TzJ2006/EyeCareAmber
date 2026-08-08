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

    /// BCP-47 语言码。大小写按规范写法，查找时不依赖它。
    private var localizationCode: String {
        if self != .system {
            return self == .zhHans ? "zh-Hans" : rawValue
        }
        let preferred = Locale.preferredLanguages.first?.lowercased() ?? "en"
        if preferred.hasPrefix("zh") { return "zh-Hans" }
        if preferred.hasPrefix("fr") { return "fr" }
        if preferred.hasPrefix("es") { return "es" }
        return "en"
    }

    /// 找到某个语言的 .lproj，**不区分大小写、也不假设 bundle 布局**。
    ///
    /// 必须这么做，因为两条构建路径产出的东西不一样：
    ///
    /// | 构建方式 | 布局 | 中文目录名 |
    /// |---|---|---|
    /// | SwiftPM 原生（`swift build`） | 扁平 | `zh-hans.lproj`（转小写） |
    /// | xcbuild（`--arch a --arch b` 通用二进制） | 嵌套 `Contents/Resources/` | `zh-Hans.lproj` |
    ///
    /// `Bundle.path(forResource:ofType:)` 是精确匹配，写死任何一种大小写，
    /// 另一种构建出来的包中文就会静默退化成显示原始 key。
    /// `resourceURL` 对两种布局都会指向正确的资源根目录。
    private static func lproj(for code: String) -> Bundle? {
        let root = resourceBundle
        if let path = root.path(forResource: code, ofType: "lproj"),
           let bundle = Bundle(path: path) {
            return bundle
        }
        let base = root.resourceURL ?? root.bundleURL
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: base, includingPropertiesForKeys: nil) else { return nil }
        let match = entries.first {
            $0.pathExtension == "lproj"
            && $0.deletingPathExtension().lastPathComponent
                .caseInsensitiveCompare(code) == .orderedSame
        }
        return match.flatMap(Bundle.init(url:))
    }

    /// 解析结果缓存 —— 每次取字符串都扫目录太浪费。
    private static var lprojCache: [String: Bundle] = [:]
    private static let cacheLock = NSLock()

    private static func cachedLproj(for code: String) -> Bundle? {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if let hit = lprojCache[code] { return hit }
        guard let bundle = lproj(for: code) else { return nil }
        lprojCache[code] = bundle
        return bundle
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
        guard let bundle = Self.cachedLproj(for: localizationCode) else { return key }
        return bundle.localizedString(forKey: key, value: key, table: "Localizable")
    }

    func format(_ key: String, _ arguments: CVarArg...) -> String {
        format(key, arguments: arguments)
    }

    func format(_ key: String, arguments: [CVarArg]) -> String {
        String(format: text(key), locale: locale, arguments: arguments)
    }
}
