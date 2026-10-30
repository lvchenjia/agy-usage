import Cocoa

class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var menu: NSMenu!
    private var timer: Timer?
    private var retryTimer: Timer?
    private var isFetching = false
    
    private var lastConfigs: [ClientModelConfig]? = nil
    private var lastEnhancedGroups: [EnhancedQuotaGroup]? = nil
    private var isOffline = true
    
    private var currentPercentageText: String = "--%"
    private var currentStatusColor: NSColor? = nil
    
    private var tokenStatsWindowController: TokenStatsWindowController?
    
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
    
    private func startPolling() {
        timer?.invalidate()
        let interval = Double(ProcessInfo.processInfo.environment["AGY_TEST_POLL_INTERVAL"] ?? "15.0") ?? 15.0
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.fetchStatus()
        }
    }
    
    private func scheduleRetry() {
        retryTimer?.invalidate()
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
        } else if let enhancedGroups = lastEnhancedGroups, !enhancedGroups.isEmpty {
            for group in enhancedGroups {
                let menuItem = NSMenuItem()
                let customView = QuotaMenuItemView(
                    title: group.title,
                    fraction: group.fiveHourFraction,
                    resetText: formatResetTime(group.fiveHourReset),
                    weeklyFraction: group.weeklyFraction,
                    weeklyResetText: formatResetTime(group.weeklyReset)
                )
                menuItem.view = customView
                menu.addItem(menuItem)
            }
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
            self.lastEnhancedGroups = nil
            self.updateStatusBar(percentageText: "--%", color: nil)
            self.rebuildMenu()
            
            let agyRunning = DaemonClient.shared.isAgyProcessRunning()
            
            if !agyRunning && self.quitOnFailure {
                NSLog("AgyUsage: No active agy process found in system. Auto-quitting as configured.")
                NSApp.terminate(nil)
                return
            }
            
            if agyRunning {
                NSLog("AgyUsage: agy process is alive but RPC failed (%@). Retrying in 2.0s...", errorDescription)
                self.scheduleRetry()
            }
        }
    }
    
    private func fetchStatus() {
        guard !isFetching else { return }
        isFetching = true
        
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            
            let agyRunning = DaemonClient.shared.isAgyProcessRunning()
            if !agyRunning && self.quitOnFailure {
                DispatchQueue.main.async {
                    NSLog("AgyUsage: No active agy process found in system. Auto-quitting as configured.")
                    NSApp.terminate(nil)
                }
                return
            }
            
            DaemonClient.shared.fetchStatus { [weak self] result in
                guard let self = self else { return }
                DispatchQueue.main.async {
                    self.isFetching = false
                    switch result {
                    case .enhanced(let groups, _):
                        self.retryTimer?.invalidate()
                        self.retryTimer = nil
                        self.isOffline = false
                        self.lastEnhancedGroups = groups
                        self.lastConfigs = nil
                        
                        let repGroup = groups.first(where: { $0.title.localizedCaseInsensitiveContains("Gemini") }) ?? groups[0]
                        let fraction = repGroup.fiveHourFraction
                        let pct = self.formatPct(fraction)
                        let pctText = "\(pct)%"
                        let color: NSColor = (fraction > 0.50) ? .systemGreen : ((fraction >= 0.20) ? .systemOrange : .systemRed)
                        self.updateStatusBar(percentageText: pctText, color: color)
                        self.rebuildMenu()
                        NSLog("AgyUsage: successfully fetched quota summary %@", pctText)
                        
                    case .legacy(let configs, _):
                        self.retryTimer?.invalidate()
                        self.retryTimer = nil
                        self.isOffline = false
                        self.lastEnhancedGroups = nil
                        self.lastConfigs = configs
                        
                        if let repConfig = self.findStatusBarConfig(from: configs),
                           let fraction = repConfig.quotaInfo?.remainingFraction {
                            let pct = self.formatPct(fraction)
                            let pctText = "\(pct)%"
                            let color: NSColor = (fraction > 0.50) ? .systemGreen : ((fraction >= 0.20) ? .systemOrange : .systemRed)
                            self.updateStatusBar(percentageText: pctText, color: color)
                            NSLog("AgyUsage: successfully fetched legacy quota %@", pctText)
                        } else {
                            self.updateStatusBar(percentageText: "--%", color: nil)
                        }
                        self.rebuildMenu()
                        
                    case .failure(let errorDescription):
                        self.handleFetchFailure(errorDescription: errorDescription)
                    }
                }
            }
        }
    }
    
    private func formatPct(_ fraction: Double) -> Int {
        let rawPct = fraction * 100.0
        if fraction >= 0.9999 { return 100 }
        if fraction < 1.0 && rawPct >= 99.0 { return 99 }
        if fraction > 0.0 && rawPct < 1.0 { return 1 }
        return Int(round(rawPct))
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
        
        if !geminiConfigs.isEmpty {
            let rep = geminiConfigs.first(where: { $0.label.localizedCaseInsensitiveContains("Medium") }) ?? geminiConfigs[0]
            groups.append(GroupedQuota(
                name: "Gemini",
                fraction: rep.quotaInfo?.remainingFraction ?? 0.0,
                resetTime: rep.quotaInfo?.resetTime
            ))
        }
        
        if !claudeGptConfigs.isEmpty {
            let rep = claudeGptConfigs[0]
            groups.append(GroupedQuota(
                name: "Claude",
                fraction: rep.quotaInfo?.remainingFraction ?? 0.0,
                resetTime: rep.quotaInfo?.resetTime
            ))
        }
        
        for other in otherConfigs {
            groups.append(GroupedQuota(
                name: other.label,
                fraction: other.quotaInfo?.remainingFraction ?? 0.0,
                resetTime: other.quotaInfo?.resetTime
            ))
        }
        
        return groups
    }
}
