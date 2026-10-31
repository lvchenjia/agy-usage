import Cocoa

class AnalyticsWindow: NSWindow {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command) {
            if event.charactersIgnoringModifiers == "r" {
                if let wc = self.windowController as? TokenStatsWindowController {
                    wc.loadData(forceRefresh: true)
                    return true
                }
            } else if event.charactersIgnoringModifiers == "w" {
                self.close()
                return true
            } else if let chars = event.charactersIgnoringModifiers, let num = Int(chars), num >= 1 && num <= 5 {
                if let wc = self.windowController as? TokenStatsWindowController {
                    wc.selectTimeWindow(num - 1)
                    return true
                }
            }
        } else if event.keyCode == 53 { // Escape
            self.close()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

class TokenStatsWindowController: NSWindowController, NSToolbarDelegate, NSTableViewDataSource, NSTableViewDelegate {
    private static let toolbarIdentifier = NSToolbar.Identifier("TokenStatsToolbar")
    private static let segmentItemId = NSToolbarItem.Identifier("TokenStatsTimeWindowSegment")
    private static let refreshItemId = NSToolbarItem.Identifier("TokenStatsRefresh")
    
    private var allRecords: [TokenRecord] = []
    private var currentWindow: TimeWindow = .fiveHours
    private var displayedStats: [ModelAggregatedStats] = []
    
    private var timeSegmentControl: NSSegmentedControl?
    private var refreshButton: NSButton?
    
    private var totalTokensCard: NativeMetricCard!
    private var cacheRatioCard: NativeMetricCard!
    private var totalCallsCard: NativeMetricCard!
    
    private var tableContainer: RoundedCardContainer!
    private var tableView: NSTableView!
    private var emptyStateView: NSView!
    private var statusLabel: NSTextField!
    
    convenience init() {
        let window = AnalyticsWindow(
            contentRect: NSRect(x: 0, y: 0, width: 750, height: 450),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Token Analytics"
        window.toolbarStyle = .unified
        window.minSize = NSSize(width: 680, height: 380)
        window.center()
        self.init(window: window)
        setupToolbar()
        setupUI()
    }
    
    private func setupToolbar() {
        guard let window = self.window else { return }
        let toolbar = NSToolbar(identifier: Self.toolbarIdentifier)
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar
    }
    
    // MARK: - NSToolbarDelegate
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        return [.flexibleSpace, Self.segmentItemId, .flexibleSpace, Self.refreshItemId]
    }
    
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        return [.flexibleSpace, Self.segmentItemId, .flexibleSpace, Self.refreshItemId]
    }
    
    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        if itemIdentifier == Self.segmentItemId {
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            let titles = TimeWindow.allCases.map { $0.title }
            let seg = NSSegmentedControl(labels: titles, trackingMode: .selectOne, target: self, action: #selector(segmentChanged(_:)))
            seg.selectedSegment = currentWindow.rawValue
            seg.segmentStyle = .texturedRounded
            seg.controlSize = .regular
            self.timeSegmentControl = seg
            item.view = seg
            item.label = "Time Window"
            item.paletteLabel = "Time Window"
            return item
        } else if itemIdentifier == Self.refreshItemId {
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            let img = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "Refresh")
            let btn = NSButton(image: img!, target: self, action: #selector(refreshClicked(_:)))
            btn.bezelStyle = .texturedRounded
            btn.toolTip = "Refresh local session data (⌘R)"
            btn.controlSize = .regular
            self.refreshButton = btn
            item.view = btn
            item.label = "Refresh"
            item.paletteLabel = "Refresh"
            return item
        }
        return nil
    }
    
    private func setupUI() {
        guard let window = self.window, let contentView = window.contentView else { return }
        
        // 1. Top Metrics Cards Row
        let cardStack = NSStackView()
        cardStack.orientation = .horizontal
        cardStack.distribution = .fillEqually
        cardStack.spacing = 12
        cardStack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(cardStack)
        
        totalTokensCard = NativeMetricCard(title: "Total Tokens", systemImage: "chart.bar.fill", tint: .systemBlue)
        cacheRatioCard = NativeMetricCard(title: "Cache Hit Rate", systemImage: "bolt.badge.clock.fill", tint: .systemGreen)
        totalCallsCard = NativeMetricCard(title: "Total Requests", systemImage: "arrow.up.arrow.down", tint: .systemOrange)
        
        cardStack.addArrangedSubview(totalTokensCard)
        cardStack.addArrangedSubview(cacheRatioCard)
        cardStack.addArrangedSubview(totalCallsCard)
        
        // 2. Rounded Table Container Card
        tableContainer = RoundedCardContainer(cornerRadius: 10)
        tableContainer.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(tableContainer)
        
        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.wantsLayer = true
        scrollView.layer?.cornerRadius = 10
        scrollView.layer?.masksToBounds = true
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        tableContainer.addSubview(scrollView)
        
        tableView = NSTableView()
        tableView.headerView = ModernHeaderView()
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.backgroundColor = .clear
        tableView.gridStyleMask = .solidHorizontalGridLineMask
        tableView.gridColor = NSColor.separatorColor.withAlphaComponent(0.08)
        tableView.rowHeight = 44
        tableView.intercellSpacing = NSSize(width: 0, height: 0)
        tableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        tableView.dataSource = self
        tableView.delegate = self
        
        let columns: [(String, String, CGFloat, CGFloat, NSTextAlignment)] = [
            ("model", "MODEL", 205, 150, .left),
            ("calls", "REQUESTS", 70, 50, .right),
            ("total", "TOKENS", 75, 60, .right),
            ("speed", "SPEED", 85, 70, .right),
            ("cache", "PROMPT CACHE", 130, 105, .right),
            ("share", "USAGE SHARE", 120, 95, .right)
        ]
        
        for (colId, title, width, minW, align) in columns {
            let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(colId))
            col.title = title
            col.width = width
            col.minWidth = minW
            col.resizingMask = [.userResizingMask, .autoresizingMask]
            let cell = ModernHeaderCell(textCell: title)
            cell.alignment = align
            col.headerCell = cell
            tableView.addTableColumn(col)
        }
        
        scrollView.documentView = tableView
        
        // 3. Empty State View
        emptyStateView = makeEmptyStateView()
        emptyStateView.translatesAutoresizingMaskIntoConstraints = false
        emptyStateView.isHidden = true
        tableContainer.addSubview(emptyStateView)
        
        // 4. Bottom Native Status Bar
        let bottomView = NSView()
        bottomView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(bottomView)
        
        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        bottomView.addSubview(separator)
        
        statusLabel = NSTextField(labelWithString: "Ready")
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.font = NSFont.systemFont(ofSize: 11, weight: .regular)
        statusLabel.textColor = .secondaryLabelColor
        bottomView.addSubview(statusLabel)
        
        NSLayoutConstraint.activate([
            // Cards Row
            cardStack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 14),
            cardStack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            cardStack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            cardStack.heightAnchor.constraint(equalToConstant: 80),
            
            // Rounded Table Container
            tableContainer.topAnchor.constraint(equalTo: cardStack.bottomAnchor, constant: 12),
            tableContainer.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            tableContainer.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            tableContainer.bottomAnchor.constraint(equalTo: bottomView.topAnchor, constant: -8),
            
            scrollView.topAnchor.constraint(equalTo: tableContainer.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: tableContainer.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: tableContainer.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: tableContainer.bottomAnchor),
            
            // Empty State View centered over table area
            emptyStateView.centerXAnchor.constraint(equalTo: tableContainer.centerXAnchor),
            emptyStateView.centerYAnchor.constraint(equalTo: tableContainer.centerYAnchor),
            emptyStateView.widthAnchor.constraint(equalToConstant: 340),
            emptyStateView.heightAnchor.constraint(equalToConstant: 130),
            
            // Bottom Status Bar
            bottomView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            bottomView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            bottomView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            bottomView.heightAnchor.constraint(equalToConstant: 26),
            
            separator.leadingAnchor.constraint(equalTo: bottomView.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: bottomView.trailingAnchor),
            separator.topAnchor.constraint(equalTo: bottomView.topAnchor),
            
            statusLabel.leadingAnchor.constraint(equalTo: bottomView.leadingAnchor, constant: 16),
            statusLabel.centerYAnchor.constraint(equalTo: bottomView.centerYAnchor)
        ])
    }
    
    private func makeEmptyStateView() -> NSView {
        let v = NSView()
        let icon = NSImageView()
        icon.translatesAutoresizingMaskIntoConstraints = false
        let cfg = NSImage.SymbolConfiguration(pointSize: 32, weight: .regular)
        icon.image = NSImage(systemSymbolName: "tray", accessibilityDescription: nil)?.withSymbolConfiguration(cfg)
        icon.contentTintColor = .tertiaryLabelColor
        v.addSubview(icon)
        
        let label = NSTextField(labelWithString: "No activity recorded in this time window")
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        label.textColor = .secondaryLabelColor
        label.alignment = .center
        v.addSubview(label)
        
        let sub = NSTextField(labelWithString: "Try selecting a broader window like '7d' or 'All'")
        sub.translatesAutoresizingMaskIntoConstraints = false
        sub.font = NSFont.systemFont(ofSize: 11, weight: .regular)
        sub.textColor = .tertiaryLabelColor
        sub.alignment = .center
        v.addSubview(sub)
        
        NSLayoutConstraint.activate([
            icon.centerXAnchor.constraint(equalTo: v.centerXAnchor),
            icon.topAnchor.constraint(equalTo: v.topAnchor, constant: 10),
            
            label.topAnchor.constraint(equalTo: icon.bottomAnchor, constant: 10),
            label.leadingAnchor.constraint(equalTo: v.leadingAnchor),
            label.trailingAnchor.constraint(equalTo: v.trailingAnchor),
            
            sub.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 4),
            sub.leadingAnchor.constraint(equalTo: v.leadingAnchor),
            sub.trailingAnchor.constraint(equalTo: v.trailingAnchor)
        ])
        return v
    }
    
    func selectTimeWindow(_ index: Int) {
        guard let win = TimeWindow(rawValue: index) else { return }
        currentWindow = win
        timeSegmentControl?.selectedSegment = index
        applyFilter()
    }
    
    @objc private func segmentChanged(_ sender: NSSegmentedControl) {
        if let win = TimeWindow(rawValue: sender.selectedSegment) {
            currentWindow = win
            applyFilter()
        }
    }
    
    @objc private func refreshClicked(_ sender: NSButton) {
        loadData(forceRefresh: true)
    }
    
    func loadData(forceRefresh: Bool = false) {
        statusLabel.stringValue = "Refreshing..."
        
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let records = TokenStatsManager.shared.scanAllRecords(forceRefresh: forceRefresh)
            DispatchQueue.main.async {
                self?.allRecords = records
                self?.applyFilter()
            }
        }
    }
    
    private func applyFilter() {
        let now = Date()
        let filtered: [TokenRecord]
        if let maxSec = currentWindow.maxSeconds {
            filtered = allRecords.filter { r in
                guard let t = r.timestamp else { return false }
                return now.timeIntervalSince(t) <= maxSec
            }
        } else {
            filtered = allRecords
        }
        
        var statsDict: [String: ModelAggregatedStats] = [:]
        var totalIn: Int64 = 0
        var totalCache: Int64 = 0
        var totalOut: Int64 = 0
        var totalCalls = 0
        
        for r in filtered {
            var item = statsDict[r.modelName] ?? ModelAggregatedStats(modelName: r.modelName)
            item.callCount += 1
            totalCalls += 1
            item.inputTokens += r.inputTokens
            item.cacheReadTokens += r.cacheReadTokens
            item.outputTokens += r.outputTokens
            item.totalDurationSeconds += r.durationSeconds
            statsDict[r.modelName] = item
            
            totalIn += r.inputTokens
            totalCache += r.cacheReadTokens
            totalOut += r.outputTokens
        }
        
        let totalAll = totalIn + totalCache + totalOut
        self.displayedStats = statsDict.values.sorted { $0.totalTokens > $1.totalTokens }
        
        let isEmpty = self.displayedStats.isEmpty
        self.emptyStateView.isHidden = !isEmpty
        self.tableView.isHidden = isEmpty
        self.tableView.reloadData()
        
        // 1. Total Tokens
        totalTokensCard.update(value: formatKMB(totalAll))
        
        // 2. Cache Hit Rate
        let promptTokens = totalIn + totalCache
        if promptTokens > 0 {
            let ratio = Double(totalCache) / Double(promptTokens) * 100.0
            cacheRatioCard.update(
                value: String(format: "%.1f%%", ratio),
                valueColor: .systemGreen
            )
        } else {
            cacheRatioCard.update(value: "0.0%", valueColor: .labelColor)
        }
        
        // 3. Total Requests
        let callText = totalCalls >= 1000 ? formatKMB(Int64(totalCalls)) : "\(totalCalls)"
        totalCallsCard.update(value: callText)
        
        // Status Bar
        let df = DateFormatter()
        df.timeStyle = .medium
        let totalOutDuration = displayedStats.reduce(0.0) { $0 + $1.totalDurationSeconds }
        let speedSnippet: String
        if totalOutDuration > 0.1, totalOut > 0 {
            let overallSpeed = Double(totalOut) / totalOutDuration
            let formatted = formatTokenSpeed(overallSpeed)
            speedSnippet = " · Avg Speed \(formatted.value) \(formatted.unit ?? "")"
        } else {
            speedSnippet = ""
        }
        statusLabel.stringValue = "● Scanned \(allRecords.count) sessions (\(filtered.count) in window)\(speedSnippet) · Updated \(df.string(from: Date()))"
    }
    
    // MARK: - NSTableViewDataSource & Delegate
    func numberOfRows(in tableView: NSTableView) -> Int {
        return displayedStats.count
    }
    
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < displayedStats.count, let column = tableColumn else { return nil }
        let item = displayedStats[row]
        let colId = column.identifier.rawValue
        let totalAcrossAll = displayedStats.reduce(0) { $0 + $1.totalTokens }
        
        switch colId {
        case "model":
            let cell = (tableView.makeView(withIdentifier: NSUserInterfaceItemIdentifier("ModelCell"), owner: self) as? ModelCellView) ?? ModelCellView()
            cell.identifier = NSUserInterfaceItemIdentifier("ModelCell")
            cell.configure(modelName: item.modelName)
            return cell
            
        case "calls":
            let cell = (tableView.makeView(withIdentifier: NSUserInterfaceItemIdentifier("CallsCell"), owner: self) as? MetricTextCellView) ?? MetricTextCellView()
            cell.identifier = NSUserInterfaceItemIdentifier("CallsCell")
            let callText = item.callCount >= 1000 ? formatKMB(Int64(item.callCount)) : "\(item.callCount)"
            cell.configure(text: callText)
            return cell
            
        case "total":
            let cell = (tableView.makeView(withIdentifier: NSUserInterfaceItemIdentifier("TotalCell"), owner: self) as? MetricTextCellView) ?? MetricTextCellView()
            cell.identifier = NSUserInterfaceItemIdentifier("TotalCell")
            cell.configure(text: formatKMB(item.totalTokens), isBold: true)
            return cell
            
        case "speed":
            let cell = (tableView.makeView(withIdentifier: NSUserInterfaceItemIdentifier("SpeedCell"), owner: self) as? SpeedCellView) ?? SpeedCellView()
            cell.identifier = NSUserInterfaceItemIdentifier("SpeedCell")
            cell.configure(speed: item.tokenSpeed)
            return cell
            
        case "cache":
            let cell = (tableView.makeView(withIdentifier: NSUserInterfaceItemIdentifier("CacheCell"), owner: self) as? CacheCellView) ?? CacheCellView()
            cell.identifier = NSUserInterfaceItemIdentifier("CacheCell")
            cell.configure(tokens: item.cacheReadTokens, ratio: item.cacheRatio)
            return cell
            
        case "share":
            let cell = (tableView.makeView(withIdentifier: NSUserInterfaceItemIdentifier("ShareCell"), owner: self) as? ShareCellView) ?? ShareCellView()
            cell.identifier = NSUserInterfaceItemIdentifier("ShareCell")
            let share = totalAcrossAll > 0 ? (Double(item.totalTokens) / Double(totalAcrossAll) * 100.0) : 0.0
            cell.configure(share: share)
            return cell
            
        default:
            return nil
        }
    }
}
