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
            return "Wallpaper list"
        case .images:
            return "Image download"
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
            return "Update Status: Up to Date"
        case .updating:
            return "Update Status: Updating…"
        case .retrying:
            return "Update Status: Failed — Retry Scheduled"
        case .failed:
            return "Update Status: Failed"
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
    private(set) var status: WallpaperUpdateStatus

    nonisolated private static let RETRY_BASE_INTERVAL: TimeInterval = 30
    nonisolated private static let RETRY_MAX_INTERVAL: TimeInterval = 30 * 60

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
        Task { [weak self] in
            await self?.doUpdateOrScheduleActivity()
        }
    }

    @MainActor
    private func doUpdateOrScheduleActivity() async {
        var downloadedMarkets = Set<String?>()
        for descriptor in Database.instance.allImageDescriptors() {
            if await descriptor.image.isValidOnDisk() {
                downloadedMarkets.insert(descriptor.marketCode)
            }
        }
        let isMissingRequiredMarket = settings.requiredBingMarketCodes.contains {
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
        for marketCode in settings.requiredBingMarketCodes {
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
        guard isUpdating == false else {
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
        let marketCodes = settings.requiredBingMarketCodes

        Task { [weak self] in
            var metadataFailure: Error?
            var imageFailureRequiringRetry: Error?
            var replacedExistingImage = false

            for marketCode in marketCodes {
                let imageEntries: [DownloadManager.ImageEntry]
                do {
                    imageEntries = try await DownloadManager.downloadImageEntries(
                        numberOfImages: 8,
                        marketCode: marketCode
                    )
                } catch {
                    logger.error("Failed to download image entries for market \(marketCode ?? "automatic", privacy: .public) with error: \(error.localizedDescription, privacy: .public)")
                    if metadataFailure == nil {
                        metadataFailure = error
                    }
                    continue
                }

                let descriptorUpdate: Database.ImageDescriptorUpdate
                do {
                    descriptorUpdate = try Database.instance.updateImageDescriptors(
                        from: imageEntries,
                        marketCode: marketCode
                    )
                } catch {
                    logger.error("Failed to store wallpaper metadata for market \(marketCode ?? "automatic", privacy: .public): \(error.localizedDescription, privacy: .public)")
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
    }

    @MainActor
    @objc func receiveWakeNote(note: NSNotification) {
        Task { [weak self] in
            await self?.doUpdateOrScheduleActivity()
        }
    }
}
