import Cocoa
import OSLog
import UniformTypeIdentifiers

private let logger = Logger(
    subsystem: Logging.subsystem,
    category: Logging.Category.Menu.rawValue
)

@MainActor
final class MenuController: NSObject {
    private var statusItem: NSStatusItem?
    private var menu: NSMenu?
    private let settings = Settings()
    private var descriptors = [ImageDescriptor]()
    private var selectedDescriptorIndex = 0
    private var activeDisplayIdentifier: String?
    private var imageLoadGeneration = 0
    private var imageSelectorView: ImageSelectorView!
    var updateManager: UpdateManager?
    private static let IMAGE_VIEW_TAG = 6
    private static let TEXT_VIEW_TAG = 7
    private static let UPDATE_STATUS_TAG = 8
    private static let REFRESH_IMAGES_TAG = 9
    private static let FAVORITES_TAG = 11
    private static let ACTIVE_DISPLAY_TAG = 12
    /// 多屏手动切换范围入口的菜单标识。
    private static let SWITCHING_SCOPE_TAG = 13
    /// 主菜单预览和说明区域的宽度，单位为 pt，避免长显示器名称撑宽菜单。
    private static let MENU_CONTENT_WIDTH: CGFloat = 340
    private lazy var settingsWc = SettingsWc.instance()
    
    // MARK: - UI setup
    
    @MainActor
    func setup() {
        guard self.statusItem == nil && self.menu == nil else { return }
        if settings.hideMenuBarIcon == true {
            showNewestImage()
            return
        }
        
        self.statusItem = createStatusBarItem()
        self.menu = createMenu()
        self.statusItem!.menu = menu
        
        showNewestImage()
        updateStatusMenu()
    }
    
    /// 创建菜单栏入口，使用独立的单色山水模板，由系统适配明暗及选中状态。
    private func createStatusBarItem() -> NSStatusItem {
        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        
        if let button = statusItem.button {
            // 菜单栏使用矢量符号，避免完整应用图标缩小后丢失细节。
            let image = NSImage(named: "StatusBarIcon")?.copy() as? NSImage
            image?.size = NSSize(width: 18, height: 18)
            image?.isTemplate = true
            image?.accessibilityDescription = "BingWallpaper"
            button.image = image
        }
        
        return statusItem
    }
    
    private func createMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self
        menu.minimumWidth = MenuController.MENU_CONTENT_WIDTH
        
        let imageItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        imageSelectorView = ImageSelectorView(frame: CGRect(x: 0, y: 0, width: MenuController.MENU_CONTENT_WIDTH, height: imageSelectorViewHeight()))
        imageSelectorView.leftButton.action = #selector(MenuController.imageSelectorViewLeftButtonAction)
        imageSelectorView.leftButton.target = self
        imageSelectorView.rightButton.action = #selector(MenuController.imageSelectorViewRightButtonAction)
        imageSelectorView.rightButton.target = self
        imageSelectorView.imageClickAction = { [weak self] in
            self?.openImageSource(nil)
        }
        imageItem.view = imageSelectorView
        imageItem.tag = MenuController.IMAGE_VIEW_TAG
        menu.addItem(imageItem)
        
        menu.addItem(NSMenuItem.separator())

        let activeDisplayItem = NSMenuItem(
            title: "Display",
            action: nil,
            keyEquivalent: ""
        )
        activeDisplayItem.tag = MenuController.ACTIVE_DISPLAY_TAG
        activeDisplayItem.image = NSImage(
            systemSymbolName: "display",
            accessibilityDescription: "Current display"
        )
        activeDisplayItem.isEnabled = false
        menu.addItem(activeDisplayItem)

        let switchingScopeItem = NSMenuItem(title: "切换范围", action: nil, keyEquivalent: "")
        switchingScopeItem.tag = MenuController.SWITCHING_SCOPE_TAG
        menu.addItem(switchingScopeItem)

        let updateStatusItem = NSMenuItem(title: "Update Status", action: nil, keyEquivalent: "")
        updateStatusItem.tag = MenuController.UPDATE_STATUS_TAG
        menu.addItem(updateStatusItem)
        
        let refreshItem = NSMenuItem(title: "Refresh Images", action: #selector(refreshImages), keyEquivalent: "")
        refreshItem.target = self
        refreshItem.tag = MenuController.REFRESH_IMAGES_TAG
        menu.addItem(refreshItem)

        let favoritesItem = NSMenuItem(title: "Favorites", action: nil, keyEquivalent: "")
        favoritesItem.tag = MenuController.FAVORITES_TAG
        menu.addItem(favoritesItem)
        
        menu.addItem(NSMenuItem.separator())
        
        let appUpdateItem = NSMenuItem(title: "Check for app update", action: #selector(checkForAppUpdate), keyEquivalent: "")
        appUpdateItem.target = self
        menu.addItem(appUpdateItem)
        
        let settingsItem = NSMenuItem(title: "Settings", action: #selector(showSettingsWc), keyEquivalent: "")
        settingsItem.target = self
        menu.addItem(settingsItem)
        
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        
        return menu
    }
    
    // MARK: - IBActions
    
    @MainActor
    @objc func showSettingsWc(sender: NSMenuItem?) {
        (settingsWc.contentViewController as! SettingsVc).delegate = self
        (settingsWc.contentViewController as! SettingsVc).updateManager = updateManager
        settingsWc.showWindow(self)
        settingsWc.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    
    @MainActor
    @objc func refreshImages(sender: NSMenuItem) {
        updateManager?.update()
    }
    
    @MainActor
    @objc func checkForAppUpdate(sender: NSMenuItem) {
        Task {
            await AppUpdateManager.checkForUpdate(notifyUserAboutNoNewVersion: true)
        }
    }
    
    @MainActor
    @objc func imageSelectorViewLeftButtonAction(_ sender: NSButton) {
        if descriptors.indices.contains(selectedDescriptorIndex - 1) == false {
            return
        }
        
        selectedDescriptorIndex = selectedDescriptorIndex - 1
        updateSelectedImage(newSelectedDescriptorIndex: selectedDescriptorIndex)
        updateImageSelectorView(newSelectedDescriptorIndex: selectedDescriptorIndex)
    }
    
    @MainActor
    @objc func imageSelectorViewRightButtonAction(_ sender: NSButton) {
        if descriptors.indices.contains(selectedDescriptorIndex + 1) == false {
            return
        }
        
        selectedDescriptorIndex = selectedDescriptorIndex + 1
        updateSelectedImage(newSelectedDescriptorIndex: selectedDescriptorIndex)
        updateImageSelectorView(newSelectedDescriptorIndex: selectedDescriptorIndex)
    }
    
    @objc func openImageSource(_ sender: Any?) {
        guard let descriptor = descriptors[safe: selectedDescriptorIndex] else { return }
        NSWorkspace.shared.open(descriptor.copyrightUrl)
    }

    @objc func revealImageInFinder(_ sender: NSMenuItem) {
        guard let descriptor = descriptors[safe: selectedDescriptorIndex] else { return }
        NSWorkspace.shared.activateFileViewerSelecting([descriptor.image.downloadPath])
    }

    @MainActor
    @objc func toggleFavorite(_ sender: NSMenuItem) {
        guard let descriptor = descriptors[safe: selectedDescriptorIndex] else { return }
        var favorites = settings.favoriteWallpaperIDs
        if favorites.contains(descriptor.wallpaperIdentifier) {
            favorites.remove(descriptor.wallpaperIdentifier)
        } else {
            favorites.insert(descriptor.wallpaperIdentifier)
        }
        settings.favoriteWallpaperIDs = favorites
        updateFavoriteMenus()
    }

    @MainActor
    @objc func togglePinnedWallpaper(_ sender: NSMenuItem) {
        guard let descriptor = descriptors[safe: selectedDescriptorIndex] else {
            return
        }
        if let activeDisplayIdentifier {
            let profile = settings.wallpaperDisplayProfiles[activeDisplayIdentifier]
            if profile?.pinMode == .pinned,
               profile?.pinnedWallpaperID == descriptor.wallpaperIdentifier {
                WallpaperManager.shared.followLatestWallpaper(
                    forDisplayIdentifier: activeDisplayIdentifier
                )
            } else {
                WallpaperManager.shared.setWallpaper(
                    descriptor: descriptor,
                    forDisplayIdentifier: activeDisplayIdentifier
                )
            }
        } else {
            if settings.pinnedWallpaperID == descriptor.wallpaperIdentifier {
                settings.pinnedWallpaperID = nil
                showNewestImage()
            } else {
                settings.pinnedWallpaperID = descriptor.wallpaperIdentifier
                WallpaperManager.shared.setWallpaper(descriptor: descriptor)
            }
        }
        updateFavoriteMenus()
    }

    @MainActor
    @objc func selectFavoriteWallpaper(_ sender: NSMenuItem) {
        guard let wallpaperID = sender.representedObject as? String,
              let descriptor = Database.instance.allImageDescriptors()
                .first(where: { $0.wallpaperIdentifier == wallpaperID }),
              descriptor.image.isOnDisk() else {
            return
        }

        descriptors = ImageDescriptor.distinctWallpaperDescriptors(
            from: Database.instance.allImageDescriptors(marketCode: descriptor.marketCode)
                .filter { $0.image.isOnDisk() },
            preferredWallpaperID: wallpaperID
        )
        guard let index = descriptors.firstIndex(where: { $0.wallpaperIdentifier == wallpaperID }) else {
            return
        }
        selectedDescriptorIndex = index
        updateSelectedImage(newSelectedDescriptorIndex: index)
        updateImageSelectorView(newSelectedDescriptorIndex: index)
    }

    @MainActor
    @objc func saveImageCopy(_ sender: NSMenuItem) {
        guard let descriptor = descriptors[safe: selectedDescriptorIndex] else { return }

        let savePanel = NSSavePanel()
        savePanel.title = "Save Wallpaper Copy"
        savePanel.nameFieldStringValue = descriptor.image.fileName
        savePanel.allowedContentTypes = [.jpeg]
        savePanel.canCreateDirectories = true
        guard savePanel.runModal() == .OK, let destination = savePanel.url else { return }

        do {
            let data = try FileHandler.loadImageDataFromDisk(at: descriptor.image.downloadPath)
            let didStartAccess = destination.startAccessingSecurityScopedResource()
            defer {
                if didStartAccess {
                    destination.stopAccessingSecurityScopedResource()
                }
            }
            try data.write(to: destination, options: .atomic)
        } catch {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Couldn’t Save Wallpaper"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }
    
    // MARK: - Helper
    
    /// 根据预览区域宽度计算高度，与 XIB 中的 16:9 图片约束保持一致。
    private func imageSelectorViewHeight() -> CGFloat {
        let outerPadding = 5.0
        let buttonWidth = 15.0
        let innerPadding = 5.0
        let imageViewWidth = MenuController.MENU_CONTENT_WIDTH - outerPadding*2 - buttonWidth*2 - innerPadding*2
        let topMargin = 4.0
        return imageViewWidth / 16*9 + topMargin
    }
    
    /// 浏览或选择收藏时按用户选择更新所有屏幕或当前屏幕，避免隐式固定旧壁纸。
    @MainActor
    private func updateSelectedImage(newSelectedDescriptorIndex: Int) {
        guard let descriptor = descriptors[safe: newSelectedDescriptorIndex] else { return }
        if settings.switchesAllDisplaysTogether {
            WallpaperManager.shared.browseWallpaperOnAllDisplays(descriptor: descriptor)
        } else if let activeDisplayIdentifier {
            WallpaperManager.shared.setWallpaper(
                descriptor: descriptor,
                forDisplayIdentifier: activeDisplayIdentifier,
                pinWallpaper: false
            )
        }
    }

    /// 多屏时展示明确的切换范围和当前选项，单屏时隐藏该入口。
    private func updateWallpaperSwitchingScopeMenu() {
        guard let item = menu?.item(withTag: Self.SWITCHING_SCOPE_TAG) else { return }
        item.isHidden = WallpaperManager.connectedDisplays().count < 2
        let scopeMenu = NSMenu(title: "切换范围")
        for (title, allDisplays) in [("所有屏幕一起切换", true), ("仅当前屏幕", false)] {
            let option = NSMenuItem(title: title, action: #selector(selectWallpaperSwitchingScope(_:)), keyEquivalent: "")
            option.target = self
            option.representedObject = allDisplays
            option.state = settings.switchesAllDisplaysTogether == allDisplays ? .on : .off
            scopeMenu.addItem(option)
        }
        item.title = settings.switchesAllDisplaysTogether ? "切换范围：所有屏幕" : "切换范围：仅当前屏幕"
        item.submenu = scopeMenu
    }

    /// 记住手动切换范围；更改范围本身不立即替换壁纸。
    @objc private func selectWallpaperSwitchingScope(_ sender: NSMenuItem) {
        guard let allDisplays = sender.representedObject as? Bool else { return }
        settings.switchesAllDisplaysTogether = allDisplays
        updateWallpaperSwitchingScopeMenu()
    }

    @MainActor
    private func updateImageSelectorView(newSelectedDescriptorIndex: Int) {
        guard let menu = menu else { return }
        
        let descriptor = descriptors[safe: newSelectedDescriptorIndex]
        imageLoadGeneration += 1
        let loadGeneration = imageLoadGeneration
        if descriptor == nil {
            imageSelectorView.imageView.image = nil
        }
        Task {
            guard let descriptor else { return }
            do {
                let imageData = try await descriptor.image.loadFromDisk()
                await MainActor.run { [weak self] in
                    guard let self,
                          self.imageLoadGeneration == loadGeneration,
                          self.descriptors[safe: self.selectedDescriptorIndex]?.wallpaperIdentifier
                            == descriptor.wallpaperIdentifier else {
                        return
                    }
                    self.imageSelectorView.imageView.image = NSImage(data: imageData)
                }
            } catch {
                logger.error("Failed to load image from disk: \(String(describing: descriptor), privacy: .public)")
            }
        }
        
        if let oldTextItem = menu.item(withTag: MenuController.TEXT_VIEW_TAG) {
            menu.removeItem(oldTextItem)
        }

        let imageItem = menu.item(withTag: MenuController.IMAGE_VIEW_TAG)!
        imageItem.submenu = nil
        let textItemIndex = menu.index(of: imageItem) + 1
        if let descriptor {
            let info = descriptor.imageInfo
            // 标题由自定义视图显示，避免 NSMenu 按完整标题的单行长度撑宽菜单。
            let textItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
            textItem.tag = MenuController.TEXT_VIEW_TAG

            let textView = TextView(frame: CGRect(x: 0, y: 0, width: MenuController.MENU_CONTENT_WIDTH, height: 76))
            // 将长标题限制为两行，版权限制为一行，完整内容仍可在详情中查看。
            textView.descriptionLabel.maximumNumberOfLines = 2
            textView.descriptionLabel.lineBreakMode = .byWordWrapping
            textView.descriptionLabel.preferredMaxLayoutWidth = MenuController.MENU_CONTENT_WIDTH - 50
            textView.copyrightLabel.maximumNumberOfLines = 1
            textView.copyrightLabel.lineBreakMode = .byTruncatingTail
            textView.copyrightLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            textView.descriptionLabel.stringValue = info.title
            textView.copyrightLabel.stringValue = info.copyright
            textView.button.action = nil
            textView.button.target = nil
            textView.button.toolTip = "Show image details and actions"
            textItem.view = textView
            textItem.submenu = imageActionsMenu(for: descriptor)
            menu.insertItem(textItem, at: textItemIndex)
        }
        
        imageSelectorView.leftButton.isEnabled = descriptors.indices.contains(newSelectedDescriptorIndex - 1)
        imageSelectorView.rightButton.isEnabled = descriptors.indices.contains(newSelectedDescriptorIndex + 1)
    }

    private func imageActionsMenu(for descriptor: ImageDescriptor) -> NSMenu {
        let menu = NSMenu(title: "Wallpaper Details")
        let info = descriptor.imageInfo
        addImageDetail(title: "Title: \(info.title)", fullText: info.title, to: menu)
        addImageDetail(title: "Date: \(info.date)", fullText: info.date, to: menu)
        addImageDetail(title: "Region: \(info.region)", fullText: info.region, to: menu)
        if info.copyright.isEmpty == false {
            addImageDetail(
                title: "Copyright: \(info.copyright)",
                fullText: info.copyright,
                to: menu
            )
        }

        menu.addItem(.separator())
        let isFavorite = settings.favoriteWallpaperIDs.contains(descriptor.wallpaperIdentifier)
        addImageAction(
            title: isFavorite ? "Remove from Favorites" : "Add to Favorites",
            selector: #selector(toggleFavorite(_:)),
            systemImageName: isFavorite ? "star.slash" : "star",
            to: menu
        )
        let pinTitle: String
        let pinImageName: String
        let activePinnedWallpaperID = activeDisplayIdentifier.flatMap {
            settings.wallpaperDisplayProfiles[$0]
        }.flatMap { profile in
            profile.pinMode == .pinned ? profile.pinnedWallpaperID : nil
        }
        if activePinnedWallpaperID == descriptor.wallpaperIdentifier ||
            (activeDisplayIdentifier == nil &&
                settings.pinnedWallpaperID == descriptor.wallpaperIdentifier) {
            pinTitle = "Unpin Wallpaper"
            pinImageName = "pin.slash"
        } else if activeDisplayIdentifier != nil || settings.pinnedWallpaperID == nil {
            pinTitle = activeDisplayIdentifier == nil
                ? "Pin This Wallpaper"
                : "Pin This Wallpaper on This Display"
            pinImageName = "pin"
        } else {
            pinTitle = "Replace Pinned Wallpaper"
            pinImageName = "pin.fill"
        }
        addImageAction(
            title: pinTitle,
            selector: #selector(togglePinnedWallpaper(_:)),
            systemImageName: pinImageName,
            to: menu
        )

        menu.addItem(.separator())
        addImageAction(title: "Open Source on Bing", selector: #selector(openImageSource(_:)), to: menu)
        addImageAction(title: "Show in Finder", selector: #selector(revealImageInFinder(_:)), to: menu)
        addImageAction(title: "Save a Copy…", selector: #selector(saveImageCopy(_:)), to: menu)
        return menu
    }

    private func addImageDetail(title: String, fullText: String, to menu: NSMenu) {
        let displayTitle = title.count > 100 ? String(title.prefix(97)) + "…" : title
        let item = NSMenuItem(title: displayTitle, action: nil, keyEquivalent: "")
        item.toolTip = fullText
        item.isEnabled = false
        menu.addItem(item)
    }

    private func addImageAction(
        title: String,
        selector: Selector,
        systemImageName: String? = nil,
        to menu: NSMenu
    ) {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
        item.target = self
        if let systemImageName {
            item.image = NSImage(systemSymbolName: systemImageName, accessibilityDescription: title)
        }
        menu.addItem(item)
    }

    @MainActor
    private func updateFavoriteMenus() {
        guard let menu else { return }
        let allDescriptors = Database.instance.allImageDescriptors()
        let descriptorByID = allDescriptors.reduce(into: [String: ImageDescriptor]()) {
            $0[$1.wallpaperIdentifier] = $1
        }

        guard let favoritesItem = menu.item(withTag: MenuController.FAVORITES_TAG) else { return }
        let favoritesMenu = NSMenu(title: "Favorites")
        let favoriteDescriptors = settings.favoriteWallpaperIDs
            .compactMap { descriptorByID[$0] }
            .sorted(by: >)
        if favoriteDescriptors.isEmpty {
            let emptyItem = NSMenuItem(title: "No Favorites", action: nil, keyEquivalent: "")
            emptyItem.isEnabled = false
            favoritesMenu.addItem(emptyItem)
        } else {
            for descriptor in favoriteDescriptors {
                let info = descriptor.imageInfo
                let item = NSMenuItem(
                    title: "\(info.title) — \(info.date)",
                    action: #selector(selectFavoriteWallpaper(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.representedObject = descriptor.wallpaperIdentifier
                item.toolTip = "\(info.region)\n\(info.copyright)"
                item.isEnabled = descriptor.image.isOnDisk()
                favoritesMenu.addItem(item)
            }
        }
        favoritesItem.title = favoriteDescriptors.isEmpty
            ? "Favorites"
            : "Favorites (\(favoriteDescriptors.count))"
        favoritesItem.image = NSImage(
            systemSymbolName: favoriteDescriptors.isEmpty ? "star" : "star.fill",
            accessibilityDescription: "Favorite wallpapers"
        )
        favoritesItem.submenu = favoritesMenu
    }

    @MainActor
    private func updateStatusMenu() {
        guard let menu,
              let updateManager,
              let statusItem = menu.item(withTag: MenuController.UPDATE_STATUS_TAG) else {
            return
        }

        let status = updateManager.status
        statusItem.title = status.menuTitle
        statusItem.image = updateStatusImage(for: status.phase)

        let detailsMenu = NSMenu()
        addStatusDetail(
            title: "Last successful update: \(formattedDate(status.lastSuccessAt))",
            to: detailsMenu
        )
        if let lastAttemptAt = status.lastAttemptAt {
            addStatusDetail(title: "Last attempt: \(formattedDate(lastAttemptAt))", to: detailsMenu)
        }
        if let nextAttemptAt = status.nextAttemptAt {
            let label = status.phase == .retrying ? "Next retry" : "Next update"
            addStatusDetail(title: "\(label): \(formattedDate(nextAttemptAt))", to: detailsMenu)
        }
        if let failure = status.failure {
            detailsMenu.addItem(.separator())
            addStatusDetail(title: "Failed step: \(failure.stage.title)", to: detailsMenu)
            let message = failure.message.count > 120
                ? String(failure.message.prefix(117)) + "…"
                : failure.message
            let errorItem = NSMenuItem(title: message, action: nil, keyEquivalent: "")
            errorItem.toolTip = failure.message
            errorItem.isEnabled = false
            detailsMenu.addItem(errorItem)
        }
        statusItem.submenu = detailsMenu

        if let refreshItem = menu.item(withTag: MenuController.REFRESH_IMAGES_TAG) {
            refreshItem.title = status.phase == .retrying || status.phase == .failed
                ? "Retry Now"
                : "Refresh Images"
            refreshItem.isEnabled = status.phase != .updating
        }
    }

    private func addStatusDetail(title: String, to menu: NSMenu) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        menu.addItem(item)
    }

    private func formattedDate(_ date: Date?) -> String {
        guard let date else { return "Never" }
        return DateFormatter.localizedString(from: date, dateStyle: .short, timeStyle: .short)
    }

    private func updateStatusImage(for phase: WallpaperUpdatePhase) -> NSImage? {
        let symbolName: String
        switch phase {
        case .idle, .succeeded:
            symbolName = "checkmark.circle"
        case .updating:
            symbolName = "arrow.triangle.2.circlepath"
        case .retrying, .failed:
            symbolName = "exclamationmark.triangle"
        }
        return NSImage(systemSymbolName: symbolName, accessibilityDescription: "Wallpaper update status")
    }
    
    @MainActor
    private func showNewestImage() {
        let downloadedDescriptors = Database.instance.allImageDescriptors()
            .filter { $0.image.isOnDisk() }
        let pinnedDescriptor = settings.pinnedWallpaperID.flatMap { pinnedID in
            downloadedDescriptors.first { $0.wallpaperIdentifier == pinnedID }
        }
        let pinnedWallpaperIsUnavailable = settings.pinnedWallpaperID != nil
            && pinnedDescriptor == nil
        let visibleMarketCode = pinnedDescriptor?.marketCode ?? settings.bingMarketCode
        self.descriptors = ImageDescriptor.distinctWallpaperDescriptors(
            from: downloadedDescriptors.filter { $0.marketCode == visibleMarketCode },
            preferredWallpaperID: pinnedDescriptor?.wallpaperIdentifier
        )
        guard descriptors.isEmpty == false else {
            selectedDescriptorIndex = 0
            imageSelectorView?.imageView.image = nil
            if let pinnedDescriptor {
                WallpaperManager.shared.setWallpaper(descriptor: pinnedDescriptor)
            }
            updateFavoriteMenus()
            return
        }
        selectedDescriptorIndex = pinnedDescriptor.flatMap { pinned in
            descriptors.firstIndex { $0.wallpaperIdentifier == pinned.wallpaperIdentifier }
        } ?? descriptors.count - 1
        if let pinnedDescriptor {
            WallpaperManager.shared.setWallpaper(descriptor: pinnedDescriptor)
        } else if let newestDescriptor = descriptors[safe: selectedDescriptorIndex] {
            if !pinnedWallpaperIsUnavailable {
                WallpaperManager.shared.setWallpaper(descriptor: newestDescriptor)
            }
        } else {
            imageSelectorView?.imageView.image = nil
        }
        updateFavoriteMenus()
    }

    private func showWallpaperForMenuDisplay() {
        activeDisplayIdentifier = WallpaperManager.displayIdentifier(
            at: NSEvent.mouseLocation
        )
        guard let activeDisplayIdentifier else {
            showNewestImage()
            return
        }

        showWallpaper(forMenuDisplayIdentifier: activeDisplayIdentifier)
    }

    private func showWallpaper(forMenuDisplayIdentifier activeDisplayIdentifier: String) {

        let downloadedDescriptors = Database.instance.allImageDescriptors()
            .filter { $0.image.isOnDisk() }
        let profile = settings.wallpaperDisplayProfiles[activeDisplayIdentifier]
            ?? WallpaperDisplayProfile()
        let currentWallpaperID = WallpaperManager.currentWallpaperIdentifier(
            forDisplayIdentifier: activeDisplayIdentifier
        )
        let effectiveMarketCode = profile.effectiveMarketCode(
            globalMarketCode: settings.bingMarketCode
        )

        let configuredWallpaperID: String?
        if profile.pinMode == .pinned {
            configuredWallpaperID = profile.pinnedWallpaperID
        } else if profile.pinMode == .inherit,
                  let globallyPinnedWallpaperID = settings.pinnedWallpaperID {
            configuredWallpaperID = globallyPinnedWallpaperID
        } else if profile.pinMode == .followLatest || profile.marketMode != .inherit {
            configuredWallpaperID = downloadedDescriptors
                .filter { $0.marketCode == effectiveMarketCode }
                .max()?
                .wallpaperIdentifier
        } else {
            configuredWallpaperID = currentWallpaperID
        }

        let displayedDescriptor = (configuredWallpaperID ?? currentWallpaperID).flatMap {
            wallpaperID in
            downloadedDescriptors.first { $0.wallpaperIdentifier == wallpaperID }
        }
        let visibleMarketCode = displayedDescriptor?.marketCode ?? effectiveMarketCode
        descriptors = ImageDescriptor.distinctWallpaperDescriptors(
            from: downloadedDescriptors.filter { $0.marketCode == visibleMarketCode },
            preferredWallpaperID: displayedDescriptor?.wallpaperIdentifier
        )
        selectedDescriptorIndex = displayedDescriptor.flatMap { displayed in
            descriptors.firstIndex {
                $0.wallpaperIdentifier == displayed.wallpaperIdentifier
            }
        } ?? max(0, descriptors.count - 1)

        if let displayItem = menu?.item(withTag: MenuController.ACTIVE_DISPLAY_TAG) {
            let title = WallpaperManager.displayInfo(
                for: activeDisplayIdentifier
            )?.title ?? "Current Display"
            // 菜单保留简短名称，完整型号及分辨率通过悬停提示查看。
            let compactTitle = title.count > 30 ? String(title.prefix(27)) + "…" : title
            displayItem.title = "Display: \(compactTitle)"
            displayItem.toolTip = "\(title)\nUse the switching scope menu to choose all displays or this display."
        }
    }
}

// MARK: - Delegates

extension MenuController: UpdateManagerDelegate {
    func wallpaperLibraryDidChange(forceWallpaperRefresh: Bool) {
        // 即使菜单打开也先更新全局最新图片，避免只刷新预览而漏掉桌面更新。
        showNewestImage()
        if let activeDisplayIdentifier {
            showWallpaper(forMenuDisplayIdentifier: activeDisplayIdentifier)
            updateImageSelectorView(newSelectedDescriptorIndex: selectedDescriptorIndex)
        }
        if forceWallpaperRefresh {
            WallpaperManager.shared.refreshWallpaper(force: true)
        }
    }

    func updateStatusDidChange(_ status: WallpaperUpdateStatus) {
        updateStatusMenu()
    }
}

extension MenuController: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        showWallpaperForMenuDisplay()
        updateWallpaperSwitchingScopeMenu()
        updateImageSelectorView(newSelectedDescriptorIndex: selectedDescriptorIndex)
        updateStatusMenu()
        updateFavoriteMenus()
    }

    func menuDidClose(_ menu: NSMenu) {
        activeDisplayIdentifier = nil
    }
}

extension MenuController: SettingsVcDelegate {
    func bingMarketDidChange() {
        showNewestImage()
    }

    func wallpaperDisplaySelectionDidChange() {
        WallpaperManager.shared.refreshWallpaper()
    }

    func wallpaperStorageDidChange() {
        showNewestImage()
    }

    func wallpaperDatabaseDidReset() {
        showNewestImage()
    }

    func showMenuBarIcon() {
        setup()
    }
    
    func hideMenuBarIcon() {
        guard let statusItem = statusItem else { return }
        NSStatusBar.system.removeStatusItem(statusItem)
        self.menu?.removeAllItems()
        self.menu = nil
        self.statusItem = nil
    }
}
