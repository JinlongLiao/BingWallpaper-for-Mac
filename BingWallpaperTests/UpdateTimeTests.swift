//
//  UpdateTimeTests.swift
//  BingWallpaperTests
//
//  Created by Laurenz Lazarus on 31.10.22.
//

import XCTest
@testable import BingWallpaper

final class UpdateTimeTests: XCTestCase {
    
    override func setUpWithError() throws { }
    
    override func tearDownWithError() throws { }
    
    func testUpdateAfter3h() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let before3h = now.addingTimeInterval(-3 * 3600)
        
        XCTAssertTrue(UpdateScheduleManager.isUpdateNecessary(lastUpdate: before3h, now: now))
    }
    
    func testUpdateAfter2h() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let before2h = now.addingTimeInterval(-2 * 3600)
        
        XCTAssertFalse(UpdateScheduleManager.isUpdateNecessary(lastUpdate: before2h, now: now))
    }

}

final class BingMarketTests: XCTestCase {
    func testAutomaticMarketDoesNotAddMarketQuery() {
        let url = DownloadManager.imageArchiveUrl(numberOfImages: 8, marketCode: nil)
        let queryItems = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems

        XCTAssertNil(queryItems?.first(where: { $0.name == "mkt" }))
    }

    func testExplicitMarketAddsMarketQuery() {
        let url = DownloadManager.imageArchiveUrl(numberOfImages: 8, marketCode: "zh-CN")
        let queryItems = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems

        XCTAssertEqual(queryItems?.first(where: { $0.name == "mkt" })?.value, "zh-CN")
    }

    func testSupportedMarketCodesAreUniqueAndWellFormed() {
        let codes = BingMarketOption.supportedCodes

        XCTAssertEqual(Set(codes).count, codes.count)
        XCTAssertTrue(codes.allSatisfy { $0.range(of: "^[a-z]{2}-[A-Z]{2}$", options: .regularExpression) != nil })
    }
}

final class DownloadValidationTests: XCTestCase {
    func testRejectsHttpErrorStatus() {
        let response = HTTPURLResponse(
            url: URL(string: "https://example.com/image.jpg")!,
            statusCode: 404,
            httpVersion: nil,
            headerFields: nil
        )!

        XCTAssertThrowsError(try DownloadManager.validateHttpResponse(response))
    }

    func testClassifiesOnlyMissingHTTPResourcesAsPermanent() {
        XCTAssertTrue(DownloadManager.isPermanentlyUnavailableResourceError(
            DownloadManager.Error.httpStatus(404)
        ))
        XCTAssertTrue(DownloadManager.isPermanentlyUnavailableResourceError(
            DownloadManager.Error.httpStatus(410)
        ))
        XCTAssertFalse(DownloadManager.isPermanentlyUnavailableResourceError(
            DownloadManager.Error.httpStatus(500)
        ))
        XCTAssertFalse(DownloadManager.isPermanentlyUnavailableResourceError(
            URLError(.timedOut)
        ))
    }

    func testRecognizesFlatInstallerPackageMagic() {
        XCTAssertTrue(DownloadManager.isValidInstallerPackage(Data([0x78, 0x61, 0x72, 0x21, 0x00])))
        XCTAssertFalse(DownloadManager.isValidInstallerPackage(Data("<html>not a package</html>".utf8)))
    }

    func testRejectsInvalidImageData() {
        XCTAssertFalse(DownloadManager.isValidImageData(Data("<html>not an image</html>".utf8)))
    }

    func testSha256ChecksumVerification() {
        let packageData = Data("abc".utf8)
        let checksum = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad  BingWallpaper.pkg\n"

        XCTAssertTrue(AppUpdateManager.verifyChecksum(packageData: packageData, checksumText: checksum))
        XCTAssertFalse(AppUpdateManager.verifyChecksum(packageData: packageData, checksumText: String(repeating: "0", count: 64)))
    }

    func testReleaseAPIUsesConfiguredRepository() {
        XCTAssertEqual(
            AppUpdateManager.latestReleaseAPIURL(repository: "ader47/BingWallpaper-for-Mac")?.absoluteString,
            "https://api.github.com/repos/ader47/BingWallpaper-for-Mac/releases/latest"
        )
        XCTAssertNil(AppUpdateManager.latestReleaseAPIURL(repository: "../unexpected"))
    }

    func testInstallerPathStaysInsideTemporaryDirectory() {
        let installerURL = FileHandler.pkgInstallerPathUrl(
            appVersion: "v1/../../outside"
        )
        let temporaryDirectory = URL(
            fileURLWithPath: NSTemporaryDirectory(),
            isDirectory: true
        )

        XCTAssertEqual(
            installerURL.deletingLastPathComponent().standardizedFileURL,
            temporaryDirectory.standardizedFileURL
        )
        XCTAssertEqual(installerURL.lastPathComponent, "BingWallpaper_v1-..-..-outside.pkg")
    }
}

final class BingMetadataValidationTests: XCTestCase {
    func testAcceptsValidBingMetadataAndBuildsUHDURL() throws {
        let metadata = try ImageDescriptor.validatedMetadata(from: validEntry())

        XCTAssertEqual(metadata.startDate, "20250102")
        XCTAssertEqual(metadata.endDate, "20250103")
        XCTAssertEqual(metadata.imageURL.scheme, "https")
        XCTAssertEqual(metadata.imageURL.host, "www.bing.com")
        XCTAssertTrue(metadata.imageURL.absoluteString.contains("UHD"))
    }

    func testRejectsInvalidOrImpossibleDates() {
        XCTAssertThrowsError(try ImageDescriptor.validatedMetadata(
            from: validEntry(startDate: "../../x")
        ))
        XCTAssertThrowsError(try ImageDescriptor.validatedMetadata(
            from: validEntry(startDate: "20250231")
        ))
    }

    func testRejectsUntrustedImageAndCopyrightURLs() {
        XCTAssertThrowsError(try ImageDescriptor.validatedMetadata(
            from: validEntry(imageURL: "//example.com/wallpaper.jpg")
        ))
        XCTAssertThrowsError(try ImageDescriptor.validatedMetadata(
            from: validEntry(copyrightURL: "https://example.com/details")
        ))
    }

    func testMalformedPersistedValuesCannotCreateNestedFilePaths() {
        let fileName = Image.fileName(startDate: "../../escape", marketCode: "../bad")

        XCTAssertEqual(URL(fileURLWithPath: fileName).lastPathComponent, fileName)
        XCTAssertFalse(fileName.contains("/"))
    }

    func testChangedAutomaticRegionImageRequiresSameDayRefresh() {
        let previousURL = URL(string: "https://www.bing.com/th?id=OHR.RegionA_UHD.jpg")!
        let newURL = URL(string: "https://www.bing.com/th?id=OHR.RegionB_UHD.jpg")!

        XCTAssertTrue(ImageDescriptor.metadataRequiresImageRefresh(
            currentImageURL: previousURL,
            newImageURL: newURL
        ))
        XCTAssertFalse(ImageDescriptor.metadataRequiresImageRefresh(
            currentImageURL: previousURL,
            newImageURL: previousURL
        ))
    }

    private func validEntry(
        startDate: String = "20250102",
        imageURL: String = "/th?id=OHR.Example_1920x1080.jpg",
        copyrightURL: String = "https://www.bing.com/search?q=example"
    ) -> DownloadManager.ImageEntry {
        return DownloadManager.ImageEntry(
            url: imageURL,
            enddate: "20250103",
            startdate: startDate,
            copyright: "Example (© Photographer)",
            copyrightlink: copyrightURL
        )
    }
}

final class ImageDirectorySettingsTests: XCTestCase {
    func testKeepImageSelectionMapsToActualImageCount() {
        let suiteName = "BingWallpaperTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = Settings(defaults: defaults)

        settings.keepImageDuration = KeepImageDuration.five.rawValue
        XCTAssertEqual(settings.maximumStoredImageCount(), 5)
        settings.keepImageDuration = KeepImageDuration.onehundred.rawValue
        XCTAssertEqual(settings.maximumStoredImageCount(), 100)
        settings.keepImageDuration = KeepImageDuration.infinite.rawValue
        XCTAssertNil(settings.maximumStoredImageCount())
    }

    func testSecurityScopedBookmarkRoundTrip() throws {
        let suiteName = "BingWallpaperTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BingWallpaperTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let settings = Settings(defaults: defaults)
        try settings.setImageDownloadPath(directory)

        XCTAssertEqual(settings.imageDownloadPath.standardizedFileURL, directory.standardizedFileURL)
    }
}

@MainActor
final class DatabaseTests: XCTestCase {
    /// 自动地区的不同语言编号指向相同内容时，只保留最近一次看到的版本。
    func testDuplicateRegionalWallpapersKeepLatestVersion() throws {
        let database = Database(inMemory: true)
        let update = try database.updateImageDescriptors(from: [
            makeEntry(startDate: "20261030", imageURL: "/th?id=OHR.Church_ZH-CN123_UHD.jpg"),
            makeEntry(startDate: "20261030", imageURL: "/th?id=OHR.Church_JA-JP456_UHD.jpg")
        ], marketCode: nil)
        let descriptors = update.descriptors
        XCTAssertEqual(descriptors.count, 2)

        let distinct = ImageDescriptor.distinctWallpaperDescriptors(from: descriptors) { _ in
            "same-file-content"
        }

        XCTAssertEqual(distinct.map(\.wallpaperIdentifier), [descriptors[1].wallpaperIdentifier])
        XCTAssertEqual(database.allImageDescriptors().count, 2)
    }

    /// 去重后仍能定位固定或收藏中选中的版本，文件不可读的条目不被误删。
    func testDuplicateWallpapersPreserveSelectedVersionAndUnreadableEntries() throws {
        let database = Database(inMemory: true)
        let update = try database.updateImageDescriptors(from: [
            makeEntry(startDate: "20261028"),
            makeEntry(startDate: "20261029"),
            makeEntry(startDate: "20261030")
        ], marketCode: "zh-CN")
        let descriptors = update.descriptors
        let selectedID = descriptors[0].wallpaperIdentifier
        let distinct = ImageDescriptor.distinctWallpaperDescriptors(
            from: descriptors,
            preferredWallpaperID: selectedID
        ) { descriptor in
            descriptor.startDate == "20261030" ? nil : "same-content"
        }

        XCTAssertEqual(distinct.map(\.wallpaperIdentifier), [selectedID, descriptors[2].wallpaperIdentifier])
    }

    /// 不同图片即使标题相同也不合并，保持原有浏览顺序。
    func testDifferentWallpaperContentsRemainVisibleInOrder() throws {
        let database = Database(inMemory: true)
        let update = try database.updateImageDescriptors(from: [
            makeEntry(startDate: "20261029"),
            makeEntry(startDate: "20261030")
        ], marketCode: "zh-CN")
        let distinct = ImageDescriptor.distinctWallpaperDescriptors(from: update.descriptors) {
            $0.startDate
        }
        XCTAssertEqual(distinct.map(\.startDate), ["20261029", "20261030"])
    }

    /// 摘要按真实字节计算，并在原路径被新内容覆盖后失效。
    func testWallpaperContentDigestTracksFileReplacement() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BingWallpaperDigestTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = directory.appendingPathComponent("zh-CN.jpg")
        let second = directory.appendingPathComponent("ja-JP.jpg")
        try Data("same-image".utf8).write(to: first)
        try Data("same-image".utf8).write(to: second)
        let digest = try XCTUnwrap(FileHandler.wallpaperContentDigest(at: first))
        XCTAssertEqual(FileHandler.wallpaperContentDigest(at: second), digest)
        try Data("different-image-content".utf8).write(to: first, options: .atomic)
        XCTAssertNotEqual(FileHandler.wallpaperContentDigest(at: first), digest)
        XCTAssertEqual(FileHandler.wallpaperContentDigest(at: second), digest)
    }

    /// 展示日期采用归档日，避免 UTC 起始日期使东亚当天壁纸显示为前一天。
    func testWallpaperInfoUsesArchiveDayWithoutChangingIdentity() throws {
        let database = Database(inMemory: true)
        let entry = DownloadManager.ImageEntry(
            url: "/th?id=OHR.FrankfurtHalloween_ZH-CN5998782698_1920x1080.jpg",
            enddate: "20261031",
            startdate: "20261030",
            copyright: "Frankfurt (© Example)",
            copyrightlink: "https://www.bing.com/search?q=Frankfurt"
        )
        let update = try database.updateImageDescriptors(from: [entry], marketCode: "zh-CN")
        let descriptor = try XCTUnwrap(update.descriptors.first)
        let expected = WallpaperImageInfo(
            description: entry.copyright,
            startDate: entry.enddate,
            marketCode: "zh-CN"
        )

        XCTAssertEqual(descriptor.imageInfo.date, expected.date)
        XCTAssertEqual(descriptor.startDate, "20261030")
        XCTAssertEqual(descriptor.wallpaperIdentifier, "zh-CN:20261030")
    }

    func testRejectsUpdateWhenEveryMetadataEntryIsInvalid() {
        let database = Database(inMemory: true)
        let invalidEntry = makeEntry(startDate: "../../invalid")

        XCTAssertThrowsError(try database.updateImageDescriptors(
            from: [invalidEntry],
            marketCode: "en-US"
        )) { error in
            guard case Database.Error.noValidMetadata = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertTrue(database.allImageDescriptors().isEmpty)
    }

    func testCountCleanupKeepsNewestImagesAndPreservedWallpaper() throws {
        let database = Database(inMemory: true)
        let entries = [
            makeEntry(startDate: "20250101"),
            makeEntry(startDate: "20250102"),
            makeEntry(startDate: "20250103"),
            makeEntry(startDate: "20250104")
        ]
        _ = try database.updateImageDescriptors(from: entries, marketCode: "en-US")
        let preservedID = ImageDescriptor.wallpaperIdentifier(
            startDate: "20250101",
            marketCode: "en-US"
        )

        let deletedFiles = try database.deleteImageDescriptors(
            exceedingMaximumCount: 2,
            preserving: [preservedID]
        )

        XCTAssertEqual(
            database.allImageDescriptors().map(\.startDate),
            ["20250101", "20250103", "20250104"]
        )
        XCTAssertEqual(deletedFiles, ["en-US_20250102.jpg"])
    }

    func testValidMetadataIsPersisted() throws {
        let database = Database(inMemory: true)

        let update = try database.updateImageDescriptors(
            from: [makeEntry(startDate: "20250102")],
            marketCode: "zh-CN"
        )

        XCTAssertEqual(update.descriptors.count, 1)
        XCTAssertEqual(database.allImageDescriptors().first?.marketCode, "zh-CN")
    }

    func testAutomaticRegionVariantsOnTheSameDateRemainDistinct() throws {
        let database = Database(inMemory: true)
        let firstEntry = makeEntry(
            startDate: "20250102",
            imageURL: "/th?id=OHR.RegionOne_1920x1080.jpg"
        )
        let secondEntry = makeEntry(
            startDate: "20250102",
            imageURL: "/th?id=OHR.RegionTwo_1920x1080.jpg"
        )

        _ = try database.updateImageDescriptors(from: [firstEntry], marketCode: nil)
        _ = try database.updateImageDescriptors(from: [secondEntry], marketCode: nil)

        let descriptors = database.allImageDescriptors(marketCode: nil)
        XCTAssertEqual(descriptors.count, 2)
        XCTAssertEqual(Set(descriptors.map(\.wallpaperIdentifier)).count, 2)
        XCTAssertEqual(Set(descriptors.map { $0.image.fileName }).count, 2)
    }

    func testChangedImageRemainsPendingUntilDownloadIsRecorded() throws {
        let database = Database(inMemory: true)
        let originalEntry = makeEntry(
            startDate: "20250102",
            imageURL: "/th?id=OHR.Original_1920x1080.jpg"
        )
        _ = try database.updateImageDescriptors(from: [originalEntry], marketCode: "en-US")
        let descriptor = try XCTUnwrap(database.allImageDescriptors().first)
        try database.markImageDownloadCompleted(for: descriptor)
        XCTAssertFalse(descriptor.requiresImageDownload)

        let changedEntry = makeEntry(
            startDate: "20250102",
            imageURL: "/th?id=OHR.Replacement_1920x1080.jpg"
        )
        let firstUpdate = try database.updateImageDescriptors(
            from: [changedEntry],
            marketCode: "en-US"
        )
        XCTAssertTrue(descriptor.requiresImageDownload)
        XCTAssertTrue(firstUpdate.wallpaperIDsRequiringDownload.contains(
            descriptor.wallpaperIdentifier
        ))

        let retryUpdate = try database.updateImageDescriptors(
            from: [changedEntry],
            marketCode: "en-US"
        )
        XCTAssertTrue(retryUpdate.wallpaperIDsRequiringDownload.contains(
            descriptor.wallpaperIdentifier
        ))

        try database.markImageDownloadCompleted(for: descriptor)
        XCTAssertFalse(descriptor.requiresImageDownload)
    }

    private func makeEntry(
        startDate: String,
        imageURL: String = "/th?id=OHR.Example_1920x1080.jpg"
    ) -> DownloadManager.ImageEntry {
        DownloadManager.ImageEntry(
            url: imageURL,
            enddate: nextDay(after: startDate),
            startdate: startDate,
            copyright: "Example (© Photographer)",
            copyrightlink: "https://www.bing.com/search?q=example"
        )
    }

    private func nextDay(after date: String) -> String {
        guard ImageDescriptor.isValidBingDate(date),
              let value = Int(date) else {
            return "20250102"
        }
        return String(value + 1)
    }
}

final class FileHandlerCleanupTests: XCTestCase {
    func testDeletesOnlyExplicitlyManagedWallpaperFiles() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BingWallpaperCleanupTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let managedFile = directory.appendingPathComponent("en-US_20250101.jpg")
        let unrelatedFile = directory.appendingPathComponent("vacation_20200101.png")
        try Data("managed".utf8).write(to: managedFile)
        try Data("personal".utf8).write(to: unrelatedFile)

        FileHandler.deleteImages(
            fileNames: [managedFile.lastPathComponent],
            from: directory
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: managedFile.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelatedFile.path))
    }

    func testRejectsFileNamesThatEscapeWallpaperDirectory() throws {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("BingWallpaperCleanupTests-\(UUID().uuidString)", isDirectory: true)
        let directory = parent.appendingPathComponent("wallpapers", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }

        let outsideFile = parent.appendingPathComponent("keep.jpg")
        try Data("personal".utf8).write(to: outsideFile)

        FileHandler.deleteImages(fileNames: ["../keep.jpg"], from: directory)

        XCTAssertTrue(FileManager.default.fileExists(atPath: outsideFile.path))
    }
}

final class WallpaperManagerTests: XCTestCase {
    func testEquivalentFileURLsMatch() {
        let currentURL = URL(fileURLWithPath: "/tmp/wallpapers/../wallpapers/current.jpg")
        let desiredURL = URL(fileURLWithPath: "/tmp/wallpapers/current.jpg")

        XCTAssertTrue(WallpaperManager.wallpaperURL(currentURL, matches: desiredURL))
    }

    func testDifferentFileURLsDoNotMatch() {
        let currentURL = URL(fileURLWithPath: "/tmp/wallpapers/previous.jpg")
        let desiredURL = URL(fileURLWithPath: "/tmp/wallpapers/current.jpg")

        XCTAssertFalse(WallpaperManager.wallpaperURL(currentURL, matches: desiredURL))
    }

    func testMissingCurrentURLDoesNotMatch() {
        let desiredURL = URL(fileURLWithPath: "/tmp/wallpapers/current.jpg")

        XCTAssertFalse(WallpaperManager.wallpaperURL(nil, matches: desiredURL))
    }

    func testAllDisplayModeTargetsEveryDisplay() {
        XCTAssertTrue(WallpaperManager.shouldApplyWallpaper(
            toDisplayIdentifier: nil,
            isMainDisplay: false,
            mode: .all,
            selectedDisplayIDs: []
        ))
    }

    func testMainDisplayModeTargetsOnlyMainDisplay() {
        XCTAssertTrue(WallpaperManager.shouldApplyWallpaper(
            toDisplayIdentifier: "main",
            isMainDisplay: true,
            mode: .main,
            selectedDisplayIDs: []
        ))
        XCTAssertFalse(WallpaperManager.shouldApplyWallpaper(
            toDisplayIdentifier: "secondary",
            isMainDisplay: false,
            mode: .main,
            selectedDisplayIDs: []
        ))
    }

    func testSelectedDisplayModeTargetsOnlySelectedIdentifiers() {
        let selectedDisplayIDs: Set<String> = ["secondary"]

        XCTAssertTrue(WallpaperManager.shouldApplyWallpaper(
            toDisplayIdentifier: "secondary",
            isMainDisplay: false,
            mode: .selected,
            selectedDisplayIDs: selectedDisplayIDs
        ))
        XCTAssertFalse(WallpaperManager.shouldApplyWallpaper(
            toDisplayIdentifier: "main",
            isMainDisplay: true,
            mode: .selected,
            selectedDisplayIDs: selectedDisplayIDs
        ))
    }
}

final class WallpaperDisplaySettingsTests: XCTestCase {
    func testDefaultsToAllDisplays() {
        withSettings { settings in
            XCTAssertEqual(settings.wallpaperDisplayMode, .all)
            XCTAssertTrue(settings.selectedWallpaperDisplayIDs.isEmpty)
        }
    }

    func testPersistsSelectedDisplays() {
        withSettings { settings in
            settings.wallpaperDisplayMode = .selected
            settings.selectedWallpaperDisplayIDs = ["display-b", "display-a"]

            XCTAssertEqual(settings.wallpaperDisplayMode, .selected)
            XCTAssertEqual(settings.selectedWallpaperDisplayIDs, ["display-a", "display-b"])
        }
    }

    private func withSettings(_ operation: (Settings) -> Void) {
        let suiteName = "BingWallpaperTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        operation(Settings(defaults: defaults))
    }
}

final class WallpaperAlchemyRotationSettingsTests: XCTestCase {
    func testWallpaperAlchemyRefreshIntervalDefaultsToOffAndPersists() {
        withSettings { settings in
            XCTAssertEqual(settings.wallpaperAlchemyRefreshInterval, .never)
            XCTAssertNil(settings.wallpaperAlchemyRefreshInterval.timeInterval)

            settings.wallpaperAlchemyRefreshInterval = .fiveMinutes
            XCTAssertEqual(settings.wallpaperAlchemyRefreshInterval, .fiveMinutes)
            XCTAssertEqual(settings.wallpaperAlchemyRefreshInterval.timeInterval, 300)
            XCTAssertEqual(
                WallpaperAlchemyRefreshInterval.allCases.compactMap(\.timeInterval),
                [60, 300, 600, 3600, 7200]
            )
        }
    }

    func testChangingWallpaperAlchemyCategoryRestartsRotation() {
        withSettings { settings in
            settings.wallpaperAlchemyCategory = DownloadManager.WallpaperAlchemyCategory(
                id: 7,
                name: "landscape",
                title: "风景"
            )
            settings.wallpaperAlchemyRotationPosition = 12

            // 同一分类只是换了语言名称，继续当前进度。
            settings.wallpaperAlchemyCategory = DownloadManager.WallpaperAlchemyCategory(
                id: 7,
                name: "landscape",
                title: "Landscape"
            )
            XCTAssertEqual(settings.wallpaperAlchemyRotationPosition, 12)

            settings.wallpaperAlchemyCategory = DownloadManager.WallpaperAlchemyCategory(
                id: 9,
                name: "cars",
                title: nil
            )
            XCTAssertEqual(settings.wallpaperAlchemyRotationPosition, 0)
        }
    }

    private func withSettings(_ operation: (Settings) -> Void) {
        let suiteName = "BingWallpaperTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        operation(Settings(defaults: defaults))
    }
}

final class UpdateStatusTests: XCTestCase {
    func testStatusMenuTitles() {
        let base = WallpaperUpdateStatus(
            phase: .idle,
            lastSuccessAt: nil,
            lastAttemptAt: nil,
            nextAttemptAt: nil,
            failure: nil,
            consecutiveFailures: 0
        )

        XCTAssertEqual(base.menuTitle, "Update Status: Up to Date")
        XCTAssertEqual(status(from: base, phase: .updating).menuTitle, "Update Status: Updating…")
        XCTAssertEqual(status(from: base, phase: .retrying).menuTitle, "Update Status: Failed — Retry Scheduled")
        XCTAssertEqual(status(from: base, phase: .failed).menuTitle, "Update Status: Failed")
    }

    func testRetryBackoffStartsAtThirtySecondsAndCapsAtThirtyMinutes() {
        XCTAssertEqual(UpdateManager.retryInterval(forFailureCount: 0), 30)
        XCTAssertEqual(UpdateManager.retryInterval(forFailureCount: 1), 30)
        XCTAssertEqual(UpdateManager.retryInterval(forFailureCount: 2), 60)
        XCTAssertEqual(UpdateManager.retryInterval(forFailureCount: 3), 120)
        XCTAssertEqual(UpdateManager.retryInterval(forFailureCount: 20), 30 * 60)
    }

    @MainActor
    func testManagerInitialStatusUsesPersistedLastSuccess() {
        let suiteName = "BingWallpaperTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let expectedDate = Date(timeIntervalSince1970: 1_700_000_000)
        let settings = Settings(defaults: defaults)
        settings.lastUpdate = expectedDate

        let manager = UpdateManager(settings: settings)

        XCTAssertEqual(manager.status.lastSuccessAt, expectedDate)
        XCTAssertEqual(manager.status.phase, .idle)
    }

    func testPartialImageAvailabilityDoesNotTriggerRetryLoop() {
        let transientError = DownloadManager.Error.httpStatus(500)

        XCTAssertFalse(UpdateManager.imageDownloadFailuresRequireRetry(
            hasAvailableImage: true,
            errors: [transientError]
        ))
        XCTAssertTrue(UpdateManager.imageDownloadFailuresRequireRetry(
            hasAvailableImage: false,
            errors: [transientError]
        ))
        XCTAssertFalse(UpdateManager.imageDownloadFailuresRequireRetry(
            hasAvailableImage: false,
            errors: [DownloadManager.Error.httpStatus(404)]
        ))
    }

    private func status(
        from status: WallpaperUpdateStatus,
        phase: WallpaperUpdatePhase
    ) -> WallpaperUpdateStatus {
        return WallpaperUpdateStatus(
            phase: phase,
            lastSuccessAt: status.lastSuccessAt,
            lastAttemptAt: status.lastAttemptAt,
            nextAttemptAt: status.nextAttemptAt,
            failure: status.failure,
            consecutiveFailures: status.consecutiveFailures
        )
    }
}

final class WallpaperImageInfoTests: XCTestCase {
    private let locale = Locale(identifier: "en_US")
    private let timeZone = TimeZone(secondsFromGMT: 0)!

    func testParsesTitleCopyrightDateAndRegion() {
        let info = WallpaperImageInfo(
            description: "Mountain lake (© Example Photographer)",
            startDate: "20250102",
            marketCode: "en-US",
            locale: locale,
            timeZone: timeZone
        )

        XCTAssertEqual(info.title, "Mountain lake")
        XCTAssertEqual(info.copyright, "© Example Photographer")
        XCTAssertEqual(info.date, "Jan 2, 2025")
        XCTAssertTrue(info.region.hasSuffix("(en-US)"))
    }

    func testKeepsParenthesesInsideTitle() {
        let info = WallpaperImageInfo(
            description: "Lake (North Shore) at dawn (© Example)",
            startDate: "20250102",
            marketCode: nil,
            locale: locale,
            timeZone: timeZone
        )

        XCTAssertEqual(info.title, "Lake (North Shore) at dawn")
        XCTAssertEqual(info.copyright, "© Example")
        XCTAssertEqual(info.region, "Automatic (Network Location)")
    }

    func testDescriptionWithoutTrailingCopyrightRemainsTitle() {
        let info = WallpaperImageInfo(
            description: "Lake on the North Shore",
            startDate: "not-a-date",
            marketCode: nil,
            locale: locale,
            timeZone: timeZone
        )

        XCTAssertEqual(info.title, "Lake on the North Shore")
        XCTAssertEqual(info.copyright, "")
        XCTAssertEqual(info.date, "not-a-date")
    }
}

final class FavoriteWallpaperSettingsTests: XCTestCase {
    func testFavoriteAndPinnedWallpaperSettingsRoundTrip() {
        withSettings { settings in
            settings.favoriteWallpaperIDs = ["en-US:20250102", "automatic:20250101"]
            settings.pinnedWallpaperID = "en-US:20250102"

            XCTAssertEqual(
                settings.favoriteWallpaperIDs,
                ["en-US:20250102", "automatic:20250101"]
            )
            XCTAssertEqual(settings.pinnedWallpaperID, "en-US:20250102")

            settings.pinnedWallpaperID = nil
            XCTAssertNil(settings.pinnedWallpaperID)
        }
    }

    func testWallpaperIdentifierIncludesMarket() {
        let automaticImageURL = URL(
            string: "https://www.bing.com/th?id=OHR.AutomaticExample_UHD.jpg"
        )!
        XCTAssertEqual(
            ImageDescriptor.wallpaperIdentifier(startDate: "20250102", marketCode: "zh-CN"),
            "zh-CN:20250102"
        )
        XCTAssertEqual(
            ImageDescriptor.wallpaperIdentifier(
                startDate: "20250102",
                marketCode: nil,
                imageURL: automaticImageURL
            ),
            "automatic:20250102:OHR.AutomaticExample_UHD.jpg"
        )
    }

    @MainActor
    func testMigratesLegacyAutomaticFavoritesAndPins() throws {
        let database = Database(inMemory: true)
        let entry = DownloadManager.ImageEntry(
            url: "/th?id=OHR.AutomaticExample_1920x1080.jpg",
            enddate: "20250103",
            startdate: "20250102",
            copyright: "Example (© Photographer)",
            copyrightlink: "https://www.bing.com/search?q=example"
        )
        let descriptor = try XCTUnwrap(database.updateImageDescriptors(
            from: [entry],
            marketCode: nil
        ).descriptors.first)

        withSettings { settings in
            let legacyID = "automatic:20250102"
            settings.favoriteWallpaperIDs = [legacyID]
            settings.pinnedWallpaperID = legacyID
            settings.wallpaperDisplayProfiles = [
                "display": WallpaperDisplayProfile(
                    pinMode: .pinned,
                    pinnedWallpaperID: legacyID
                )
            ]

            settings.migrateLegacyAutomaticWallpaperIdentifiers(using: [descriptor])

            XCTAssertEqual(settings.favoriteWallpaperIDs, [descriptor.wallpaperIdentifier])
            XCTAssertEqual(settings.pinnedWallpaperID, descriptor.wallpaperIdentifier)
            XCTAssertEqual(
                settings.wallpaperDisplayProfiles["display"]?.pinnedWallpaperID,
                descriptor.wallpaperIdentifier
            )
        }
    }

    func testResetClearsPinsWithoutLeavingPinnedProfiles() {
        withSettings { settings in
            settings.favoriteWallpaperIDs = ["en-US:20250102"]
            settings.pinnedWallpaperID = "en-US:20250102"
            settings.wallpaperDisplayProfiles = [
                "display": WallpaperDisplayProfile(
                    marketMode: .explicit,
                    marketCode: "en-US",
                    pinMode: .pinned,
                    pinnedWallpaperID: "en-US:20250102"
                )
            ]

            settings.resetWallpaperLibrarySelections()

            XCTAssertTrue(settings.favoriteWallpaperIDs.isEmpty)
            XCTAssertNil(settings.pinnedWallpaperID)
            XCTAssertEqual(
                settings.wallpaperDisplayProfiles["display"]?.pinMode,
                .followLatest
            )
            XCTAssertNil(settings.wallpaperDisplayProfiles["display"]?.pinnedWallpaperID)
            XCTAssertEqual(settings.wallpaperDisplayProfiles["display"]?.marketCode, "en-US")
        }
    }

    private func withSettings(_ operation: (Settings) -> Void) {
        let suiteName = "BingWallpaperTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        operation(Settings(defaults: defaults))
    }
}

final class WallpaperDisplayProfileTests: XCTestCase {
    /// 切换范围默认选择全部屏幕，用户改为当前屏幕后应持久保存。
    func testWallpaperSwitchingScopeDefaultsToAllAndPersistsCurrentDisplayChoice() {
        let suiteName = "BingWallpaperTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = Settings(defaults: defaults)
        XCTAssertTrue(settings.switchesAllDisplaysTogether)
        settings.switchesAllDisplaysTogether = false
        XCTAssertFalse(Settings(defaults: defaults).switchesAllDisplaysTogether)
    }

    /// 所有屏幕一起浏览后解除在线屏幕的固定和地区覆盖，离线屏幕配置保持不变。
    func testSharedBrowsingRestoresConnectedDisplaysToGlobalWallpaper() {
        withSettings { settings in
            let oldProfile = WallpaperDisplayProfile(
                marketMode: .automatic,
                pinMode: .pinned,
                pinnedWallpaperID: "automatic:20261102"
            )
            settings.pinnedWallpaperID = "zh-CN:20261101"
            settings.wallpaperDisplayProfiles = [
                "built-in": oldProfile,
                "external": oldProfile,
                "disconnected": oldProfile
            ]

            settings.restoreSharedWallpaperSelection(forDisplayIdentifiers: ["built-in", "external"])

            XCTAssertNil(settings.pinnedWallpaperID)
            XCTAssertNil(settings.wallpaperDisplayProfiles["built-in"])
            XCTAssertNil(settings.wallpaperDisplayProfiles["external"])
            XCTAssertEqual(settings.wallpaperDisplayProfiles["disconnected"], oldProfile)
        }
    }

    func testProfilesPersistAndDefaultProfilesAreDiscarded() {
        withSettings { settings in
            settings.wallpaperDisplayProfiles = [
                "display-a": WallpaperDisplayProfile(
                    marketMode: .explicit,
                    marketCode: "ja-JP",
                    pinMode: .followLatest,
                    pinnedWallpaperID: nil
                ),
                "display-b": WallpaperDisplayProfile()
            ]

            XCTAssertEqual(settings.wallpaperDisplayProfiles.count, 1)
            XCTAssertEqual(
                settings.wallpaperDisplayProfiles["display-a"]?.marketCode,
                "ja-JP"
            )
            XCTAssertNil(settings.wallpaperDisplayProfiles["display-b"])
        }
    }

    func testRequiredMarketsIncludeGlobalAndProfileOverridesWithoutDuplicates() {
        withSettings { settings in
            settings.bingMarketCode = "en-US"
            settings.wallpaperDisplayProfiles = [
                "display-a": WallpaperDisplayProfile(
                    marketMode: .explicit,
                    marketCode: "ja-JP",
                    pinMode: .inherit,
                    pinnedWallpaperID: nil
                ),
                "display-b": WallpaperDisplayProfile(
                    marketMode: .automatic,
                    marketCode: nil,
                    pinMode: .followLatest,
                    pinnedWallpaperID: nil
                ),
                "display-c": WallpaperDisplayProfile(
                    marketMode: .explicit,
                    marketCode: "en-US",
                    pinMode: .followLatest,
                    pinnedWallpaperID: nil
                )
            ]

            XCTAssertEqual(settings.requiredChannelCodes.count, 3)
            XCTAssertTrue(settings.requiredChannelCodes.contains { $0 == "en-US" })
            XCTAssertTrue(settings.requiredChannelCodes.contains { $0 == "ja-JP" })
            XCTAssertTrue(settings.requiredChannelCodes.contains { $0 == nil })
        }
    }

    func testEffectiveMarketHonorsInheritAutomaticAndExplicitModes() {
        XCTAssertEqual(
            WallpaperDisplayProfile().effectiveMarketCode(globalMarketCode: "en-US"),
            "en-US"
        )
        XCTAssertNil(
            WallpaperDisplayProfile(marketMode: .automatic)
                .effectiveMarketCode(globalMarketCode: "en-US")
        )
        XCTAssertEqual(
            WallpaperDisplayProfile(marketMode: .explicit, marketCode: "zh-CN")
                .effectiveMarketCode(globalMarketCode: "en-US"),
            "zh-CN"
        )
    }

    private func withSettings(_ operation: (Settings) -> Void) {
        let suiteName = "BingWallpaperTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        operation(Settings(defaults: defaults))
    }
}

final class WallpaperSourceSettingsTests: XCTestCase {
    func testSourceDefaultsToBingAndSwitchesGlobalChannel() {
        withSettings { settings in
            settings.bingMarketCode = "ja-JP"
            XCTAssertEqual(settings.wallpaperSource, .bing)
            XCTAssertEqual(settings.globalChannelCode, "ja-JP")

            settings.wallpaperSource = .wallpaperAlchemy
            XCTAssertEqual(settings.globalChannelCode, WallpaperChannel.wallpaperAlchemyCode)
            XCTAssertEqual(settings.requiredChannelCodes, [WallpaperChannel.wallpaperAlchemyCode])
            // 切换来源不应丢失已选的必应地区。
            XCTAssertEqual(settings.bingMarketCode, "ja-JP")
        }
    }

    func testDisplayProfileCanUseWallpaperAlchemyWhileGlobalIsBing() {
        withSettings { settings in
            settings.bingMarketCode = "en-US"
            settings.wallpaperDisplayProfiles = [
                "display-a": WallpaperDisplayProfile(
                    marketMode: .explicit,
                    marketCode: WallpaperChannel.wallpaperAlchemyCode
                )
            ]

            XCTAssertEqual(settings.requiredChannelCodes.count, 2)
            XCTAssertTrue(settings.requiredChannelCodes.contains { $0 == "en-US" })
            XCTAssertTrue(settings.requiredChannelCodes.contains {
                $0 == WallpaperChannel.wallpaperAlchemyCode
            })
        }
    }

    func testWallpaperAlchemyCategoryIsOptionalAndClearable() {
        withSettings { settings in
            XCTAssertNil(settings.wallpaperAlchemyCategory)

            let category = DownloadManager.WallpaperAlchemyCategory(id: 3, name: "landscape", title: "风景")
            settings.wallpaperAlchemyCategory = category
            XCTAssertEqual(settings.wallpaperAlchemyCategory, category)

            settings.wallpaperAlchemyCategory = nil
            XCTAssertNil(settings.wallpaperAlchemyCategory)
        }
    }

    func testChannelCodeDoesNotCollideWithBingMarkets() {
        XCTAssertFalse(BingMarketOption.supportedCodes.contains(WallpaperChannel.wallpaperAlchemyCode))
        XCTAssertTrue(WallpaperChannel.isSupported(WallpaperChannel.wallpaperAlchemyCode))
        XCTAssertFalse(WallpaperChannel.isSupported("../bad"))
        XCTAssertEqual(WallpaperChannel.source(for: nil), .bing)
        XCTAssertEqual(WallpaperChannel.source(for: "zh-CN"), .bing)
        XCTAssertEqual(
            WallpaperChannel.source(for: WallpaperChannel.wallpaperAlchemyCode),
            .wallpaperAlchemy
        )
    }

    private func withSettings(_ operation: (Settings) -> Void) {
        let suiteName = "BingWallpaperTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        operation(Settings(defaults: defaults))
    }
}

final class WallpaperAlchemyMetadataTests: XCTestCase {
    func testListUrlRequestsMostDownloadedDesktopWallpapers() {
        let url = DownloadManager.wallpaperAlchemyListUrl(numberOfImages: 8, locale: "zh-CN", page: 3)
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let query = Dictionary(uniqueKeysWithValues: (components?.queryItems ?? []).map {
            ($0.name, $0.value ?? "")
        })

        XCTAssertEqual(components?.host, "server.wallpaperalchemy.com")
        XCTAssertEqual(components?.path, "/api/v1/wallpapers")
        XCTAssertEqual(query["perPage"], "8")
        XCTAssertEqual(query["device"], "desktop")
        XCTAssertEqual(query["sort"], "downloads")
        XCTAssertEqual(query["locale"], "zh-CN")
        XCTAssertEqual(query["page"], "3")
        XCTAssertNil(query["tag"])
    }

    func testListUrlFiltersByCategoryID() {
        let url = DownloadManager.wallpaperAlchemyListUrl(numberOfImages: 8, locale: "en", page: 0, categoryID: 42)
        let query = Dictionary(uniqueKeysWithValues: (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map {
            ($0.name, $0.value ?? "")
        })
        XCTAssertEqual(query["tag"], "42")
        XCTAssertEqual(query["page"], "1")
    }

    func testRotationPositionWrapsWithinRankingPoolAndCategorySize() {
        let poolSize = DownloadManager.wallpaperAlchemyRotationPoolSize
        XCTAssertEqual(DownloadManager.wallpaperAlchemyRotationPosition(5), 5)
        XCTAssertEqual(DownloadManager.wallpaperAlchemyRotationPosition(poolSize), 0)
        XCTAssertEqual(DownloadManager.wallpaperAlchemyRotationPosition(poolSize + 3), 3)
        XCTAssertEqual(DownloadManager.wallpaperAlchemyRotationPosition(7, totalItems: 5), 2)
        XCTAssertEqual(DownloadManager.wallpaperAlchemyRotationPosition(7, totalItems: 0), 7)
        XCTAssertEqual(DownloadManager.wallpaperAlchemyRotationPosition(-1), poolSize - 1)
    }

    func testSingleWallpaperUrlSelectsRankingPosition() {
        let url = DownloadManager.wallpaperAlchemyListUrl(numberOfImages: 1, locale: "en", page: 13, categoryID: 42)
        let query = Dictionary(
            uniqueKeysWithValues: URLComponents(url: url, resolvingAgainstBaseURL: false)!
                .queryItems!.map { ($0.name, $0.value ?? "") }
        )
        XCTAssertEqual(query["perPage"], "1")
        XCTAssertEqual(query["page"], "13")
        XCTAssertEqual(query["device"], "desktop")
        XCTAssertEqual(query["sort"], "downloads")
        XCTAssertEqual(query["tag"], "42")
    }

    func testCategoriesUrlRequestsDesktopCategoriesByDownloads() {
        let url = DownloadManager.wallpaperAlchemyCategoriesUrl(locale: "zh-CN")
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let query = Dictionary(uniqueKeysWithValues: (components?.queryItems ?? []).map {
            ($0.name, $0.value ?? "")
        })
        XCTAssertEqual(components?.path, "/api/v1/tags")
        XCTAssertEqual(query["sort"], "downloads")
        XCTAssertEqual(query["perPage"], "1000")
        XCTAssertEqual(query["device"], "desktop")
        XCTAssertEqual(query["locale"], "zh-CN")
    }

    func testRotationPageCyclesThroughTopPagesAndCategorySize() {
        XCTAssertEqual(DownloadManager.wallpaperAlchemyRotationPage(day: 0), 1)
        XCTAssertEqual(DownloadManager.wallpaperAlchemyRotationPage(day: 9), 10)
        XCTAssertEqual(DownloadManager.wallpaperAlchemyRotationPage(day: 10), 1)
        XCTAssertEqual(DownloadManager.wallpaperAlchemyRotationPage(day: 7, totalPages: 3), 2)
        XCTAssertEqual(DownloadManager.wallpaperAlchemyRotationPage(day: 7, totalPages: 0), 8)
        XCTAssertEqual(DownloadManager.wallpaperAlchemyRotationPage(day: -1), 10)
    }

    func testRotationDayAdvancesOncePerLocalDay() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let morning = calendar.date(from: DateComponents(year: 2026, month: 11, day: 11, hour: 0, minute: 5))!
        let night = calendar.date(from: DateComponents(year: 2026, month: 11, day: 11, hour: 23, minute: 55))!
        let nextDay = calendar.date(byAdding: .day, value: 1, to: morning)!

        let day = DownloadManager.wallpaperAlchemyRotationDay(for: morning, calendar: calendar)
        XCTAssertEqual(DownloadManager.wallpaperAlchemyRotationDay(for: night, calendar: calendar), day)
        XCTAssertEqual(DownloadManager.wallpaperAlchemyRotationDay(for: nextDay, calendar: calendar), day + 1)
    }

    func testCategoryDecodingAndDisplayTitleFallback() throws {
        let json = """
        {"success":true,"data":{"data":[{"id":3,"name":"landscape","title":"风景","imageUrl":"/a.webp"},{"id":4,"name":"minimal","title":" "}],"pageInfo":{"totalItems":2,"totalPages":1}}}
        """
        let categories = try JSONDecoder().decode(
            DownloadManager.WallpaperAlchemyResponse<DownloadManager.WallpaperAlchemyCategory>.self,
            from: Data(json.utf8)
        ).data.data
        XCTAssertEqual(categories.map(\.displayTitle), ["风景", "minimal"])
    }

    func testCategoryMatcherSupportsFuzzyAndPinyinSearch() {
        typealias Category = DownloadManager.WallpaperAlchemyCategory
        let categories = [
            Category(id: 1, name: "anime", title: "动漫"),
            Category(id: 2, name: "landscape", title: "风景"),
            Category(id: 3, name: "natural-landscape", title: "自然风景"),
            Category(id: 4, name: "cars", title: "汽车"),
            Category(id: 5, name: "minimal", title: "Minimalist")
        ]
        let matcher = WallpaperAlchemyCategoryMatcher(categories: categories)
        func ids(_ query: String) -> [Int] { matcher.matches(for: query).map(\.id) }

        XCTAssertEqual(ids(""), [1, 2, 3, 4, 5])
        XCTAssertEqual(ids("风景"), [2, 3])
        XCTAssertEqual(ids("fengjing"), [2, 3])
        XCTAssertEqual(ids("feng jing"), [2, 3])
        XCTAssertEqual(ids("fj").first, 2)
        XCTAssertEqual(ids("zrfj"), [3])
        XCTAssertEqual(ids("LAND"), [2, 3])
        XCTAssertEqual(ids("ｍｉｎｉ"), [5])
        XCTAssertEqual(ids("mnmlst"), [5])
        XCTAssertTrue(ids("qiche").contains(4))
        XCTAssertEqual(ids("xyzxyz"), [])
    }

    func testChangingGlobalSourceReleasesDisplaysFollowingPreviousSource() throws {
        let suiteName = "BingWallpaperTests.release.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = Settings(defaults: defaults)
        let alchemy = WallpaperChannel.wallpaperAlchemyCode
        settings.pinnedWallpaperID = "global-pin"
        settings.wallpaperDisplayProfiles = [
            "browsed": WallpaperDisplayProfile(marketMode: .explicit, marketCode: alchemy, pinMode: .followLatest),
            "pinned": WallpaperDisplayProfile(marketMode: .explicit, marketCode: alchemy, pinMode: .pinned, pinnedWallpaperID: "w"),
            "bing": WallpaperDisplayProfile(marketMode: .explicit, marketCode: "ja-JP", pinMode: .followLatest)
        ]

        settings.releaseSelections(followingPreviousGlobalChannel: alchemy)

        XCTAssertNil(settings.pinnedWallpaperID)
        XCTAssertEqual(Set(settings.wallpaperDisplayProfiles.keys), ["pinned", "bing"])
    }

    func testAppLanguageResolvesSystemPreferenceWithEnglishFallback() {
        XCTAssertEqual(AppLanguage.system.resolved(preferredLanguages: ["zh-Hans-CN"]), .chineseSimplified)
        XCTAssertEqual(AppLanguage.system.resolved(preferredLanguages: ["zh-Hant-TW"]), .chineseSimplified)
        XCTAssertEqual(AppLanguage.system.resolved(preferredLanguages: ["ja-JP", "en-US"]), .english)
        XCTAssertEqual(AppLanguage.system.resolved(preferredLanguages: ["de-DE", "zh-Hans"]), .chineseSimplified)
        XCTAssertEqual(AppLanguage.system.resolved(preferredLanguages: ["xx"]), .english)
        XCTAssertEqual(AppLanguage.english.resolved(preferredLanguages: ["zh-Hans-CN"]), .english)
        XCTAssertEqual(AppLanguage.chineseSimplified.resolved(preferredLanguages: ["en-US"]), .chineseSimplified)
    }

    func testWallpaperAlchemyLocaleFollowsInterfaceLanguage() throws {
        let suiteName = "BingWallpaperTests.language.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = Settings(defaults: defaults)

        XCTAssertEqual(settings.appLanguage, .system)
        settings.appLanguage = .chineseSimplified
        XCTAssertEqual(settings.appLanguage, .chineseSimplified)
        XCTAssertEqual(settings.wallpaperAlchemyLocale, "zh-CN")
        settings.appLanguage = .english
        XCTAssertEqual(settings.wallpaperAlchemyLocale, "en")
    }

    func testChineseTranslationsKeepFormatPlaceholders() {
        let placeholder = try! NSRegularExpression(pattern: "%(\\d+\\$)?[@dlu]+")
        func placeholders(_ text: String) -> [String] {
            placeholder.matches(in: text, range: NSRange(text.startIndex..., in: text)).map {
                (text as NSString).substring(with: $0.range)
            }
        }
        for (key, value) in Localization.chineseSimplified {
            XCTAssertEqual(placeholders(key), placeholders(value), key)
        }
        XCTAssertEqual(Localization.string("Switching Scope", language: .chineseSimplified), "切换范围")
        XCTAssertEqual(Localization.string("Switching Scope", language: .english), "Switching Scope")
        XCTAssertEqual(Localization.string("Untranslated text", language: .chineseSimplified), "Untranslated text")
        XCTAssertEqual(L("Favorites (%d)", 3), "Favorites (3)")
    }

    func testDecodesApiResponse() throws {
        let json = """
        {"success":true,"data":{"data":[{"id":7552,"slug":"makima-4k","image":"/storage/wallpapers/7552/makima-4k.jpeg","cardImage":"/storage/wallpapers/7552/makima-4k-card.webp","type":"image","videoUrl":null,"width":3840,"height":2160,"author":1,"links":{},"storage":"vps","createdAt":"2026-11-09T18:31:22.000Z","updatedAt":"2026-11-09T18:31:22.000Z","name":"玛奇玛 4K 壁纸","description":"d","keywords":"k"}],"pageInfo":{"page":1}}}
        """
        let response = try JSONDecoder().decode(
            DownloadManager.WallpaperAlchemyResponse<DownloadManager.WallpaperAlchemyEntry>.self,
            from: Data(json.utf8)
        )
        XCTAssertEqual(response.data.data.first?.id, 7552)
        XCTAssertEqual(response.data.data.first?.name, "玛奇玛 4K 壁纸")
    }

    func testValidatedMetadataBuildsUrlsDateAndDescription() throws {
        let metadata = try ImageDescriptor.validatedMetadata(
            from: makeEntry(),
            locale: "zh-CN",
            featuredAt: ISO8601DateFormatter().date(from: "2026-11-09T18:31:22Z")!,
            timeZone: TimeZone(identifier: "Asia/Shanghai")!
        )

        XCTAssertEqual(
            metadata.imageURL.absoluteString,
            "https://server.wallpaperalchemy.com/storage/wallpapers/7552/makima-4k.jpeg"
        )
        XCTAssertEqual(
            metadata.copyrightURL.absoluteString,
            "https://www.wallpaperalchemy.com/zh-CN/wallpaper/makima-4k-7552"
        )
        // 展示日期取获取时间，18:31 UTC 在上海已是次日。
        XCTAssertEqual(metadata.startDate, "20261110")
        XCTAssertEqual(metadata.endDate, "20261110")

        let info = WallpaperImageInfo(
            description: metadata.descriptionString,
            startDate: metadata.endDate,
            marketCode: WallpaperChannel.wallpaperAlchemyCode
        )
        XCTAssertEqual(info.title, "玛奇玛 4K 壁纸")
        XCTAssertEqual(info.copyright, "© Wallpaper Alchemy · 3840×2160")
        XCTAssertEqual(info.source, "Wallpaper Alchemy")
    }

    func testEnglishDetailPageHasNoLocalePrefix() throws {
        let metadata = try ImageDescriptor.validatedMetadata(from: makeEntry(), locale: "en")
        XCTAssertEqual(
            metadata.copyrightURL.absoluteString,
            "https://www.wallpaperalchemy.com/wallpaper/makima-4k-7552"
        )
    }

    func testRejectsUntrustedVideoAndPortraitEntries() {
        XCTAssertThrowsError(try ImageDescriptor.validatedMetadata(
            from: makeEntry(image: "https://example.com/storage/wallpapers/1/a.jpg"),
            locale: "en"
        ))
        XCTAssertThrowsError(try ImageDescriptor.validatedMetadata(
            from: makeEntry(image: "http://server.wallpaperalchemy.com/storage/wallpapers/1/a.jpg"),
            locale: "en"
        ))
        XCTAssertThrowsError(try ImageDescriptor.validatedMetadata(
            from: makeEntry(type: "video"),
            locale: "en"
        ))
        XCTAssertThrowsError(try ImageDescriptor.validatedMetadata(
            from: makeEntry(width: 2160, height: 3840),
            locale: "en"
        ))
    }

    func testIdentityAndFileNameUseWallpaperID() throws {
        let metadata = try ImageDescriptor.validatedMetadata(from: makeEntry(), locale: "en")
        let code = WallpaperChannel.wallpaperAlchemyCode

        XCTAssertEqual(
            ImageDescriptor.wallpaperIdentifier(
                startDate: metadata.startDate,
                marketCode: code,
                imageURL: metadata.imageURL
            ),
            "wallpaperalchemy:7552"
        )
        XCTAssertEqual(
            Image.fileName(
                startDate: metadata.startDate,
                marketCode: code,
                imageIdentity: ImageDescriptor.imageIdentity(for: metadata.imageURL),
                fileExtension: metadata.imageURL.pathExtension
            ),
            "wallpaperalchemy_7552.jpeg"
        )
        XCTAssertEqual(
            Image.fileName(
                startDate: metadata.startDate,
                marketCode: code,
                imageIdentity: "7552",
                fileExtension: "exe"
            ),
            "wallpaperalchemy_7552.jpg"
        )
    }

    private func makeEntry(
        image: String = "/storage/wallpapers/7552/makima-4k.jpeg",
        type: String = "image",
        width: Int? = 3840,
        height: Int? = 2160,
        createdAt: String = "2026-11-09T18:31:22.000Z"
    ) -> DownloadManager.WallpaperAlchemyEntry {
        return DownloadManager.WallpaperAlchemyEntry(
            id: 7552,
            slug: "makima-4k",
            image: image,
            type: type,
            width: width,
            height: height,
            createdAt: createdAt,
            name: "玛奇玛 4K 壁纸"
        )
    }
}

@MainActor
final class WallpaperAlchemyDatabaseTests: XCTestCase {
    func testSameDayWallpapersAreStoredSeparatelyAndTopRankIsNewest() throws {
        let database = Database(inMemory: true)
        let update = try database.updateWallpaperAlchemyImageDescriptors(
            from: [makeEntry(id: 12), makeEntry(id: 11), makeEntry(id: 10)],
            locale: "en"
        )

        XCTAssertEqual(update.descriptors.count, 3)
        XCTAssertEqual(
            database.allImageDescriptors(marketCode: WallpaperChannel.wallpaperAlchemyCode)
                .map(\.wallpaperIdentifier),
            ["wallpaperalchemy:10", "wallpaperalchemy:11", "wallpaperalchemy:12"]
        )
        XCTAssertEqual(
            database.allImageDescriptors().max()?.wallpaperIdentifier,
            "wallpaperalchemy:12"
        )
        XCTAssertEqual(Set(update.descriptors.map(\.image.fileName)).count, 3)
    }

    func testRefreshReusesExistingWallpaperAlchemyDescriptor() throws {
        let database = Database(inMemory: true)
        _ = try database.updateWallpaperAlchemyImageDescriptors(from: [makeEntry(id: 10)], locale: "en")
        let update = try database.updateWallpaperAlchemyImageDescriptors(
            from: [makeEntry(id: 11), makeEntry(id: 10)],
            locale: "en"
        )

        XCTAssertEqual(update.descriptors.count, 2)
        XCTAssertEqual(database.allImageDescriptors().count, 2)
    }

    func testBingAndWallpaperAlchemyChannelsStaySeparate() throws {
        let database = Database(inMemory: true)
        _ = try database.updateImageDescriptors(from: [
            DownloadManager.ImageEntry(
                url: "/th?id=OHR.Example_1920x1080.jpg",
                enddate: "20261110",
                startdate: "20261109",
                copyright: "Example (© Photographer)",
                copyrightlink: "https://www.bing.com/search?q=example"
            )
        ], marketCode: "zh-CN")
        _ = try database.updateWallpaperAlchemyImageDescriptors(from: [makeEntry(id: 10)], locale: "en")

        XCTAssertEqual(database.allImageDescriptors(marketCode: "zh-CN").count, 1)
        XCTAssertEqual(
            database.allImageDescriptors(marketCode: WallpaperChannel.wallpaperAlchemyCode).count,
            1
        )
    }

    func testLaterRotationBecomesNewest() throws {
        let database = Database(inMemory: true)
        let firstDay = ISO8601DateFormatter().date(from: "2026-11-10T04:00:00Z")!
        let secondDay = firstDay.addingTimeInterval(24 * 60 * 60)
        _ = try database.updateWallpaperAlchemyImageDescriptors(
            from: [makeEntry(id: 900), makeEntry(id: 800)],
            locale: "en",
            featuredAt: firstDay
        )
        _ = try database.updateWallpaperAlchemyImageDescriptors(
            from: [makeEntry(id: 5), makeEntry(id: 6)],
            locale: "en",
            featuredAt: secondDay
        )

        XCTAssertEqual(
            database.allImageDescriptors().map(\.wallpaperIdentifier),
            ["wallpaperalchemy:800", "wallpaperalchemy:900", "wallpaperalchemy:6", "wallpaperalchemy:5"]
        )
    }

    func testAllInvalidEntriesThrowNoValidMetadata() {
        let database = Database(inMemory: true)
        XCTAssertThrowsError(try database.updateWallpaperAlchemyImageDescriptors(
            from: [makeEntry(id: 10, type: "video")],
            locale: "en"
        ))
    }

    private func makeEntry(id: Int, type: String = "image") -> DownloadManager.WallpaperAlchemyEntry {
        return DownloadManager.WallpaperAlchemyEntry(
            id: id,
            slug: "wallpaper",
            image: "/storage/wallpapers/\(id)/wallpaper.jpg",
            type: type,
            width: 3840,
            height: 2160,
            createdAt: "2026-11-09T06:00:00.000Z",
            name: "Wallpaper \(id)"
        )
    }
}
