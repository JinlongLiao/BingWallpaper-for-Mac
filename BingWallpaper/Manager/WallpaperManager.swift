import AppKit
import ColorSync
import Foundation
import OSLog

private let logger = Logger(
    subsystem: Logging.subsystem,
    category: Logging.Category.Wallpaper.rawValue
)

struct WallpaperDisplayInfo {
    let identifier: String
    let title: String
    let isMain: Bool
}

@MainActor
final class WallpaperManager {
    private var imageDescriptor: ImageDescriptor?
    private let settings = Settings()
    static let shared = WallpaperManager()
    
    private init() {
        setupObserver()
    }
    
    private func setupObserver() {
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(WallpaperManager.activeWorkspaceDidChange),
            name: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(WallpaperManager.workspaceDidWake),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(WallpaperManager.screenParametersDidChange),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    @MainActor
    @objc func activeWorkspaceDidChange() {
        updateWallpaperIfNeeded(forceRefresh: false)
    }

    @MainActor
    @objc func workspaceDidWake() {
        updateWallpaperIfNeeded(forceRefresh: false)
    }

    @MainActor
    @objc func screenParametersDidChange() {
        updateWallpaperIfNeeded(forceRefresh: false)
    }
    
    @MainActor
    func setWallpaper(descriptor: ImageDescriptor) {
        imageDescriptor = descriptor
        updateWallpaperIfNeeded(forceRefresh: false)
    }

    /// 设置单屏壁纸；显式固定才持久保留图片，普通浏览在下次更新时继续跟随最新。
    /// - Parameters:
    ///   - descriptor: 已下载的壁纸。
    ///   - displayIdentifier: 目标屏幕的稳定标识。
    ///   - pinWallpaper: 是否由用户显式要求固定，默认为 true。
    func setWallpaper(
        descriptor: ImageDescriptor,
        forDisplayIdentifier displayIdentifier: String,
        pinWallpaper: Bool = true
    ) {
        var profiles = settings.wallpaperDisplayProfiles
        var profile = profiles[displayIdentifier] ?? WallpaperDisplayProfile()
        if let marketCode = descriptor.marketCode {
            profile.marketMode = .explicit
            profile.marketCode = marketCode
        } else {
            profile.marketMode = .automatic
            profile.marketCode = nil
        }
        profile.pinMode = pinWallpaper ? .pinned : .followLatest
        profile.pinnedWallpaperID = pinWallpaper ? descriptor.wallpaperIdentifier : nil
        profiles[displayIdentifier] = profile
        settings.wallpaperDisplayProfiles = profiles
        applyWallpaper(descriptor, toDisplayIdentifier: displayIdentifier)
    }

    /// 手动共享浏览覆盖所有在线屏幕的旧选择，不改动自动更新的屏幕范围配置。
    /// - Parameter descriptor: 同时应用到在线屏幕的已下载壁纸，下次更新后继续跟随最新。
    func browseWallpaperOnAllDisplays(descriptor: ImageDescriptor) {
        let identifiers = Set(Self.connectedDisplays().map { $0.identifier })
        settings.restoreSharedWallpaperSelection(forDisplayIdentifiers: identifiers)
        imageDescriptor = descriptor
        for identifier in identifiers {
            applyWallpaper(descriptor, toDisplayIdentifier: identifier)
        }
    }

    func followLatestWallpaper(forDisplayIdentifier displayIdentifier: String) {
        var profiles = settings.wallpaperDisplayProfiles
        var profile = profiles[displayIdentifier] ?? WallpaperDisplayProfile()
        profile.pinMode = .followLatest
        profile.pinnedWallpaperID = nil
        profiles[displayIdentifier] = profile
        settings.wallpaperDisplayProfiles = profiles

        let effectiveMarketCode = profile.effectiveMarketCode(
            globalMarketCode: settings.bingMarketCode
        )
        guard let descriptor = Database.instance.allImageDescriptors()
            .filter({
                $0.marketCode == effectiveMarketCode && $0.image.isOnDisk()
            })
            .max() else {
            return
        }
        applyWallpaper(descriptor, toDisplayIdentifier: displayIdentifier)
    }

    @MainActor
    func refreshWallpaper(force: Bool = false) {
        updateWallpaperIfNeeded(forceRefresh: force)
    }

    static func connectedDisplays() -> [WallpaperDisplayInfo] {
        return NSScreen.screens.compactMap { screen in
            guard let identifier = displayIdentifier(for: screen) else { return nil }
            let width = Int(screen.frame.width * screen.backingScaleFactor)
            let height = Int(screen.frame.height * screen.backingScaleFactor)
            let isMain = displayID(for: screen) == CGMainDisplayID()
            let mainSuffix = isMain ? " — Main Display" : ""
            return WallpaperDisplayInfo(
                identifier: identifier,
                title: "\(screen.localizedName) (\(width)×\(height))\(mainSuffix)",
                isMain: isMain
            )
        }.sorted { lhs, rhs in
            if lhs.isMain != rhs.isMain {
                return lhs.isMain
            }
            return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
        }
    }

    static func displayIdentifier(at point: NSPoint) -> String? {
        let screen = NSScreen.screens.first(where: { $0.frame.contains(point) })
            ?? NSScreen.main
        return screen.flatMap { displayIdentifier(for: $0) }
    }

    static func displayInfo(for identifier: String) -> WallpaperDisplayInfo? {
        connectedDisplays().first { $0.identifier == identifier }
    }

    nonisolated static func shouldApplyWallpaper(
        toDisplayIdentifier identifier: String?,
        isMainDisplay: Bool,
        mode: WallpaperDisplayMode,
        selectedDisplayIDs: Set<String>
    ) -> Bool {
        switch mode {
        case .all:
            return true
        case .main:
            return isMainDisplay
        case .selected:
            guard let identifier else { return false }
            return selectedDisplayIDs.contains(identifier)
        }
    }

    nonisolated static func wallpaperURL(_ currentURL: URL?, matches desiredURL: URL) -> Bool {
        guard let currentURL else { return false }

        if currentURL.isFileURL && desiredURL.isFileURL {
            return currentURL.standardizedFileURL.resolvingSymlinksInPath()
                == desiredURL.standardizedFileURL.resolvingSymlinksInPath()
        }

        return currentURL.absoluteURL == desiredURL.absoluteURL
    }

    @MainActor
    static func currentWallpaperIdentifier(forDisplayIdentifier identifier: String) -> String? {
        guard let screen = NSScreen.screens.first(where: { displayIdentifier(for: $0) == identifier }),
              let currentURL = NSWorkspace.shared.desktopImageURL(for: screen) else {
            return nil
        }
        return Database.instance.allImageDescriptors().first(where: {
            wallpaperURL(currentURL, matches: $0.image.downloadPath)
        })?.wallpaperIdentifier
    }

    static func currentWallpaperIdentifiers() -> Set<String> {
        let descriptors = Database.instance.allImageDescriptors()
        return Set(NSScreen.screens.compactMap { screen in
            guard let currentURL = NSWorkspace.shared.desktopImageURL(for: screen) else {
                return nil
            }
            return descriptors.first(where: {
                wallpaperURL(currentURL, matches: $0.image.downloadPath)
            })?.wallpaperIdentifier
        })
    }

    @MainActor
    private func updateWallpaperIfNeeded(forceRefresh: Bool) {
        let workspace = NSWorkspace.shared
        let mode = settings.wallpaperDisplayMode
        let selectedDisplayIDs = settings.selectedWallpaperDisplayIDs
        let downloadedDescriptors = Database.instance.allImageDescriptors()
            .filter { $0.image.isOnDisk() }
        var profiles = settings.wallpaperDisplayProfiles
        var profilesDidChange = false
        
        FileHandler.withWallpaperDirectoryAccess { _ in
            for screen in NSScreen.screens {
                let displayIdentifier = Self.displayIdentifier(for: screen)
                guard Self.shouldApplyWallpaper(
                    toDisplayIdentifier: displayIdentifier,
                    isMainDisplay: Self.displayID(for: screen) == CGMainDisplayID(),
                    mode: mode,
                    selectedDisplayIDs: selectedDisplayIDs
                ) else {
                    continue
                }

                var profile = displayIdentifier.flatMap { profiles[$0] }
                    ?? WallpaperDisplayProfile()
                guard let descriptor = desiredDescriptor(
                    for: &profile,
                    from: downloadedDescriptors
                ) else {
                    continue
                }
                if let displayIdentifier {
                    if profile.isDefault {
                        if profiles.removeValue(forKey: displayIdentifier) != nil {
                            profilesDidChange = true
                        }
                    } else if profiles[displayIdentifier] != profile {
                        profiles[displayIdentifier] = profile
                        profilesDidChange = true
                    }
                }
                let imageUrl = descriptor.image.downloadPath

                guard forceRefresh ||
                    !Self.wallpaperURL(workspace.desktopImageURL(for: screen), matches: imageUrl) else {
                    continue
                }

                do {
                    try workspace.setDesktopImageURL(imageUrl, for: screen, options: [:])
                } catch {
                    logger.error("Failed to set desktop image: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
        if profilesDidChange {
            settings.wallpaperDisplayProfiles = profiles
        }
    }

    private func desiredDescriptor(
        for profile: inout WallpaperDisplayProfile,
        from downloadedDescriptors: [ImageDescriptor]
    ) -> ImageDescriptor? {
        if profile.pinMode == .inherit,
           let pinnedWallpaperID = settings.pinnedWallpaperID {
            return downloadedDescriptors.first {
                $0.wallpaperIdentifier == pinnedWallpaperID
            }
        }

        let effectiveMarketCode = profile.effectiveMarketCode(
            globalMarketCode: settings.bingMarketCode
        )
        if profile.pinMode == .pinned {
            guard let pinnedWallpaperID = profile.pinnedWallpaperID else {
                return nil
            }
            return downloadedDescriptors.first {
                $0.wallpaperIdentifier == pinnedWallpaperID
            }
        }

        if profile.marketMode == .inherit,
           profile.pinMode == .inherit {
            return imageDescriptor
        }

        return downloadedDescriptors
            .filter { $0.marketCode == effectiveMarketCode }
            .max()
    }

    private func applyWallpaper(
        _ descriptor: ImageDescriptor,
        toDisplayIdentifier displayIdentifier: String
    ) {
        guard let screen = NSScreen.screens.first(where: {
            Self.displayIdentifier(for: $0) == displayIdentifier
        }) else {
            return
        }

        let imageURL = descriptor.image.downloadPath
        FileHandler.withWallpaperDirectoryAccess { _ in
            guard Self.wallpaperURL(
                NSWorkspace.shared.desktopImageURL(for: screen),
                matches: imageURL
            ) == false else {
                return
            }
            do {
                try NSWorkspace.shared.setDesktopImageURL(
                    imageURL,
                    for: screen,
                    options: [:]
                )
            } catch {
                logger.error("Failed to set desktop image: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private static func displayID(for screen: NSScreen) -> CGDirectDisplayID? {
        let screenNumberKey = NSDeviceDescriptionKey("NSScreenNumber")
        guard let screenNumber = screen.deviceDescription[screenNumberKey] as? NSNumber else {
            return nil
        }
        return CGDirectDisplayID(screenNumber.uint32Value)
    }

    private static func displayIdentifier(for screen: NSScreen) -> String? {
        guard let displayID = displayID(for: screen),
              let unmanagedUUID = CGDisplayCreateUUIDFromDisplayID(displayID) else {
            return nil
        }
        let uuid = unmanagedUUID.takeRetainedValue()
        return CFUUIDCreateString(nil, uuid) as String
    }
}
