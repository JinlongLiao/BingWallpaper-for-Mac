
import Foundation
import ServiceManagement
import OSLog

private let logger = Logger(
    subsystem: Logging.subsystem,
    category: Logging.Category.Settings.rawValue
)

struct BingMarketOption: Equatable {
    let code: String?
    let title: String

    static var automatic: BingMarketOption {
        return BingMarketOption(code: nil, title: L("Automatic (Network Location)"))
    }

    // Bing's documented `mkt` values. A market is a language and a
    // country/region, so a country can appear more than once.
    static let supportedCodes = [
        "es-AR", "en-AU", "de-AT", "nl-BE", "fr-BE", "pt-BR",
        "en-CA", "fr-CA", "es-CL", "da-DK", "fi-FI", "fr-FR",
        "de-DE", "zh-HK", "en-IN", "en-ID", "it-IT", "ja-JP",
        "ko-KR", "en-MY", "es-MX", "nl-NL", "en-NZ", "no-NO",
        "zh-CN", "pl-PL", "en-PH", "ru-RU", "en-ZA", "es-ES",
        "sv-SE", "fr-CH", "de-CH", "zh-TW", "tr-TR", "en-GB",
        "en-US", "es-US"
    ]

    static var all: [BingMarketOption] {
        let localizedMarkets = supportedCodes
            .map { code in
                let localizedName = Localization.locale.localizedString(forIdentifier: code) ?? code
                return BingMarketOption(code: code, title: "\(localizedName) (\(code))")
            }
            .sorted { (lhs: BingMarketOption, rhs: BingMarketOption) in
                lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
            }
        return [automatic] + localizedMarkets
    }
}

/// 壁纸图片来源，必应为默认来源。
enum WallpaperSource: String, CaseIterable {
    case bing
    case wallpaperAlchemy

    var title: String {
        switch self {
        case .bing:
            return L("Microsoft Bing")
        case .wallpaperAlchemy:
            return "Wallpaper Alchemy"
        }
    }
}

/// 壁纸频道沿用数据库中的 marketCode 字段：nil 与必应地区码属于必应，
/// 保留码属于 Wallpaper Alchemy。保留码不含连字符，不会与必应地区码冲突。
enum WallpaperChannel {
    static let wallpaperAlchemyCode = "wallpaperalchemy"

    static func source(for channelCode: String?) -> WallpaperSource {
        return channelCode == wallpaperAlchemyCode ? .wallpaperAlchemy : .bing
    }

    /// 判断频道码是否可用于显示器配置中的显式选择。
    static func isSupported(_ channelCode: String) -> Bool {
        return channelCode == wallpaperAlchemyCode
            || BingMarketOption.supportedCodes.contains(channelCode)
    }

    /// 频道的展示名称：必应显示地区，Wallpaper Alchemy 显示来源名。
    static func title(for channelCode: String?, locale: Locale = Localization.locale) -> String {
        guard let channelCode else { return BingMarketOption.automatic.title }
        if channelCode == wallpaperAlchemyCode {
            return WallpaperSource.wallpaperAlchemy.title
        }
        let localizedName = locale.localizedString(forIdentifier: channelCode) ?? channelCode
        return "\(localizedName) (\(channelCode))"
    }
}

enum WallpaperDisplayMode: String, CaseIterable {
    case all
    case main
    case selected

    var title: String {
        switch self {
        case .all:
            return L("All Displays")
        case .main:
            return L("Main Display Only")
        case .selected:
            return L("Selected Displays…")
        }
    }
}

/// Wallpaper Alchemy 自动更换壁纸的间隔，关闭时沿用每天轮换一页的方式。
enum WallpaperAlchemyRefreshInterval: Int, CaseIterable {
    case never = 0
    case oneMinute = 60
    case fiveMinutes = 300
    case tenMinutes = 600
    case oneHour = 3600
    case twoHours = 7200

    /// 更换间隔（秒），关闭时为 nil。
    var timeInterval: TimeInterval? {
        return rawValue > 0 ? TimeInterval(rawValue) : nil
    }

    var title: String {
        switch self {
        case .never:
            return L("Off")
        case .oneMinute:
            return L("Every 1 Minute")
        case .fiveMinutes:
            return L("Every 5 Minutes")
        case .tenMinutes:
            return L("Every 10 Minutes")
        case .oneHour:
            return L("Every 1 Hour")
        case .twoHours:
            return L("Every 2 Hours")
        }
    }
}

enum WallpaperDisplayMarketMode: String, Codable, CaseIterable {
    case inherit
    case automatic
    case explicit
}

enum WallpaperDisplayPinMode: String, Codable, CaseIterable {
    case inherit
    case followLatest
    case pinned
}

struct WallpaperDisplayProfile: Codable, Equatable {
    var marketMode: WallpaperDisplayMarketMode = .inherit
    var marketCode: String?
    var pinMode: WallpaperDisplayPinMode = .inherit
    var pinnedWallpaperID: String?

    var isDefault: Bool {
        return marketMode == .inherit && pinMode == .inherit
    }

    func effectiveMarketCode(globalMarketCode: String?) -> String? {
        switch marketMode {
        case .inherit:
            return globalMarketCode
        case .automatic:
            return nil
        case .explicit:
            guard let marketCode,
                  WallpaperChannel.isSupported(marketCode) else {
                return globalMarketCode
            }
            return marketCode
        }
    }
}

public class Settings {
    private let defaults: UserDefaults

    public convenience init() {
        self.init(defaults: .standard)
    }

    init(defaults: UserDefaults) {
        self.defaults = defaults
        migrateLegacyLoginItemIfNeeded()
    }

    /// `true` when the user's intent is "launch at login enabled".
    ///
    /// On macOS 15+/26 the system frequently keeps a freshly registered login
    /// item in `.requiresApproval` until the user confirms it in
    /// System Settings → General → Login Items. We treat that as "on" so the
    /// checkbox doesn't snap back to off the instant the user toggles it.
    var launchAtLogin: Bool {
        switch SMAppService.mainApp.status {
        case .enabled, .requiresApproval:
            return true
        case .notRegistered, .notFound:
            return false
        @unknown default:
            return false
        }
    }

    /// `true` when the login item is registered but waiting for the user to
    /// approve it in System Settings. Callers should route the user there.
    var launchAtLoginRequiresApproval: Bool {
        return SMAppService.mainApp.status == .requiresApproval
    }

    /// Register or unregister the main app as a login item. Throws on failure
    /// so the caller can surface the error to the user instead of swallowing
    /// it.
    func setLaunchAtLogin(_ newValue: Bool) throws {
        do {
            if newValue {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            let actionString = newValue ? "register" : "unregister"
            logger.error("Failed to \(actionString, privacy: .public) login item with error: \(String(describing: error), privacy: .public)")
            throw error
        }
    }

    private func migrateLegacyLoginItemIfNeeded() {
        guard defaults.object(forKey: Settings.SM_LOGIN_ENABLED_LEGACY) != nil else { return }
        let wasEnabled = defaults.bool(forKey: Settings.SM_LOGIN_ENABLED_LEGACY)
        defaults.removeObject(forKey: Settings.SM_LOGIN_ENABLED_LEGACY)
        if wasEnabled, SMAppService.mainApp.status != .enabled {
            try? SMAppService.mainApp.register()
        }
    }
    
    var hideMenuBarIcon: Bool {
        get {
            return defaults.bool(forKey: Settings.HIDE_MENU_BAR_ICON)
        }
        set {
            defaults.set(newValue, forKey: Settings.HIDE_MENU_BAR_ICON)
        }
    }
    
    var imageDownloadPath: URL {
        guard let bookmarkData = defaults.data(forKey: Settings.IMAGE_DOWNLOAD_PATH_BOOKMARK) else {
            return defaults.url(forKey: Settings.IMAGE_DOWNLOAD_PATH) ?? FileHandler.defaultBingWallpaperDirectory()
        }

        var isStale = false
        do {
            let url = try URL(
                resolvingBookmarkData: bookmarkData,
                options: [.withSecurityScope, .withoutUI],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            if isStale {
                do {
                    try saveImageDownloadPathBookmark(for: url)
                } catch {
                    logger.error("Failed to refresh stale image directory bookmark: \(error.localizedDescription, privacy: .public)")
                }
            }
            return url
        } catch {
            logger.error("Failed to resolve image directory bookmark: \(error.localizedDescription, privacy: .public)")
            return defaults.url(forKey: Settings.IMAGE_DOWNLOAD_PATH) ?? FileHandler.defaultBingWallpaperDirectory()
        }
    }

    func setImageDownloadPath(_ url: URL) throws {
        try saveImageDownloadPathBookmark(for: url)
        defaults.set(url, forKey: Settings.IMAGE_DOWNLOAD_PATH)
    }

    private func saveImageDownloadPathBookmark(for url: URL) throws {
        let bookmarkData = try url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        defaults.set(bookmarkData, forKey: Settings.IMAGE_DOWNLOAD_PATH_BOOKMARK)
    }

    /// The explicit Bing market selected by the user, or `nil` when Bing
    /// should infer it from the network location.
    var bingMarketCode: String? {
        get {
            guard let code = defaults.string(forKey: Settings.BING_MARKET_CODE),
                  BingMarketOption.supportedCodes.contains(code) else {
                return nil
            }
            return code
        }
        set {
            if let newValue, BingMarketOption.supportedCodes.contains(newValue) {
                defaults.set(newValue, forKey: Settings.BING_MARKET_CODE)
            } else {
                defaults.removeObject(forKey: Settings.BING_MARKET_CODE)
            }
        }
    }

    /// 全局壁纸来源，缺省或无法识别时使用必应。
    var wallpaperSource: WallpaperSource {
        get {
            guard let rawValue = defaults.string(forKey: Settings.WALLPAPER_SOURCE),
                  let source = WallpaperSource(rawValue: rawValue) else {
                return .bing
            }
            return source
        }
        set {
            defaults.set(newValue.rawValue, forKey: Settings.WALLPAPER_SOURCE)
        }
    }

    /// 界面语言，默认跟随系统。
    var appLanguage: AppLanguage {
        get {
            let rawValue = defaults.string(forKey: Localization.languageDefaultsKey) ?? ""
            return AppLanguage(rawValue: rawValue) ?? .system
        }
        set {
            defaults.set(newValue.rawValue, forKey: Localization.languageDefaultsKey)
        }
    }

    /// Wallpaper Alchemy 的请求语言跟随界面语言。
    var wallpaperAlchemyLocale: String {
        return appLanguage.resolved().wallpaperAlchemyLocale
    }

    /// Wallpaper Alchemy 的分类筛选，nil 表示不限分类、使用全站下载排行。
    var wallpaperAlchemyCategory: DownloadManager.WallpaperAlchemyCategory? {
        get {
            guard let data = defaults.data(forKey: Settings.WALLPAPER_ALCHEMY_CATEGORY),
                  let category = try? JSONDecoder().decode(
                    DownloadManager.WallpaperAlchemyCategory.self,
                    from: data
                  ),
                  category.id > 0 else {
                return nil
            }
            return category
        }
        set {
            // 换了分类就从该分类下载排行的第一张重新轮换。
            if newValue?.id != wallpaperAlchemyCategory?.id {
                wallpaperAlchemyRotationPosition = 0
            }
            if let newValue, newValue.id > 0,
               let data = try? JSONEncoder().encode(newValue) {
                defaults.set(data, forKey: Settings.WALLPAPER_ALCHEMY_CATEGORY)
            } else {
                defaults.removeObject(forKey: Settings.WALLPAPER_ALCHEMY_CATEGORY)
            }
        }
    }

    /// Wallpaper Alchemy 自动更换壁纸的间隔，缺省为关闭。
    var wallpaperAlchemyRefreshInterval: WallpaperAlchemyRefreshInterval {
        get {
            return WallpaperAlchemyRefreshInterval(
                rawValue: defaults.integer(forKey: Settings.WALLPAPER_ALCHEMY_REFRESH_INTERVAL)
            ) ?? .never
        }
        set {
            defaults.set(newValue.rawValue, forKey: Settings.WALLPAPER_ALCHEMY_REFRESH_INTERVAL)
        }
    }

    /// 自动更换时当前壁纸在下载排行中的名次，从 0 开始。
    var wallpaperAlchemyRotationPosition: Int {
        get {
            return max(0, defaults.integer(forKey: Settings.WALLPAPER_ALCHEMY_ROTATION_POSITION))
        }
        set {
            defaults.set(max(0, newValue), forKey: Settings.WALLPAPER_ALCHEMY_ROTATION_POSITION)
        }
    }

    /// 上次自动更换壁纸的时间，重启应用后据此继续计时。
    var lastWallpaperAlchemyRotation: Date? {
        get {
            return defaults.object(forKey: Settings.LAST_WALLPAPER_ALCHEMY_ROTATION) as? Date
        }
        set {
            defaults.set(newValue, forKey: Settings.LAST_WALLPAPER_ALCHEMY_ROTATION)
        }
    }

    /// 全局壁纸频道：必应时为所选地区（nil 表示自动），否则为来源保留码。
    var globalChannelCode: String? {
        switch wallpaperSource {
        case .bing:
            return bingMarketCode
        case .wallpaperAlchemy:
            return WallpaperChannel.wallpaperAlchemyCode
        }
    }

    /// 手动浏览是否同时切换所有已连接屏幕；默认开启，与自动更新范围独立保存。
    var switchesAllDisplaysTogether: Bool {
        get { defaults.object(forKey: Settings.SWITCHES_ALL_DISPLAYS_TOGETHER) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Settings.SWITCHES_ALL_DISPLAYS_TOGETHER) }
    }

    /// 全局来源或必应地区改变时调用：解除全局固定，并让原本只是跟随旧全局频道、未固定图片的屏幕改回继承，
    /// 使这些屏幕立即切到新来源；明确固定了图片或选了其他来源的屏幕保持不变。
    /// - Parameter previousChannelCode: 改变前的全局频道。
    func releaseSelections(followingPreviousGlobalChannel previousChannelCode: String?) {
        pinnedWallpaperID = nil
        wallpaperDisplayProfiles = wallpaperDisplayProfiles.filter { _, profile in
            profile.pinMode == .pinned ||
                profile.effectiveMarketCode(globalMarketCode: previousChannelCode) != previousChannelCode
        }
    }

    /// 共享浏览时解除在线屏幕的独立地区及固定状态，离线屏幕配置保留。
    /// - Parameter identifiers: 本次参与共享浏览的已连接屏幕标识。
    func restoreSharedWallpaperSelection(forDisplayIdentifiers identifiers: Set<String>) {
        pinnedWallpaperID = nil
        wallpaperDisplayProfiles = wallpaperDisplayProfiles.filter { !identifiers.contains($0.key) }
    }

    var wallpaperDisplayMode: WallpaperDisplayMode {
        get {
            guard let rawValue = defaults.string(forKey: Settings.WALLPAPER_DISPLAY_MODE),
                  let mode = WallpaperDisplayMode(rawValue: rawValue) else {
                return .all
            }
            return mode
        }
        set {
            defaults.set(newValue.rawValue, forKey: Settings.WALLPAPER_DISPLAY_MODE)
        }
    }

    var selectedWallpaperDisplayIDs: Set<String> {
        get {
            return Set(defaults.stringArray(forKey: Settings.SELECTED_WALLPAPER_DISPLAY_IDS) ?? [])
        }
        set {
            defaults.set(newValue.sorted(), forKey: Settings.SELECTED_WALLPAPER_DISPLAY_IDS)
        }
    }

    var favoriteWallpaperIDs: Set<String> {
        get {
            return Set(defaults.stringArray(forKey: Settings.FAVORITE_WALLPAPER_IDS) ?? [])
        }
        set {
            defaults.set(newValue.sorted(), forKey: Settings.FAVORITE_WALLPAPER_IDS)
        }
    }

    var pinnedWallpaperID: String? {
        get {
            return defaults.string(forKey: Settings.PINNED_WALLPAPER_ID)
        }
        set {
            if let newValue {
                defaults.set(newValue, forKey: Settings.PINNED_WALLPAPER_ID)
            } else {
                defaults.removeObject(forKey: Settings.PINNED_WALLPAPER_ID)
            }
        }
    }

    var wallpaperDisplayProfiles: [String: WallpaperDisplayProfile] {
        get {
            guard let data = defaults.data(forKey: Settings.WALLPAPER_DISPLAY_PROFILES),
                  let profiles = try? JSONDecoder().decode(
                    [String: WallpaperDisplayProfile].self,
                    from: data
                  ) else {
                return [:]
            }
            return profiles
        }
        set {
            let profiles = newValue.filter { $0.value.isDefault == false }
            guard profiles.isEmpty == false,
                  let data = try? JSONEncoder().encode(profiles) else {
                defaults.removeObject(forKey: Settings.WALLPAPER_DISPLAY_PROFILES)
                return
            }
            defaults.set(data, forKey: Settings.WALLPAPER_DISPLAY_PROFILES)
        }
    }

    /// 需要下载的全部频道：全局频道加上各显示器单独指定的频道，去重后返回。
    var requiredChannelCodes: [String?] {
        let globalChannelCode = globalChannelCode
        var result = [globalChannelCode]
        for profile in wallpaperDisplayProfiles.values where profile.marketMode != .inherit {
            let marketCode = profile.effectiveMarketCode(globalMarketCode: globalChannelCode)
            if result.contains(where: { $0 == marketCode }) == false {
                result.append(marketCode)
            }
        }
        return result
    }

    func migrateLegacyAutomaticWallpaperIdentifiers(using descriptors: [ImageDescriptor]) {
        let replacements = descriptors.reduce(into: [String: String]()) { result, descriptor in
            guard descriptor.marketCode == nil else { return }
            result[ImageDescriptor.legacyAutomaticWallpaperIdentifier(
                startDate: descriptor.startDate
            )] = descriptor.wallpaperIdentifier
        }
        guard replacements.isEmpty == false else { return }

        favoriteWallpaperIDs = Set(favoriteWallpaperIDs.map { replacements[$0] ?? $0 })
        if let pinnedWallpaperID, let replacement = replacements[pinnedWallpaperID] {
            self.pinnedWallpaperID = replacement
        }
        wallpaperDisplayProfiles = wallpaperDisplayProfiles.mapValues { profile in
            var profile = profile
            if let pinnedWallpaperID = profile.pinnedWallpaperID,
               let replacement = replacements[pinnedWallpaperID] {
                profile.pinnedWallpaperID = replacement
            }
            return profile
        }
    }

    func resetWallpaperLibrarySelections() {
        favoriteWallpaperIDs = []
        pinnedWallpaperID = nil
        wallpaperDisplayProfiles = wallpaperDisplayProfiles.mapValues { profile in
            var profile = profile
            if profile.pinMode == .pinned {
                profile.pinMode = .followLatest
            }
            profile.pinnedWallpaperID = nil
            return profile
        }
    }
    
    public var lastUpdate: Date {
        get {
            return defaults.object(forKey: Settings.LAST_UPDATE) as? Date ?? Date.distantPast
        }
        set {
            defaults.set(newValue, forKey: Settings.LAST_UPDATE)
        }
    }
    
    var keepImageDuration: Int {
        get {
            return defaults.object(forKey: Settings.KEEP_IMAGE_DURATION) as? Int ?? KeepImageDuration.fifty.rawValue
        }
        set {
            defaults.set(newValue, forKey: Settings.KEEP_IMAGE_DURATION)
        }
    }
    
    func maximumStoredImageCount() -> Int? {
        switch keepImageDuration {
        case KeepImageDuration.five.rawValue:
            return 5
        case KeepImageDuration.ten.rawValue:
            return 10
        case KeepImageDuration.fifty.rawValue:
            return 50
        case KeepImageDuration.onehundred.rawValue:
            return 100
        case KeepImageDuration.infinite.rawValue:
            return nil
        default:
            return 50
        }
    }
    
    private static let SM_LOGIN_ENABLED_LEGACY = "SM_LOGIN_ENABLED"
    private static let HIDE_MENU_BAR_ICON = "HIDE_MENU_BAR_ICON"
    private static let IMAGE_DOWNLOAD_PATH = "IMAGE_DOWNLOAD_PATH"
    private static let IMAGE_DOWNLOAD_PATH_BOOKMARK = "IMAGE_DOWNLOAD_PATH_BOOKMARK"
    private static let BING_MARKET_CODE = "BING_MARKET_CODE"
    private static let WALLPAPER_SOURCE = "WALLPAPER_SOURCE"
    private static let WALLPAPER_ALCHEMY_CATEGORY = "WALLPAPER_ALCHEMY_CATEGORY"
    private static let WALLPAPER_ALCHEMY_REFRESH_INTERVAL = "WALLPAPER_ALCHEMY_REFRESH_INTERVAL"
    private static let WALLPAPER_ALCHEMY_ROTATION_POSITION = "WALLPAPER_ALCHEMY_ROTATION_POSITION"
    private static let LAST_WALLPAPER_ALCHEMY_ROTATION = "LAST_WALLPAPER_ALCHEMY_ROTATION"
    /// 手动浏览切换范围的持久化键，缺省时切换所有在线屏幕。
    private static let SWITCHES_ALL_DISPLAYS_TOGETHER = "SWITCHES_ALL_DISPLAYS_TOGETHER"
    private static let WALLPAPER_DISPLAY_MODE = "WALLPAPER_DISPLAY_MODE"
    private static let SELECTED_WALLPAPER_DISPLAY_IDS = "SELECTED_WALLPAPER_DISPLAY_IDS"
    private static let FAVORITE_WALLPAPER_IDS = "FAVORITE_WALLPAPER_IDS"
    private static let PINNED_WALLPAPER_ID = "PINNED_WALLPAPER_ID"
    private static let WALLPAPER_DISPLAY_PROFILES = "WALLPAPER_DISPLAY_PROFILES"
    private static let LAST_UPDATE = "LAST_UPDATE"
    private static let KEEP_IMAGE_DURATION = "KEEP_IMAGE_DURATION"
}
