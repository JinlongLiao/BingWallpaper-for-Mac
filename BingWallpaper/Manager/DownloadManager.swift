import Foundation
import ImageIO

class DownloadManager {

    enum Error: LocalizedError {
        case nonHttpResponse
        case httpStatus(Int)
        case unexpectedContentType(String?)
        case invalidText
        case invalidImage
        case invalidPackage

        var errorDescription: String? {
            switch self {
            case .nonHttpResponse:
                return L("The server response was not HTTP")
            case .httpStatus(let statusCode):
                return L("The server returned HTTP %d", statusCode)
            case .unexpectedContentType(let contentType):
                return L("Unexpected content type: %@", contentType ?? L("missing"))
            case .invalidText:
                return L("The response was not valid UTF-8 text")
            case .invalidImage:
                return L("The downloaded data was not a valid image")
            case .invalidPackage:
                return L("The downloaded data was not a valid installer package")
            }
        }
    }
    
    struct ImageArchive: Codable {
        let images: [ImageEntry]
    }
    
    struct ImageEntry: Codable {
        let url: String
        let enddate: String
        let startdate: String
        let copyright: String
        let copyrightlink: String
    }
    
    private static func downloadData(from url: URL, headers: [String: String] = [:]) async throws -> DownloadResponse {
        var request = URLRequest(url: url)
        headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
        let (data, urlResponse) = try await URLSession.shared.data(for: request)
        try validateHttpResponse(urlResponse)
        return DownloadResponse(data: data, urlResponse: urlResponse)
    }
    
    static func validateHttpResponse(_ response: URLResponse) throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw Error.nonHttpResponse
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            throw Error.httpStatus(httpResponse.statusCode)
        }
    }

    static func isPermanentlyUnavailableResourceError(_ error: Swift.Error) -> Bool {
        guard case Error.httpStatus(let statusCode) = error else { return false }
        return statusCode == 404 || statusCode == 410
    }

    private static func validateContentType(_ response: URLResponse, prefixes: [String]) throws {
        guard let mimeType = response.mimeType,
              prefixes.contains(where: { mimeType.hasPrefix($0) }) else {
            throw Error.unexpectedContentType(response.mimeType)
        }
    }
    
    static func imageArchiveUrl(numberOfImages: Int, marketCode: String?) -> URL {
        var components = URLComponents(string: "https://www.bing.com/HPImageArchive.aspx")!
        components.queryItems = [
            URLQueryItem(name: "format", value: "js"),
            URLQueryItem(name: "n", value: String(numberOfImages)),
            URLQueryItem(name: "idx", value: "0")
        ]
        if let marketCode {
            components.queryItems?.append(URLQueryItem(name: "mkt", value: marketCode))
        }
        return components.url!
    }

    static func downloadImageEntries(numberOfImages: Int, marketCode: String?) async throws -> [ImageEntry] {
        // TODO: @2h4u: idx is the start index of the batch of image descriptors that is downloaded, maybe add support for it so more images from the past can be used?
        let response = try await downloadData(from: imageArchiveUrl(numberOfImages: numberOfImages, marketCode: marketCode))
        try validateContentType(response.urlResponse, prefixes: ["application/json", "text/json", "application/vnd.github+json"])
        return try JSONDecoder().decode(ImageArchive.self, from: response.data).images
    }

    // MARK: - Wallpaper Alchemy

    struct WallpaperAlchemyResponse<Item: Decodable>: Decodable {
        let data: WallpaperAlchemyPage<Item>
    }

    struct WallpaperAlchemyPage<Item: Decodable>: Decodable {
        let data: [Item]
        let pageInfo: WallpaperAlchemyPageInfo?
    }

    struct WallpaperAlchemyPageInfo: Decodable {
        let totalItems: Int?
        let totalPages: Int?
    }

    struct WallpaperAlchemyEntry: Decodable {
        let id: Int
        let slug: String
        let image: String
        let type: String
        let width: Int?
        let height: Int?
        let createdAt: String
        let name: String?
    }

    /// 站点分类（接口中称为 tag），`title` 为请求语言下的分类名称。
    struct WallpaperAlchemyCategory: Codable, Equatable {
        let id: Int
        let name: String
        let title: String?

        var displayTitle: String {
            let trimmedTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return trimmedTitle.isEmpty ? name : trimmedTitle
        }
    }

    enum WallpaperAlchemyError: LocalizedError, Equatable {
        case noDesktopWallpapers

        var errorDescription: String? {
            switch self {
            case .noDesktopWallpapers:
                return L("The selected Wallpaper Alchemy category has no desktop wallpapers")
            }
        }
    }

    static let wallpaperAlchemyApiBaseUrl = URL(string: "https://server.wallpaperalchemy.com")!
    static let wallpaperAlchemySiteBaseUrl = URL(string: "https://www.wallpaperalchemy.com")!
    /// 每日轮换最多覆盖下载排行的前若干页，避免轮换到冷门图片。
    static let wallpaperAlchemyMaximumRotationPages = 10
    /// 每次更新获取的壁纸数量。
    static let wallpaperAlchemyPageSize = 8
    /// 按间隔自动更换时只在下载排行前若干张中循环，与每日轮换覆盖的范围一致，也限制了占用的磁盘空间。
    static let wallpaperAlchemyRotationPoolSize = wallpaperAlchemyMaximumRotationPages * wallpaperAlchemyPageSize

    /// 下载量排行的桌面壁纸列表，与站点"最多下载 + 台式机"筛选一致。
    /// - Parameters:
    ///   - page: 从 1 开始的页码。
    ///   - categoryID: 站点分类编号，nil 表示不限分类。
    static func wallpaperAlchemyListUrl(
        numberOfImages: Int,
        locale: String,
        page: Int = 1,
        categoryID: Int? = nil
    ) -> URL {
        var components = URLComponents(
            url: wallpaperAlchemyApiBaseUrl.appendingPathComponent("api/v1/wallpapers"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [
            URLQueryItem(name: "page", value: String(max(1, page))),
            URLQueryItem(name: "perPage", value: String(numberOfImages)),
            URLQueryItem(name: "device", value: "desktop"),
            URLQueryItem(name: "sort", value: "downloads"),
            URLQueryItem(name: "locale", value: locale)
        ]
        if let categoryID {
            components.queryItems?.append(URLQueryItem(name: "tag", value: String(categoryID)))
        }
        return components.url!
    }

    /// 只取有桌面壁纸的分类并按下载量排序，热门分类排在前面；不加设备条件会混入只有手机壁纸或空的分类。
    static func wallpaperAlchemyCategoriesUrl(locale: String) -> URL {
        var components = URLComponents(
            url: wallpaperAlchemyApiBaseUrl.appendingPathComponent("api/v1/tags"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [
            URLQueryItem(name: "page", value: "1"),
            URLQueryItem(name: "perPage", value: "1000"),
            URLQueryItem(name: "device", value: "desktop"),
            URLQueryItem(name: "sort", value: "downloads"),
            URLQueryItem(name: "locale", value: locale)
        ]
        return components.url!
    }

    /// 以本地日历的天数作为轮换序号，同一天内多次更新得到同一页。
    static func wallpaperAlchemyRotationDay(
        for date: Date = Date(),
        calendar: Calendar = .current
    ) -> Int {
        let startOfDay = calendar.startOfDay(for: date)
        let reference = calendar.startOfDay(for: Date(timeIntervalSince1970: 0))
        return calendar.dateComponents([.day], from: reference, to: startOfDay).day ?? 0
    }

    /// 计算当天应请求的页码；总页数未知时先按最大轮换页数计算。
    static func wallpaperAlchemyRotationPage(day: Int, totalPages: Int? = nil) -> Int {
        var pageCount = wallpaperAlchemyMaximumRotationPages
        if let totalPages, totalPages > 0 {
            pageCount = min(pageCount, totalPages)
        }
        let index = ((day % pageCount) + pageCount) % pageCount
        return index + 1
    }

    /// 下载当天轮换到的一页壁纸；分类图片不足时改为在实际页数内轮换。
    static func downloadWallpaperAlchemyEntries(
        numberOfImages: Int,
        locale: String,
        categoryID: Int? = nil,
        rotationDay: Int = wallpaperAlchemyRotationDay()
    ) async throws -> [WallpaperAlchemyEntry] {
        let page = wallpaperAlchemyRotationPage(day: rotationDay)
        let response = try await downloadJson(
            WallpaperAlchemyResponse<WallpaperAlchemyEntry>.self,
            from: wallpaperAlchemyListUrl(
                numberOfImages: numberOfImages,
                locale: locale,
                page: page,
                categoryID: categoryID
            )
        )
        if response.data.data.isEmpty == false {
            return response.data.data
        }

        let totalPages = response.data.pageInfo?.totalPages ?? 0
        guard totalPages > 0 else {
            throw WallpaperAlchemyError.noDesktopWallpapers
        }
        let fallbackPage = wallpaperAlchemyRotationPage(day: rotationDay, totalPages: totalPages)
        guard fallbackPage != page else {
            throw WallpaperAlchemyError.noDesktopWallpapers
        }
        let fallbackEntries = try await downloadJson(
            WallpaperAlchemyResponse<WallpaperAlchemyEntry>.self,
            from: wallpaperAlchemyListUrl(
                numberOfImages: numberOfImages,
                locale: locale,
                page: fallbackPage,
                categoryID: categoryID
            )
        ).data.data
        guard fallbackEntries.isEmpty == false else {
            throw WallpaperAlchemyError.noDesktopWallpapers
        }
        return fallbackEntries
    }

    /// 把自动更换的名次限制在轮换范围内；分类图片少于轮换范围时在实际数量内循环。
    /// - Parameters:
    ///   - position: 期望的名次，从 0 开始，可超出范围。
    ///   - totalItems: 分类中的桌面壁纸数量，未知时为 nil。
    static func wallpaperAlchemyRotationPosition(_ position: Int, totalItems: Int? = nil) -> Int {
        var poolSize = wallpaperAlchemyRotationPoolSize
        if let totalItems, totalItems > 0 {
            poolSize = min(poolSize, totalItems)
        }
        return ((position % poolSize) + poolSize) % poolSize
    }

    /// 下载下载量排行中指定名次的单张桌面壁纸，用于按间隔自动更换。
    /// - Returns: 实际使用的名次（超出分类图片数时已回绕）与对应壁纸。
    static func downloadWallpaperAlchemyEntry(
        at position: Int,
        locale: String,
        categoryID: Int? = nil
    ) async throws -> (position: Int, entry: WallpaperAlchemyEntry) {
        let requestedPosition = wallpaperAlchemyRotationPosition(position)
        let response = try await downloadJson(
            WallpaperAlchemyResponse<WallpaperAlchemyEntry>.self,
            from: wallpaperAlchemyListUrl(
                numberOfImages: 1,
                locale: locale,
                page: requestedPosition + 1,
                categoryID: categoryID
            )
        )
        if let entry = response.data.data.first {
            return (requestedPosition, entry)
        }

        let totalItems = response.data.pageInfo?.totalItems ?? 0
        guard totalItems > 0 else {
            throw WallpaperAlchemyError.noDesktopWallpapers
        }
        let wrappedPosition = wallpaperAlchemyRotationPosition(position, totalItems: totalItems)
        guard wrappedPosition != requestedPosition else {
            throw WallpaperAlchemyError.noDesktopWallpapers
        }
        let wrappedResponse = try await downloadJson(
            WallpaperAlchemyResponse<WallpaperAlchemyEntry>.self,
            from: wallpaperAlchemyListUrl(
                numberOfImages: 1,
                locale: locale,
                page: wrappedPosition + 1,
                categoryID: categoryID
            )
        )
        guard let entry = wrappedResponse.data.data.first else {
            throw WallpaperAlchemyError.noDesktopWallpapers
        }
        return (wrappedPosition, entry)
    }

    /// 检查分类是否有桌面壁纸；站点上不少分类只有手机壁纸或尚无图片。
    static func wallpaperAlchemyCategoryHasDesktopWallpapers(categoryID: Int, locale: String) async throws -> Bool {
        let response = try await downloadJson(
            WallpaperAlchemyResponse<WallpaperAlchemyEntry>.self,
            from: wallpaperAlchemyListUrl(numberOfImages: 1, locale: locale, page: 1, categoryID: categoryID)
        )
        return response.data.data.isEmpty == false
    }

    static func downloadWallpaperAlchemyCategories(locale: String) async throws -> [WallpaperAlchemyCategory] {
        return try await downloadJson(
            WallpaperAlchemyResponse<WallpaperAlchemyCategory>.self,
            from: wallpaperAlchemyCategoriesUrl(locale: locale)
        ).data.data
    }

    static func downloadJson<T: Decodable>(_ type: T.Type, from url: URL, headers: [String: String] = [:]) async throws -> T {
        let response = try await downloadData(from: url, headers: headers)
        try validateContentType(response.urlResponse, prefixes: ["application/json", "text/json", "application/vnd.github+json"])
        return try JSONDecoder().decode(type, from: response.data)
    }
    
    static func downloadText(from url: URL) async throws -> String {
        let response = try await downloadData(from: url)
        guard let text = String(data: response.data, encoding: .utf8) else {
            throw Error.invalidText
        }
        return text
    }

    static func downloadImage(from url: URL) async throws -> Data {
        let response = try await downloadData(from: url)
        try validateContentType(response.urlResponse, prefixes: ["image/"])
        guard isValidImageData(response.data) else {
            throw Error.invalidImage
        }
        return response.data
    }

    static func isValidImageData(_ data: Data) -> Bool {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return false }
        return CGImageSourceCreateImageAtIndex(source, 0, nil) != nil
    }

    static func downloadPackage(from url: URL) async throws -> Data {
        let response = try await downloadData(from: url)
        guard isValidInstallerPackage(response.data) else {
            throw Error.invalidPackage
        }
        return response.data
    }

    static func isValidInstallerPackage(_ data: Data) -> Bool {
        // Flat .pkg installers are XAR archives and begin with the ASCII magic `xar!`.
        return data.starts(with: [0x78, 0x61, 0x72, 0x21])
    }
}
