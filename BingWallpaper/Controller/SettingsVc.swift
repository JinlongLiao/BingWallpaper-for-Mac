import Cocoa
import OSLog
import ServiceManagement

private let logger = Logger(
    subsystem: Logging.subsystem,
    category: Logging.Category.Settings.rawValue
)

protocol SettingsVcDelegate: AnyObject {
    @MainActor
    func bingMarketDidChange()
    @MainActor
    func wallpaperSourceDidChange()
    @MainActor
    func wallpaperDisplaySelectionDidChange()
    @MainActor
    func wallpaperStorageDidChange()
    @MainActor
    func wallpaperDatabaseDidReset()
    @MainActor
    func appLanguageDidChange()
    @MainActor
    func showMenuBarIcon()
    @MainActor
    func hideMenuBarIcon()
}

private struct DisplayWallpaperOption {
    let wallpaperID: String
    let marketCode: String?
    let title: String
}

@MainActor
private final class DisplayProfileRowController: NSObject {
    static let inheritSelection = "__inherit_global_wallpaper__"
    static let latestSelection = "__follow_latest_wallpaper__"

    let display: WallpaperDisplayInfo
    let marketSelector: NSPopUpButton
    let wallpaperSelector = NSPopUpButton(frame: .zero, pullsDown: false)

    private let globalMarketCode: String?
    private let wallpaperOptions: [DisplayWallpaperOption]

    init(
        display: WallpaperDisplayInfo,
        marketSelector: NSPopUpButton,
        profile: WallpaperDisplayProfile,
        globalMarketCode: String?,
        wallpaperOptions: [DisplayWallpaperOption]
    ) {
        self.display = display
        self.marketSelector = marketSelector
        self.globalMarketCode = globalMarketCode
        self.wallpaperOptions = wallpaperOptions
        super.init()

        marketSelector.target = self
        marketSelector.action = #selector(marketSelectionDidChange(_:))
        rebuildWallpaperSelector(selecting: Self.selectionValue(for: profile))
    }

    var wallpaperSelection: String {
        wallpaperSelector.selectedItem?.representedObject as? String
            ?? Self.latestSelection
    }

    private static func selectionValue(for profile: WallpaperDisplayProfile) -> String {
        switch profile.pinMode {
        case .inherit:
            return inheritSelection
        case .followLatest:
            return latestSelection
        case .pinned:
            return profile.pinnedWallpaperID ?? latestSelection
        }
    }

    @objc private func marketSelectionDidChange(_ sender: NSPopUpButton) {
        rebuildWallpaperSelector(selecting: Self.latestSelection)
    }

    private func effectiveMarketCode() -> String? {
        let value = marketSelector.selectedItem?.representedObject as? String ?? "inherit"
        switch value {
        case "inherit":
            return globalMarketCode
        case "automatic":
            return nil
        default:
            return WallpaperChannel.isSupported(value) ? value : globalMarketCode
        }
    }

    private func rebuildWallpaperSelector(selecting selection: String) {
        wallpaperSelector.removeAllItems()
        addOption(
            title: L("Inherit Global Wallpaper"),
            value: Self.inheritSelection
        )
        addOption(
            title: L("Follow Latest in This Source"),
            value: Self.latestSelection
        )

        let matchingOptions = wallpaperOptions.filter {
            $0.marketCode == effectiveMarketCode()
        }
        if matchingOptions.isEmpty {
            let unavailableItem = NSMenuItem(
                title: L("No downloaded wallpapers for this source"),
                action: nil,
                keyEquivalent: ""
            )
            unavailableItem.isEnabled = false
            wallpaperSelector.menu?.addItem(.separator())
            wallpaperSelector.menu?.addItem(unavailableItem)
        } else {
            wallpaperSelector.menu?.addItem(.separator())
            for option in matchingOptions {
                addOption(title: option.title, value: option.wallpaperID)
            }
        }

        let selectedItem = wallpaperSelector.itemArray.first {
            ($0.representedObject as? String) == selection
        } ?? wallpaperSelector.itemArray.first {
            ($0.representedObject as? String) == Self.latestSelection
        }
        wallpaperSelector.select(selectedItem)
        wallpaperSelector.toolTip = selectedItem?.title
    }

    private func addOption(title: String, value: String) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.representedObject = value
        wallpaperSelector.menu?.addItem(item)
    }
}

class SettingsVc: NSViewController {
    @IBOutlet var launchAtLoginCheckBox: NSButton!
    @IBOutlet weak var hideMenuBarIconCheckBox: NSButton!
    @IBOutlet var imagePathButton: NSButton!
    @IBOutlet weak var keepImagesSlider: NSSlider!
    @IBOutlet weak var keepImagesTextField: NSTextField!

    private let languageLabel = NSTextField(labelWithString: "")
    private let languagePopUpButton = NSPopUpButton(frame: .zero, pullsDown: false)
    private let wallpaperSourceLabel = NSTextField(labelWithString: "")
    private let wallpaperSourcePopUpButton = NSPopUpButton(frame: .zero, pullsDown: false)
    private let bingMarketLabel = NSTextField(labelWithString: "")
    private let bingMarketPopUpButton = NSPopUpButton(frame: .zero, pullsDown: false)
    private var bingMarketTopConstraint: NSLayoutConstraint?
    private let wallpaperAlchemyCategoryLabel = NSTextField(labelWithString: "")
    /// 点击后弹出可搜索的分类面板，分类有近千个，下拉菜单难以查找。
    private let wallpaperAlchemyCategoryButton = NSButton(title: "", target: nil, action: nil)
    private var wallpaperAlchemyCategoryPopover: NSPopover?
    private weak var wallpaperAlchemyCategoryPicker: WallpaperAlchemyCategoryPickerViewController?
    private var wallpaperAlchemyCategories: [DownloadManager.WallpaperAlchemyCategory]?
    private var wallpaperAlchemyCategoriesFailed = false
    private var wallpaperAlchemyCategoriesLocale: String?
    private var wallpaperAlchemyCategoriesTask: Task<Void, Never>?
    private var wallpaperAlchemyCategoryValidationTask: Task<Void, Never>?
    /// 已保存但没有桌面壁纸的分类编号，在分类按钮上给出警示。
    private var emptyWallpaperAlchemyCategoryID: Int?
    private let wallpaperAlchemyRefreshLabel = NSTextField(labelWithString: "")
    private let wallpaperAlchemyRefreshPopUpButton = NSPopUpButton(frame: .zero, pullsDown: false)
    /// 显示器行的两种上边约束：显示定时更换行时接在它下方，否则直接接在来源选项行下方。
    private var wallpaperDisplayBelowRefreshConstraint: NSLayoutConstraint?
    private var wallpaperDisplayBelowMarketConstraint: NSLayoutConstraint?
    /// 分类列表按语言缓存，重复打开设置时无需再次请求。
    private static var cachedWallpaperAlchemyCategories = [String: [DownloadManager.WallpaperAlchemyCategory]]()
    private let wallpaperDisplayLabel = NSTextField(labelWithString: "")
    private let wallpaperDisplayPopUpButton = NSPopUpButton(frame: .zero, pullsDown: false)
    private let displayProfilesLabel = NSTextField(labelWithString: "")
    private let displayProfilesButton = NSButton(title: "", target: nil, action: nil)
    /// 故事板中静态控件的英文原文，切换语言时据此重新翻译。
    private var storyboardTexts = [(view: NSView, key: String)]()
    
    private let settings = Settings()
    weak var delegate: SettingsVcDelegate?
    weak var updateManager: UpdateManager?
    
    // MARK: - Lifecycle
    
    override func viewDidLoad() {
        super.viewDidLoad()
        captureStoryboardTexts()
        refreshLaunchAtLoginCheckbox()
        hideMenuBarIconCheckBox.state = settings.hideMenuBarIcon ? .on : .off
        imagePathButton.title = settings.imageDownloadPath.path
        imagePathButton.toolTip = imagePathButton.title
        keepImagesSlider.integerValue = settings.keepImageDuration
        setKeepImagesText()
        setupBingMarketSelector()
        setupWallpaperSourceSelector()
        setupLanguageSelector()
        setupWallpaperAlchemyCategorySelector()
        setupWallpaperDisplaySelector()
        setupWallpaperAlchemyRefreshSelector()
        setupDisplayProfilesButton()
        applyLocalization()
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        refreshLaunchAtLoginCheckbox()
        refreshWallpaperDisplaySelector()
        refreshDisplayProfilesButton()
        refreshWallpaperAlchemySelectorState()
        // 上次加载失败或界面语言已变化时重新获取分类。
        if wallpaperAlchemyCategoriesFailed || wallpaperAlchemyCategoriesLocale != settings.wallpaperAlchemyLocale {
            loadWallpaperAlchemyCategories()
        }
        checkSavedWallpaperAlchemyCategory()
    }

    /// 打开设置时检查已保存的分类，之前选中的空分类会持续导致更新失败，需要明确提示。
    private func checkSavedWallpaperAlchemyCategory() {
        guard let category = settings.wallpaperAlchemyCategory else { return }
        let locale = settings.wallpaperAlchemyLocale
        Task { @MainActor [weak self] in
            guard let hasWallpapers = try? await DownloadManager.wallpaperAlchemyCategoryHasDesktopWallpapers(
                categoryID: category.id,
                locale: locale
            ), let self, self.settings.wallpaperAlchemyCategory?.id == category.id else { return }
            self.emptyWallpaperAlchemyCategoryID = hasWallpapers ? nil : category.id
            self.refreshWallpaperAlchemyCategoryButton()
        }
    }

    // MARK: - Actions

    @IBAction func launchAtLoginAction(_ sender: NSButton) {
        let newState = sender.state == .on
        do {
            try settings.setLaunchAtLogin(newState)
        } catch {
            logger.error("Failed to toggle launch-at-login: \(String(describing: error), privacy: .public)")
            refreshLaunchAtLoginCheckbox()
            presentLaunchAtLoginError(error)
            return
        }

        // Sync the checkbox to the real status 
        refreshLaunchAtLoginCheckbox()

        if newState, settings.launchAtLoginRequiresApproval {
            promptToApproveLoginItem()
        }
    }
    
    @IBAction func hideMenuBarIconCheckBoxAction(_ sender: NSButton) {
        let newState = sender.state == .on
        settings.hideMenuBarIcon = newState
        if newState == true {
            delegate?.hideMenuBarIcon()
        } else {
            delegate?.showMenuBarIcon()
        }
    }
    
    @IBAction func imagePathButtonAction(_ sender: NSButton) {
        let dialog = NSOpenPanel()
        dialog.showsResizeIndicator = true
        dialog.showsHiddenFiles = false
        dialog.allowsMultipleSelection = false
        dialog.canChooseDirectories = true
        
        if dialog.runModal() == NSApplication.ModalResponse.OK {
            guard let result = dialog.url else { return }
            do {
                try settings.setImageDownloadPath(result)
                imagePathButton.title = result.path
                imagePathButton.toolTip = result.path
                delegate?.wallpaperStorageDidChange()
                updateManager?.update()
            } catch {
                logger.error("Failed to save image directory permission: \(error.localizedDescription, privacy: .public)")
                presentImagePathError(error)
            }
        }
    }

    @objc private func bingMarketAction(_ sender: NSPopUpButton) {
        let oldMarketCode = settings.bingMarketCode
        let newMarketCode = sender.selectedItem?.representedObject as? String
        guard oldMarketCode != newMarketCode else { return }
        settings.releaseSelections(followingPreviousGlobalChannel: settings.globalChannelCode)
        settings.bingMarketCode = newMarketCode
        refreshDisplayProfilesButton()
        delegate?.bingMarketDidChange()
        updateManager?.update()
    }

    @objc private func wallpaperSourceAction(_ sender: NSPopUpButton) {
        guard let rawValue = sender.selectedItem?.representedObject as? String,
              let newSource = WallpaperSource(rawValue: rawValue),
              newSource != settings.wallpaperSource else {
            return
        }
        // 跟随旧来源的屏幕一并切到新来源，壁纸立即更新而不必等待下一次下载。
        settings.releaseSelections(followingPreviousGlobalChannel: settings.globalChannelCode)
        settings.wallpaperSource = newSource
        refreshBingMarketSelectorState()
        refreshDisplayProfilesButton()
        delegate?.wallpaperSourceDidChange()
        updateManager?.update()
    }

    @objc private func languageAction(_ sender: NSPopUpButton) {
        guard let rawValue = sender.selectedItem?.representedObject as? String,
              let newLanguage = AppLanguage(rawValue: rawValue),
              newLanguage != settings.appLanguage else { return }
        let oldAlchemyLocale = settings.wallpaperAlchemyLocale
        settings.appLanguage = newLanguage
        applyLocalization()
        delegate?.appLanguageDidChange()

        guard settings.wallpaperAlchemyLocale != oldAlchemyLocale else { return }
        wallpaperAlchemyCategoryPopover?.close()
        loadWallpaperAlchemyCategories()
        // 重新获取 Wallpaper Alchemy 列表，图片标题换成新语言。
        if settings.requiredChannelCodes.contains(WallpaperChannel.wallpaperAlchemyCode) {
            updateManager?.update()
        }
    }

    @objc private func wallpaperAlchemyCategoryButtonAction(_ sender: NSButton) {
        if let popover = wallpaperAlchemyCategoryPopover, popover.isShown {
            popover.close()
            return
        }
        if wallpaperAlchemyCategoriesFailed {
            loadWallpaperAlchemyCategories()
        }
        let picker = WallpaperAlchemyCategoryPickerViewController(
            selectedCategoryID: settings.wallpaperAlchemyCategory?.id,
            state: wallpaperAlchemyCategoryPickerState()
        )
        picker.onSelect = { [weak self] category in
            self?.wallpaperAlchemyCategoryPopover?.close()
            self?.selectWallpaperAlchemyCategory(category)
        }
        picker.onRetry = { [weak self] in
            self?.loadWallpaperAlchemyCategories()
        }
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = picker
        popover.contentSize = NSSize(width: 360, height: 400)
        wallpaperAlchemyCategoryPicker = picker
        wallpaperAlchemyCategoryPopover = popover
        popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .maxY)
    }

    /// 先确认分类有桌面壁纸再保存，避免选中空分类后更新失败、壁纸毫无变化。
    private func selectWallpaperAlchemyCategory(_ category: DownloadManager.WallpaperAlchemyCategory?) {
        wallpaperAlchemyCategoryValidationTask?.cancel()
        guard category?.id != settings.wallpaperAlchemyCategory?.id else {
            refreshWallpaperAlchemyCategoryButton()
            return
        }
        guard let category else {
            applyWallpaperAlchemyCategory(nil)
            return
        }

        wallpaperAlchemyCategoryButton.title = L("Checking “%@”…", category.displayTitle)
        let locale = settings.wallpaperAlchemyLocale
        wallpaperAlchemyCategoryValidationTask = Task { @MainActor [weak self] in
            let hasWallpapers: Bool
            do {
                hasWallpapers = try await DownloadManager.wallpaperAlchemyCategoryHasDesktopWallpapers(
                    categoryID: category.id,
                    locale: locale
                )
            } catch {
                // 网络异常时照常保存，由更新流程重试并在菜单中提示。
                logger.error("Failed to check Wallpaper Alchemy category: \(error.localizedDescription, privacy: .public)")
                hasWallpapers = true
            }
            guard let self, Task.isCancelled == false else { return }
            guard hasWallpapers else {
                self.refreshWallpaperAlchemyCategoryButton()
                self.presentEmptyWallpaperAlchemyCategoryAlert(category)
                return
            }
            self.applyWallpaperAlchemyCategory(category)
        }
    }

    private func presentEmptyWallpaperAlchemyCategoryAlert(_ category: DownloadManager.WallpaperAlchemyCategory) {
        let alert = NSAlert()
        alert.messageText = L("“%@” has no desktop wallpapers", category.displayTitle)
        alert.informativeText = L("Please choose another category. The current category is kept.")
        alert.alertStyle = .informational
        alert.addButton(withTitle: L("OK"))
        if let window = view.window {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }

    private func applyWallpaperAlchemyCategory(_ category: DownloadManager.WallpaperAlchemyCategory?) {
        emptyWallpaperAlchemyCategoryID = nil
        settings.wallpaperAlchemyCategory = category
        refreshWallpaperAlchemyCategoryButton()
        delegate?.wallpaperSourceDidChange()
        updateManager?.update()
    }

    @objc private func wallpaperAlchemyRefreshAction(_ sender: NSPopUpButton) {
        guard let rawValue = sender.selectedItem?.representedObject as? Int,
              let newInterval = WallpaperAlchemyRefreshInterval(rawValue: rawValue) else { return }
        let previousInterval = settings.wallpaperAlchemyRefreshInterval
        guard newInterval != previousInterval else { return }
        settings.wallpaperAlchemyRefreshInterval = newInterval
        updateManager?.wallpaperAlchemyRefreshIntervalDidChange(from: previousInterval)
    }

    private func wallpaperAlchemyCategoryPickerState() -> WallpaperAlchemyCategoryPickerViewController.State {
        if let categories = wallpaperAlchemyCategories {
            return .loaded(categories)
        }
        return wallpaperAlchemyCategoriesFailed ? .failed : .loading
    }

    @objc private func wallpaperDisplayAction(_ sender: NSPopUpButton) {
        let oldMode = settings.wallpaperDisplayMode
        guard let rawValue = sender.selectedItem?.representedObject as? String,
              let newMode = WallpaperDisplayMode(rawValue: rawValue) else {
            refreshWallpaperDisplaySelector()
            return
        }

        if newMode == .selected, !presentWallpaperDisplaySelection() {
            selectWallpaperDisplayMode(oldMode)
            return
        }

        settings.wallpaperDisplayMode = newMode
        refreshWallpaperDisplaySelector()
        guard oldMode != newMode || newMode == .selected else { return }
        delegate?.wallpaperDisplaySelectionDidChange()
    }

    @objc private func displayProfilesAction(_ sender: NSButton) {
        presentDisplayProfileConfiguration()
    }
    
    @IBAction func keepImagesSliderAction(_ sender: NSSlider) {
        settings.keepImageDuration = sender.integerValue
        setKeepImagesText()
    }
    
    @IBAction func resetDatabaseButtonAction(_ sender: NSButton) {
        logger.info("Resetting Database...")
        do {
            try Database.instance.deleteAllImageDescriptors()
            settings.resetWallpaperLibrarySelections()
            delegate?.wallpaperDatabaseDidReset()
            updateManager?.update()
        } catch let error {
            logger.error("Failed resetting Database: \(error.localizedDescription, privacy: .public)")
            let alert = NSAlert()
            alert.messageText = L("Failed to reset Database")
            alert.informativeText = error.localizedDescription
            let updateButton = alert.addButton(withTitle: L("Ok"))
            alert.alertStyle = .informational
            alert.window.defaultButtonCell = updateButton.cell as? NSButtonCell
            alert.runModal()
        }
    }
    
    // MARK: - Private

    private func refreshLaunchAtLoginCheckbox() {
        launchAtLoginCheckBox.state = settings.launchAtLogin ? .on : .off
    }

    private func populateBingMarketSelector() {
        let options = BingMarketOption.all
        bingMarketPopUpButton.removeAllItems()
        for option in options {
            let item = NSMenuItem(title: option.title, action: nil, keyEquivalent: "")
            item.representedObject = option.code
            bingMarketPopUpButton.menu?.addItem(item)
        }

        if let selectedIndex = options.firstIndex(where: { $0.code == settings.bingMarketCode }) {
            bingMarketPopUpButton.selectItem(at: selectedIndex)
        }
    }

    private func populateWallpaperSourceSelector() {
        wallpaperSourcePopUpButton.removeAllItems()
        for source in WallpaperSource.allCases {
            let item = NSMenuItem(title: source.title, action: nil, keyEquivalent: "")
            item.representedObject = source.rawValue
            wallpaperSourcePopUpButton.menu?.addItem(item)
        }
        wallpaperSourcePopUpButton.select(wallpaperSourcePopUpButton.itemArray.first {
            ($0.representedObject as? String) == settings.wallpaperSource.rawValue
        })
    }

    private func populateLanguageSelector() {
        languagePopUpButton.removeAllItems()
        for language in AppLanguage.allCases {
            let item = NSMenuItem(title: language.title, action: nil, keyEquivalent: "")
            item.representedObject = language.rawValue
            languagePopUpButton.menu?.addItem(item)
        }
        languagePopUpButton.select(languagePopUpButton.itemArray.first {
            ($0.representedObject as? String) == settings.appLanguage.rawValue
        })
    }

    /// 记下故事板中静态文字的英文原文；路径按钮和保留数量文字由代码设置，不在其中。
    private func captureStoryboardTexts() {
        let dynamicViews: [NSView] = [imagePathButton, keepImagesTextField]
        var pending = view.subviews
        while let subview = pending.popLast() {
            pending.append(contentsOf: subview.subviews)
            guard dynamicViews.contains(where: { $0 === subview }) == false else { continue }
            if let button = subview as? NSButton, button.title.isEmpty == false {
                storyboardTexts.append((button, button.title))
            } else if let textField = subview as? NSTextField, textField.isEditable == false,
                      textField.stringValue.isEmpty == false {
                storyboardTexts.append((textField, textField.stringValue))
            }
        }
    }

    /// 按当前界面语言刷新设置窗口中的全部文字。
    private func applyLocalization() {
        for (textView, key) in storyboardTexts {
            if let button = textView as? NSButton {
                button.title = L(key)
            } else if let textField = textView as? NSTextField {
                textField.stringValue = L(key)
            }
        }
        languageLabel.stringValue = L("Language:")
        wallpaperSourceLabel.stringValue = L("Image source:")
        bingMarketLabel.stringValue = L("Bing region:")
        wallpaperAlchemyCategoryLabel.stringValue = L("Alchemy category:")
        wallpaperAlchemyRefreshLabel.stringValue = L("Change wallpaper:")
        populateWallpaperAlchemyRefreshSelector()
        wallpaperDisplayLabel.stringValue = L("Apply wallpaper to:")
        displayProfilesLabel.stringValue = L("Per-display profiles:")
        populateLanguageSelector()
        populateWallpaperSourceSelector()
        populateBingMarketSelector()
        refreshWallpaperDisplaySelector()
        refreshDisplayProfilesButton()
        refreshBingMarketSelectorState()
        refreshWallpaperAlchemyCategoryButton()
        setKeepImagesText()
    }

    private func setupBingMarketSelector() {
        populateBingMarketSelector()
        bingMarketPopUpButton.target = self
        bingMarketPopUpButton.action = #selector(bingMarketAction(_:))

        bingMarketLabel.translatesAutoresizingMaskIntoConstraints = false
        bingMarketPopUpButton.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(bingMarketLabel)
        view.addSubview(bingMarketPopUpButton)

        // Insert the market row between the menu-bar preference and image path.
        if let oldImageTopConstraint = view.constraints.first(where: {
            ($0.firstItem as? NSView) === imagePathButton &&
            $0.firstAttribute == .top &&
            ($0.secondItem as? NSView) === hideMenuBarIconCheckBox &&
            $0.secondAttribute == .bottom
        }) {
            NSLayoutConstraint.deactivate([oldImageTopConstraint])
        }

        let bingMarketTopConstraint = bingMarketPopUpButton.topAnchor.constraint(
            equalTo: hideMenuBarIconCheckBox.bottomAnchor,
            constant: 12
        )
        self.bingMarketTopConstraint = bingMarketTopConstraint
        NSLayoutConstraint.activate([
            bingMarketTopConstraint,
            bingMarketPopUpButton.leadingAnchor.constraint(equalTo: imagePathButton.leadingAnchor),
            bingMarketPopUpButton.widthAnchor.constraint(equalTo: imagePathButton.widthAnchor),
            imagePathButton.topAnchor.constraint(equalTo: bingMarketPopUpButton.bottomAnchor, constant: 12),
            bingMarketLabel.trailingAnchor.constraint(equalTo: bingMarketPopUpButton.leadingAnchor, constant: -8),
            bingMarketLabel.centerYAnchor.constraint(equalTo: bingMarketPopUpButton.centerYAnchor)
        ])

        preferredContentSize = NSSize(width: view.frame.width, height: view.frame.height + 40)
    }

    /// 在菜单栏选项与必应地区之间插入来源选择行；选择非必应来源时地区不可用。
    private func setupWallpaperSourceSelector() {
        populateWallpaperSourceSelector()
        wallpaperSourcePopUpButton.target = self
        wallpaperSourcePopUpButton.action = #selector(wallpaperSourceAction(_:))

        wallpaperSourceLabel.translatesAutoresizingMaskIntoConstraints = false
        wallpaperSourcePopUpButton.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(wallpaperSourceLabel)
        view.addSubview(wallpaperSourcePopUpButton)

        if let bingMarketTopConstraint {
            NSLayoutConstraint.deactivate([bingMarketTopConstraint])
        }
        NSLayoutConstraint.activate([
            wallpaperSourcePopUpButton.topAnchor.constraint(equalTo: hideMenuBarIconCheckBox.bottomAnchor, constant: 12),
            wallpaperSourcePopUpButton.leadingAnchor.constraint(equalTo: imagePathButton.leadingAnchor),
            wallpaperSourcePopUpButton.widthAnchor.constraint(equalTo: imagePathButton.widthAnchor),
            bingMarketPopUpButton.topAnchor.constraint(equalTo: wallpaperSourcePopUpButton.bottomAnchor, constant: 12),
            wallpaperSourceLabel.trailingAnchor.constraint(equalTo: wallpaperSourcePopUpButton.leadingAnchor, constant: -8),
            wallpaperSourceLabel.centerYAnchor.constraint(equalTo: wallpaperSourcePopUpButton.centerYAnchor)
        ])

        preferredContentSize = NSSize(width: preferredContentSize.width, height: preferredContentSize.height + 40)
        refreshBingMarketSelectorState()
    }

    /// 在菜单栏选项与图片来源之间插入界面语言选择行。
    private func setupLanguageSelector() {
        languagePopUpButton.target = self
        languagePopUpButton.action = #selector(languageAction(_:))
        for subview in [languageLabel, languagePopUpButton] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(subview)
        }

        if let sourceTopConstraint = view.constraints.first(where: {
            ($0.firstItem as? NSView) === wallpaperSourcePopUpButton &&
            $0.firstAttribute == .top &&
            ($0.secondItem as? NSView) === hideMenuBarIconCheckBox &&
            $0.secondAttribute == .bottom
        }) {
            NSLayoutConstraint.deactivate([sourceTopConstraint])
        }
        NSLayoutConstraint.activate([
            languagePopUpButton.topAnchor.constraint(equalTo: hideMenuBarIconCheckBox.bottomAnchor, constant: 12),
            languagePopUpButton.leadingAnchor.constraint(equalTo: imagePathButton.leadingAnchor),
            languagePopUpButton.widthAnchor.constraint(equalTo: imagePathButton.widthAnchor),
            wallpaperSourcePopUpButton.topAnchor.constraint(equalTo: languagePopUpButton.bottomAnchor, constant: 12),
            languageLabel.trailingAnchor.constraint(equalTo: languagePopUpButton.leadingAnchor, constant: -8),
            languageLabel.centerYAnchor.constraint(equalTo: languagePopUpButton.centerYAnchor)
        ])
        preferredContentSize = NSSize(width: preferredContentSize.width, height: preferredContentSize.height + 40)
    }

    /// 必应地区与 Alchemy 分类共用一行，只显示当前图片来源对应的选项。
    private func refreshBingMarketSelectorState() {
        let isBing = settings.wallpaperSource == .bing
        bingMarketPopUpButton.isHidden = !isBing
        bingMarketLabel.isHidden = !isBing
        wallpaperAlchemyCategoryButton.isHidden = isBing
        wallpaperAlchemyCategoryLabel.isHidden = isBing
        if isBing {
            wallpaperAlchemyCategoryPopover?.close()
        }
        // 定时更换只用于 Wallpaper Alchemy，选择必应时收起这一行。
        wallpaperAlchemyRefreshPopUpButton.isHidden = isBing
        wallpaperAlchemyRefreshLabel.isHidden = isBing
        if let wallpaperDisplayBelowRefreshConstraint, let wallpaperDisplayBelowMarketConstraint {
            wallpaperDisplayBelowRefreshConstraint.isActive = !isBing
            wallpaperDisplayBelowMarketConstraint.isActive = isBing
        }
        refreshWallpaperAlchemySelectorState()
    }

    /// 在分类行下方插入定时更换壁纸的间隔选择行。
    private func setupWallpaperAlchemyRefreshSelector() {
        wallpaperAlchemyRefreshPopUpButton.target = self
        wallpaperAlchemyRefreshPopUpButton.action = #selector(wallpaperAlchemyRefreshAction(_:))
        populateWallpaperAlchemyRefreshSelector()
        for subview in [wallpaperAlchemyRefreshLabel, wallpaperAlchemyRefreshPopUpButton] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(subview)
        }

        let displayTopConstraint = view.constraints.first(where: {
            ($0.firstItem as? NSView) === wallpaperDisplayPopUpButton &&
            $0.firstAttribute == .top &&
            ($0.secondItem as? NSView) === bingMarketPopUpButton &&
            $0.secondAttribute == .bottom
        }) ?? wallpaperDisplayPopUpButton.topAnchor.constraint(
            equalTo: bingMarketPopUpButton.bottomAnchor,
            constant: 12
        )
        wallpaperDisplayBelowMarketConstraint = displayTopConstraint
        wallpaperDisplayBelowRefreshConstraint = wallpaperDisplayPopUpButton.topAnchor.constraint(
            equalTo: wallpaperAlchemyRefreshPopUpButton.bottomAnchor,
            constant: 12
        )
        NSLayoutConstraint.activate([
            wallpaperAlchemyRefreshPopUpButton.topAnchor.constraint(equalTo: bingMarketPopUpButton.bottomAnchor, constant: 12),
            wallpaperAlchemyRefreshPopUpButton.leadingAnchor.constraint(equalTo: imagePathButton.leadingAnchor),
            wallpaperAlchemyRefreshPopUpButton.widthAnchor.constraint(equalTo: imagePathButton.widthAnchor),
            wallpaperAlchemyRefreshLabel.trailingAnchor.constraint(equalTo: wallpaperAlchemyRefreshPopUpButton.leadingAnchor, constant: -8),
            wallpaperAlchemyRefreshLabel.centerYAnchor.constraint(equalTo: wallpaperAlchemyRefreshPopUpButton.centerYAnchor)
        ])

        preferredContentSize = NSSize(width: preferredContentSize.width, height: preferredContentSize.height + 40)
        refreshBingMarketSelectorState()
    }

    private func populateWallpaperAlchemyRefreshSelector() {
        wallpaperAlchemyRefreshPopUpButton.removeAllItems()
        for interval in WallpaperAlchemyRefreshInterval.allCases {
            let item = NSMenuItem(title: interval.title, action: nil, keyEquivalent: "")
            item.representedObject = interval.rawValue
            wallpaperAlchemyRefreshPopUpButton.menu?.addItem(item)
        }
        wallpaperAlchemyRefreshPopUpButton.select(wallpaperAlchemyRefreshPopUpButton.itemArray.first {
            ($0.representedObject as? Int) == settings.wallpaperAlchemyRefreshInterval.rawValue
        })
        wallpaperAlchemyRefreshPopUpButton.toolTip = L("Automatically changes to the next wallpaper in the selected category's download ranking.")
    }

    /// 在必应地区下方插入 Wallpaper Alchemy 的分类选择行，分类名称跟随界面语言。
    private func setupWallpaperAlchemyCategorySelector() {
        wallpaperAlchemyCategoryButton.target = self
        wallpaperAlchemyCategoryButton.action = #selector(wallpaperAlchemyCategoryButtonAction(_:))
        wallpaperAlchemyCategoryButton.bezelStyle = .rounded
        wallpaperAlchemyCategoryButton.alignment = .left
        wallpaperAlchemyCategoryButton.lineBreakMode = .byTruncatingTail
        wallpaperAlchemyCategoryButton.image = NSImage(
            systemSymbolName: "magnifyingglass",
            accessibilityDescription: nil
        )
        wallpaperAlchemyCategoryButton.imagePosition = .imageTrailing
        wallpaperAlchemyCategoryButton.imageHugsTitle = false
        refreshWallpaperAlchemyCategoryButton()

        for subview in [wallpaperAlchemyCategoryLabel, wallpaperAlchemyCategoryButton] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(subview)
        }

        if let imageTopConstraint = view.constraints.first(where: {
            ($0.firstItem as? NSView) === imagePathButton &&
            $0.firstAttribute == .top &&
            ($0.secondItem as? NSView) === bingMarketPopUpButton &&
            $0.secondAttribute == .bottom
        }) {
            NSLayoutConstraint.deactivate([imageTopConstraint])
        }

        // 与必应地区重叠在同一行，二者按图片来源只显示其一。
        NSLayoutConstraint.activate([
            wallpaperAlchemyCategoryButton.centerYAnchor.constraint(equalTo: bingMarketPopUpButton.centerYAnchor),
            wallpaperAlchemyCategoryButton.leadingAnchor.constraint(equalTo: imagePathButton.leadingAnchor),
            wallpaperAlchemyCategoryButton.widthAnchor.constraint(equalTo: imagePathButton.widthAnchor),
            wallpaperAlchemyCategoryLabel.trailingAnchor.constraint(equalTo: wallpaperAlchemyCategoryButton.leadingAnchor, constant: -8),
            wallpaperAlchemyCategoryLabel.centerYAnchor.constraint(equalTo: wallpaperAlchemyCategoryButton.centerYAnchor),
            imagePathButton.topAnchor.constraint(equalTo: bingMarketPopUpButton.bottomAnchor, constant: 12)
        ])

        refreshBingMarketSelectorState()
        loadWallpaperAlchemyCategories()
    }

    /// 分类同时作用于使用 Wallpaper Alchemy 的屏幕配置，悬停提示说明适用范围。
    private func refreshWallpaperAlchemySelectorState() {
        wallpaperAlchemyCategoryButton.toolTip = L("Applies only when Wallpaper Alchemy is the image source or used by a display profile.")
    }

    private func refreshWallpaperAlchemyCategoryButton() {
        let category = settings.wallpaperAlchemyCategory
        let isEmpty = category != nil && category?.id == emptyWallpaperAlchemyCategoryID
        if let category, isEmpty {
            wallpaperAlchemyCategoryButton.title = L("%@ — No desktop wallpapers", category.displayTitle)
            wallpaperAlchemyCategoryButton.image = NSImage(
                systemSymbolName: "exclamationmark.triangle.fill",
                accessibilityDescription: nil
            )
            wallpaperAlchemyCategoryButton.contentTintColor = .systemOrange
            wallpaperAlchemyCategoryButton.toolTip = L("Please choose another category. The current category is kept.")
        } else {
            wallpaperAlchemyCategoryButton.title = category?.displayTitle
                ?? L("All Categories (Most Downloaded)")
            wallpaperAlchemyCategoryButton.image = NSImage(
                systemSymbolName: "magnifyingglass",
                accessibilityDescription: nil
            )
            wallpaperAlchemyCategoryButton.contentTintColor = nil
            refreshWallpaperAlchemySelectorState()
        }
    }

    /// 按当前语言获取分类列表；同一语言只请求一次。
    private func loadWallpaperAlchemyCategories() {
        let locale = settings.wallpaperAlchemyLocale
        wallpaperAlchemyCategoriesTask?.cancel()
        wallpaperAlchemyCategoriesLocale = locale
        if let cachedCategories = Self.cachedWallpaperAlchemyCategories[locale] {
            applyWallpaperAlchemyCategories(cachedCategories)
            return
        }

        wallpaperAlchemyCategories = nil
        wallpaperAlchemyCategoriesFailed = false
        wallpaperAlchemyCategoryPicker?.update(state: .loading)
        wallpaperAlchemyCategoriesTask = Task { @MainActor [weak self] in
            do {
                let categories = try await DownloadManager.downloadWallpaperAlchemyCategories(locale: locale)
                Self.cachedWallpaperAlchemyCategories[locale] = categories
                guard let self, Task.isCancelled == false,
                      self.settings.wallpaperAlchemyLocale == locale else { return }
                self.applyWallpaperAlchemyCategories(categories)
            } catch {
                guard let self, Task.isCancelled == false else { return }
                logger.error("Failed to load Wallpaper Alchemy categories: \(error.localizedDescription, privacy: .public)")
                self.wallpaperAlchemyCategoriesFailed = true
                self.wallpaperAlchemyCategoryPicker?.update(state: .failed)
            }
        }
    }

    private func applyWallpaperAlchemyCategories(_ categories: [DownloadManager.WallpaperAlchemyCategory]) {
        wallpaperAlchemyCategories = categories
        wallpaperAlchemyCategoriesFailed = false
        // 切换语言后同步保存的分类名称，菜单与设置显示一致。
        if let selectedCategory = settings.wallpaperAlchemyCategory,
           let localizedCategory = categories.first(where: { $0.id == selectedCategory.id }),
           localizedCategory != selectedCategory {
            settings.wallpaperAlchemyCategory = localizedCategory
        }
        refreshWallpaperAlchemyCategoryButton()
        wallpaperAlchemyCategoryPicker?.update(state: .loaded(categories))
    }

    private func setupWallpaperDisplaySelector() {
        wallpaperDisplayLabel.translatesAutoresizingMaskIntoConstraints = false
        wallpaperDisplayPopUpButton.translatesAutoresizingMaskIntoConstraints = false
        wallpaperDisplayPopUpButton.target = self
        wallpaperDisplayPopUpButton.action = #selector(wallpaperDisplayAction(_:))
        view.addSubview(wallpaperDisplayLabel)
        view.addSubview(wallpaperDisplayPopUpButton)
        refreshWallpaperDisplaySelector()

        if let imageTopConstraint = view.constraints.first(where: {
            ($0.firstItem as? NSView) === imagePathButton &&
            $0.firstAttribute == .top &&
            ($0.secondItem as? NSView) === bingMarketPopUpButton &&
            $0.secondAttribute == .bottom
        }) {
            NSLayoutConstraint.deactivate([imageTopConstraint])
        }

        NSLayoutConstraint.activate([
            wallpaperDisplayPopUpButton.topAnchor.constraint(equalTo: bingMarketPopUpButton.bottomAnchor, constant: 12),
            wallpaperDisplayPopUpButton.leadingAnchor.constraint(equalTo: imagePathButton.leadingAnchor),
            wallpaperDisplayPopUpButton.widthAnchor.constraint(equalTo: imagePathButton.widthAnchor),
            imagePathButton.topAnchor.constraint(equalTo: wallpaperDisplayPopUpButton.bottomAnchor, constant: 12),
            wallpaperDisplayLabel.trailingAnchor.constraint(equalTo: wallpaperDisplayPopUpButton.leadingAnchor, constant: -8),
            wallpaperDisplayLabel.centerYAnchor.constraint(equalTo: wallpaperDisplayPopUpButton.centerYAnchor)
        ])

        preferredContentSize = NSSize(width: preferredContentSize.width, height: preferredContentSize.height + 40)
    }

    private func setupDisplayProfilesButton() {
        displayProfilesLabel.translatesAutoresizingMaskIntoConstraints = false
        displayProfilesButton.translatesAutoresizingMaskIntoConstraints = false
        displayProfilesButton.target = self
        displayProfilesButton.action = #selector(displayProfilesAction(_:))
        displayProfilesButton.alignment = .left
        view.addSubview(displayProfilesLabel)
        view.addSubview(displayProfilesButton)
        refreshDisplayProfilesButton()

        if let imageTopConstraint = view.constraints.first(where: {
            ($0.firstItem as? NSView) === imagePathButton &&
            $0.firstAttribute == .top &&
            ($0.secondItem as? NSView) === wallpaperDisplayPopUpButton &&
            $0.secondAttribute == .bottom
        }) {
            NSLayoutConstraint.deactivate([imageTopConstraint])
        }

        NSLayoutConstraint.activate([
            displayProfilesButton.topAnchor.constraint(equalTo: wallpaperDisplayPopUpButton.bottomAnchor, constant: 12),
            displayProfilesButton.leadingAnchor.constraint(equalTo: imagePathButton.leadingAnchor),
            displayProfilesButton.widthAnchor.constraint(equalTo: imagePathButton.widthAnchor),
            imagePathButton.topAnchor.constraint(equalTo: displayProfilesButton.bottomAnchor, constant: 12),
            displayProfilesLabel.trailingAnchor.constraint(equalTo: displayProfilesButton.leadingAnchor, constant: -8),
            displayProfilesLabel.centerYAnchor.constraint(equalTo: displayProfilesButton.centerYAnchor)
        ])

        preferredContentSize = NSSize(width: preferredContentSize.width, height: preferredContentSize.height + 40)
    }

    private func refreshDisplayProfilesButton() {
        let count = settings.wallpaperDisplayProfiles.count
        displayProfilesButton.title = count == 0
            ? L("Configure…")
            : L("Configure (%d)…", count)
    }

    private func refreshWallpaperDisplaySelector() {
        let selectedCount = settings.selectedWallpaperDisplayIDs.count
        wallpaperDisplayPopUpButton.removeAllItems()
        for mode in WallpaperDisplayMode.allCases {
            let title: String
            if mode == .selected, selectedCount > 0 {
                title = L("Selected Displays (%d)…", selectedCount)
            } else {
                title = mode.title
            }
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.representedObject = mode.rawValue
            wallpaperDisplayPopUpButton.menu?.addItem(item)
        }
        selectWallpaperDisplayMode(settings.wallpaperDisplayMode)
    }

    private func selectWallpaperDisplayMode(_ mode: WallpaperDisplayMode) {
        guard let item = wallpaperDisplayPopUpButton.itemArray.first(where: {
            ($0.representedObject as? String) == mode.rawValue
        }) else { return }
        wallpaperDisplayPopUpButton.select(item)
    }

    private func presentWallpaperDisplaySelection() -> Bool {
        let displays = WallpaperManager.connectedDisplays()
        guard !displays.isEmpty else {
            let alert = NSAlert()
            alert.messageText = L("No displays are available")
            alert.informativeText = L("Connect a display and try again.")
            alert.alertStyle = .warning
            alert.addButton(withTitle: L("OK"))
            alert.runModal()
            return false
        }

        let previouslySelected = settings.selectedWallpaperDisplayIDs
        let initiallySelected: Set<String>
        if previouslySelected.isEmpty {
            initiallySelected = Set(displays.filter(\.isMain).map(\.identifier))
        } else {
            initiallySelected = previouslySelected
        }

        let stackView = NSStackView()
        stackView.orientation = .vertical
        stackView.alignment = .leading
        stackView.spacing = 8
        var checkBoxes = [NSButton]()
        for display in displays {
            let checkBox = NSButton(checkboxWithTitle: display.title, target: nil, action: nil)
            checkBox.state = initiallySelected.contains(display.identifier) ? .on : .off
            checkBoxes.append(checkBox)
            stackView.addArrangedSubview(checkBox)
        }
        stackView.frame = NSRect(x: 0, y: 0, width: 420, height: max(28, CGFloat(displays.count) * 26))

        let alert = NSAlert()
        alert.messageText = L("Choose displays")
        alert.informativeText = L("BingWallpaper will update only the selected displays. Disconnected displays remain selected and will resume when reconnected.")
        alert.alertStyle = .informational
        alert.icon = displayConfigurationIcon()
        alert.accessoryView = stackView
        alert.addButton(withTitle: L("Apply"))
        alert.addButton(withTitle: L("Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return false }

        let connectedIDs = Set(displays.map(\.identifier))
        let disconnectedSelections = previouslySelected.subtracting(connectedIDs)
        let checkedIDs = Set(zip(displays, checkBoxes).compactMap { display, checkBox in
            checkBox.state == .on ? display.identifier : nil
        })
        let newSelection = disconnectedSelections.union(checkedIDs)
        guard !newSelection.isEmpty else {
            let emptyAlert = NSAlert()
            emptyAlert.messageText = L("Select at least one display")
            emptyAlert.alertStyle = .warning
            emptyAlert.addButton(withTitle: L("OK"))
            emptyAlert.runModal()
            return false
        }

        settings.selectedWallpaperDisplayIDs = newSelection
        return true
    }

    private func presentDisplayProfileConfiguration() {
        let displays = WallpaperManager.connectedDisplays()
        guard displays.isEmpty == false else {
            let alert = NSAlert()
            alert.messageText = L("No displays are available")
            alert.informativeText = L("Connect a display and try again.")
            alert.alertStyle = .warning
            alert.addButton(withTitle: L("OK"))
            alert.runModal()
            return
        }

        let descriptors = Database.instance.allImageDescriptors()
            .filter { $0.image.isOnDisk() }
        let wallpaperOptions = descriptors
            .sorted(by: >)
            .map { descriptor in
                let info = descriptor.imageInfo
                return DisplayWallpaperOption(
                    wallpaperID: descriptor.wallpaperIdentifier,
                    marketCode: descriptor.marketCode,
                    title: "\(info.date) — \(info.title)"
                )
            }
        var controls = [DisplayProfileRowController]()
        var rows = [[NSView]]()
        rows.append([
            profileHeader(L("Display")),
            profileHeader(L("Source / Bing Region")),
            profileHeader(L("Wallpaper"))
        ])
        let profiles = settings.wallpaperDisplayProfiles
        for display in displays {
            let profile = profiles[display.identifier] ?? WallpaperDisplayProfile()
            let marketSelector = displayMarketSelector(for: profile)
            let rowController = DisplayProfileRowController(
                display: display,
                marketSelector: marketSelector,
                profile: profile,
                globalMarketCode: settings.globalChannelCode,
                wallpaperOptions: wallpaperOptions
            )
            let displayLabel = NSTextField(labelWithString: display.title)
            displayLabel.lineBreakMode = .byTruncatingTail
            displayLabel.toolTip = display.title
            rows.append([displayLabel, marketSelector, rowController.wallpaperSelector])
            controls.append(rowController)
        }

        let grid = NSGridView(views: rows)
        grid.rowSpacing = 8
        grid.columnSpacing = 10
        grid.column(at: 0).width = 230
        grid.column(at: 1).width = 250
        grid.column(at: 2).width = 310
        grid.frame = NSRect(
            x: 0,
            y: 0,
            width: 810,
            height: CGFloat(rows.count) * 34
        )

        let accessoryView: NSView
        if rows.count > 6 {
            let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 810, height: 220))
            scrollView.documentView = grid
            scrollView.hasVerticalScroller = true
            scrollView.drawsBackground = false
            accessoryView = scrollView
        } else {
            accessoryView = grid
        }

        let alert = NSAlert()
        alert.messageText = L("Configure Displays")
        alert.informativeText = L("Each display can inherit the global wallpaper, follow the latest image from its own source or Bing region, or use a specific downloaded wallpaper. Disconnected display profiles remain saved.")
        alert.alertStyle = .informational
        alert.icon = displayConfigurationIcon()
        alert.accessoryView = accessoryView
        alert.addButton(withTitle: L("Apply"))
        alert.addButton(withTitle: L("Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        var updatedProfiles = profiles
        for control in controls {
            var profile = updatedProfiles[control.display.identifier]
                ?? WallpaperDisplayProfile()
            applyMarketSelection(control.marketSelector, to: &profile)
            switch control.wallpaperSelection {
            case DisplayProfileRowController.inheritSelection:
                profile.pinMode = .inherit
                profile.pinnedWallpaperID = nil
            case DisplayProfileRowController.latestSelection:
                profile.pinMode = .followLatest
                profile.pinnedWallpaperID = nil
            case let wallpaperID:
                let effectiveMarketCode = profile.effectiveMarketCode(
                    globalMarketCode: settings.globalChannelCode
                )
                if descriptors.contains(where: {
                    $0.wallpaperIdentifier == wallpaperID &&
                        $0.marketCode == effectiveMarketCode
                }) {
                    profile.pinMode = .pinned
                    profile.pinnedWallpaperID = wallpaperID
                } else {
                    profile.pinMode = .followLatest
                    profile.pinnedWallpaperID = nil
                }
            }

            if profile.isDefault {
                updatedProfiles.removeValue(forKey: control.display.identifier)
            } else {
                updatedProfiles[control.display.identifier] = profile
            }
        }

        settings.wallpaperDisplayProfiles = updatedProfiles
        refreshDisplayProfilesButton()
        refreshWallpaperAlchemySelectorState()
        delegate?.wallpaperDisplaySelectionDidChange()
        updateManager?.update()
    }

    private func displayConfigurationIcon() -> NSImage? {
        let configuration = NSImage.SymbolConfiguration(pointSize: 48, weight: .regular)
        return NSImage(systemSymbolName: "display.2", accessibilityDescription: L("Displays"))?
            .withSymbolConfiguration(configuration)
    }

    private func profileHeader(_ title: String) -> NSTextField {
        let field = NSTextField(labelWithString: title)
        field.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        return field
    }

    private func displayMarketSelector(for profile: WallpaperDisplayProfile) -> NSPopUpButton {
        let selector = NSPopUpButton(frame: .zero, pullsDown: false)
        let globalTitle = WallpaperChannel.title(for: settings.globalChannelCode)
        addProfileOption(title: L("Inherit Global — %@", globalTitle), value: "inherit", to: selector)
        addProfileOption(
            title: WallpaperSource.wallpaperAlchemy.title,
            value: WallpaperChannel.wallpaperAlchemyCode,
            to: selector
        )
        selector.menu?.addItem(.separator())
        addProfileOption(title: L("Bing — %@", BingMarketOption.automatic.title), value: "automatic", to: selector)
        for option in BingMarketOption.all where option.code != nil {
            addProfileOption(title: L("Bing — %@", option.title), value: option.code!, to: selector)
        }

        let selectedValue: String
        switch profile.marketMode {
        case .inherit:
            selectedValue = "inherit"
        case .automatic:
            selectedValue = "automatic"
        case .explicit:
            selectedValue = profile.marketCode ?? "inherit"
        }
        selector.select(selector.itemArray.first(where: {
            ($0.representedObject as? String) == selectedValue
        }))
        return selector
    }

    private func addProfileOption(title: String, value: String, to selector: NSPopUpButton) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.representedObject = value
        selector.menu?.addItem(item)
    }

    private func applyMarketSelection(
        _ selector: NSPopUpButton,
        to profile: inout WallpaperDisplayProfile
    ) {
        let value = selector.selectedItem?.representedObject as? String ?? "inherit"
        switch value {
        case "inherit":
            profile.marketMode = .inherit
            profile.marketCode = nil
        case "automatic":
            profile.marketMode = .automatic
            profile.marketCode = nil
        default:
            profile.marketMode = .explicit
            profile.marketCode = WallpaperChannel.isSupported(value) ? value : nil
        }
    }

    private func promptToApproveLoginItem() {
        let alert = NSAlert()
        alert.messageText = L("Approve BingWallpaper in Login Items")
        alert.informativeText = L("BingWallpaper has been added to your Login Items but macOS needs your approval before it can launch at login. Open System Settings to confirm it.")
        alert.alertStyle = .informational
        let openButton = alert.addButton(withTitle: L("Open Login Items"))
        alert.addButton(withTitle: L("Later"))
        alert.window.defaultButtonCell = openButton.cell as? NSButtonCell

        if alert.runModal() == .alertFirstButtonReturn {
            SMAppService.openSystemSettingsLoginItems()
        }
    }

    private func presentLaunchAtLoginError(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = L("Couldn't update Launch at Login")
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        alert.addButton(withTitle: L("Ok"))
        alert.runModal()
    }

    private func presentImagePathError(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = L("Couldn't use the selected image location")
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        alert.addButton(withTitle: L("Ok"))
        alert.runModal()
    }

    private func setKeepImagesText() {
        guard let keepImageDuration = KeepImageDuration(rawValue: settings.keepImageDuration) else { return }
        
        switch keepImageDuration {
        case .five, .ten, .fifty, .onehundred:
            keepImagesTextField.stringValue = L("Keep last %@ images:", keepImageDuration.text)
        case .infinite:
            keepImagesTextField.stringValue = L("Keep all images forever:")
        }
    }
}

enum KeepImageDuration: Int {
    case five
    case ten
    case fifty
    case onehundred
    case infinite
    
    var text: String {
        switch self {
        case .five:
            return "5"
        case .ten:
            return "10"
        case .fifty:
            return "50"
        case .onehundred:
            return "100"
        case .infinite:
            return "∞"
        }
    }
}
