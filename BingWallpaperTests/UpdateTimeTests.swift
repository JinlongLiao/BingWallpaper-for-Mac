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

            XCTAssertEqual(settings.requiredBingMarketCodes.count, 3)
            XCTAssertTrue(settings.requiredBingMarketCodes.contains { $0 == "en-US" })
            XCTAssertTrue(settings.requiredBingMarketCodes.contains { $0 == "ja-JP" })
            XCTAssertTrue(settings.requiredBingMarketCodes.contains { $0 == nil })
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
