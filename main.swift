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
        case .fiveHours: return "5 Hours"
        case .today: return "Today"
        case .sevenDays: return "7 Days"
        case .thirtyDays: return "30 Days"
        case .allTime: return "All"
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
    
    private var memoryCacheRecords: [TokenRecord] = []
    private var modelMapCache: [String: [Int: String]] = [:]
    private var lastScanTime: Date? = nil
    
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
    
    var currentRecords: [TokenRecord] {
        return memoryCacheRecords
    }
    
    func parseDate(_ str: String?) -> Date? {
        guard let s = str, !s.isEmpty else { return nil }
        return isoDateFormatter.date(from: s) ?? isoDateFractionFormatter.date(from: s)
    }
    
    func scanAllRecords(forceRefresh: Bool = false) -> [TokenRecord] {
        if !forceRefresh, !memoryCacheRecords.isEmpty, let last = lastScanTime, Date().timeIntervalSince(last) < 20.0 {
            return memoryCacheRecords
        }
        
        var records: [TokenRecord] = []
        let fileManager = FileManager.default
        guard let dbFiles = try? fileManager.contentsOfDirectory(at: convDir, includingPropertiesForKeys: nil) else {
            return []
        }
        
        for dbURL in dbFiles where dbURL.pathExtension == "db" {
            let convId = dbURL.deletingPathExtension().lastPathComponent
            let transcriptURL = brainDir.appendingPathComponent(convId).appendingPathComponent(".system_generated/logs/transcript.jsonl")
            guard fileManager.fileExists(atPath: transcriptURL.path) else { continue }
            
            let modelMap = getModelMap(for: convId, dbURL: dbURL)
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
        
        self.memoryCacheRecords = records
        self.lastScanTime = Date()
        return records
    }
    
    private static let knownPatterns: [(Data, String)] = [
        ("Claude Sonnet 4.6 (Thinking)".data(using: .utf8)!, "Claude Sonnet 4.6 (Thinking)"),
        ("Claude Sonnet 4.6".data(using: .utf8)!, "Claude Sonnet 4.6"),
        ("Claude Opus 4.6 (Thinking)".data(using: .utf8)!, "Claude Opus 4.6 (Thinking)"),
        ("Claude Opus 4.6".data(using: .utf8)!, "Claude Opus 4.6"),
        ("Gemini 3.8 Flash (High)".data(using: .utf8)!, "Gemini 3.8 Flash (High)"),
        ("Gemini 3.8 Flash (Medium)".data(using: .utf8)!, "Gemini 3.8 Flash (Medium)"),
        ("Gemini 3.8 Flash (Low)".data(using: .utf8)!, "Gemini 3.8 Flash (Low)"),
        ("Gemini 3.5 Flash (High)".data(using: .utf8)!, "Gemini 3.5 Flash (High)"),
        ("Gemini 3.5 Flash".data(using: .utf8)!, "Gemini 3.5 Flash"),
        ("GPT-OSS 120B (Medium)".data(using: .utf8)!, "GPT-OSS 120B (Medium)"),
        ("GPT-OSS 120B".data(using: .utf8)!, "GPT-OSS 120B"),
        ("Gemini 4 Argon".data(using: .utf8)!, "Gemini 4 Argon")
    ]
    
    private func getModelMap(for convId: String, dbURL: URL) -> [Int: String] {
        if let cached = modelMapCache[convId] {
            return cached
        }
        let map = loadModelMap(from: dbURL)
        modelMapCache[convId] = map
        return map
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
                        let d = Data(bytesNoCopy: UnsafeMutableRawPointer(mutating: blobPtr), count: bytes, deallocator: .none)
                        map[idx] = extractModelName(from: d)
                    }
                }
                sqlite3_finalize(stmt)
            }
            sqlite3_close(db)
        }
        return map
    }
    
    private func extractModelName(from data: Data) -> String {
        for (patternData, name) in TokenStatsManager.knownPatterns {
            if data.range(of: patternData) != nil {
                return name
            }
        }
        return "Gemini 3.8 Flash (Medium)"
    }
}

// MARK: - Modern UI Components

class CapsulePillBar: NSView {
    var onSelectionChanged: ((Int) -> Void)?
    private var buttons: [NSButton] = []
    private let indicatorView = NSBox()
    private let stack = NSStackView()
    private(set) var selectedIndex: Int = 0
    
    init(items: [String]) {
        super.init(frame: .zero)
        setup(items: items)
    }
    required init?(coder: NSCoder) { fatalError() }
    
    private func setup(items: [String]) {
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.backgroundColor = NSColor.quaternaryLabelColor.withAlphaComponent(0.12).cgColor
        
        // Single sliding elevated card indicator
        indicatorView.boxType = .custom
        indicatorView.cornerRadius = 7
        indicatorView.borderWidth = 0
        indicatorView.translatesAutoresizingMaskIntoConstraints = true
        addSubview(indicatorView)
        
        stack.orientation = .horizontal
        stack.distribution = .fillEqually
        stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 3),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 3),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -3),
            heightAnchor.constraint(equalToConstant: 34)
        ])
        
        for (i, item) in items.enumerated() {
            let btn = NSButton(title: item, target: self, action: #selector(btnClicked(_:)))
            btn.tag = i
            btn.isBordered = false
            btn.alignment = .center
            btn.font = NSFont.systemFont(ofSize: 13, weight: .medium)
            buttons.append(btn)
            stack.addArrangedSubview(btn)
            btn.widthAnchor.constraint(greaterThanOrEqualToConstant: 68).isActive = true
        }
        updateIndicator()
    }
    
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateIndicator()
    }
    
    @objc private func btnClicked(_ sender: NSButton) {
        setSelectedIndex(sender.tag)
        onSelectionChanged?(sender.tag)
    }
    
    func setSelectedIndex(_ index: Int) {
        guard index >= 0 && index < buttons.count else { return }
        selectedIndex = index
        updateIndicator()
    }
    
    override func layout() {
        super.layout()
        updateIndicatorFrame()
    }
    
    private func updateIndicatorFrame() {
        guard selectedIndex >= 0 && selectedIndex < buttons.count else { return }
        let targetBtn = buttons[selectedIndex]
        indicatorView.frame = targetBtn.frame.offsetBy(dx: 3, dy: 3)
    }
    
    private func updateIndicator() {
        let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        indicatorView.fillColor = isDark ? NSColor(white: 0.28, alpha: 1.0) : NSColor.white
        indicatorView.shadow = {
            let s = NSShadow()
            s.shadowColor = NSColor.black.withAlphaComponent(isDark ? 0.35 : 0.08)
            s.shadowOffset = NSSize(width: 0, height: -1)
            s.shadowBlurRadius = 2.0
            return s
        }()
        
        for (i, btn) in buttons.enumerated() {
            let isSel = (i == selectedIndex)
            btn.contentTintColor = isSel ? .labelColor : .secondaryLabelColor
            btn.font = NSFont.systemFont(ofSize: 13, weight: isSel ? .semibold : .medium)
        }
        updateIndicatorFrame()
    }
}

class FlatActionPillButton: NSControl {
    private let titleLabel = NSTextField(labelWithString: "")
    private let iconView = NSImageView()
    private let contentStack = NSStackView()
    private var isHovered = false
    private var isPressed = false
    
    var title: String = "" {
        didSet { titleLabel.stringValue = title }
    }
    
    override var isEnabled: Bool {
        didSet {
            alphaValue = isEnabled ? 1.0 : 0.5
            updateAppearance()
        }
    }
    
    init(title: String, symbol: String? = nil, target: AnyObject?, action: Selector?) {
        super.init(frame: .zero)
        self.target = target
        self.action = action
        self.title = title
        setup(title: title, symbol: symbol)
    }
    required init?(coder: NSCoder) { fatalError() }
    
    private func setup(title: String, symbol: String?) {
        wantsLayer = true
        layer?.cornerRadius = 8
        
        contentStack.orientation = .horizontal
        contentStack.alignment = .centerY
        contentStack.spacing = 6
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(contentStack)
        
        if let sym = symbol {
            let config = NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
            iconView.image = NSImage(systemSymbolName: sym, accessibilityDescription: title)?.withSymbolConfiguration(config)
            iconView.contentTintColor = .secondaryLabelColor
            contentStack.addArrangedSubview(iconView)
        }
        
        titleLabel.stringValue = title
        titleLabel.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        titleLabel.textColor = .labelColor
        contentStack.addArrangedSubview(titleLabel)
        
        NSLayoutConstraint.activate([
            contentStack.centerXAnchor.constraint(equalTo: centerXAnchor),
            contentStack.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: 30)
        ])
        
        updateAppearance()
    }
    
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateAppearance()
    }
    
    private func updateAppearance() {
        let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        if isPressed {
            layer?.backgroundColor = isDark ? NSColor(white: 0.32, alpha: 1.0).cgColor : NSColor(white: 0.82, alpha: 1.0).cgColor
        } else if isHovered {
            layer?.backgroundColor = isDark ? NSColor(white: 0.26, alpha: 1.0).cgColor : NSColor(white: 0.88, alpha: 1.0).cgColor
        } else {
            layer?.backgroundColor = isDark ? NSColor(white: 0.22, alpha: 1.0).cgColor : NSColor(white: 0.92, alpha: 1.0).cgColor
        }
    }
    
    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        isPressed = true
        updateAppearance()
    }
    
    override func mouseUp(with event: NSEvent) {
        guard isEnabled else { return }
        isPressed = false
        updateAppearance()
        let pt = convert(event.locationInWindow, from: nil)
        if bounds.contains(pt) {
            sendAction(action, to: target)
        }
    }
}

class FlatTableHeaderView: NSTableHeaderView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.clear.set()
        bounds.fill()
        
        super.draw(dirtyRect)
        
        let hairline = NSRect(x: 0, y: bounds.height - 0.5, width: bounds.width, height: 0.5)
        NSColor.separatorColor.withAlphaComponent(0.18).set()
        hairline.fill()
    }
}

class FlatTableHeaderCell: NSTableHeaderCell {
    override func draw(withFrame cellFrame: NSRect, in controlView: NSView) {
        drawInterior(withFrame: cellFrame, in: controlView)
    }
    
    override func drawInterior(withFrame cellFrame: NSRect, in controlView: NSView) {
        let text = stringValue
        let pStyle = NSMutableParagraphStyle()
        pStyle.alignment = self.alignment
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: pStyle
        ]
        let inset = NSRect(x: cellFrame.origin.x, y: cellFrame.origin.y + 6, width: cellFrame.width - 4, height: cellFrame.height - 6)
        text.draw(in: inset, withAttributes: attrs)
    }
}

class ModernTableRowView: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {
        if isSelected {
            let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 4, dy: 2), xRadius: 8, yRadius: 8)
            NSColor.quaternaryLabelColor.withAlphaComponent(0.12).set()
            path.fill()
        }
    }
    
    override func drawSeparator(in dirtyRect: NSRect) {
        let sepColor = NSColor.separatorColor.withAlphaComponent(0.10)
        sepColor.set()
        let sepRect = NSRect(x: 14, y: 0, width: bounds.width - 28, height: 0.5)
        sepRect.fill()
    }
}

class MetricCardView: NSView {
    private let dotView = NSBox()
    private let titleLabel = NSTextField(labelWithString: "")
    private let valueLabel = NSTextField(labelWithString: "--")
    private let subLabel = NSTextField(labelWithString: "--")
    private let container = NSBox()
    
    init(title: String, tint: NSColor) {
        super.init(frame: .zero)
        setup(title: title, tint: tint)
    }
    required init?(coder: NSCoder) { fatalError() }
    
    private func setup(title: String, tint: NSColor) {
        container.boxType = .custom
        container.cornerRadius = 10
        container.fillColor = NSColor.controlBackgroundColor.withAlphaComponent(0.65)
        container.borderColor = NSColor.separatorColor.withAlphaComponent(0.14)
        container.borderWidth = 0.5
        container.translatesAutoresizingMaskIntoConstraints = false
        addSubview(container)
        
        dotView.boxType = .custom
        dotView.cornerRadius = 4.0
        dotView.fillColor = tint
        dotView.borderWidth = 0
        dotView.translatesAutoresizingMaskIntoConstraints = false
        container.contentView?.addSubview(dotView)
        
        titleLabel.stringValue = title
        titleLabel.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        titleLabel.textColor = .secondaryLabelColor
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        container.contentView?.addSubview(titleLabel)
        
        valueLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 22, weight: .bold)
        valueLabel.textColor = .labelColor
        valueLabel.translatesAutoresizingMaskIntoConstraints = false
        container.contentView?.addSubview(valueLabel)
        
        subLabel.font = NSFont.systemFont(ofSize: 11, weight: .regular)
        subLabel.textColor = .tertiaryLabelColor
        subLabel.translatesAutoresizingMaskIntoConstraints = false
        container.contentView?.addSubview(subLabel)
        
        NSLayoutConstraint.activate([
            container.topAnchor.constraint(equalTo: topAnchor),
            container.leadingAnchor.constraint(equalTo: leadingAnchor),
            container.trailingAnchor.constraint(equalTo: trailingAnchor),
            container.bottomAnchor.constraint(equalTo: bottomAnchor),
            
            dotView.leadingAnchor.constraint(equalTo: container.contentView!.leadingAnchor, constant: 14),
            dotView.topAnchor.constraint(equalTo: container.contentView!.topAnchor, constant: 12),
            dotView.widthAnchor.constraint(equalToConstant: 8),
            dotView.heightAnchor.constraint(equalToConstant: 8),
            
            titleLabel.leadingAnchor.constraint(equalTo: dotView.trailingAnchor, constant: 7),
            titleLabel.centerYAnchor.constraint(equalTo: dotView.centerYAnchor),
            
            valueLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 4),
            valueLabel.leadingAnchor.constraint(equalTo: container.contentView!.leadingAnchor, constant: 14),
            valueLabel.trailingAnchor.constraint(lessThanOrEqualTo: container.contentView!.trailingAnchor, constant: -8),
            
            subLabel.topAnchor.constraint(equalTo: valueLabel.bottomAnchor, constant: 2),
            subLabel.leadingAnchor.constraint(equalTo: container.contentView!.leadingAnchor, constant: 14),
            subLabel.trailingAnchor.constraint(lessThanOrEqualTo: container.contentView!.trailingAnchor, constant: -8)
        ])
    }
    
    func update(value: String, sub: String, valueColor: NSColor = .labelColor) {
        valueLabel.stringValue = value
        valueLabel.textColor = valueColor
        subLabel.stringValue = sub
    }
}

class ModelCellView: NSTableCellView {
    let iconBadge = NSBox()
    let iconView = NSImageView()
    let titleLabel = NSTextField(labelWithString: "")
    
    override init(frame: NSRect) {
        super.init(frame: frame)
        setup()
    }
    required init?(coder: NSCoder) { super.init(coder: coder); setup() }
    
    private func setup() {
        iconBadge.boxType = .custom
        iconBadge.cornerRadius = 6
        iconBadge.borderWidth = 0
        iconBadge.translatesAutoresizingMaskIntoConstraints = false
        addSubview(iconBadge)
        
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconBadge.contentView?.addSubview(iconView)
        
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        titleLabel.textColor = .labelColor
        titleLabel.lineBreakMode = .byTruncatingTail
        addSubview(titleLabel)
        
        if let bcv = iconBadge.contentView {
            NSLayoutConstraint.activate([
                iconView.centerXAnchor.constraint(equalTo: bcv.centerXAnchor),
                iconView.centerYAnchor.constraint(equalTo: bcv.centerYAnchor)
            ])
        }
        
        NSLayoutConstraint.activate([
            iconBadge.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            iconBadge.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconBadge.widthAnchor.constraint(equalToConstant: 24),
            iconBadge.heightAnchor.constraint(equalToConstant: 24),
            
            titleLabel.leadingAnchor.constraint(equalTo: iconBadge.trailingAnchor, constant: 10),
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }
    
    func configure(modelName: String) {
        titleLabel.stringValue = modelName
        let lower = modelName.lowercased()
        let symName: String
        let tint: NSColor
        if lower.contains("gemini") {
            symName = "sparkles"
            tint = .systemBlue
        } else if lower.contains("claude") {
            symName = "brain.head.profile"
            tint = .systemOrange
        } else if lower.contains("gpt") {
            symName = "bolt.fill"
            tint = .systemGreen
        } else {
            symName = "cpu"
            tint = .secondaryLabelColor
        }
        iconBadge.fillColor = tint.withAlphaComponent(0.12)
        let config = NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
        iconView.image = NSImage(systemSymbolName: symName, accessibilityDescription: modelName)?.withSymbolConfiguration(config)
        iconView.contentTintColor = tint
    }
}

class CacheCellView: NSTableCellView {
    let valueLabel = NSTextField(labelWithString: "")
    let pillBadge = NSBox()
    let pillLabel = NSTextField(labelWithString: "")
    
    override init(frame: NSRect) {
        super.init(frame: frame)
        setup()
    }
    required init?(coder: NSCoder) { super.init(coder: coder); setup() }
    
    private func setup() {
        valueLabel.translatesAutoresizingMaskIntoConstraints = false
        valueLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        valueLabel.alignment = .right
        valueLabel.textColor = .labelColor
        addSubview(valueLabel)
        
        pillBadge.boxType = .custom
        pillBadge.cornerRadius = 4
        pillBadge.borderWidth = 0
        pillBadge.fillColor = NSColor.systemGreen.withAlphaComponent(0.14)
        pillBadge.translatesAutoresizingMaskIntoConstraints = false
        addSubview(pillBadge)
        
        pillLabel.translatesAutoresizingMaskIntoConstraints = false
        pillLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .bold)
        pillLabel.textColor = .systemGreen
        pillLabel.alignment = .center
        pillBadge.contentView?.addSubview(pillLabel)
        
        if let bcv = pillBadge.contentView {
            NSLayoutConstraint.activate([
                pillLabel.leadingAnchor.constraint(equalTo: bcv.leadingAnchor, constant: 4),
                pillLabel.trailingAnchor.constraint(equalTo: bcv.trailingAnchor, constant: -4),
                pillLabel.centerYAnchor.constraint(equalTo: bcv.centerYAnchor)
            ])
        }
        
        NSLayoutConstraint.activate([
            pillBadge.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            pillBadge.centerYAnchor.constraint(equalTo: centerYAnchor),
            pillBadge.heightAnchor.constraint(equalToConstant: 18),
            
            valueLabel.trailingAnchor.constraint(equalTo: pillBadge.leadingAnchor, constant: -6),
            valueLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            valueLabel.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 2)
        ])
    }
    
    func configure(tokens: Int64, ratio: Double, formatter: NumberFormatter) {
        valueLabel.stringValue = formatter.string(from: NSNumber(value: tokens)) ?? "0"
        pillLabel.stringValue = String(format: "%.1f%%", ratio)
        pillBadge.isHidden = (tokens == 0)
    }
}

class MetricTextCellView: NSTableCellView {
    let label = NSTextField(labelWithString: "")
    
    override init(frame: NSRect) {
        super.init(frame: frame)
        setup()
    }
    required init?(coder: NSCoder) { super.init(coder: coder); setup() }
    
    private func setup() {
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        label.alignment = .right
        label.textColor = .labelColor
        label.lineBreakMode = .byTruncatingTail
        addSubview(label)
        
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            label.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }
    
    func configure(text: String, isBold: Bool = false, color: NSColor = .labelColor) {
        label.stringValue = text
        label.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: isBold ? .bold : .regular)
        label.textColor = color
    }
}

class ShareCellView: NSTableCellView {
    let progressBar = ProgressBarView()
    let percentLabel = NSTextField(labelWithString: "")
    
    override init(frame: NSRect) {
        super.init(frame: frame)
        setup()
    }
    required init?(coder: NSCoder) { super.init(coder: coder); setup() }
    
    private func setup() {
        progressBar.translatesAutoresizingMaskIntoConstraints = false
        progressBar.color = .systemBlue
        addSubview(progressBar)
        
        percentLabel.translatesAutoresizingMaskIntoConstraints = false
        percentLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        percentLabel.textColor = .secondaryLabelColor
        percentLabel.alignment = .right
        addSubview(percentLabel)
        
        NSLayoutConstraint.activate([
            percentLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            percentLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            percentLabel.widthAnchor.constraint(equalToConstant: 42),
            
            progressBar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            progressBar.trailingAnchor.constraint(equalTo: percentLabel.leadingAnchor, constant: -6),
            progressBar.centerYAnchor.constraint(equalTo: centerYAnchor),
            progressBar.heightAnchor.constraint(equalToConstant: 4)
        ])
    }
    
    func configure(share: Double) {
        progressBar.progress = share / 100.0
        percentLabel.stringValue = String(format: "%.1f%%", share)
    }
}

// MARK: - Token Analytics Custom Window & Controller

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

class TokenStatsWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    private var allRecords: [TokenRecord] = []
    private var currentWindow: TimeWindow = .fiveHours
    private var displayedStats: [ModelAggregatedStats] = []
    
    private var pillBar: CapsulePillBar!
    private var tableView: NSTableView!
    private var emptyStateView: NSView!
    
    // Metric Cards
    private var totalTokensCard: MetricCardView!
    private var cacheRatioCard: MetricCardView!
    private var outputCard: MetricCardView!
    private var totalCallsCard: MetricCardView!
    
    private var statusLabel: NSTextField!
    private var refreshButton: FlatActionPillButton!
    private var closeButton: FlatActionPillButton!
    
    convenience init() {
        let window = AnalyticsWindow(
            contentRect: NSRect(x: 0, y: 0, width: 880, height: 580),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = ""
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.center()
        window.minSize = NSSize(width: 800, height: 500)
        self.init(window: window)
        setupUI()
    }
    
    private func setupUI() {
        guard let window = self.window else { return }
        
        let visualEffect = NSVisualEffectView(frame: window.contentView!.bounds)
        visualEffect.autoresizingMask = [.width, .height]
        visualEffect.blendingMode = .behindWindow
        visualEffect.material = .underWindowBackground
        visualEffect.state = .active
        window.contentView = visualEffect
        let contentView = visualEffect
        
        // 1. Top Header Area (Integrated Toolbar Title & Elevated Capsule Pill Selector)
        let headerView = NSView()
        headerView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(headerView)
        
        let headerTitle = NSTextField(labelWithString: "Token Analytics")
        headerTitle.translatesAutoresizingMaskIntoConstraints = false
        headerTitle.font = NSFont.systemFont(ofSize: 18, weight: .bold)
        headerTitle.textColor = .labelColor
        headerView.addSubview(headerTitle)
        
        let headerSubtitle = NSTextField(labelWithString: "Antigravity Assistant Token Usage & Prompt Cache Analytics")
        headerSubtitle.translatesAutoresizingMaskIntoConstraints = false
        headerSubtitle.font = NSFont.systemFont(ofSize: 12, weight: .regular)
        headerSubtitle.textColor = .secondaryLabelColor
        headerView.addSubview(headerSubtitle)
        
        let labels = TimeWindow.allCases.map { $0.title }
        pillBar = CapsulePillBar(items: labels)
        pillBar.translatesAutoresizingMaskIntoConstraints = false
        pillBar.onSelectionChanged = { [weak self] index in
            if let window = TimeWindow(rawValue: index) {
                self?.currentWindow = window
                self?.filterAndDisplay()
            }
        }
        headerView.addSubview(pillBar)
        
        // 2. Metrics Cards Row
        let cardStack = NSStackView()
        cardStack.orientation = .horizontal
        cardStack.distribution = .fillEqually
        cardStack.spacing = 10
        cardStack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(cardStack)
        
        totalTokensCard = MetricCardView(title: "Total Tokens", tint: .systemBlue)
        cacheRatioCard = MetricCardView(title: "Cache Hit Rate", tint: .systemGreen)
        outputCard = MetricCardView(title: "Output Tokens", tint: .systemPurple)
        totalCallsCard = MetricCardView(title: "Total Requests", tint: .systemOrange)
        
        cardStack.addArrangedSubview(totalTokensCard)
        cardStack.addArrangedSubview(cacheRatioCard)
        cardStack.addArrangedSubview(outputCard)
        cardStack.addArrangedSubview(totalCallsCard)
        
        // 3. Table Container Card
        let tableContainer = NSBox()
        tableContainer.boxType = .custom
        tableContainer.cornerRadius = 10
        tableContainer.fillColor = NSColor.controlBackgroundColor.withAlphaComponent(0.65)
        tableContainer.borderColor = NSColor.separatorColor.withAlphaComponent(0.14)
        tableContainer.borderWidth = 0.5
        tableContainer.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(tableContainer)
        
        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        tableContainer.contentView?.addSubview(scrollView)
        
        tableView = NSTableView()
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.backgroundColor = .clear
        tableView.gridStyleMask = [] // Clean modern minimalist list style
        tableView.rowHeight = 44
        tableView.intercellSpacing = NSSize(width: 8, height: 4)
        tableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        tableView.dataSource = self
        tableView.delegate = self
        
        let modernHeader = FlatTableHeaderView()
        tableView.headerView = modernHeader
        
        let columns: [(String, String, CGFloat, CGFloat, NSTextAlignment)] = [
            ("model", "Model", 215, 160, .left),
            ("calls", "Requests", 60, 45, .right),
            ("input", "Input", 65, 50, .right),
            ("cache", "Prompt Cache", 125, 95, .right),
            ("output", "Output", 65, 50, .right),
            ("total", "Total Tokens", 85, 65, .right),
            ("share", "Share", 80, 60, .right)
        ]
        
        for (colId, title, width, minW, align) in columns {
            let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(colId))
            col.title = title
            col.width = width
            col.minWidth = minW
            col.resizingMask = [.userResizingMask, .autoresizingMask]
            let cell = FlatTableHeaderCell(textCell: title)
            cell.alignment = align
            col.headerCell = cell
            tableView.addTableColumn(col)
        }
        
        scrollView.documentView = tableView
        
        // Empty State View
        emptyStateView = makeEmptyStateView()
        emptyStateView.translatesAutoresizingMaskIntoConstraints = false
        emptyStateView.isHidden = true
        tableContainer.contentView?.addSubview(emptyStateView)
        
        // 4. Bottom Controls Bar
        let bottomView = NSView()
        bottomView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(bottomView)
        
        let bottomSeparator = NSBox()
        bottomSeparator.boxType = .separator
        bottomSeparator.translatesAutoresizingMaskIntoConstraints = false
        bottomView.addSubview(bottomSeparator)
        
        statusLabel = NSTextField(labelWithString: "Ready")
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.font = NSFont.systemFont(ofSize: 12)
        statusLabel.textColor = .secondaryLabelColor
        bottomView.addSubview(statusLabel)
        
        refreshButton = FlatActionPillButton(title: "Refresh", symbol: "arrow.clockwise", target: self, action: #selector(refreshClicked(_:)))
        refreshButton.translatesAutoresizingMaskIntoConstraints = false
        bottomView.addSubview(refreshButton)
        
        closeButton = FlatActionPillButton(title: "Close", symbol: nil, target: self, action: #selector(closeClicked(_:)))
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        bottomView.addSubview(closeButton)
        
        // AutoLayout Constraints
        NSLayoutConstraint.activate([
            // Header (avoiding traffic lights at top-left)
            headerView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 28),
            headerView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 80),
            headerView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -24),
            headerView.heightAnchor.constraint(equalToConstant: 44),
            
            headerTitle.topAnchor.constraint(equalTo: headerView.topAnchor, constant: 1),
            headerTitle.leadingAnchor.constraint(equalTo: headerView.leadingAnchor),
            
            headerSubtitle.topAnchor.constraint(equalTo: headerTitle.bottomAnchor, constant: 3),
            headerSubtitle.leadingAnchor.constraint(equalTo: headerView.leadingAnchor),
            
            pillBar.centerYAnchor.constraint(equalTo: headerView.centerYAnchor),
            pillBar.trailingAnchor.constraint(equalTo: headerView.trailingAnchor),
            
            // Cards Row
            cardStack.topAnchor.constraint(equalTo: headerView.bottomAnchor, constant: 14),
            cardStack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 24),
            cardStack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -24),
            cardStack.heightAnchor.constraint(equalToConstant: 78),
            
            // Table Container Card
            tableContainer.topAnchor.constraint(equalTo: cardStack.bottomAnchor, constant: 14),
            tableContainer.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 24),
            tableContainer.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -24),
            tableContainer.bottomAnchor.constraint(equalTo: bottomView.topAnchor, constant: -8),
            
            // ScrollView inside Table Container
            scrollView.topAnchor.constraint(equalTo: tableContainer.contentView!.topAnchor, constant: 8),
            scrollView.leadingAnchor.constraint(equalTo: tableContainer.contentView!.leadingAnchor, constant: 10),
            scrollView.trailingAnchor.constraint(equalTo: tableContainer.contentView!.trailingAnchor, constant: -10),
            scrollView.bottomAnchor.constraint(equalTo: tableContainer.contentView!.bottomAnchor, constant: -8),
            
            // Empty State View (centered over table container)
            emptyStateView.centerXAnchor.constraint(equalTo: tableContainer.centerXAnchor),
            emptyStateView.centerYAnchor.constraint(equalTo: tableContainer.centerYAnchor),
            emptyStateView.widthAnchor.constraint(equalToConstant: 320),
            emptyStateView.heightAnchor.constraint(equalToConstant: 120),
            
            // Bottom Bar
            bottomView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            bottomView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            bottomView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            bottomView.heightAnchor.constraint(equalToConstant: 46),
            
            bottomSeparator.topAnchor.constraint(equalTo: bottomView.topAnchor),
            bottomSeparator.leadingAnchor.constraint(equalTo: bottomView.leadingAnchor),
            bottomSeparator.trailingAnchor.constraint(equalTo: bottomView.trailingAnchor),
            
            statusLabel.leadingAnchor.constraint(equalTo: bottomView.leadingAnchor, constant: 24),
            statusLabel.centerYAnchor.constraint(equalTo: bottomView.centerYAnchor),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: refreshButton.leadingAnchor, constant: -12),
            
            refreshButton.trailingAnchor.constraint(equalTo: closeButton.leadingAnchor, constant: -10),
            refreshButton.centerYAnchor.constraint(equalTo: bottomView.centerYAnchor),
            refreshButton.heightAnchor.constraint(equalToConstant: 28),
            refreshButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 90),
            
            closeButton.trailingAnchor.constraint(equalTo: bottomView.trailingAnchor, constant: -24),
            closeButton.centerYAnchor.constraint(equalTo: bottomView.centerYAnchor),
            closeButton.heightAnchor.constraint(equalToConstant: 28),
            closeButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 64)
        ])
    }
    
    private func makeEmptyStateView() -> NSView {
        let view = NSView()
        let icon = NSImageView()
        icon.translatesAutoresizingMaskIntoConstraints = false
        let config = NSImage.SymbolConfiguration(pointSize: 32, weight: .light)
        icon.image = NSImage(systemSymbolName: "tray", accessibilityDescription: "Empty")?.withSymbolConfiguration(config)
        icon.contentTintColor = .tertiaryLabelColor
        view.addSubview(icon)
        
        let label = NSTextField(labelWithString: "No Token Activity Recorded")
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = NSFont.systemFont(ofSize: 14, weight: .medium)
        label.textColor = .secondaryLabelColor
        label.alignment = .center
        view.addSubview(label)
        
        let sub = NSTextField(labelWithString: "Switch to 'Today' or 'All' in the top right to view historical records")
        sub.translatesAutoresizingMaskIntoConstraints = false
        sub.font = NSFont.systemFont(ofSize: 12, weight: .regular)
        sub.textColor = .tertiaryLabelColor
        sub.alignment = .center
        view.addSubview(sub)
        
        NSLayoutConstraint.activate([
            icon.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            icon.topAnchor.constraint(equalTo: view.topAnchor),
            
            label.topAnchor.constraint(equalTo: icon.bottomAnchor, constant: 8),
            label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            
            sub.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 4),
            sub.centerXAnchor.constraint(equalTo: view.centerXAnchor)
        ])
        return view
    }
    
    func selectTimeWindow(_ index: Int) {
        guard index >= 0 && index < TimeWindow.allCases.count else { return }
        pillBar.setSelectedIndex(index)
        if let window = TimeWindow(rawValue: index) {
            self.currentWindow = window
            self.filterAndDisplay()
        }
    }
    
    @objc func refreshClicked(_ sender: Any?) {
        loadData(forceRefresh: true)
    }
    
    @objc func closeClicked(_ sender: Any?) {
        self.window?.close()
    }
    
    func loadData(forceRefresh: Bool = false) {
        // Fast path: if memory cache exists and not forced, display immediately
        if !forceRefresh && !TokenStatsManager.shared.currentRecords.isEmpty {
            self.allRecords = TokenStatsManager.shared.currentRecords
            self.filterAndDisplay()
        }
        
        refreshButton.isEnabled = false
        statusLabel.stringValue = "Syncing local session transcripts..."
        
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let scanned = TokenStatsManager.shared.scanAllRecords(forceRefresh: forceRefresh)
            
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
        
        let isEmpty = self.displayedStats.isEmpty
        self.emptyStateView.isHidden = !isEmpty
        self.tableView.isHidden = isEmpty
        self.tableView.reloadData()
        
        // Update Metric Cards
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        
        // 1. Total Tokens
        let totStr = formatter.string(from: NSNumber(value: totalAll)) ?? "\(totalAll)"
        totalTokensCard.update(value: totStr, sub: formatCompactNumber(totalAll) + " tokens processed")
        
        // 2. Cache Hit Ratio
        let promptTokens = totalIn + totalCache
        if promptTokens > 0 {
            let ratio = Double(totalCache) / Double(promptTokens) * 100.0
            cacheRatioCard.update(
                value: String(format: "%.1f%%", ratio),
                sub: "Saved " + formatCompactNumber(totalCache) + " cached tokens",
                valueColor: .systemGreen
            )
        } else {
            cacheRatioCard.update(value: "0.0%", sub: "No prompt cache", valueColor: .labelColor)
        }
        
        // 3. Output Tokens
        let outStr = formatter.string(from: NSNumber(value: totalOut)) ?? "\(totalOut)"
        let outShare = totalAll > 0 ? (Double(totalOut) / Double(totalAll) * 100.0) : 0.0
        outputCard.update(value: outStr, sub: String(format: "%.1f%% of total volume", outShare))
        
        // 4. Total Calls
        if totalCalls > 0 {
            let avgPerCall = totalAll / Int64(totalCalls)
            totalCallsCard.update(value: "\(totalCalls)", sub: "Avg " + formatCompactNumber(avgPerCall) + " / request")
        } else {
            totalCallsCard.update(value: "0", sub: "No calls in this window")
        }
        
        // Status bar
        let df = DateFormatter()
        df.timeStyle = .medium
        statusLabel.stringValue = "● Scanned \(allRecords.count) sessions (\(filtered.count) in window) · Updated \(df.string(from: Date()))"
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
        
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
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
            cell.configure(text: "\(item.callCount)")
            return cell
            
        case "input":
            let cell = (tableView.makeView(withIdentifier: NSUserInterfaceItemIdentifier("InputCell"), owner: self) as? MetricTextCellView) ?? MetricTextCellView()
            cell.identifier = NSUserInterfaceItemIdentifier("InputCell")
            cell.configure(text: formatter.string(from: NSNumber(value: item.inputTokens)) ?? "0")
            return cell
            
        case "cache":
            let cell = (tableView.makeView(withIdentifier: NSUserInterfaceItemIdentifier("CacheCell"), owner: self) as? CacheCellView) ?? CacheCellView()
            cell.identifier = NSUserInterfaceItemIdentifier("CacheCell")
            cell.configure(tokens: item.cacheReadTokens, ratio: item.cacheRatio, formatter: formatter)
            return cell
            
        case "output":
            let cell = (tableView.makeView(withIdentifier: NSUserInterfaceItemIdentifier("OutputCell"), owner: self) as? MetricTextCellView) ?? MetricTextCellView()
            cell.identifier = NSUserInterfaceItemIdentifier("OutputCell")
            cell.configure(text: formatter.string(from: NSNumber(value: item.outputTokens)) ?? "0")
            return cell
            
        case "total":
            let cell = (tableView.makeView(withIdentifier: NSUserInterfaceItemIdentifier("TotalCell"), owner: self) as? MetricTextCellView) ?? MetricTextCellView()
            cell.identifier = NSUserInterfaceItemIdentifier("TotalCell")
            cell.configure(text: formatter.string(from: NSNumber(value: item.totalTokens)) ?? "0", isBold: true)
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
    
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        return ModernTableRowView()
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
        let trackColor = NSColor.quaternaryLabelColor.withAlphaComponent(0.2)
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
        
        // Background scan tokens in advance so dashboard opens instantaneously
        DispatchQueue.global(qos: .background).async {
            _ = TokenStatsManager.shared.scanAllRecords()
        }
        
        // Command-line flag to open dashboard immediately (useful for testing and previews)
        if CommandLine.arguments.contains("--dashboard") {
            openTokenStatsDashboard(nil)
        }
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
        tokenStatsWindowController?.loadData(forceRefresh: false)
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
