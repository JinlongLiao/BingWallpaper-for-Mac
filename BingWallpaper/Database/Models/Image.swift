//
//  Image.swift
//  BingWallpaper
//
//  Created by Laurenz Lazarus on 23.03.24.
//

import Foundation

class Image {
    enum Error: Swift.Error {
        case missingDescriptor
    }
    
    let fileName: String
    private weak var descriptor: ImageDescriptor?

    var downloadPath: URL {
        return FileHandler.wallpaperDirectory().appendingPathComponent(fileName)
    }
    
    init(descriptor: ImageDescriptor) {
        self.descriptor = descriptor
        self.fileName = Self.fileName(
            startDate: descriptor.startDate,
            marketCode: descriptor.marketCode,
            imageIdentity: ImageDescriptor.usesImageIdentity(marketCode: descriptor.marketCode)
                ? ImageDescriptor.imageIdentity(for: descriptor.imageUrl)
                : nil,
            fileExtension: descriptor.imageUrl.pathExtension
        )
    }

    /// Wallpaper Alchemy 保留原始图片格式，其余来源一律保存为 jpg。
    static let supportedFileExtensions: Set<String> = ["jpg", "jpeg", "png", "heic", "webp"]

    static func fileName(
        startDate: String,
        marketCode: String?,
        imageIdentity: String? = nil,
        fileExtension: String? = nil
    ) -> String {
        let safeDate = safeFileNameComponent(startDate, expectedDate: true)
        if marketCode == WallpaperChannel.wallpaperAlchemyCode, let imageIdentity {
            let safeIdentity = safeFileNameComponent(imageIdentity, expectedDate: false)
            let normalizedExtension = fileExtension?.lowercased() ?? ""
            let safeExtension = supportedFileExtensions.contains(normalizedExtension)
                ? normalizedExtension
                : "jpg"
            return "\(WallpaperChannel.wallpaperAlchemyCode)_\(safeIdentity).\(safeExtension)"
        }
        guard let marketCode else {
            guard let imageIdentity else { return legacyAutomaticFileName(startDate: startDate) }
            let safeIdentity = safeFileNameComponent(imageIdentity, expectedDate: false)
            return "automatic_\(safeDate)_\(safeIdentity).jpg"
        }
        let safeMarket = safeFileNameComponent(marketCode, expectedDate: false)
        return safeMarket + "_" + safeDate + ".jpg"
    }

    static func legacyAutomaticFileName(startDate: String) -> String {
        return safeFileNameComponent(startDate, expectedDate: true) + ".jpg"
    }

    private static func safeFileNameComponent(_ value: String, expectedDate: Bool) -> String {
        let isExpectedValue: Bool
        if expectedDate {
            isExpectedValue = ImageDescriptor.isValidBingDate(value)
        } else {
            let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
            isExpectedValue = value.isEmpty == false && value.unicodeScalars.allSatisfy {
                allowed.contains($0)
            }
        }
        guard isExpectedValue else {
            let encodedValue = value.utf8
                .prefix(64)
                .map { String(format: "%02x", $0) }
                .joined()
            return "invalid-" + (encodedValue.isEmpty ? "empty" : encodedValue)
        }
        return value
    }
    
    @MainActor
    func loadFromDisk() async throws -> Data {
        let downloadPath = downloadPath
        let wallpaperDirectory = FileHandler.wallpaperDirectory()
        return try await Task.detached(priority: .userInitiated) {
            try FileHandler.loadImageDataFromDisk(
                at: downloadPath,
                wallpaperDirectory: wallpaperDirectory
            )
        }.value
    }
    
    @MainActor
    func downloadAndSaveToDisk() async throws {
        guard let descriptor else {
            throw Error.missingDescriptor
        }
        let downloadPath = downloadPath
        let wallpaperDirectory = FileHandler.wallpaperDirectory()
        let imageData = try await DownloadManager.downloadImage(from: descriptor.imageUrl)
        try await Task.detached(priority: .utility) {
            try FileHandler.saveImageDataToDisk(
                imageData: imageData,
                toUrl: downloadPath,
                wallpaperDirectory: wallpaperDirectory
            )
        }.value
    }
    
    static func isSavedToDisk(descriptor: ImageDescriptor) -> Bool {
        return descriptor.image.isOnDisk()
    }
    
    func isOnDisk() -> Bool {
        return FileHandler.wallpaperFileExists(at: downloadPath)
    }

    @MainActor
    func isValidOnDisk() async -> Bool {
        let downloadPath = downloadPath
        let wallpaperDirectory = FileHandler.wallpaperDirectory()
        return await Task.detached(priority: .utility) {
            FileHandler.wallpaperFileIsValid(
                at: downloadPath,
                wallpaperDirectory: wallpaperDirectory
            )
        }.value
    }
}
