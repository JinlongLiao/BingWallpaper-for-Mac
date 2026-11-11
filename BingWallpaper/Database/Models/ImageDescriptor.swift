import AppKit
import CoreData
import CryptoKit
import Foundation

struct WallpaperImageInfo: Equatable {
    let title: String
    let copyright: String
    let date: String
    let region: String
    let source: String

    init(
        description: String,
        startDate: String,
        marketCode: String?,
        locale: Locale = Localization.locale,
        timeZone: TimeZone = .current
    ) {
        let components = Self.descriptionComponents(from: description)
        title = components.title
        copyright = components.copyright
        date = Self.formattedDate(
            from: startDate,
            locale: locale,
            timeZone: timeZone
        )
        region = WallpaperChannel.title(for: marketCode, locale: locale)
        source = WallpaperChannel.source(for: marketCode).title
    }

    private static func descriptionComponents(from description: String) -> (title: String, copyright: String) {
        let trimmedDescription = description.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedDescription.hasSuffix(")"),
              let separatorRange = trimmedDescription.range(of: " (", options: .backwards) else {
            return (trimmedDescription, "")
        }

        let title = trimmedDescription[..<separatorRange.lowerBound]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let copyrightStart = separatorRange.upperBound
        let copyrightEnd = trimmedDescription.index(before: trimmedDescription.endIndex)
        let copyright = trimmedDescription[copyrightStart..<copyrightEnd]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard copyright.isEmpty == false else { return (trimmedDescription, "") }
        return (title, copyright)
    }

    private static func formattedDate(
        from startDate: String,
        locale: Locale,
        timeZone: TimeZone
    ) -> String {
        let parser = DateFormatter()
        parser.calendar = Calendar(identifier: .gregorian)
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.timeZone = timeZone
        parser.dateFormat = "yyyyMMdd"
        guard let parsedDate = parser.date(from: startDate) else { return startDate }

        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: parsedDate)
    }

}

public final class ImageDescriptor: NSManagedObject {
    enum ValidationError: LocalizedError, Equatable {
        case invalidStartDate(String)
        case invalidEndDate(String)
        case invalidImageURL(String)
        case invalidCopyrightURL(String)
        case unsupportedMediaType(String)
        case unsupportedOrientation
        case missingEntity

        var errorDescription: String? {
            switch self {
            case .invalidStartDate(let value):
                return "Invalid Bing start date: \(value)"
            case .invalidEndDate(let value):
                return "Invalid Bing end date: \(value)"
            case .invalidImageURL(let value):
                return "Invalid Bing image URL: \(value)"
            case .invalidCopyrightURL(let value):
                return "Invalid Bing copyright URL: \(value)"
            case .unsupportedMediaType(let value):
                return "Unsupported Wallpaper Alchemy media type: \(value)"
            case .unsupportedOrientation:
                return "Wallpaper Alchemy image is not a landscape desktop wallpaper"
            case .missingEntity:
                return "The wallpaper database model is missing ImageDescriptor"
            }
        }
    }

    struct ValidatedMetadata {
        let startDate: String
        let endDate: String
        let imageURL: URL
        let descriptionString: String
        let copyrightURL: URL
        /// 本次出现在列表中的时间；Wallpaper Alchemy 用它记录排行名次，nil 表示当前时间。
        var seenAt: Date? = nil
    }

    @NSManaged var startDate: String
    @NSManaged var endDate: String
    @NSManaged var imageUrl: URL
    @NSManaged var descriptionString: String
    @NSManaged var copyrightUrl: URL
    @NSManaged var marketCode: String?
    @NSManaged var requiresImageDownload: Bool
    @NSManaged var lastSeenAt: Date?
    lazy var image: Image = {
        return Image(descriptor: self)
    }()

    /// 使用必应归档日展示日期。东亚地区的 startdate 是前一天的 UTC 日期，
    /// enddate 对应当天归档日；startDate 仍用于原有排序、文件名及收藏标识。
    var imageInfo: WallpaperImageInfo {
        return WallpaperImageInfo(
            description: descriptionString,
            startDate: endDate,
            marketCode: marketCode
        )
    }

    var wallpaperIdentifier: String {
        return Self.wallpaperIdentifier(
            startDate: startDate,
            marketCode: marketCode,
            imageURL: imageUrl
        )
    }

    /// 对菜单候选按实际文件内容去重，不改变数据库、收藏或磁盘文件。
    /// 输入应按时间升序排列；同图默认保留较新的条目，已选中的条目优先。
    /// 读取失败的条目独立保留，避免单个文件异常使其他壁纸消失。
    @MainActor
    static func distinctWallpaperDescriptors(
        from descriptors: [ImageDescriptor],
        preferredWallpaperID: String? = nil,
        contentDigest: @MainActor (ImageDescriptor) -> String? = {
            FileHandler.wallpaperContentDigest(at: $0.image.downloadPath)
        }
    ) -> [ImageDescriptor] {
        var indexByDigest = [String: Int]()
        var retainedIndices = Set<Int>()
        for (index, descriptor) in descriptors.enumerated() {
            guard let digest = contentDigest(descriptor) else {
                retainedIndices.insert(index)
                continue
            }
            if let previousIndex = indexByDigest[digest] {
                if descriptors[previousIndex].wallpaperIdentifier == preferredWallpaperID {
                    continue
                }
                retainedIndices.remove(previousIndex)
            }
            indexByDigest[digest] = index
            retainedIndices.insert(index)
        }
        return descriptors.enumerated().compactMap { index, descriptor in
            retainedIndices.contains(index) ? descriptor : nil
        }
    }

    static func wallpaperIdentifier(
        startDate: String,
        marketCode: String?,
        imageURL: URL? = nil
    ) -> String {
        // Wallpaper Alchemy 同一天会上传多张图片，标识只取图片编号，与日期无关。
        if marketCode == WallpaperChannel.wallpaperAlchemyCode, let imageURL {
            return "\(WallpaperChannel.wallpaperAlchemyCode):\(imageIdentity(for: imageURL))"
        }
        guard marketCode == nil, let imageURL else {
            return "\(marketCode ?? "automatic"):\(startDate)"
        }
        return "automatic:\(startDate):\(imageIdentity(for: imageURL))"
    }

    static func legacyAutomaticWallpaperIdentifier(startDate: String) -> String {
        return "automatic:\(startDate)"
    }

    static func imageIdentity(for imageURL: URL) -> String {
        let components = URLComponents(url: imageURL, resolvingAgainstBaseURL: false)
        let bingImageID = components?.queryItems?.first(where: {
            $0.name.caseInsensitiveCompare("id") == .orderedSame
        })?.value
        if let identity = safeIdentityComponent(bingImageID), identity.isEmpty == false {
            return identity
        }
        if let wallpaperAlchemyID = wallpaperAlchemyID(for: imageURL) {
            return String(wallpaperAlchemyID)
        }

        let digest = SHA256.hash(data: Data(imageURL.absoluteString.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func safeIdentityComponent(_ value: String?) -> String? {
        guard let value else { return nil }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        let scalars = value.unicodeScalars.filter { allowed.contains($0) }
        return String(String.UnicodeScalarView(scalars).prefix(120))
    }

    /// 是否需要用图片自身的标识区分同一天的多张图片（必应自动地区及 Wallpaper Alchemy）。
    static func usesImageIdentity(marketCode: String?) -> Bool {
        return marketCode == nil || marketCode == WallpaperChannel.wallpaperAlchemyCode
    }

    /// 从 `/storage/wallpapers/{id}/文件名` 形式的 Wallpaper Alchemy 地址中取出图片编号。
    static func wallpaperAlchemyID(for imageURL: URL) -> Int? {
        guard isTrustedWallpaperAlchemyImageURL(imageURL) else { return nil }
        let components = imageURL.pathComponents
        guard let index = components.firstIndex(of: "wallpapers"),
              index > 0,
              components[index - 1] == "storage",
              components.indices.contains(index + 2),
              let id = Int(components[index + 1]),
              id > 0 else {
            return nil
        }
        return id
    }

    static func archiveIdentity(startDate: String, marketCode: String?, imageURL: URL) -> String {
        if marketCode == WallpaperChannel.wallpaperAlchemyCode {
            return imageIdentity(for: imageURL)
        }
        guard marketCode == nil else { return startDate }
        return "\(startDate):\(imageIdentity(for: imageURL))"
    }
    
    static func == (lhs: ImageDescriptor, rhs: ImageDescriptor) -> Bool {
        if lhs.marketCode == WallpaperChannel.wallpaperAlchemyCode {
            return lhs.wallpaperIdentifier == rhs.wallpaperIdentifier
        }
        return lhs.startDate == rhs.startDate && lhs.marketCode == rhs.marketCode
    }
    
    static func instantiate(
        from metadata: ValidatedMetadata,
        marketCode: String?,
        in managedContext: NSManagedObjectContext
    ) throws -> ImageDescriptor {
        guard let entity = NSEntityDescription.entity(
            forEntityName: "ImageDescriptor",
            in: managedContext
        ) else {
            throw ValidationError.missingEntity
        }
        let imageDescriptor = ImageDescriptor(entity: entity, insertInto: managedContext)
        imageDescriptor.startDate = metadata.startDate
        imageDescriptor.endDate = metadata.endDate
        imageDescriptor.imageUrl = metadata.imageURL
        imageDescriptor.descriptionString = metadata.descriptionString
        imageDescriptor.copyrightUrl = metadata.copyrightURL
        imageDescriptor.marketCode = marketCode
        imageDescriptor.requiresImageDownload = true
        imageDescriptor.lastSeenAt = metadata.seenAt ?? Date()
        return imageDescriptor
    }

    @discardableResult
    func update(from metadata: ValidatedMetadata) -> Bool {
        let imageChanged = Self.metadataRequiresImageRefresh(
            currentImageURL: imageUrl,
            newImageURL: metadata.imageURL
        )
        startDate = metadata.startDate
        endDate = metadata.endDate
        imageUrl = metadata.imageURL
        descriptionString = metadata.descriptionString
        copyrightUrl = metadata.copyrightURL
        if imageChanged {
            requiresImageDownload = true
        }
        lastSeenAt = metadata.seenAt ?? Date()
        return imageChanged
    }

    static func metadataRequiresImageRefresh(currentImageURL: URL, newImageURL: URL) -> Bool {
        return currentImageURL.absoluteURL != newImageURL.absoluteURL
    }

    static func validatedMetadata(from entry: DownloadManager.ImageEntry) throws -> ValidatedMetadata {
        guard isValidBingDate(entry.startdate) else {
            throw ValidationError.invalidStartDate(entry.startdate)
        }
        guard isValidBingDate(entry.enddate) else {
            throw ValidationError.invalidEndDate(entry.enddate)
        }

        let bingBaseURL = URL(string: "https://www.bing.com")!
        let imagePath = entry.url.replacingOccurrences(of: "1920x1080", with: "UHD")
        guard let imageURL = URL(string: imagePath, relativeTo: bingBaseURL)?.absoluteURL,
              isTrustedBingURL(imageURL) else {
            throw ValidationError.invalidImageURL(entry.url)
        }
        guard let copyrightURL = URL(string: entry.copyrightlink, relativeTo: bingBaseURL)?.absoluteURL,
              isTrustedBingURL(copyrightURL) else {
            throw ValidationError.invalidCopyrightURL(entry.copyrightlink)
        }

        return ValidatedMetadata(
            startDate: entry.startdate,
            endDate: entry.enddate,
            imageURL: imageURL,
            descriptionString: entry.copyright,
            copyrightURL: copyrightURL
        )
    }

    /// 校验 Wallpaper Alchemy 条目并转换为与必应一致的元数据。
    /// 排行图片的上传时间与展示无关，日期取被选为壁纸的当天，名次记录在 `seenAt` 中。
    /// - Parameters:
    ///   - entry: 接口返回的单张壁纸。
    ///   - locale: 请求时使用的站点语言，用于生成详情页地址。
    ///   - featuredAt: 本次获取列表的时间。
    ///   - rank: 在本次列表中的名次，从 0 开始，名次越靠前越新。
    ///   - timeZone: 换算本地日期所用的时区。
    static func validatedMetadata(
        from entry: DownloadManager.WallpaperAlchemyEntry,
        locale: String,
        featuredAt: Date = Date(),
        rank: Int = 0,
        timeZone: TimeZone = .current
    ) throws -> ValidatedMetadata {
        guard entry.type == "image" else {
            throw ValidationError.unsupportedMediaType(entry.type)
        }
        if let width = entry.width, let height = entry.height, width < height {
            throw ValidationError.unsupportedOrientation
        }
        let date = wallpaperAlchemyDateString(from: featuredAt, timeZone: timeZone)

        // 接口返回站内相对路径，也可能返回对象存储上的绝对地址。
        guard let imageURL = URL(
            string: entry.image,
            relativeTo: DownloadManager.wallpaperAlchemyApiBaseUrl
        )?.absoluteURL,
              isTrustedWallpaperAlchemyImageURL(imageURL) else {
            throw ValidationError.invalidImageURL(entry.image)
        }

        var detailComponents = URLComponents(
            url: DownloadManager.wallpaperAlchemySiteBaseUrl,
            resolvingAgainstBaseURL: false
        )!
        let localePrefix = locale == "en" ? "" : "/\(locale)"
        detailComponents.path = "\(localePrefix)/wallpaper/\(entry.slug)-\(entry.id)"
        guard let copyrightURL = detailComponents.url else {
            throw ValidationError.invalidCopyrightURL(entry.slug)
        }

        let trimmedName = entry.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let title = trimmedName.isEmpty ? entry.slug : trimmedName
        var credit = "© \(WallpaperSource.wallpaperAlchemy.title)"
        if let width = entry.width, let height = entry.height, width > 0, height > 0 {
            credit += " · \(width)×\(height)"
        }

        return ValidatedMetadata(
            startDate: date,
            endDate: date,
            imageURL: imageURL,
            // 沿用必应"标题 (版权)"格式，菜单可直接拆出标题和版权行。
            descriptionString: "\(title) (\(credit))",
            copyrightURL: copyrightURL,
            seenAt: featuredAt.addingTimeInterval(-Double(max(0, rank)) / 1000)
        )
    }

    static func wallpaperAlchemyDateString(from date: Date, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyyMMdd"
        return formatter.string(from: date)
    }

    static func isTrustedWallpaperAlchemyImageURL(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased() else {
            return false
        }
        return host == "server.wallpaperalchemy.com"
            || host == "wallpaperalchemy-bucket.s3.eu-north-1.amazonaws.com"
    }

    static func isValidBingDate(_ value: String) -> Bool {
        guard value.utf8.count == 8,
              value.utf8.allSatisfy({ (48...57).contains($0) }) else {
            return false
        }

        guard let year = Int(value.prefix(4)) else { return false }
        let monthStart = value.index(value.startIndex, offsetBy: 4)
        let dayStart = value.index(value.startIndex, offsetBy: 6)
        guard let month = Int(value[monthStart..<dayStart]),
              let day = Int(value[dayStart...]) else {
            return false
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        guard let date = calendar.date(from: DateComponents(year: year, month: month, day: day)) else {
            return false
        }
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return components.year == year && components.month == month && components.day == day
    }

    private static func isTrustedBingURL(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased() else {
            return false
        }
        return host == "bing.com" || host.hasSuffix(".bing.com")
    }
}

extension ImageDescriptor: Comparable {
    public static func < (lhs: ImageDescriptor, rhs: ImageDescriptor) -> Bool {
        if lhs.startDate != rhs.startDate {
            return lhs.startDate < rhs.startDate
        }
        // 同一天的 Wallpaper Alchemy 图片按最近一次获取时的排行名次排序，名次越靠前越新；
        // 时间相同时再按站内编号兜底，保证排序稳定。
        if lhs.marketCode == WallpaperChannel.wallpaperAlchemyCode,
           rhs.marketCode == WallpaperChannel.wallpaperAlchemyCode {
            if lhs.lastSeenAt != rhs.lastSeenAt {
                return (lhs.lastSeenAt ?? .distantPast) < (rhs.lastSeenAt ?? .distantPast)
            }
            if let lhsID = wallpaperAlchemyID(for: lhs.imageUrl),
               let rhsID = wallpaperAlchemyID(for: rhs.imageUrl),
               lhsID != rhsID {
                return lhsID < rhsID
            }
        }
        if lhs.lastSeenAt != rhs.lastSeenAt {
            return (lhs.lastSeenAt ?? .distantPast) < (rhs.lastSeenAt ?? .distantPast)
        }
        if lhs.marketCode == rhs.marketCode, usesImageIdentity(marketCode: lhs.marketCode) {
            return Self.imageIdentity(for: lhs.imageUrl) < Self.imageIdentity(for: rhs.imageUrl)
        }
        return (lhs.marketCode ?? "") < (rhs.marketCode ?? "")
    }
}
