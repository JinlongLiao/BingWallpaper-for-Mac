import Foundation
import AppKit
import OSLog

private let logger = Logger(
    subsystem: Logging.subsystem,
    category: Logging.Category.Update.rawValue
)

enum WallpaperUpdatePhase: Equatable {
    case idle
    case updating
    case succeeded
    case retrying
    case failed
}

enum WallpaperUpdateFailureStage: Equatable {
    case metadata
    case images

    var title: String {
        switch self {
        case .metadata:
            return L("Wallpaper list")
        case .images:
            return L("Image download")
        }
    }
}

struct WallpaperUpdateFailure: Equatable {
    let stage: WallpaperUpdateFailureStage
    let message: String
    let occurredAt: Date
}

struct WallpaperUpdateStatus: Equatable {
    let phase: WallpaperUpdatePhase
    let lastSuccessAt: Date?
    let lastAttemptAt: Date?
    let nextAttemptAt: Date?
    let failure: WallpaperUpdateFailure?
    let consecutiveFailures: Int

    var menuTitle: String {
        switch phase {
        case .idle, .succeeded:
            return L("Update Status: Up to Date")
        case .updating:
            return L("Update Status: Updating…")
        case .retrying:
            return L("Update Status: Failed — Retry Scheduled")
        case .failed:
            return L("Update Status: Failed")
        }
    }
}

protocol UpdateManagerDelegate: AnyObject {
    @MainActor
    func wallpaperLibraryDidChange(forceWallpaperRefresh: Bool)
    @MainActor
    func updateStatusDidChange(_ status: WallpaperUpdateStatus)
}

@MainActor
final class UpdateManager {
    private static let ACTIVITY_IDENTIFIER = "com.2h4u.BingWallpaper.update"

    weak var delegate: UpdateManagerDelegate?
    private let settings: Settings
    private var activity: NSBackgroundActivityScheduler?
    private var pendingCompletion: NSBackgroundActivityScheduler.CompletionHandler?
    private var consecutiveFailures = 0
    private var isUpdating = false
    private var pendingUpdateRequested = false
    private var rotationTimer: Timer?
    private var isRotating = false
    private(set) var status: WallpaperUpdateStatus

    nonisolated private static let RETRY_BASE_INTERVAL: TimeInterval = 30
    nonisolated private static let RETRY_MAX_INTERVAL: TimeInterval = 30 * 60
    /// 更新进行中时，自动更换稍后再试的间隔。
    nonisolated private static let ROTATION_BUSY_RETRY_INTERVAL: TimeInterval = 15

    init(settings: Settings = Settings()) {
        self.settings = settings
        let lastUpdate = settings.lastUpdate
        let lastSuccessAt = lastUpdate == Date.distantPast ? nil : lastUpdate
        self.status = WallpaperUpdateStatus(
            phase: .idle,
            lastSuccessAt: lastSuccessAt,
            lastAttemptAt: nil,
            nextAttemptAt: nil,
            failure: nil,
            consecutiveFailures: 0
        )
    }

    @MainActor
    func start() {
        setupObserver()
        scheduleWallpaperAlchemyRotation()
        Task { [weak self] in
            await self?.doUpdateOrScheduleActivity()
        }
    }

    // MARK: - Wallpaper Alchemy 定时更换

    /// 更换间隔变化后重新计时；从关闭改为开启时立即换一张，让设置马上生效。
    /// - Parameter previousInterval: 修改前的间隔。
    func wallpaperAlchemyRefreshIntervalDidChange(from previousInterval: WallpaperAlchemyRefreshInterval) {
        let interval = settings.wallpaperAlchemyRefreshInterval
        if previousInterval == .never, interval != .never {
            // 从当天每日轮换所在的位置接着往下换，避免跳回排行第一张。
            let rotationPage = DownloadManager.wallpaperAlchemyRotationPage(
                day: DownloadManager.wallpaperAlchemyRotationDay()
            )
            settings.wallpaperAlchemyRotationPosition = (rotationPage - 1) * DownloadManager.wallpaperAlchemyPageSize
            rotateWallpaperAlchemy()
            return
        }
        scheduleWallpaperAlchemyRotation()
    }

    /// 按上次更换时间安排下一次更换；关闭时停止计时。
    /// - Parameter delay: 指定的等待时间，nil 时按设置的间隔计算。
    private func scheduleWallpaperAlchemyRotation(after delay: TimeInterval? = nil) {
        rotationTimer?.invalidate()
        rotationTimer = nil
        guard let interval = settings.wallpaperAlchemyRefreshInterval.timeInterval else { return }

        let fireInterval: TimeInterval
        if let delay {
            fireInterval = delay
        } else if let lastRotation = settings.lastWallpaperAlchemyRotation,
                  lastRotation <= Date() {
            fireInterval = max(0, interval - Date().timeIntervalSince(lastRotation))
        } else {
            settings.lastWallpaperAlchemyRotation = Date()
            fireInterval = interval
        }

        let timer = Timer(timeInterval: fireInterval, repeats: false) { _ in
            Task { @MainActor [weak self] in
                self?.rotateWallpaperAlchemy()
            }
        }
        timer.tolerance = min(max(1, fireInterval * 0.1), 60)
        // 菜单打开时运行循环处于事件跟踪模式，加入 common 模式才能按时触发。
        RunLoop.main.add(timer, forMode: .common)
        rotationTimer = timer
    }

    /// 换成所选分类下载排行中的下一张壁纸，只请求一张图片。
    private func rotateWallpaperAlchemy() {
        guard settings.wallpaperAlchemyRefreshInterval != .never else {
            scheduleWallpaperAlchemyRotation()
            return
        }
        // 没有任何显示器使用 Wallpaper Alchemy 时不请求网络，只继续计时。
        guard settings.requiredChannelCodes.contains(WallpaperChannel.wallpaperAlchemyCode) else {
            settings.lastWallpaperAlchemyRotation = Date()
            scheduleWallpaperAlchemyRotation()
            return
        }
        guard isUpdating == false, isRotating == false else {
            scheduleWallpaperAlchemyRotation(after: Self.ROTATION_BUSY_RETRY_INTERVAL)
            return
        }

        isRotating = true
        rotationTimer?.invalidate()
        rotationTimer = nil
        let locale = settings.wallpaperAlchemyLocale
        let categoryID = settings.wallpaperAlchemyCategory?.id
        let nextPosition = settings.wallpaperAlchemyRotationPosition + 1
        logger.info("Changing Wallpaper Alchemy wallpaper to ranking position \(nextPosition, privacy: .public)")

        Task { [weak self] in
            do {
                let result = try await DownloadManager.downloadWallpaperAlchemyEntry(
                    at: nextPosition,
                    locale: locale,
                    categoryID: categoryID
                )
                // 请求期间换了分类或语言时丢弃结果，由随之触发的更新显示新分类。
                guard let self,
                      self.settings.wallpaperAlchemyCategory?.id == categoryID,
                      self.settings.wallpaperAlchemyLocale == locale else {
                    self?.finishWallpaperAlchemyRotation()
                    return
                }
                self.settings.wallpaperAlchemyRotationPosition = result.position
                let descriptorUpdate = try Database.instance.updateWallpaperAlchemyImageDescriptors(
                    from: [result.entry],
                    locale: locale
                )
                for descriptor in descriptorUpdate.descriptors {
                    let isOnDisk = await descriptor.image.isValidOnDisk()
                    guard descriptor.requiresImageDownload || isOnDisk == false else { continue }
                    try await descriptor.image.downloadAndSaveToDisk()
                    try Database.instance.markImageDownloadCompleted(for: descriptor)
                }
                self.delegate?.wallpaperLibraryDidChange(forceWallpaperRefresh: false)
                self.cleanup()
            } catch {
                logger.error("Failed to change the Wallpaper Alchemy wallpaper: \(error.localizedDescription, privacy: .public)")
            }
            self?.finishWallpaperAlchemyRotation()
        }
    }

    private func finishWallpaperAlchemyRotation() {
        isRotating = false
        settings.lastWallpaperAlchemyRotation = Date()
        scheduleWallpaperAlchemyRotation()
        _ = beginPendingUpdateIfNeeded()
    }

    @MainActor
    private func doUpdateOrScheduleActivity() async {
        var downloadedMarkets = Set<String?>()
        for descriptor in Database.instance.allImageDescriptors() {
            if await descriptor.image.isValidOnDisk() {
                downloadedMarkets.insert(descriptor.marketCode)
            }
        }
        let isMissingRequiredMarket = settings.requiredChannelCodes.contains {
            downloadedMarkets.contains($0) == false
        }
        if UpdateScheduleManager.isUpdateNecessary() || isMissingRequiredMarket {
            update()
            return
        }

        let nextUpdateAt = scheduleNextActivity()
        publishStatus(WallpaperUpdateStatus(
            phase: .idle,
            lastSuccessAt: lastSuccessfulUpdate,
            lastAttemptAt: status.lastAttemptAt,
            nextAttemptAt: nextUpdateAt,
            failure: nil,
            consecutiveFailures: 0
        ))
    }

    @MainActor
    @discardableResult
    private func scheduleNextActivity(overrideInterval: TimeInterval? = nil) -> Date {
        let nextFetchInterval = overrideInterval ?? UpdateScheduleManager.nextFetchTimeInterval()
        let nextUpdateAt = Date().addingTimeInterval(nextFetchInterval)
        logger.info("Next update at \(nextUpdateAt, privacy: .public)")

        activity?.invalidate()

        let scheduler = NSBackgroundActivityScheduler(identifier: UpdateManager.ACTIVITY_IDENTIFIER)
        scheduler.repeats = false
        scheduler.interval = nextFetchInterval
        scheduler.tolerance = min(nextFetchInterval / 2, 60 * 30)
        scheduler.qualityOfService = .utility
        // 两层闭包均弱引用管理器，避免调度器持有回调期间形成循环引用。
        scheduler.schedule { [weak self] completion in
            Task { @MainActor [weak self] in
                guard let self = self else {
                    completion(.finished)
                    return
                }
                self.pendingCompletion = completion
                self.update()
            }
        }

        activity = scheduler
        return nextUpdateAt
    }
        
    @MainActor
    private func cleanup() {
        // TODO: @2h4u: find entries with same startDate and remove them
        // TODO: @2h4u: probably do this in a migration function in appdelegate
        
        guard let maximumCount = settings.maximumStoredImageCount() else { return }
        var preservedIDs = settings.favoriteWallpaperIDs
        if let pinnedWallpaperID = settings.pinnedWallpaperID {
            preservedIDs.insert(pinnedWallpaperID)
        }
        for profile in settings.wallpaperDisplayProfiles.values {
            if let pinnedWallpaperID = profile.pinnedWallpaperID {
                preservedIDs.insert(pinnedWallpaperID)
            }
        }
        let downloadedDescriptors = Database.instance.allImageDescriptors()
            .filter { $0.image.isOnDisk() }
        for marketCode in settings.requiredChannelCodes {
            if let newestDescriptor = downloadedDescriptors
                .filter({ $0.marketCode == marketCode })
                .max() {
                preservedIDs.insert(newestDescriptor.wallpaperIdentifier)
            }
        }
        preservedIDs.formUnion(WallpaperManager.currentWallpaperIdentifiers())
        do {
            let deletedFileNames = try Database.instance.deleteImageDescriptors(
                exceedingMaximumCount: maximumCount,
                preserving: preservedIDs
            )
            FileHandler.deleteImages(fileNames: deletedFileNames)
        } catch {
            logger.error("Failed to clean up old wallpapers: \(error.localizedDescription, privacy: .public)")
        }
    }
    
    private func setupObserver() {
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(receiveSleepNote),
            name: NSWorkspace.willSleepNotification,
            object: nil
        )
        
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(receiveWakeNote),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
    }
    
    @MainActor
    @objc func update() {
        guard isUpdating == false, isRotating == false else {
            pendingUpdateRequested = true
            logger.info("An update is already running; queueing one follow-up update")
            return
        }

        activity?.invalidate()
        activity = nil
        isUpdating = true
        let attemptDate = Date()
        publishStatus(WallpaperUpdateStatus(
            phase: .updating,
            lastSuccessAt: lastSuccessfulUpdate,
            lastAttemptAt: attemptDate,
            nextAttemptAt: nil,
            failure: nil,
            consecutiveFailures: consecutiveFailures
        ))
        logger.info("Updating")
        let marketCodes = settings.requiredChannelCodes
        let wallpaperAlchemyFeed = WallpaperAlchemyFeed(
            locale: settings.wallpaperAlchemyLocale,
            categoryID: settings.wallpaperAlchemyCategory?.id,
            rotationPosition: settings.wallpaperAlchemyRefreshInterval == .never
                ? nil
                : settings.wallpaperAlchemyRotationPosition
        )

        Task { [weak self] in
            var metadataFailure: Error?
            var imageFailureRequiringRetry: Error?
            var replacedExistingImage = false
            // 第一张新图下载完就先换上壁纸，其余图片继续在后台下载。
            var didPublishFirstImage = false

            for marketCode in marketCodes {
                let descriptorUpdate: Database.ImageDescriptorUpdate
                do {
                    descriptorUpdate = try await Self.downloadAndStoreMetadata(
                        forChannel: marketCode,
                        wallpaperAlchemyFeed: wallpaperAlchemyFeed
                    )
                } catch {
                    logger.error("Failed to update wallpaper metadata for channel \(marketCode ?? "automatic", privacy: .public) with error: \(error.localizedDescription, privacy: .public)")
                    if metadataFailure == nil {
                        metadataFailure = error
                    }
                    continue
                }
                var validWallpaperIDs = Set<String>()
                for descriptor in Database.instance.allImageDescriptors(marketCode: marketCode) {
                    if descriptor.requiresImageDownload == false,
                       await descriptor.image.isValidOnDisk() {
                        validWallpaperIDs.insert(descriptor.wallpaperIdentifier)
                    }
                }
                var marketHasAvailableImage = validWallpaperIDs.isEmpty == false
                var marketErrors = [Error]()
                let missingDescriptors = descriptorUpdate.descriptors
                    .filter {
                        descriptorUpdate.wallpaperIDsRequiringDownload.contains($0.wallpaperIdentifier) ||
                            validWallpaperIDs.contains($0.wallpaperIdentifier) == false
                    }

                for descriptor in missingDescriptors {
                    let replacesExistingImage = descriptorUpdate.wallpaperIDsRequiringDownload
                        .contains(descriptor.wallpaperIdentifier)
                    do {
                        try await descriptor.image.downloadAndSaveToDisk()
                        try Database.instance.markImageDownloadCompleted(for: descriptor)
                        replacedExistingImage = replacedExistingImage || replacesExistingImage
                        marketHasAvailableImage = true
                        if didPublishFirstImage == false {
                            didPublishFirstImage = true
                            self?.delegate?.wallpaperLibraryDidChange(forceWallpaperRefresh: false)
                        }
                    } catch {
                        marketErrors.append(error)
                        logger.error("Failed to download and store image \(descriptor.imageUrl, privacy: .public) with error: \(error.localizedDescription, privacy: .public)")
                    }
                }

                // A partially successful archive is still usable. Retry only
                // when a transient error leaves this market with no local image.
                if Self.imageDownloadFailuresRequireRetry(
                    hasAvailableImage: marketHasAvailableImage,
                    errors: marketErrors
                ), imageFailureRequiringRetry == nil {
                    imageFailureRequiringRetry = marketErrors.first {
                        DownloadManager.isPermanentlyUnavailableResourceError($0) == false
                    }
                }
            }

            await MainActor.run { [weak self] in
                guard let self = self else { return }
                // Metadata may have been recreated while the image files were
                // already on disk (for example after Reset Database), so the UI
                // must refresh even when no download occurred.
                self.delegate?.wallpaperLibraryDidChange(forceWallpaperRefresh: replacedExistingImage)
                if let metadataFailure {
                    self.finishUpdateWithFailure(stage: .metadata, error: metadataFailure)
                    return
                }
                if let imageFailureRequiringRetry {
                    self.finishUpdateWithFailure(
                        stage: .images,
                        error: imageFailureRequiringRetry
                    )
                    return
                }

                self.isUpdating = false
                let completedAt = Date()
                self.settings.lastUpdate = completedAt
                self.consecutiveFailures = 0
                self.cleanup()

                let completion = self.pendingCompletion
                self.pendingCompletion = nil
                completion?(.finished)

                if self.beginPendingUpdateIfNeeded() {
                    return
                }

                let nextUpdateAt = self.scheduleNextActivity()
                self.publishStatus(WallpaperUpdateStatus(
                    phase: .succeeded,
                    lastSuccessAt: completedAt,
                    lastAttemptAt: attemptDate,
                    nextAttemptAt: nextUpdateAt,
                    failure: nil,
                    consecutiveFailures: 0
                ))
            }
        }
    }

    /// Wallpaper Alchemy 列表的请求条件，在一次更新开始时从设置中读取。
    private struct WallpaperAlchemyFeed {
        let locale: String
        let categoryID: Int?
        /// 开启定时更换时为当前名次，只获取这一张；nil 表示按天轮换获取一整页。
        let rotationPosition: Int?
    }

    /// 按频道下载最新壁纸列表并写入数据库。
    /// - Parameters:
    ///   - channelCode: 必应地区码（nil 为自动地区）或 Wallpaper Alchemy 保留码。
    ///   - wallpaperAlchemyFeed: Wallpaper Alchemy 的语言与分类。
    @MainActor
    private static func downloadAndStoreMetadata(
        forChannel channelCode: String?,
        wallpaperAlchemyFeed: WallpaperAlchemyFeed
    ) async throws -> Database.ImageDescriptorUpdate {
        switch WallpaperChannel.source(for: channelCode) {
        case .bing:
            let imageEntries = try await DownloadManager.downloadImageEntries(
                numberOfImages: 8,
                marketCode: channelCode
            )
            return try Database.instance.updateImageDescriptors(
                from: imageEntries,
                marketCode: channelCode
            )
        case .wallpaperAlchemy:
            let featuredAt = Date()
            // 定时更换时保持当前这一张，避免每次常规更新都跳回当天那一页的第一张。
            if let rotationPosition = wallpaperAlchemyFeed.rotationPosition {
                let result = try await DownloadManager.downloadWallpaperAlchemyEntry(
                    at: rotationPosition,
                    locale: wallpaperAlchemyFeed.locale,
                    categoryID: wallpaperAlchemyFeed.categoryID
                )
                return try Database.instance.updateWallpaperAlchemyImageDescriptors(
                    from: [result.entry],
                    locale: wallpaperAlchemyFeed.locale,
                    featuredAt: featuredAt
                )
            }
            let imageEntries = try await DownloadManager.downloadWallpaperAlchemyEntries(
                numberOfImages: DownloadManager.wallpaperAlchemyPageSize,
                locale: wallpaperAlchemyFeed.locale,
                categoryID: wallpaperAlchemyFeed.categoryID,
                rotationDay: DownloadManager.wallpaperAlchemyRotationDay(for: featuredAt)
            )
            return try Database.instance.updateWallpaperAlchemyImageDescriptors(
                from: imageEntries,
                locale: wallpaperAlchemyFeed.locale,
                featuredAt: featuredAt
            )
        }
    }

    @MainActor
    private func finishUpdateWithFailure(stage: WallpaperUpdateFailureStage, error: Error) {
        isUpdating = false
        let completion = pendingCompletion
        pendingCompletion = nil
        completion?(.deferred)
        if beginPendingUpdateIfNeeded() {
            return
        }
        scheduleRetryAfterFailure(stage: stage, error: error)
    }

    @MainActor
    private func beginPendingUpdateIfNeeded() -> Bool {
        guard pendingUpdateRequested else { return false }
        pendingUpdateRequested = false
        update()
        return true
    }

    @MainActor
    private func scheduleRetryAfterFailure(stage: WallpaperUpdateFailureStage, error: Error) {
        consecutiveFailures += 1
        let backoff = Self.retryInterval(forFailureCount: consecutiveFailures)
        logger.info("Update failed (\(self.consecutiveFailures, privacy: .public) in a row), retrying in \(backoff, privacy: .public)s")
        let failureDate = Date()
        let nextRetryAt = scheduleNextActivity(overrideInterval: backoff)
        publishStatus(WallpaperUpdateStatus(
            phase: .retrying,
            lastSuccessAt: lastSuccessfulUpdate,
            lastAttemptAt: status.lastAttemptAt ?? failureDate,
            nextAttemptAt: nextRetryAt,
            failure: WallpaperUpdateFailure(
                stage: stage,
                message: error.localizedDescription,
                occurredAt: failureDate
            ),
            consecutiveFailures: consecutiveFailures
        ))
    }

    nonisolated static func retryInterval(forFailureCount failureCount: Int) -> TimeInterval {
        let exponent = min(max(failureCount, 1) - 1, 10)
        return min(
            RETRY_BASE_INTERVAL * pow(2.0, Double(exponent)),
            RETRY_MAX_INTERVAL
        )
    }

    nonisolated static func imageDownloadFailuresRequireRetry(
        hasAvailableImage: Bool,
        errors: [Error]
    ) -> Bool {
        return hasAvailableImage == false && errors.contains {
            DownloadManager.isPermanentlyUnavailableResourceError($0) == false
        }
    }

    private var lastSuccessfulUpdate: Date? {
        let lastUpdate = settings.lastUpdate
        return lastUpdate == Date.distantPast ? nil : lastUpdate
    }

    @MainActor
    private func publishStatus(_ newStatus: WallpaperUpdateStatus) {
        status = newStatus
        delegate?.updateStatusDidChange(newStatus)
    }
    
    @MainActor
    @objc func receiveSleepNote(note: NSNotification) {
        activity?.invalidate()
        rotationTimer?.invalidate()
        rotationTimer = nil
    }

    @MainActor
    @objc func receiveWakeNote(note: NSNotification) {
        // 睡眠期间计时器不走，唤醒后按实际经过的时间重新计算。
        if isRotating == false {
            scheduleWallpaperAlchemyRotation()
        }
        Task { [weak self] in
            await self?.doUpdateOrScheduleActivity()
        }
    }
}
