import Cocoa
import Foundation
import AppKit
import Darwin
import SQLite3

// MARK: - Models

struct GetUserStatusResponse: Codable {
    let userStatus: UserStatus?
}

struct UserStatus: Codable {
    let cascadeModelConfigData: CascadeModelConfigData?
}

struct CascadeModelConfigData: Codable {
    let clientModelConfigs: [ClientModelConfig]?
}

struct ClientModelConfig: Codable {
    let label: String
    let quotaInfo: QuotaInfo?
}

struct QuotaInfo: Codable {
    let remainingFraction: Double?
    let resetTime: String?
}

struct GroupedQuota {
    let name: String
    let fraction: Double
    let resetTime: String?
}

struct EndpointTarget: Equatable {
    let scheme: String
    let port: Int
}

// MARK: - Token Usage Data Models & Manager

struct TokenRecord {
    let modelName: String
    let inputTokens: Int64
    let cacheReadTokens: Int64
    let outputTokens: Int64
    let timestamp: Date?
    
    var totalTokens: Int64 {
        return inputTokens + cacheReadTokens + outputTokens
    }
}

struct ModelAggregatedStats {
    let modelName: String
    var callCount: Int = 0
    var inputTokens: Int64 = 0
    var cacheReadTokens: Int64 = 0
    var outputTokens: Int64 = 0
    
    var totalTokens: Int64 {
        return inputTokens + cacheReadTokens + outputTokens
    }
    
    var cacheRatio: Double {
        let promptTokens = inputTokens + cacheReadTokens
        guard promptTokens > 0 else { return 0.0 }
        return Double(cacheReadTokens) / Double(promptTokens) * 100.0
    }
}

enum TimeWindow: Int, CaseIterable {
    case fiveHours = 0
    case today = 1
    case sevenDays = 2
    case thirtyDays = 3
    case allTime = 4
    
    var title: String {
        switch self {
        case .fiveHours: return "5h 窗口"
        case .today: return "当天 (24h)"
        case .sevenDays: return "近 7 天"
        case .thirtyDays: return "近 30 天"
        case .allTime: return "全部时间"
        }
    }
    
    var maxSeconds: TimeInterval? {
        switch self {
        case .fiveHours: return 5 * 3600
        case .today: return 24 * 3600
        case .sevenDays: return 7 * 86400
        case .thirtyDays: return 30 * 86400
        case .allTime: return nil
        }
    }
}

class TokenStatsManager {
    static let shared = TokenStatsManager()
    
    private let homeDir = FileManager.default.homeDirectoryForCurrentUser
    private var brainDir: URL {
        homeDir.appendingPathComponent(".gemini/antigravity-cli/brain")
    }
    private var convDir: URL {
        homeDir.appendingPathComponent(".gemini/antigravity-cli/conversations")
    }
    
    private let isoDateFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
    
    private let isoDateFractionFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    
    func parseDate(_ str: String?) -> Date? {
        guard let s = str, !s.isEmpty else { return nil }
        return isoDateFormatter.date(from: s) ?? isoDateFractionFormatter.date(from: s)
    }
    
    func scanAllRecords() -> [TokenRecord] {
        var records: [TokenRecord] = []
        let fileManager = FileManager.default
        guard let dbFiles = try? fileManager.contentsOfDirectory(at: convDir, includingPropertiesForKeys: nil) else {
            return []
        }
        
        for dbURL in dbFiles where dbURL.pathExtension == "db" {
            let convId = dbURL.deletingPathExtension().lastPathComponent
            let transcriptURL = brainDir.appendingPathComponent(convId).appendingPathComponent(".system_generated/logs/transcript.jsonl")
            guard fileManager.fileExists(atPath: transcriptURL.path) else { continue }
            
            let modelMap = loadModelMap(from: dbURL)
            guard let fileHandle = try? FileHandle(forReadingFrom: transcriptURL) else { continue }
            defer { try? fileHandle.close() }
            
            let data = fileHandle.readDataToEndOfFile()
            guard let content = String(data: data, encoding: .utf8) else { continue }
            
            var genIdx = 0
            content.enumerateLines { [weak self] line, _ in
                guard line.contains("\"PLANNER_RESPONSE\"") else { return }
                guard let lineData = line.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                      (json["type"] as? String) == "PLANNER_RESPONSE" else { return }
                
                let input = (json["input_tokens"] as? NSNumber)?.int64Value
                let cache = (json["cache_read_tokens"] as? NSNumber)?.int64Value ?? 0
                let output = (json["output_tokens"] as? NSNumber)?.int64Value ?? 0
                let createdAtStr = json["created_at"] as? String
                let date = self?.parseDate(createdAtStr)
                
                if let input = input {
                    let modelName = modelMap[genIdx] ?? (modelMap.values.first ?? "Gemini 3.8 Flash (Medium)")
                    records.append(TokenRecord(
                        modelName: modelName,
                        inputTokens: input,
                        cacheReadTokens: cache,
                        outputTokens: output,
                        timestamp: date
                    ))
                }
                genIdx += 1
            }
        }
        return records
    }
    
    private func loadModelMap(from dbURL: URL) -> [Int: String] {
        var map: [Int: String] = [:]
        var db: OpaquePointer?
        if sqlite3_open_v2(dbURL.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK {
            var stmt: OpaquePointer?
            let query = "SELECT idx, data FROM gen_metadata ORDER BY idx"
            if sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK {
                while sqlite3_step(stmt) == SQLITE_ROW {
                    let idx = Int(sqlite3_column_int(stmt, 0))
                    if let blobPtr = sqlite3_column_blob(stmt, 1) {
                        let bytes = Int(sqlite3_column_bytes(stmt, 1))
                        let data = Data(bytes: blobPtr, count: bytes)
                        map[idx] = extractModelName(from: data)
                    }
                }
                sqlite3_finalize(stmt)
            }
            sqlite3_close(db)
        }
        return map
    }
    
    private func extractModelName(from data: Data) -> String {
        if let str = String(data: data, encoding: .isoLatin1) {
            let patterns = [
                "Gemini 3.8 Flash (High)",
                "Gemini 3.8 Flash (Medium)",
                "Gemini 3.8 Flash (Low)",
                "Gemini 3.5 Flash (High)",
                "Gemini 3.5 Flash",
                "Claude Sonnet 4.6 (Thinking)",
                "Claude Sonnet 4.6",
                "Claude Opus 4.6 (Thinking)",
                "Claude Opus 4.6",
                "GPT-OSS 120B (Medium)",
                "GPT-OSS 120B",
                "Gemini 4 Argon"
            ]
            for p in patterns {
                if str.contains(p) {
                    return p
                }
            }
        }
        return "Gemini 3.8 Flash (Medium)"
    }
}

// MARK: - Token Analytics Window Controller

class TokenStatsWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    private var allRecords: [TokenRecord] = []
    private var currentWindow: TimeWindow = .fiveHours
    private var displayedStats: [ModelAggregatedStats] = []
    
    private var segmentedControl: NSSegmentedControl!
    private var tableView: NSTableView!
    
    // Metric Card Value Labels
    private var totalTokensValLabel: NSTextField!
    private var totalTokensSubLabel: NSTextField!
    
    private var cacheRatioValLabel: NSTextField!
    private var cacheRatioSubLabel: NSTextField!
    
    private var outputValLabel: NSTextField!
    private var outputSubLabel: NSTextField!
    
    private var totalCallsValLabel: NSTextField!
    private var totalCallsSubLabel: NSTextField!
    
    private var statusLabel: NSTextField!
    private var refreshButton: NSButton!
    
    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 550),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Antigravity Token Analytics"
        window.center()
        window.minSize = NSSize(width: 720, height: 460)
        self.init(window: window)
        setupUI()
    }
    
    private func setupUI() {
        guard let window = self.window else { return }
        let contentView = NSView(frame: window.contentView!.bounds)
        contentView.autoresizingMask = [.width, .height]
        window.contentView = contentView
        
        // 1. Top Header Area (Title & Segmented Window Selector)
        let headerView = NSView()
        headerView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(headerView)
        
        let headerTitle = NSTextField(labelWithString: "Token 用量与统计分析")
        headerTitle.translatesAutoresizingMaskIntoConstraints = false
        headerTitle.font = NSFont.systemFont(ofSize: 16, weight: .bold)
        headerTitle.textColor = .labelColor
        headerView.addSubview(headerTitle)
        
        let headerSubtitle = NSTextField(labelWithString: "Antigravity 本地对话调用记录与 Prompt 缓存分析")
        headerSubtitle.translatesAutoresizingMaskIntoConstraints = false
        headerSubtitle.font = NSFont.systemFont(ofSize: 11, weight: .regular)
        headerSubtitle.textColor = .secondaryLabelColor
        headerView.addSubview(headerSubtitle)
        
        let labels = TimeWindow.allCases.map { $0.title }
        segmentedControl = NSSegmentedControl(labels: labels, trackingMode: .selectOne, target: self, action: #selector(timeWindowChanged(_:)))
        segmentedControl.translatesAutoresizingMaskIntoConstraints = false
        segmentedControl.selectedSegment = 0 // Default to 5h
        headerView.addSubview(segmentedControl)
        
        // 2. Metrics Cards Row
        let cardStack = NSStackView()
        cardStack.orientation = .horizontal
        cardStack.distribution = .fillEqually
        cardStack.spacing = 10
        cardStack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(cardStack)
        
        let (card1, val1, sub1) = makeMetricCard(symbol: "chart.bar.fill", title: "总处理 Token", tint: .systemBlue)
        let (card2, val2, sub2) = makeMetricCard(symbol: "bolt.shield.fill", title: "缓存命中率 (Cache)", tint: .systemGreen)
        let (card3, val3, sub3) = makeMetricCard(symbol: "arrow.up.right.circle.fill", title: "生成输出 (Output)", tint: .systemPurple)
        let (card4, val4, sub4) = makeMetricCard(symbol: "waveform.path.ecg", title: "模型调用次数", tint: .systemOrange)
        
        self.totalTokensValLabel = val1
        self.totalTokensSubLabel = sub1
        self.cacheRatioValLabel = val2
        self.cacheRatioSubLabel = sub2
        self.outputValLabel = val3
        self.outputSubLabel = sub3
        self.totalCallsValLabel = val4
        self.totalCallsSubLabel = sub4
        
        cardStack.addArrangedSubview(card1)
        cardStack.addArrangedSubview(card2)
        cardStack.addArrangedSubview(card3)
        cardStack.addArrangedSubview(card4)
        
        // 3. Table View
        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder
        contentView.addSubview(scrollView)
        
        tableView = NSTableView()
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.gridStyleMask = [.solidHorizontalGridLineMask]
        tableView.rowHeight = 28
        tableView.dataSource = self
        tableView.delegate = self
        
        let columns: [(String, String, CGFloat, NSTextAlignment)] = [
            ("model", "模型名称 (Model)", 210, .left),
            ("calls", "调用次数", 75, .right),
            ("input", "输入 Tokens", 100, .right),
            ("cache", "缓存读取 (Prompt Cache)", 150, .right),
            ("output", "输出 Tokens", 95, .right),
            ("total", "总计 Tokens", 115, .right),
            ("share", "占比 (Share)", 70, .right)
        ]
        
        for (colId, title, width, align) in columns {
            let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(colId))
            col.title = title
            col.width = width
            col.minWidth = 50
            col.headerCell.alignment = align
            tableView.addTableColumn(col)
        }
        
        scrollView.documentView = tableView
        
        // 4. Bottom Controls Bar
        let bottomView = NSView()
        bottomView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(bottomView)
        
        statusLabel = NSTextField(labelWithString: "准备就绪")
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.font = NSFont.systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        bottomView.addSubview(statusLabel)
        
        refreshButton = NSButton(title: "刷新数据", target: self, action: #selector(refreshClicked(_:)))
        refreshButton.translatesAutoresizingMaskIntoConstraints = false
        refreshButton.bezelStyle = .rounded
        let config = NSImage.SymbolConfiguration(pointSize: 12, weight: .regular)
        refreshButton.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "Refresh")?.withSymbolConfiguration(config)
        refreshButton.imagePosition = .imageLeading
        bottomView.addSubview(refreshButton)
        
        let closeButton = NSButton(title: "关闭", target: self, action: #selector(closeClicked(_:)))
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.bezelStyle = .rounded
        bottomView.addSubview(closeButton)
        
        // AutoLayout Constraints
        NSLayoutConstraint.activate([
            // Header
            headerView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 14),
            headerView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 18),
            headerView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -18),
            headerView.heightAnchor.constraint(equalToConstant: 38),
            
            headerTitle.topAnchor.constraint(equalTo: headerView.topAnchor),
            headerTitle.leadingAnchor.constraint(equalTo: headerView.leadingAnchor),
            
            headerSubtitle.topAnchor.constraint(equalTo: headerTitle.bottomAnchor, constant: 2),
            headerSubtitle.leadingAnchor.constraint(equalTo: headerView.leadingAnchor),
            
            segmentedControl.centerYAnchor.constraint(equalTo: headerView.centerYAnchor),
            segmentedControl.trailingAnchor.constraint(equalTo: headerView.trailingAnchor),
            
            // Cards Row
            cardStack.topAnchor.constraint(equalTo: headerView.bottomAnchor, constant: 12),
            cardStack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 18),
            cardStack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -18),
            cardStack.heightAnchor.constraint(equalToConstant: 78),
            
            // Table
            scrollView.topAnchor.constraint(equalTo: cardStack.bottomAnchor, constant: 12),
            scrollView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 18),
            scrollView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -18),
            scrollView.bottomAnchor.constraint(equalTo: bottomView.topAnchor, constant: -10),
            
            // Bottom Bar
            bottomView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 18),
            bottomView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -18),
            bottomView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -12),
            bottomView.heightAnchor.constraint(equalToConstant: 30),
            
            statusLabel.leadingAnchor.constraint(equalTo: bottomView.leadingAnchor),
            statusLabel.centerYAnchor.constraint(equalTo: bottomView.centerYAnchor),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: refreshButton.leadingAnchor, constant: -12),
            
            refreshButton.trailingAnchor.constraint(equalTo: closeButton.leadingAnchor, constant: -8),
            refreshButton.centerYAnchor.constraint(equalTo: bottomView.centerYAnchor),
            
            closeButton.trailingAnchor.constraint(equalTo: bottomView.trailingAnchor),
            closeButton.centerYAnchor.constraint(equalTo: bottomView.centerYAnchor)
        ])
    }
    
    private func makeMetricCard(symbol: String, title: String, tint: NSColor) -> (NSBox, NSTextField, NSTextField) {
        let box = NSBox()
        box.boxType = .custom
        box.cornerRadius = 9
        box.fillColor = NSColor.windowBackgroundColor.withAlphaComponent(0.65)
        box.borderColor = NSColor.separatorColor.withAlphaComponent(0.35)
        box.borderWidth = 1
        
        let iconView = NSImageView()
        iconView.translatesAutoresizingMaskIntoConstraints = false
        let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
        iconView.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)?.withSymbolConfiguration(config)
        iconView.contentTintColor = tint
        box.contentView?.addSubview(iconView)
        
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        titleLabel.textColor = .secondaryLabelColor
        box.contentView?.addSubview(titleLabel)
        
        let valueLabel = NSTextField(labelWithString: "--")
        valueLabel.translatesAutoresizingMaskIntoConstraints = false
        valueLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 18, weight: .bold)
        valueLabel.textColor = .labelColor
        box.contentView?.addSubview(valueLabel)
        
        let subLabel = NSTextField(labelWithString: "--")
        subLabel.translatesAutoresizingMaskIntoConstraints = false
        subLabel.font = NSFont.systemFont(ofSize: 10, weight: .regular)
        subLabel.textColor = .tertiaryLabelColor
        box.contentView?.addSubview(subLabel)
        
        if let cv = box.contentView {
            NSLayoutConstraint.activate([
                iconView.topAnchor.constraint(equalTo: cv.topAnchor, constant: 8),
                iconView.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: 10),
                iconView.widthAnchor.constraint(equalToConstant: 16),
                iconView.heightAnchor.constraint(equalToConstant: 16),
                
                titleLabel.centerYAnchor.constraint(equalTo: iconView.centerYAnchor),
                titleLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 6),
                titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: cv.trailingAnchor, constant: -8),
                
                valueLabel.topAnchor.constraint(equalTo: iconView.bottomAnchor, constant: 4),
                valueLabel.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: 10),
                valueLabel.trailingAnchor.constraint(lessThanOrEqualTo: cv.trailingAnchor, constant: -8),
                
                subLabel.topAnchor.constraint(equalTo: valueLabel.bottomAnchor, constant: 2),
                subLabel.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: 10),
                subLabel.trailingAnchor.constraint(lessThanOrEqualTo: cv.trailingAnchor, constant: -8)
            ])
        }
        
        return (box, valueLabel, subLabel)
    }
    
    @objc func timeWindowChanged(_ sender: NSSegmentedControl) {
        let index = sender.selectedSegment
        if let window = TimeWindow(rawValue: index) {
            self.currentWindow = window
            self.filterAndDisplay()
        }
    }
    
    @objc func refreshClicked(_ sender: Any?) {
        loadData()
    }
    
    @objc func closeClicked(_ sender: Any?) {
        self.window?.close()
    }
    
    func loadData() {
        refreshButton.isEnabled = false
        statusLabel.stringValue = "正在扫描本地所有对话记录..."
        
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let scanned = TokenStatsManager.shared.scanAllRecords()
            
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.allRecords = scanned
                self.refreshButton.isEnabled = true
                self.filterAndDisplay()
            }
        }
    }
    
    private func filterAndDisplay() {
        let now = Date()
        let maxSec = currentWindow.maxSeconds
        
        // Filter records by selected time window
        let filtered: [TokenRecord]
        if let limit = maxSec {
            filtered = allRecords.filter { r in
                guard let t = r.timestamp else { return false }
                return now.timeIntervalSince(t) <= limit
            }
        } else {
            filtered = allRecords
        }
        
        // Aggregate by model
        var statsDict: [String: ModelAggregatedStats] = [:]
        var totalIn: Int64 = 0
        var totalCache: Int64 = 0
        var totalOut: Int64 = 0
        let totalCalls = filtered.count
        
        for r in filtered {
            var item = statsDict[r.modelName] ?? ModelAggregatedStats(modelName: r.modelName)
            item.callCount += 1
            item.inputTokens += r.inputTokens
            item.cacheReadTokens += r.cacheReadTokens
            item.outputTokens += r.outputTokens
            statsDict[r.modelName] = item
            
            totalIn += r.inputTokens
            totalCache += r.cacheReadTokens
            totalOut += r.outputTokens
        }
        
        let totalAll = totalIn + totalCache + totalOut
        self.displayedStats = statsDict.values.sorted { $0.totalTokens > $1.totalTokens }
        self.tableView.reloadData()
        
        // Update Metric Cards
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        
        // 1. Total Tokens
        self.totalTokensValLabel.stringValue = formatter.string(from: NSNumber(value: totalAll)) ?? "\(totalAll)"
        self.totalTokensSubLabel.stringValue = formatCompactNumber(totalAll) + " tokens 处理"
        
        // 2. Cache Hit Ratio
        let promptTokens = totalIn + totalCache
        if promptTokens > 0 {
            let ratio = Double(totalCache) / Double(promptTokens) * 100.0
            self.cacheRatioValLabel.stringValue = String(format: "%.1f%%", ratio)
            self.cacheRatioValLabel.textColor = .systemGreen
            self.cacheRatioSubLabel.stringValue = "已缓存: " + formatCompactNumber(totalCache) + " tokens"
        } else {
            self.cacheRatioValLabel.stringValue = "0.0%"
            self.cacheRatioValLabel.textColor = .labelColor
            self.cacheRatioSubLabel.stringValue = "无 Prompt 缓存"
        }
        
        // 3. Output Tokens
        self.outputValLabel.stringValue = formatter.string(from: NSNumber(value: totalOut)) ?? "\(totalOut)"
        let outShare = totalAll > 0 ? (Double(totalOut) / Double(totalAll) * 100.0) : 0.0
        self.outputSubLabel.stringValue = String(format: "占总用量 %.1f%%", outShare)
        
        // 4. Total Calls
        self.totalCallsValLabel.stringValue = "\(totalCalls) 次"
        if totalCalls > 0 {
            let avgPerCall = totalAll / Int64(totalCalls)
            self.totalCallsSubLabel.stringValue = "均次: " + formatCompactNumber(avgPerCall) + " tokens"
        } else {
            self.totalCallsSubLabel.stringValue = "当前窗口暂无调用"
        }
        
        // Status bar
        let df = DateFormatter()
        df.timeStyle = .medium
        statusLabel.stringValue = "● 已扫描 \(allRecords.count) 条历史记录 (当前窗口: \(filtered.count) 条) · 上次更新: \(df.string(from: Date()))"
    }
    
    private func formatCompactNumber(_ n: Int64) -> String {
        if n >= 1_000_000 {
            return String(format: "%.2fM", Double(n) / 1_000_000.0)
        } else if n >= 1_000 {
            return String(format: "%.1fK", Double(n) / 1_000.0)
        } else {
            return "\(n)"
        }
    }
    
    // MARK: - NSTableViewDataSource & Delegate
    
    func numberOfRows(in tableView: NSTableView) -> Int {
        return displayedStats.count
    }
    
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < displayedStats.count, let column = tableColumn else { return nil }
        let item = displayedStats[row]
        let colId = column.identifier.rawValue
        
        let cell = NSTextField(labelWithString: "")
        cell.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        cell.lineBreakMode = .byTruncatingTail
        
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        
        let totalAcrossAll = displayedStats.reduce(0) { $0 + $1.totalTokens }
        
        switch colId {
        case "model":
            cell.stringValue = item.modelName
            cell.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
            cell.alignment = .left
        case "calls":
            cell.stringValue = "\(item.callCount)"
            cell.alignment = .right
        case "input":
            cell.stringValue = formatter.string(from: NSNumber(value: item.inputTokens)) ?? "0"
            cell.alignment = .right
        case "cache":
            let cacheStr = formatter.string(from: NSNumber(value: item.cacheReadTokens)) ?? "0"
            cell.stringValue = "\(cacheStr) (\(String(format: "%.1f%%", item.cacheRatio)))"
            cell.textColor = .systemGreen
            cell.alignment = .right
        case "output":
            cell.stringValue = formatter.string(from: NSNumber(value: item.outputTokens)) ?? "0"
            cell.alignment = .right
        case "total":
            cell.stringValue = formatter.string(from: NSNumber(value: item.totalTokens)) ?? "0"
            cell.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .bold)
            cell.alignment = .right
        case "share":
            let share = totalAcrossAll > 0 ? (Double(item.totalTokens) / Double(totalAcrossAll) * 100.0) : 0.0
            cell.stringValue = String(format: "%.1f%%", share)
            cell.alignment = .right
            cell.textColor = .secondaryLabelColor
        default:
            break
        }
        
        return cell
    }
}

// MARK: - Custom Views

class ProgressBarView: NSView {
    var progress: Double = 0.0 {
        didSet { needsDisplay = true }
    }
    
    var color: NSColor = .systemBlue {
        didSet { needsDisplay = true }
    }
    
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        
        // Draw Track
        let trackPath = NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2)
        let trackColor = NSColor.quaternaryLabelColor
        trackColor.set()
        trackPath.fill()
        
        // Draw Fill
        let fillWidth = bounds.width * CGFloat(max(0, min(1, progress)))
        if fillWidth > 0 {
            let fillRect = NSRect(x: 0, y: 0, width: fillWidth, height: bounds.height)
            let fillPath = NSBezierPath(roundedRect: fillRect, xRadius: bounds.height / 2, yRadius: bounds.height / 2)
            color.set()
            fillPath.fill()
        }
    }
}

class QuotaMenuItemView: NSView {
    private let logoImageView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let percentageLabel = NSTextField(labelWithString: "")
    private let progressBar = ProgressBarView()
    private let resetLabel = NSTextField(labelWithString: "")
    
    init(title: String, fraction: Double, resetText: String) {
        super.init(frame: NSRect(x: 0, y: 0, width: 280, height: 64))
        setupViews(title: title, fraction: fraction, resetText: resetText)
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    private func setupViews(title: String, fraction: Double, resetText: String) {
        // Setup logo image view
        logoImageView.translatesAutoresizingMaskIntoConstraints = false
        logoImageView.imageScaling = .scaleProportionallyUpOrDown
        
        let imageName: String
        if title.localizedCaseInsensitiveContains("Gemini") {
            imageName = "gemini"
        } else if title.localizedCaseInsensitiveContains("Claude") {
            imageName = "claude"
        } else {
            imageName = ""
        }
        
        if !imageName.isEmpty, let image = NSImage(named: imageName) {
            logoImageView.image = image
        } else {
            logoImageView.image = nil
        }
        
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor = .labelColor
        titleLabel.stringValue = title
        titleLabel.lineBreakMode = .byTruncatingTail
        
        percentageLabel.translatesAutoresizingMaskIntoConstraints = false
        percentageLabel.font = NSFont.systemFont(ofSize: 13, weight: .bold)
        percentageLabel.alignment = .right
        
        let rawPct = fraction * 100.0
        let pct: Int
        if fraction >= 0.9999 {
            pct = 100
        } else if fraction < 1.0 && rawPct >= 99.0 {
            pct = 99
        } else if fraction > 0.0 && rawPct < 1.0 {
            pct = 1
        } else {
            pct = Int(round(rawPct))
        }
        percentageLabel.stringValue = "\(pct)%"
        
        let statusColor: NSColor
        if fraction > 0.50 {
            statusColor = .systemGreen
        } else if fraction >= 0.20 {
            statusColor = .systemOrange
        } else {
            statusColor = .systemRed
        }
        percentageLabel.textColor = .labelColor
        
        progressBar.translatesAutoresizingMaskIntoConstraints = false
        progressBar.progress = fraction
        progressBar.color = statusColor
        
        resetLabel.translatesAutoresizingMaskIntoConstraints = false
        resetLabel.font = NSFont.systemFont(ofSize: 10, weight: .regular)
        resetLabel.textColor = .secondaryLabelColor
        resetLabel.stringValue = resetText
        resetLabel.lineBreakMode = .byTruncatingTail
        
        addSubview(logoImageView)
        addSubview(titleLabel)
        addSubview(percentageLabel)
        addSubview(progressBar)
        addSubview(resetLabel)
        
        let hasLogo = logoImageView.image != nil
        let contentLeadingAnchor = hasLogo ? logoImageView.trailingAnchor : leadingAnchor
        let contentLeadingConstant: CGFloat = hasLogo ? 12 : 16
        
        var constraints = [
            // Row 1: Title and Percentage
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            
            percentageLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            percentageLabel.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            percentageLabel.leadingAnchor.constraint(greaterThanOrEqualTo: titleLabel.trailingAnchor, constant: 8),
            
            // Row 2: Progress Bar
            progressBar.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            progressBar.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 6),
            progressBar.heightAnchor.constraint(equalToConstant: 6),
            
            // Row 3: Reset time
            resetLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            resetLabel.topAnchor.constraint(equalTo: progressBar.bottomAnchor, constant: 4),
            resetLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8)
        ]
        
        if hasLogo {
            constraints.append(contentsOf: [
                logoImageView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
                logoImageView.centerYAnchor.constraint(equalTo: centerYAnchor),
                logoImageView.widthAnchor.constraint(equalToConstant: 32),
                logoImageView.heightAnchor.constraint(equalToConstant: 32)
            ])
        }
        
        constraints.append(contentsOf: [
            titleLabel.leadingAnchor.constraint(equalTo: contentLeadingAnchor, constant: contentLeadingConstant),
            progressBar.leadingAnchor.constraint(equalTo: contentLeadingAnchor, constant: contentLeadingConstant),
            resetLabel.leadingAnchor.constraint(equalTo: contentLeadingAnchor, constant: contentLeadingConstant)
        ])
        
        NSLayoutConstraint.activate(constraints)
    }
}

// MARK: - Localhost SSL Delegate

class LocalhostSessionDelegate: NSObject, URLSessionDelegate {
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           let serverTrust = challenge.protectionSpace.serverTrust,
           challenge.protectionSpace.host == "127.0.0.1" || challenge.protectionSpace.host == "localhost" {
            completionHandler(.useCredential, URLCredential(trust: serverTrust))
            return
        }
        completionHandler(.performDefaultHandling, nil)
    }
}

// MARK: - App Delegate

class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var menu: NSMenu!
    private var timer: Timer?
    private var isFetching = false
    
    private var lastConfigs: [ClientModelConfig]? = nil
    private var isOffline = true
    
    private var currentPercentageText: String = "--%"
    private var currentStatusColor: NSColor? = nil
    
    private var tokenStatsWindowController: TokenStatsWindowController?
    
    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 3.0
        return URLSession(configuration: config, delegate: LocalhostSessionDelegate(), delegateQueue: nil)
    }()
    
    private var showIcon: Bool {
        get { UserDefaults.standard.bool(forKey: "showIcon") }
        set {
            UserDefaults.standard.set(newValue, forKey: "showIcon")
            updateStatusBarDisplay()
        }
    }
    
    private var showPercentage: Bool {
        get { UserDefaults.standard.bool(forKey: "showPercentage") }
        set {
            UserDefaults.standard.set(newValue, forKey: "showPercentage")
            updateStatusBarDisplay()
        }
    }
    
    private var quitOnFailure: Bool {
        get { UserDefaults.standard.bool(forKey: "quitOnFailure") }
        set {
            UserDefaults.standard.set(newValue, forKey: "quitOnFailure")
        }
    }
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Keep in menu bar without Dock icon, but allow interactive windows
        NSApp.setActivationPolicy(.accessory)
        
        // Register defaults
        UserDefaults.standard.register(defaults: [
            "showIcon": true,
            "showPercentage": true,
            "quitOnFailure": false
        ])
        
        // Setup status item
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        
        // Setup initial menu
        menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        
        updateStatusBar(percentageText: "--%", color: nil)
        rebuildMenu()
        
        // Start polling
        startPolling()
        
        // Trigger first fetch
        fetchStatus()
    }
    
    func menuWillOpen(_ menu: NSMenu) {
        // Instantly refresh quota on menu click
        fetchStatus()
    }
    
    @objc func toggleShowIcon(_ sender: NSMenuItem) {
        showIcon = !showIcon
        rebuildMenu()
    }
    
    @objc func toggleShowPercentage(_ sender: NSMenuItem) {
        showPercentage = !showPercentage
        rebuildMenu()
    }
    
    @objc func toggleQuitOnFailure(_ sender: NSMenuItem) {
        quitOnFailure = !quitOnFailure
        rebuildMenu()
    }
    
    func applicationWillTerminate(_ notification: Notification) {
        timer?.invalidate()
        retryTimer?.invalidate()
    }
    
    private var retryTimer: Timer?
    
    private func startPolling() {
        timer?.invalidate()
        let interval = Double(ProcessInfo.processInfo.environment["AGY_TEST_POLL_INTERVAL"] ?? "15.0") ?? 15.0
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.fetchStatus()
        }
    }
    
    private func scheduleRetry() {
        retryTimer?.invalidate()
        // Fast retry in 2.0s when agy process exists but RPC hasn't responded yet
        retryTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: false) { [weak self] _ in
            self?.fetchStatus()
        }
    }
    
    @objc func refreshTriggered(_ sender: Any?) {
        fetchStatus()
    }
    
    @objc func openTokenStatsDashboard(_ sender: Any?) {
        if tokenStatsWindowController == nil {
            tokenStatsWindowController = TokenStatsWindowController()
        }
        tokenStatsWindowController?.showWindow(self)
        tokenStatsWindowController?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        tokenStatsWindowController?.loadData()
    }
    
    @objc func quitTriggered(_ sender: Any?) {
        NSApp.terminate(nil)
    }
    
    private func updateStatusBar(percentageText: String, color: NSColor?) {
        currentPercentageText = percentageText
        currentStatusColor = color
        updateStatusBarDisplay()
    }
    
    private func updateStatusBarDisplay() {
        guard let button = statusItem.button else { return }
        
        let showIcon = self.showIcon
        let showPercentage = self.showPercentage
        
        // Determine image
        if showIcon {
            let config = NSImage.SymbolConfiguration(pointSize: 12, weight: .regular, scale: .medium)
            let img = NSImage(systemSymbolName: "sparkles", accessibilityDescription: nil)?
                .withSymbolConfiguration(config)
            button.image = img
            button.contentTintColor = nil
            button.imagePosition = showPercentage ? .imageLeft : .imageOnly
        } else {
            button.image = nil
            button.contentTintColor = nil
            button.imagePosition = .noImage
        }
        
        // Determine title
        if showPercentage {
            let titleString = currentPercentageText
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium),
                .baselineOffset: -1.0
            ]
            button.attributedTitle = NSAttributedString(string: titleString, attributes: attrs)
        } else {
            button.attributedTitle = NSAttributedString(string: "")
        }
    }
    
    private func rebuildMenu() {
        menu.removeAllItems()
        
        if isOffline {
            let offlineItem = NSMenuItem(title: "Antigravity is offline (Click to retry)", action: #selector(refreshTriggered(_:)), keyEquivalent: "")
            offlineItem.target = self
            menu.addItem(offlineItem)
        } else if let configs = lastConfigs {
            let groups = groupConfigs(configs)
            for group in groups {
                let menuItem = NSMenuItem()
                let customView = QuotaMenuItemView(
                    title: group.name,
                    fraction: group.fraction,
                    resetText: formatResetTime(group.resetTime)
                )
                menuItem.view = customView
                menu.addItem(menuItem)
            }
        } else {
            let loadingItem = NSMenuItem(title: "Loading...", action: nil, keyEquivalent: "")
            menu.addItem(loadingItem)
        }
        
        menu.addItem(NSMenuItem.separator())
        
        let tokenStatsItem = NSMenuItem(title: "Token Usage Dashboard...", action: #selector(openTokenStatsDashboard(_:)), keyEquivalent: "t")
        tokenStatsItem.target = self
        menu.addItem(tokenStatsItem)
        
        menu.addItem(NSMenuItem.separator())
        
        let showIconItem = NSMenuItem(title: "Show Icon", action: #selector(toggleShowIcon(_:)), keyEquivalent: "")
        showIconItem.target = self
        showIconItem.state = showIcon ? .on : .off
        showIconItem.isEnabled = showPercentage
        menu.addItem(showIconItem)
        
        let showPercentageItem = NSMenuItem(title: "Show Percentage", action: #selector(toggleShowPercentage(_:)), keyEquivalent: "")
        showPercentageItem.target = self
        showPercentageItem.state = showPercentage ? .on : .off
        showPercentageItem.isEnabled = showIcon
        menu.addItem(showPercentageItem)
        
        let quitOnFailureItem = NSMenuItem(title: "Auto-Quit if Offline", action: #selector(toggleQuitOnFailure(_:)), keyEquivalent: "")
        quitOnFailureItem.target = self
        quitOnFailureItem.state = quitOnFailure ? .on : .off
        menu.addItem(quitOnFailureItem)
        
        menu.addItem(NSMenuItem.separator())
        
        let refreshItem = NSMenuItem(title: "Refresh", action: #selector(refreshTriggered(_:)), keyEquivalent: "r")
        refreshItem.target = self
        menu.addItem(refreshItem)
        
        let quitItem = NSMenuItem(title: "Quit", action: #selector(quitTriggered(_:)), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
    }
    
    private func handleFetchFailure(errorDescription: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.isOffline = true
            self.lastConfigs = nil
            self.updateStatusBar(percentageText: "--%", color: nil)
            self.rebuildMenu()
            
            let agyRunning = self.isAgyProcessRunning()
            
            // If agy process is completely gone and Auto-Quit is enabled, quit cleanly
            if !agyRunning && self.quitOnFailure {
                NSLog("AgyUsage: No active agy process found in system. Auto-quitting as configured.")
                NSApp.terminate(nil)
                return
            }
            
            // If agy is still running, it is likely spinning up or recovering: retry in 2.0s
            if agyRunning {
                NSLog("AgyUsage: agy process is alive but RPC failed (%@). Retrying in 2.0s...", errorDescription)
                self.scheduleRetry()
            }
        }
    }
    
    private func isAgyProcessRunning() -> Bool {
        let targetName = ProcessInfo.processInfo.environment["AGY_TEST_TARGET_PROCESS"] ?? "agy"
        
        var pids = [pid_t](repeating: 0, count: 4096)
        let bytesUsed = proc_listpids(UInt32(PROC_ALL_PIDS), 0, &pids, Int32(MemoryLayout<pid_t>.stride * pids.count))
        if bytesUsed <= 0 { return false }
        
        let count = Int(bytesUsed) / MemoryLayout<pid_t>.stride
        for i in 0..<count {
            let pid = pids[i]
            if pid <= 0 { continue }
            var buffer = [CChar](repeating: 0, count: 256)
            let nameLen = proc_name(pid, &buffer, UInt32(buffer.count))
            if nameLen > 0 {
                let name = String(cString: buffer)
                if name == targetName || name.hasSuffix("/\(targetName)") {
                    return true
                }
            }
        }
        return false
    }
    
    private var cachedWorkingTarget: EndpointTarget? = nil
    
    private func fetchStatus() {
        guard !isFetching else { return }
        isFetching = true
        
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            
            let agyRunning = self.isAgyProcessRunning()
            if !agyRunning && self.quitOnFailure {
                DispatchQueue.main.async {
                    NSLog("AgyUsage: No active agy process found in system. Auto-quitting as configured.")
                    NSApp.terminate(nil)
                }
                return
            }
            
            // Fast path: Try previously verified working target
            if let cached = self.cachedWorkingTarget {
                self.tryFetch(targets: [cached], index: 0, isFallbackScan: false)
                return
            }
            
            // Slow path: Full port scan
            self.scanAndFetch()
        }
    }
    
    private func scanAndFetch() {
        let ports = self.discoverCandidatePorts()
        if ports.isEmpty {
            self.handleFetchFailure(errorDescription: "No agy daemon ports found")
            DispatchQueue.main.async { self.isFetching = false }
            return
        }
        var targets: [EndpointTarget] = []
        for p in ports {
            targets.append(EndpointTarget(scheme: "https", port: p))
            targets.append(EndpointTarget(scheme: "http", port: p))
        }
        self.tryFetch(targets: targets, index: 0, isFallbackScan: true)
    }
    
    private func tryFetch(targets: [EndpointTarget], index: Int, isFallbackScan: Bool) {
        guard index < targets.count else {
            if !isFallbackScan {
                // Cached target failed (e.g. daemon restarted), fallback to a fresh scan
                self.cachedWorkingTarget = nil
                self.scanAndFetch()
                return
            }
            self.cachedWorkingTarget = nil
            self.handleFetchFailure(errorDescription: "All candidate endpoints failed or returned empty configs")
            DispatchQueue.main.async { self.isFetching = false }
            return
        }
        
        let target = targets[index]
        let urlString = "\(target.scheme)://127.0.0.1:\(target.port)/exa.language_server_pb.LanguageServerService/GetUserStatus"
        guard let url = URL(string: urlString) else {
            tryFetch(targets: targets, index: index + 1, isFallbackScan: isFallbackScan)
            return
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        if let csrfToken = self.getCsrfToken() {
            request.setValue(csrfToken, forHTTPHeaderField: "x-codeium-csrf-token")
        }
        request.httpBody = "{}".data(using: .utf8)
        request.timeoutInterval = 3.0
        
        let task = self.session.dataTask(with: request) { [weak self] data, response, error in
            guard let self = self else { return }
            
            if error != nil || data == nil {
                self.tryFetch(targets: targets, index: index + 1, isFallbackScan: isFallbackScan)
                return
            }
            
            do {
                let decoder = JSONDecoder()
                let responseObj = try decoder.decode(GetUserStatusResponse.self, from: data!)
                guard let configs = responseObj.userStatus?.cascadeModelConfigData?.clientModelConfigs, !configs.isEmpty else {
                    self.tryFetch(targets: targets, index: index + 1, isFallbackScan: isFallbackScan)
                    return
                }
                
                // Cache the verified working endpoint
                self.cachedWorkingTarget = target
                
                DispatchQueue.main.async {
                    self.retryTimer?.invalidate()
                    self.retryTimer = nil
                    self.isFetching = false
                    self.isOffline = false
                    self.lastConfigs = configs
                    
                    if let repConfig = self.findStatusBarConfig(from: configs),
                       let fraction = repConfig.quotaInfo?.remainingFraction {
                        let rawPct = fraction * 100.0
                        let pct: Int
                        if fraction >= 0.9999 {
                            pct = 100
                        } else if fraction < 1.0 && rawPct >= 99.0 {
                            pct = 99
                        } else if fraction > 0.0 && rawPct < 1.0 {
                            pct = 1
                        } else {
                            pct = Int(round(rawPct))
                        }
                        let pctText = "\(pct)%"
                        let color: NSColor
                        if fraction > 0.50 {
                            color = .systemGreen
                        } else if fraction >= 0.20 {
                            color = .systemOrange
                        } else {
                            color = .systemRed
                        }
                        self.updateStatusBar(percentageText: pctText, color: color)
                        NSLog("AgyUsage: successfully fetched quota %@", pctText)
                    } else {
                        self.updateStatusBar(percentageText: "--%", color: nil)
                    }
                    self.rebuildMenu()
                }
            } catch {
                self.tryFetch(targets: targets, index: index + 1, isFallbackScan: isFallbackScan)
            }
        }
        task.resume()
    }
    
    // MARK: - Helpers
    
    private func discoverCandidatePorts() -> [Int] {
        if let testPortStr = ProcessInfo.processInfo.environment["AGY_TEST_PORT"], let testPort = Int(testPortStr) {
            return [testPort]
        }
        
        let process = Process()
        process.launchPath = "/usr/sbin/lsof"
        process.arguments = ["-c", "agy", "-a", "-iTCP", "-sTCP:LISTEN", "-P", "-n"]
        
        let pipe = Pipe()
        process.standardOutput = pipe
        
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            
            if let output = String(data: data, encoding: .utf8) {
                var ports: [Int] = []
                let lines = output.components(separatedBy: .newlines)
                for line in lines {
                    if line.contains("LISTEN") {
                        let parts = line.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
                        if let nameCol = parts.last(where: { $0.contains(":") }) {
                            let portStr = nameCol.components(separatedBy: ":").last ?? ""
                            if let port = Int(portStr) {
                                ports.append(port)
                            }
                        }
                    }
                }
                return ports
            }
        } catch {
            return []
        }
        
        return []
    }
    
    private func getCsrfToken() -> String? {
        if let testToken = ProcessInfo.processInfo.environment["AGY_TEST_TOKEN"] {
            return testToken
        }
        
        // 1. Try file
        let tokenPath = "/tmp/agy_csrf_token"
        if let content = try? String(contentsOfFile: tokenPath, encoding: .utf8) {
            let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        
        // 2. Try ps
        let process = Process()
        process.launchPath = "/bin/ps"
        process.arguments = ["-eo", "args"]
        
        let pipe = Pipe()
        process.standardOutput = pipe
        
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            
            if let output = String(data: data, encoding: .utf8) {
                let pattern = "--csrf_token=([a-zA-Z0-9-]+)"
                if let regex = try? NSRegularExpression(pattern: pattern) {
                    let nsString = output as NSString
                    let results = regex.matches(in: output, range: NSRange(location: 0, length: nsString.length))
                    if let firstMatch = results.first {
                        return nsString.substring(with: firstMatch.range(at: 1))
                    }
                }
            }
        } catch {
            return nil
        }
        
        return nil
    }
    
    private func findStatusBarConfig(from configs: [ClientModelConfig]) -> ClientModelConfig? {
        if let medium = configs.first(where: { $0.label.localizedCaseInsensitiveContains("Flash (Medium)") }) {
            return medium
        }
        if let flash = configs.first(where: { $0.label.localizedCaseInsensitiveContains("Flash") }) {
            return flash
        }
        return configs.first
    }
    
    private func groupConfigs(_ configs: [ClientModelConfig]) -> [GroupedQuota] {
        var geminiConfigs: [ClientModelConfig] = []
        var claudeGptConfigs: [ClientModelConfig] = []
        var otherConfigs: [ClientModelConfig] = []
        
        for config in configs {
            let label = config.label
            if label.localizedCaseInsensitiveContains("Gemini") {
                geminiConfigs.append(config)
            } else if label.localizedCaseInsensitiveContains("Claude") || label.localizedCaseInsensitiveContains("GPT") {
                claudeGptConfigs.append(config)
            } else {
                otherConfigs.append(config)
            }
        }
        
        var groups: [GroupedQuota] = []
        
        // Group 1: Gemini
        if !geminiConfigs.isEmpty {
            let rep = geminiConfigs.first(where: { $0.label.localizedCaseInsensitiveContains("Medium") }) ?? geminiConfigs[0]
            groups.append(GroupedQuota(
                name: "Gemini",
                fraction: rep.quotaInfo?.remainingFraction ?? 0.0,
                resetTime: rep.quotaInfo?.resetTime
            ))
        }
        
        // Group 2: Claude
        if !claudeGptConfigs.isEmpty {
            let rep = claudeGptConfigs[0]
            groups.append(GroupedQuota(
                name: "Claude",
                fraction: rep.quotaInfo?.remainingFraction ?? 0.0,
                resetTime: rep.quotaInfo?.resetTime
            ))
        }
        
        // Group 3: Others
        for other in otherConfigs {
            groups.append(GroupedQuota(
                name: other.label,
                fraction: other.quotaInfo?.remainingFraction ?? 0.0,
                resetTime: other.quotaInfo?.resetTime
            ))
        }
        
        return groups
    }
    
    private func formatResetTime(_ dateString: String?) -> String {
        guard let dateString = dateString else { return "No reset time" }
        let formatter = ISO8601DateFormatter()
        guard let date = formatter.date(from: dateString) else { return "Reset time unknown" }
        
        let now = Date()
        let timeInterval = date.timeIntervalSince(now)
        
        if timeInterval <= 0 {
            return "Quota reset"
        }
        
        let hours = Int(timeInterval) / 3600
        let minutes = (Int(timeInterval) % 3600) / 60
        
        if hours > 0 {
            return "Resets in \(hours)h \(minutes)m"
        } else {
            return "Resets in \(minutes)m"
        }
    }
}

// MARK: - Entry Point

let delegate = AppDelegate()
NSApplication.shared.delegate = delegate
NSApplication.shared.run()
