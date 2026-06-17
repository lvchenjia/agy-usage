import Cocoa
import Foundation
import AppKit

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
        
        let pct = Int(round(fraction * 100))
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

// MARK: - App Delegate

class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var menu: NSMenu!
    private var timer: Timer?
    private var isFetching = false
    
    private var lastConfigs: [ClientModelConfig]? = nil
    private var isOffline = true
    
    private var currentPercentageText: String = "--%"
    private var currentStatusColor: NSColor? = nil
    
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
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Hide dock icon programmatically
        NSApp.setActivationPolicy(.prohibited)
        
        // Register defaults
        UserDefaults.standard.register(defaults: [
            "showIcon": true,
            "showPercentage": true
        ])
        
        // Setup status item
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        
        // Setup initial menu
        menu = NSMenu()
        statusItem.menu = menu
        
        updateStatusBar(percentageText: "--%", color: nil)
        rebuildMenu()
        
        // Start polling
        startPolling()
        
        // Trigger first fetch
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
    
    func applicationWillTerminate(_ notification: Notification) {
        timer?.invalidate()
    }
    
    private func startPolling() {
        timer = Timer.scheduledTimer(withTimeInterval: 60.0, repeats: true) { [weak self] _ in
            self?.fetchStatus()
        }
    }
    
    @objc func refreshTriggered(_ sender: Any?) {
        fetchStatus()
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
            // Keep icon monochrome (native look) — use text color to convey status instead
            button.contentTintColor = nil
            button.imagePosition = showPercentage ? .imageLeft : .imageOnly
        } else {
            button.image = nil
            button.contentTintColor = nil
            button.imagePosition = .noImage
        }
        
        // Determine title — color the percentage text to convey quota status
        if showPercentage {
            let titleString = currentPercentageText
            let textColor = currentStatusColor ?? NSColor.labelColor
            let attrs: [NSAttributedString.Key: Any] = [
                .foregroundColor: textColor,
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
        
        menu.addItem(NSMenuItem.separator())
        
        let refreshItem = NSMenuItem(title: "Refresh", action: #selector(refreshTriggered(_:)), keyEquivalent: "r")
        refreshItem.target = self
        menu.addItem(refreshItem)
        
        let quitItem = NSMenuItem(title: "Quit", action: #selector(quitTriggered(_:)), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
    }
    
    private func fetchStatus() {
        guard !isFetching else { return }
        isFetching = true
        
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            
            guard let port = self.discoverPort() else {
                DispatchQueue.main.async {
                    self.isOffline = true
                    self.lastConfigs = nil
                    self.updateStatusBar(percentageText: "--%", color: nil)
                    self.rebuildMenu()
                    self.isFetching = false
                }
                return
            }
            
            let urlString = "http://127.0.0.1:\(port)/exa.language_server_pb.LanguageServerService/GetUserStatus"
            guard let url = URL(string: urlString) else {
                DispatchQueue.main.async {
                    self.isOffline = true
                    self.lastConfigs = nil
                    self.updateStatusBar(percentageText: "--%", color: nil)
                    self.rebuildMenu()
                    self.isFetching = false
                }
                return
            }
            
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = "{}".data(using: .utf8)
            
            let task = URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
                guard let self = self else { return }
                
                defer {
                    DispatchQueue.main.async {
                        self.isFetching = false
                    }
                }
                
                if let error = error {
                    print("Error fetching status: \(error)")
                    DispatchQueue.main.async {
                        self.isOffline = true
                        self.lastConfigs = nil
                        self.updateStatusBar(percentageText: "--%", color: nil)
                        self.rebuildMenu()
                    }
                    return
                }
                
                guard let data = data else {
                    DispatchQueue.main.async {
                        self.isOffline = true
                        self.lastConfigs = nil
                        self.updateStatusBar(percentageText: "--%", color: nil)
                        self.rebuildMenu()
                    }
                    return
                }
                
                do {
                    let decoder = JSONDecoder()
                    let responseObj = try decoder.decode(GetUserStatusResponse.self, from: data)
                    
                    guard let configs = responseObj.userStatus?.cascadeModelConfigData?.clientModelConfigs, !configs.isEmpty else {
                        DispatchQueue.main.async {
                            self.isOffline = true
                            self.lastConfigs = nil
                            self.updateStatusBar(percentageText: "--%", color: nil)
                            self.rebuildMenu()
                        }
                        return
                    }
                    
                    DispatchQueue.main.async {
                        self.isOffline = false
                        self.lastConfigs = configs
                        
                        if let repConfig = self.findStatusBarConfig(from: configs),
                           let fraction = repConfig.quotaInfo?.remainingFraction {
                            
                            let pct = Int(round(fraction * 100))
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
                        } else {
                            self.updateStatusBar(percentageText: "--%", color: nil)
                        }
                        
                        self.rebuildMenu()
                    }
                } catch {
                    print("Failed to decode JSON: \(error)")
                    DispatchQueue.main.async {
                        self.isOffline = true
                        self.lastConfigs = nil
                        self.updateStatusBar(percentageText: "--%", color: nil)
                        self.rebuildMenu()
                    }
                }
            }
            task.resume()
        }
    }
    
    // MARK: - Helpers
    
    private func discoverPort() -> Int? {
        let process = Process()
        process.launchPath = "/usr/sbin/lsof"
        process.arguments = ["-i", "-P", "-n"]
        
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            print("Failed to run lsof: \(error)")
            return nil
        }
        
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8) else { return nil }
        
        var candidates: [(pid: Int, port: Int)] = []
        
        let lines = output.components(separatedBy: .newlines)
        for line in lines {
            guard line.contains("LISTEN") else { continue }
            
            let parts = line.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
            guard parts.count >= 8 else { continue }
            
            let command = parts[0]
            guard command.hasPrefix("agy") else { continue }
            
            guard let pid = Int(parts[1]) else { continue }
            
            var port: Int? = nil
            for part in parts {
                if part.contains(":") {
                    let subparts = part.components(separatedBy: ":")
                    if let lastSubpart = subparts.last, let portNum = Int(lastSubpart) {
                        port = portNum
                        break
                    }
                }
            }
            
            if let portNum = port {
                candidates.append((pid: pid, port: portNum))
            }
        }
        
        if candidates.isEmpty { return nil }
        
        guard let maxPid = candidates.map({ $0.pid }).max() else { return nil }
        let portsForMaxPid = candidates.filter { $0.pid == maxPid }.map { $0.port }
        return portsForMaxPid.max()
    }
    
    private func findStatusBarConfig(from configs: [ClientModelConfig]) -> ClientModelConfig? {
        if let medium = configs.first(where: { $0.label.localizedCaseInsensitiveContains("Gemini 3.5 Flash (Medium)") }) {
            return medium
        }
        if let flash = configs.first(where: { $0.label.localizedCaseInsensitiveContains("Gemini 3.5 Flash") }) {
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
