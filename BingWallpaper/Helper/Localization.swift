import Foundation

/// 用户在设置中选择的界面语言，默认跟随系统。
enum AppLanguage: String, CaseIterable {
    case system
    case chineseSimplified
    case english

    /// 语言选项名称：具体语言始终用其本身的文字显示，便于在任何界面语言下辨认。
    var title: String {
        switch self {
        case .system:
            return L("Follow System")
        case .chineseSimplified:
            return "简体中文"
        case .english:
            return "English"
        }
    }

    /// 解析出实际使用的语言；跟随系统时取首选语言中第一个中文或英文，均无时使用英文。
    func resolved(preferredLanguages: [String] = Locale.preferredLanguages) -> ResolvedAppLanguage {
        switch self {
        case .chineseSimplified:
            return .chineseSimplified
        case .english:
            return .english
        case .system:
            for identifier in preferredLanguages {
                switch Locale(identifier: identifier).language.languageCode?.identifier {
                case "zh":
                    return .chineseSimplified
                case "en":
                    return .english
                default:
                    continue
                }
            }
            return .english
        }
    }
}

/// 界面实际使用的语言。
enum ResolvedAppLanguage: Equatable {
    case english
    case chineseSimplified

    /// 日期、地区名称等系统格式化使用的区域设置。
    var locale: Locale {
        switch self {
        case .english:
            let region = Locale.current.region?.identifier ?? "US"
            return Locale(identifier: "en_\(region)")
        case .chineseSimplified:
            return Locale(identifier: "zh_Hans_CN")
        }
    }

    /// Wallpaper Alchemy 接口的语言参数，图片标题与分类名称随界面语言变化。
    var wallpaperAlchemyLocale: String {
        switch self {
        case .english:
            return "en"
        case .chineseSimplified:
            return "zh-CN"
        }
    }
}

enum Localization {
    static let languageDefaultsKey = "APP_LANGUAGE"

    private static var isRunningUnitTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    /// 当前界面语言；单元测试固定为英文，避免本机设置影响断言。
    static var language: ResolvedAppLanguage {
        guard isRunningUnitTests == false else { return .english }
        let rawValue = UserDefaults.standard.string(forKey: languageDefaultsKey) ?? ""
        return (AppLanguage(rawValue: rawValue) ?? .system).resolved()
    }

    static var locale: Locale {
        return language.locale
    }

    static func string(_ key: String, language: ResolvedAppLanguage) -> String {
        switch language {
        case .english:
            return key
        case .chineseSimplified:
            return chineseSimplified[key] ?? key
        }
    }

    /// 以英文原文为键的简体中文译文；未收录的键直接显示英文。
    static let chineseSimplified: [String: String] = [
        // 设置窗口
        "Launch at login": "登录时启动",
        "Hide icon at menubar": "隐藏菜单栏图标",
        "Language:": "语言：",
        "Follow System": "跟随系统",
        "Image source:": "图片来源：",
        "Microsoft Bing": "微软必应",
        "Bing region:": "必应地区：",
        "Automatic (Network Location)": "自动（按网络位置）",
        "Alchemy category:": "Alchemy 分类：",
        "All Categories (Most Downloaded)": "全部分类（最多下载）",
        "Loading categories…": "正在加载分类…",
        "Couldn't load categories": "无法加载分类",
        "Search categories": "搜索分类（支持拼音）",
        "No matching categories": "没有匹配的分类",
        "Checking “%@”…": "正在检查「%@」…",
        "“%@” has no desktop wallpapers": "「%@」暂无桌面壁纸",
        "%@ — No desktop wallpapers": "%@ — 暂无桌面壁纸，请更换分类",
        "Please choose another category. The current category is kept.": "请选择其他分类，当前分类保持不变。",
        "Change wallpaper:": "更换壁纸：",
        "Off": "从不",
        "Every 1 Minute": "每 1 分钟",
        "Every 5 Minutes": "每 5 分钟",
        "Every 10 Minutes": "每 10 分钟",
        "Every 1 Hour": "每 1 小时",
        "Every 2 Hours": "每 2 小时",
        "Automatically changes to the next wallpaper in the selected category's download ranking.":
            "按所选分类的下载排行，定时自动换成下一张壁纸。",
        "Apply wallpaper to:": "壁纸应用到：",
        "All Displays": "所有显示器",
        "Main Display Only": "仅主显示器",
        "Selected Displays…": "所选显示器…",
        "Selected Displays (%d)…": "所选显示器（%d）…",
        "Per-display profiles:": "单屏配置：",
        "Configure…": "配置…",
        "Configure (%d)…": "配置（%d）…",
        "Image location:": "图片位置：",
        "Keep images on disk: ": "保留图片：",
        "Keep last %@ images:": "保留最近 %@ 张图片：",
        "Keep all images forever:": "永久保留所有图片：",
        "Infinite": "无限",
        "Reset Database": "重置数据库",
        "The Bing region applies only when the image source is Microsoft Bing.":
            "仅当图片来源为微软必应时，必应地区才生效。",
        "Applies only when Wallpaper Alchemy is the image source or used by a display profile.":
            "仅当图片来源为 Wallpaper Alchemy，或有显示器配置使用它时生效。",
        "Failed to reset Database": "重置数据库失败",
        "Ok": "好",
        "OK": "好",
        "Apply": "应用",
        "Cancel": "取消",
        "Later": "稍后",
        "No displays are available": "没有可用的显示器",
        "Connect a display and try again.": "请连接显示器后重试。",
        "Choose displays": "选择显示器",
        "BingWallpaper will update only the selected displays. Disconnected displays remain selected and will resume when reconnected.":
            "BingWallpaper 只会更新所选显示器。已断开的显示器仍保持选中，重新连接后恢复更新。",
        "Select at least one display": "请至少选择一个显示器",
        "Configure Displays": "配置显示器",
        "Each display can inherit the global wallpaper, follow the latest image from its own source or Bing region, or use a specific downloaded wallpaper. Disconnected display profiles remain saved.":
            "每个显示器可以继承全局壁纸、跟随自身来源或必应地区的最新图片，或使用某张已下载的壁纸。已断开显示器的配置会保留。",
        "Display": "显示器",
        "Displays": "显示器",
        "Source / Bing Region": "来源 / 必应地区",
        "Wallpaper": "壁纸",
        "Inherit Global — %@": "继承全局 — %@",
        "Bing — %@": "必应 — %@",
        "Inherit Global Wallpaper": "继承全局壁纸",
        "Follow Latest in This Source": "跟随此来源的最新壁纸",
        "No downloaded wallpapers for this source": "此来源暂无已下载的壁纸",
        "Approve BingWallpaper in Login Items": "请在登录项中允许 BingWallpaper",
        "BingWallpaper has been added to your Login Items but macOS needs your approval before it can launch at login. Open System Settings to confirm it.":
            "BingWallpaper 已加入登录项，但需要你在 macOS 中批准后才能登录时启动。请打开系统设置确认。",
        "Open Login Items": "打开登录项",
        "Couldn't update Launch at Login": "无法更改登录时启动",
        "Couldn't use the selected image location": "无法使用所选的图片位置",
        " — Main Display": " — 主显示器",

        // 菜单
        "Current display": "当前显示器",
        "Current Display": "当前显示器",
        "Display: %@": "显示器：%@",
        "%@\nUse the switching scope menu to choose all displays or this display.":
            "%@\n可在「切换范围」中选择切换所有屏幕或仅当前屏幕。",
        "Switching Scope": "切换范围",
        "Switch All Displays Together": "所有屏幕一起切换",
        "Current Display Only": "仅当前屏幕",
        "Switching Scope: All Displays": "切换范围：所有屏幕",
        "Switching Scope: Current Display": "切换范围：仅当前屏幕",
        "Update Status": "更新状态",
        "Refresh Images": "刷新图片",
        "Retry Now": "立即重试",
        "Favorites": "收藏",
        "Favorites (%d)": "收藏（%d）",
        "No Favorites": "暂无收藏",
        "Favorite wallpapers": "收藏的壁纸",
        "Check for app update": "检查应用更新",
        "Settings": "设置",
        "Quit": "退出",
        "Save Wallpaper Copy": "存储壁纸副本",
        "Couldn’t Save Wallpaper": "无法存储壁纸",
        "Show image details and actions": "显示图片详情与操作",
        "Image actions": "图片操作",
        "Open image source": "打开图片来源",
        "Wallpaper Details": "壁纸详情",
        "Title: %@": "标题：%@",
        "Date: %@": "日期：%@",
        "Source: %@": "来源：%@",
        "Region: %@": "地区：%@",
        "Copyright: %@": "版权：%@",
        "Remove from Favorites": "取消收藏",
        "Add to Favorites": "加入收藏",
        "Unpin Wallpaper": "取消固定壁纸",
        "Pin This Wallpaper": "固定此壁纸",
        "Pin This Wallpaper on This Display": "在此显示器上固定此壁纸",
        "Replace Pinned Wallpaper": "替换已固定的壁纸",
        "Open Source on %@": "在 %@ 中打开来源",
        "Show in Finder": "在访达中显示",
        "Save a Copy…": "存储副本…",
        "Last successful update: %@": "上次成功更新：%@",
        "Last attempt: %@": "上次尝试：%@",
        "Next retry: %@": "下次重试：%@",
        "Next update: %@": "下次更新：%@",
        "Failed step: %@": "失败步骤：%@",
        "Never": "从未",
        "Wallpaper update status": "壁纸更新状态",

        // 更新状态
        "Wallpaper list": "壁纸列表",
        "Image download": "图片下载",
        "Update Status: Up to Date": "更新状态：已是最新",
        "Update Status: Updating…": "更新状态：正在更新…",
        "Update Status: Failed — Retry Scheduled": "更新状态：失败，稍后重试",
        "Update Status: Failed": "更新状态：失败",

        // 应用更新与数据库
        "New version of BingWallpaper available": "BingWallpaper 有新版本",
        "Do you want to update now?\nCurrent version: %@\nNew version: %@":
            "现在更新吗？\n当前版本：%@\n新版本：%@",
        "Update": "更新",
        "BingWallpaper already up to date": "BingWallpaper 已是最新版本",
        "There is no new version of BingWallpaper available": "没有可用的新版本",
        "Couldn’t Check for Updates": "无法检查更新",
        "Wallpaper Database Recovered": "壁纸数据库已恢复",

        // 错误信息
        "The server response was not HTTP": "服务器响应不是 HTTP",
        "The server returned HTTP %d": "服务器返回 HTTP %d",
        "Unexpected content type: %@": "意外的内容类型：%@",
        "missing": "缺失",
        "The response was not valid UTF-8 text": "响应不是有效的 UTF-8 文本",
        "The downloaded data was not a valid image": "下载的数据不是有效图片",
        "The downloaded data was not a valid installer package": "下载的数据不是有效的安装包",
        "The selected Wallpaper Alchemy category has no desktop wallpapers": "所选 Wallpaper Alchemy 分类没有桌面壁纸",
        "The wallpaper source returned no valid wallpaper metadata": "壁纸来源没有返回有效的壁纸信息",
        "The wallpaper database is unavailable: %@": "壁纸数据库不可用：%@",
        "The wallpaper database was damaged and has been rebuilt. A backup was saved at %@.":
            "壁纸数据库已损坏并已重建，备份保存在 %@。",
        "The wallpaper database could not be opened. BingWallpaper is using a temporary in-memory database for this session. %@":
            "无法打开壁纸数据库，本次运行使用临时内存数据库。%@"
    ]
}

/// 返回当前界面语言下的文案。
func L(_ key: String) -> String {
    return Localization.string(key, language: Localization.language)
}

/// 返回当前界面语言下的格式化文案，格式占位符与英文原文一致。
func L(_ key: String, _ arguments: CVarArg...) -> String {
    let language = Localization.language
    return String(
        format: Localization.string(key, language: language),
        locale: language.locale,
        arguments: arguments
    )
}
