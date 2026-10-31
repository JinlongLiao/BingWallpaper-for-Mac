import Foundation
import CryptoKit
import ImageIO
import OSLog

private let logger = Logger(
    subsystem: Logging.subsystem,
    category: Logging.Category.FileHandler.rawValue
)

private final class WallpaperFileValidationCache: @unchecked Sendable {
    private struct Fingerprint: Equatable {
        let modificationDate: Date?
        let fileSize: Int?
    }

    private let lock = NSLock()
    private var fingerprints: [String: Fingerprint] = [:]

    func isKnownValid(_ url: URL, fingerprint: (Date?, Int?)) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return fingerprints[url.path] == Fingerprint(
            modificationDate: fingerprint.0,
            fileSize: fingerprint.1
        )
    }

    func markValid(_ url: URL, fingerprint: (Date?, Int?)) {
        lock.lock()
        fingerprints[url.path] = Fingerprint(
            modificationDate: fingerprint.0,
            fileSize: fingerprint.1
        )
        lock.unlock()
    }

    func invalidate(_ url: URL) {
        lock.lock()
        fingerprints.removeValue(forKey: url.path)
        lock.unlock()
    }
}

class FileHandler {
    private static let validationCache = WallpaperFileValidationCache()

    /// 主线程使用的内容摘要缓存；文件修改时间或大小变化后重新计算。
    @MainActor
    private static var wallpaperContentDigests: [URL: (Date, Int, String)] = [:]

    /// 返回文件内容标识供菜单去重；读取失败时保留原条目，不影响壁纸浏览。
    /// 摘要按文件属性缓存，避免每次打开菜单重新读取全部图片。
    @MainActor
    static func wallpaperContentDigest(at url: URL) -> String? {
        do {
            return try withWallpaperDirectoryAccess { _ in
                // URL 会缓存 resourceValues；每次创建新 URL，才能发现原路径的文件已被替换。
                let currentURL = URL(fileURLWithPath: url.path)
                let values = try currentURL.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
                if let modifiedAt = values.contentModificationDate,
                   let size = values.fileSize,
                   let cached = wallpaperContentDigests[url],
                   cached.0 == modifiedAt, cached.1 == size {
                    return cached.2
                }
                let data = try Data(contentsOf: url, options: .mappedIfSafe)
                let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                if let modifiedAt = values.contentModificationDate, let size = values.fileSize {
                    wallpaperContentDigests[url] = (modifiedAt, size, digest)
                }
                return digest
            }
        } catch {
            wallpaperContentDigests.removeValue(forKey: url)
            logger.error("Failed to read wallpaper content digest at \(url.path, privacy: .public): \(String(reflecting: error), privacy: .public)")
            return nil
        }
    }

    static func usersPictureDirectory() -> String {
        guard let picturesDirectory = NSSearchPathForDirectoriesInDomains(.picturesDirectory, .userDomainMask, true).first else {
            logger.error("Couldn't find picture directory of user")
            return FileManager.default.homeDirectoryForCurrentUser.path
        }
        
        return picturesDirectory
    }
    
    static func defaultBingWallpaperDirectory() -> String {
        return usersPictureDirectory() + "/bing-wallpapers/"
    }
    
    static func defaultBingWallpaperDirectory() -> URL {
        return URL(fileURLWithPath: defaultBingWallpaperDirectory(), isDirectory: true)
    }

    static func wallpaperDirectory() -> URL {
        return Settings().imageDownloadPath
    }

    @discardableResult
    static func withWallpaperDirectoryAccess<T>(_ operation: (URL) throws -> T) rethrows -> T {
        try withWallpaperDirectoryAccess(at: wallpaperDirectory(), operation)
    }

    @discardableResult
    static func withWallpaperDirectoryAccess<T>(
        at directory: URL,
        _ operation: (URL) throws -> T
    ) rethrows -> T {
        let didStartAccess = directory.startAccessingSecurityScopedResource()
        defer {
            if didStartAccess {
                directory.stopAccessingSecurityScopedResource()
            }
        }
        return try operation(directory)
    }
    
    static func createWallpaperFolderIfNeeded() {
        do {
            try withWallpaperDirectoryAccess { directory in
                if FileManager.default.fileExists(atPath: directory.path) { return }
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            }
        } catch {
            logger.error("Failed to create bing-wallpapers folder with error: \(error.localizedDescription, privacy: .public)")
        }
    }

    static func migrateLegacyAutomaticWallpaperFiles(_ descriptors: [ImageDescriptor]) {
        do {
            try withWallpaperDirectoryAccess { directory in
                for descriptor in descriptors where descriptor.marketCode == nil {
                    let legacyURL = directory.appendingPathComponent(
                        Image.legacyAutomaticFileName(startDate: descriptor.startDate)
                    )
                    let destinationURL = directory.appendingPathComponent(descriptor.image.fileName)
                    guard FileManager.default.fileExists(atPath: legacyURL.path),
                          FileManager.default.fileExists(atPath: destinationURL.path) == false else {
                        continue
                    }
                    validationCache.invalidate(legacyURL)
                    validationCache.invalidate(destinationURL)
                    try FileManager.default.moveItem(at: legacyURL, to: destinationURL)
                }
            }
        } catch {
            logger.error("Failed to migrate legacy automatic wallpaper files: \(error.localizedDescription, privacy: .public)")
        }
    }
    
    static func saveImageDataToDisk(imageData: Data, toUrl: URL) throws {
        try saveImageDataToDisk(
            imageData: imageData,
            toUrl: toUrl,
            wallpaperDirectory: wallpaperDirectory()
        )
    }

    static func saveImageDataToDisk(
        imageData: Data,
        toUrl: URL,
        wallpaperDirectory: URL
    ) throws {
        validationCache.invalidate(toUrl)
        try withWallpaperDirectoryAccess(at: wallpaperDirectory) { _ in
            try imageData.write(to: toUrl, options: .atomic)
        }
    }

    static func loadImageDataFromDisk(at url: URL) throws -> Data {
        try loadImageDataFromDisk(at: url, wallpaperDirectory: wallpaperDirectory())
    }

    static func loadImageDataFromDisk(at url: URL, wallpaperDirectory: URL) throws -> Data {
        try withWallpaperDirectoryAccess(at: wallpaperDirectory) { _ in
            try Data(contentsOf: url)
        }
    }

    static func wallpaperFileExists(at url: URL) -> Bool {
        return withWallpaperDirectoryAccess { _ in
            guard FileManager.default.fileExists(atPath: url.path) else {
                validationCache.invalidate(url)
                return false
            }
            let fileSize = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize
            return (fileSize ?? 0) > 0
        }
    }

    static func wallpaperFileIsValid(at url: URL, wallpaperDirectory: URL) -> Bool {
        withWallpaperDirectoryAccess(at: wallpaperDirectory) { _ in
            guard FileManager.default.fileExists(atPath: url.path) else {
                validationCache.invalidate(url)
                return false
            }
            let resourceValues = try? url.resourceValues(forKeys: [
                .contentModificationDateKey,
                .fileSizeKey
            ])
            let fingerprint = (resourceValues?.contentModificationDate, resourceValues?.fileSize)
            guard (fingerprint.1 ?? 0) > 0 else { return false }
            if validationCache.isKnownValid(url, fingerprint: fingerprint) {
                return true
            }
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return false }
            guard CGImageSourceCopyPropertiesAtIndex(source, 0, nil) != nil else { return false }
            validationCache.markValid(url, fingerprint: fingerprint)
            return true
        }
    }
    
    static func getSavedImages() -> [URL] {
        do {
            return try withWallpaperDirectoryAccess { directory in
                try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)
            }
        } catch {
            logger.error("Failed to list saved images: \(error.localizedDescription, privacy: .public)")
            return []
        }
    }
    
    static func removeImageFromDisk(imagePath: URL) {
        do {
            validationCache.invalidate(imagePath)
            return try withWallpaperDirectoryAccess { _ in
                try FileManager.default.removeItem(at: imagePath)
            }
        } catch {
            logger.error("Failed to remove image at \(imagePath.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return
        }
    }
    
    static func deleteImages(fileNames: Set<String>) {
        withWallpaperDirectoryAccess { directory in
            deleteImages(fileNames: fileNames, from: directory)
        }
    }

    static func deleteImages(
        fileNames: Set<String>,
        from directory: URL,
        fileManager: FileManager = .default
    ) {
        for fileName in fileNames {
            // Only accept a single path component. The names currently come from
            // persisted wallpaper descriptors, but this keeps cleanup contained
            // even if that data is ever corrupted.
            guard URL(fileURLWithPath: fileName).lastPathComponent == fileName else {
                logger.error("Refusing to delete unsafe wallpaper file name: \(fileName, privacy: .public)")
                continue
            }

            let fileURL = directory.appendingPathComponent(fileName, isDirectory: false)
            do {
                if fileManager.fileExists(atPath: fileURL.path) {
                    validationCache.invalidate(fileURL)
                    try fileManager.removeItem(at: fileURL)
                }
            } catch {
                logger.error("Failed to remove image at \(fileURL.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
    }
    
    static func savePkgInstallerToDisk(pkgInstaller: Data, appVersion: String) throws -> URL {
        let temporaryDirectoryUrl = pkgInstallerPathUrl(appVersion: appVersion)
        try pkgInstaller.write(to: temporaryDirectoryUrl, options: .atomic)
        return temporaryDirectoryUrl
    }
    
    static func pkgInstallerPathUrl(appVersion: String) -> URL {
        let allowedCharacters = CharacterSet.alphanumerics.union(
            CharacterSet(charactersIn: ".-_")
        )
        let sanitizedVersion = appVersion.unicodeScalars.map {
            allowedCharacters.contains($0) ? String($0) : "-"
        }.joined()
        let safeVersion = sanitizedVersion.isEmpty
            ? "update"
            : String(sanitizedVersion.prefix(80))
        var temporaryDirectoryUrl = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        temporaryDirectoryUrl.appendPathComponent(
            "BingWallpaper_\(safeVersion).pkg",
            isDirectory: false
        )
        return temporaryDirectoryUrl
    }
}
