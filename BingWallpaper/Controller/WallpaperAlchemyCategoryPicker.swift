import Cocoa

/// Wallpaper Alchemy 分类的模糊匹配：忽略大小写、音调和全半角，中文分类同时支持拼音全拼与首字母。
struct WallpaperAlchemyCategoryMatcher {
    typealias Category = DownloadManager.WallpaperAlchemyCategory

    private struct Entry {
        let category: Category
        let keys: [String]
    }

    private let entries: [Entry]

    init(categories: [Category]) {
        entries = categories.map { Entry(category: $0, keys: Self.searchKeys(for: $0)) }
    }

    /// 返回匹配的分类，匹配度高的在前，同等匹配度保持原有的下载量顺序。
    func matches(for query: String) -> [Category] {
        let normalizedQuery = Self.normalize(query)
        guard normalizedQuery.isEmpty == false else { return entries.map(\.category) }
        let queryCharacters = Array(normalizedQuery)
        return entries.enumerated()
            .compactMap { index, entry -> (score: Int, index: Int, category: Category)? in
                guard let score = entry.keys.compactMap({ Self.score(query: queryCharacters, in: $0) }).max() else {
                    return nil
                }
                return (score, index, entry.category)
            }
            .sorted { $0.score != $1.score ? $0.score > $1.score : $0.index < $1.index }
            .map(\.category)
    }

    /// 统一大小写、音调与全半角，并去掉空格和标点，便于“4k 风景”匹配“4K风景”。
    static func normalize(_ text: String) -> String {
        let folded = text.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: nil
        )
        var scalars = String.UnicodeScalarView()
        scalars.append(contentsOf: folded.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
        return String(scalars)
    }

    /// 中文名称转成拼音音节，例如“风景”得到 ["feng", "jing"]。
    static func pinyinSyllables(_ text: String) -> [String] {
        let mutableText = NSMutableString(string: text)
        CFStringTransform(mutableText, nil, kCFStringTransformMandarinLatin, false)
        CFStringTransform(mutableText, nil, kCFStringTransformStripDiacritics, false)
        return (mutableText as String)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .map(normalize)
            .filter { $0.isEmpty == false }
    }

    private static func searchKeys(for category: Category) -> [String] {
        var keys = [normalize(category.displayTitle), normalize(category.name)]
        let title = category.displayTitle
        if title.unicodeScalars.contains(where: { $0.properties.isIdeographic }) {
            let syllables = pinyinSyllables(title)
            keys.append(syllables.joined())
            keys.append(String(syllables.compactMap(\.first)))
        }
        var seen = Set<String>()
        return keys.filter { $0.isEmpty == false && seen.insert($0).inserted }
    }

    /// 完全相同 > 前缀 > 包含 > 按顺序出现的字符；越靠前、越紧凑得分越高。
    private static func score(query: [Character], in key: String) -> Int? {
        let keyCharacters = Array(key)
        guard query.count <= keyCharacters.count else { return nil }
        if keyCharacters == query {
            return 1000
        }
        if keyCharacters.starts(with: query) {
            return 900 - min(99, keyCharacters.count - query.count)
        }
        if let offset = firstOccurrence(of: query, in: keyCharacters) {
            return 700 - min(99, offset)
        }
        guard query.count >= 2 else { return nil }

        var gaps = 0
        var firstMatch: Int?
        var previousMatch: Int?
        var queryIndex = 0
        for (index, character) in keyCharacters.enumerated() where queryIndex < query.count {
            guard character == query[queryIndex] else { continue }
            if let previousMatch {
                gaps += index - previousMatch - 1
            } else {
                firstMatch = index
            }
            previousMatch = index
            queryIndex += 1
        }
        guard queryIndex == query.count else { return nil }
        return 400 - min(199, gaps * 4) - min(99, firstMatch ?? 0)
    }

    private static func firstOccurrence(of query: [Character], in key: [Character]) -> Int? {
        guard key.count >= query.count else { return nil }
        for start in 0...(key.count - query.count) where key[start] == query[0] {
            if Array(key[start..<(start + query.count)]) == query {
                return start
            }
        }
        return nil
    }
}

/// 带搜索框的分类选择面板，取代过长的下拉菜单。
@MainActor
final class WallpaperAlchemyCategoryPickerViewController: NSViewController {
    typealias Category = DownloadManager.WallpaperAlchemyCategory

    enum State {
        case loading
        case failed
        case loaded([Category])
    }

    private enum Row {
        case all
        case category(Category)
    }

    /// 选中分类后回调，nil 表示全部分类。
    var onSelect: ((Category?) -> Void)?
    var onRetry: (() -> Void)?

    private let selectedCategoryID: Int?
    private var state: State = .loading
    private var matcher = WallpaperAlchemyCategoryMatcher(categories: [])
    private var rows = [Row]()

    private let searchField = NSSearchField()
    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private let statusLabel = NSTextField(labelWithString: "")
    private let retryButton = NSButton(title: "", target: nil, action: nil)

    init(selectedCategoryID: Int?, state: State) {
        self.selectedCategoryID = selectedCategoryID
        super.init(nibName: nil, bundle: nil)
        update(state: state)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 400))

        searchField.placeholderString = L("Search categories")
        searchField.delegate = self
        searchField.sendsSearchStringImmediately = true
        searchField.translatesAutoresizingMaskIntoConstraints = false

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("category"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.rowHeight = 24
        tableView.style = .inset
        tableView.usesAutomaticRowHeights = false
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.action = #selector(tableViewClicked(_:))

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        statusLabel.alignment = .center
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        retryButton.title = L("Retry Now")
        retryButton.bezelStyle = .rounded
        retryButton.target = self
        retryButton.action = #selector(retry(_:))
        retryButton.translatesAutoresizingMaskIntoConstraints = false

        for subview in [searchField, scrollView, statusLabel, retryButton] {
            container.addSubview(subview)
        }
        NSLayoutConstraint.activate([
            searchField.topAnchor.constraint(equalTo: container.topAnchor, constant: 12),
            searchField.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            searchField.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            scrollView.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 8),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -8),
            statusLabel.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            statusLabel.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor, constant: -12),
            statusLabel.leadingAnchor.constraint(greaterThanOrEqualTo: container.leadingAnchor, constant: 16),
            retryButton.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 8),
            retryButton.centerXAnchor.constraint(equalTo: statusLabel.centerXAnchor)
        ])
        view = container
        reloadRows()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(searchField)
    }

    /// 分类加载状态变化时刷新面板，打开期间也能看到加载结果。
    func update(state: State) {
        self.state = state
        if case .loaded(let categories) = state {
            matcher = WallpaperAlchemyCategoryMatcher(categories: categories)
        }
        if isViewLoaded {
            reloadRows()
        }
    }

    private func reloadRows() {
        let query = searchField.stringValue
        switch state {
        case .loading, .failed:
            rows = query.isEmpty ? [.all] : []
        case .loaded:
            let matches = matcher.matches(for: query).map(Row.category)
            rows = WallpaperAlchemyCategoryMatcher.normalize(query).isEmpty ? [.all] + matches : matches
        }
        tableView.reloadData()

        switch state {
        case .loading:
            statusLabel.stringValue = L("Loading categories…")
        case .failed:
            statusLabel.stringValue = L("Couldn't load categories")
        case .loaded:
            statusLabel.stringValue = rows.isEmpty ? L("No matching categories") : ""
        }
        if case .failed = state {
            retryButton.isHidden = false
        } else {
            retryButton.isHidden = true
        }
        statusLabel.isHidden = statusLabel.stringValue.isEmpty

        let selectedRow = query.isEmpty
            ? rows.firstIndex(where: { isSelected($0) }) ?? 0
            : 0
        if rows.isEmpty == false {
            tableView.selectRowIndexes(IndexSet(integer: selectedRow), byExtendingSelection: false)
            tableView.scrollRowToVisible(selectedRow)
        }
    }

    private func isSelected(_ row: Row) -> Bool {
        switch row {
        case .all:
            return selectedCategoryID == nil
        case .category(let category):
            return category.id == selectedCategoryID
        }
    }

    private func title(for row: Row) -> String {
        switch row {
        case .all:
            return L("All Categories (Most Downloaded)")
        case .category(let category):
            return category.displayTitle
        }
    }

    private func commit(rowIndex: Int) {
        guard let row = rows[safe: rowIndex] else { return }
        switch row {
        case .all:
            onSelect?(nil)
        case .category(let category):
            onSelect?(category)
        }
    }

    @objc private func tableViewClicked(_ sender: NSTableView) {
        commit(rowIndex: sender.clickedRow)
    }

    @objc private func retry(_ sender: NSButton) {
        onRetry?()
    }

    private func moveSelection(by delta: Int) {
        guard rows.isEmpty == false else { return }
        let current = tableView.selectedRow < 0 ? -delta : tableView.selectedRow
        let next = min(max(0, current + delta), rows.count - 1)
        tableView.selectRowIndexes(IndexSet(integer: next), byExtendingSelection: false)
        tableView.scrollRowToVisible(next)
    }
}

extension WallpaperAlchemyCategoryPickerViewController: NSSearchFieldDelegate {
    func controlTextDidChange(_ obj: Notification) {
        reloadRows()
    }

    /// 搜索框内可直接用上下键移动、回车确认。
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.moveDown(_:)):
            moveSelection(by: 1)
            return true
        case #selector(NSResponder.moveUp(_:)):
            moveSelection(by: -1)
            return true
        case #selector(NSResponder.insertNewline(_:)):
            commit(rowIndex: tableView.selectedRow)
            return true
        default:
            return false
        }
    }
}

extension WallpaperAlchemyCategoryPickerViewController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        return rows.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("CategoryCell")
        let cell: NSTableCellView
        if let reusedCell = tableView.makeView(withIdentifier: identifier, owner: nil) as? NSTableCellView {
            cell = reusedCell
        } else {
            cell = NSTableCellView()
            cell.identifier = identifier
            let textField = NSTextField(labelWithString: "")
            textField.lineBreakMode = .byTruncatingTail
            textField.translatesAutoresizingMaskIntoConstraints = false
            let checkmark = NSImageView(image: NSImage(
                systemSymbolName: "checkmark",
                accessibilityDescription: nil
            ) ?? NSImage())
            checkmark.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(textField)
            cell.addSubview(checkmark)
            cell.textField = textField
            cell.imageView = checkmark
            NSLayoutConstraint.activate([
                textField.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                checkmark.leadingAnchor.constraint(greaterThanOrEqualTo: textField.trailingAnchor, constant: 6),
                checkmark.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                checkmark.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
            ])
            textField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        guard let rowValue = rows[safe: row] else { return cell }
        cell.textField?.stringValue = title(for: rowValue)
        cell.imageView?.isHidden = isSelected(rowValue) == false
        return cell
    }
}
