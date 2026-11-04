import Cocoa

class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var menu: NSMenu!
    private var timer: Timer?
    private var retryTimer: Timer?
    private var isFetching = false
    
    private var lastConfigs: [ClientModelConfig]? = nil
    private var lastEnhancedGroups: [EnhancedQuotaGroup]? = nil
    private var lastAccountInfo: UserAccountInfo? = nil
    private var isOffline = true
    
    private var isRemoteControlActive: Bool = false
    private var remoteControlPid: Int? = nil
    
    private var currentDisplayText: String = "G--"
    private var currentStatusColor: NSColor? = nil
    
    private var tokenStatsWindowController: TokenStatsWindowController?
    
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
            "quitOnFailure": false
        ])
        
        // Setup status item
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        
        // Setup initial menu
        menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        
        updateStatusBar(displayText: "G--", color: nil)
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
            if let winArg = CommandLine.arguments.first(where: { $0.hasPrefix("--window=") }) {
                let valStr = winArg.replacingOccurrences(of: "--window=", with: "")
                if let idx = Int(valStr) {
                    tokenStatsWindowController?.selectTimeWindow(idx)
                }
            }
        }
    }
    
    func menuWillOpen(_ menu: NSMenu) {
        fetchStatus()
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
    
    private func updateStatusBar(displayText: String, color: NSColor?) {
        currentDisplayText = displayText
        currentStatusColor = color
        updateStatusBarDisplay()
    }
    
    private func updateStatusBarDisplay() {
        guard let button = statusItem.button else { return }
        button.image = nil
        button.imagePosition = .noImage
        
        let titleString = isRemoteControlActive ? "\(currentDisplayText) R" : currentDisplayText
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 14, weight: .regular),
            .baselineOffset: -0.5
        ]
        button.attributedTitle = NSAttributedString(string: titleString, attributes: attrs)
    }
    
    @objc func openRemoteControlWebClicked(_ sender: Any?) {
        if let url = URL(string: "https://antigravity.google.com") {
            NSWorkspace.shared.open(url)
        }
    }
    
    @objc func toggleRemoteControlClicked(_ sender: Any?) {
        guard !RemoteControlService.shared.isBusy else { return }
        
        let willStart = !isRemoteControlActive
        rebuildMenu()
        
        if willStart {
            RemoteControlService.shared.startRemoteControl { [weak self] success, _ in
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    self.isRemoteControlActive = RemoteControlService.shared.currentStatus.isRunning
                    self.remoteControlPid = RemoteControlService.shared.currentStatus.pid
                    self.updateStatusBarDisplay()
                    self.rebuildMenu()
                }
            }
        } else {
            RemoteControlService.shared.stopRemoteControl { [weak self] success, _ in
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    self.isRemoteControlActive = RemoteControlService.shared.currentStatus.isRunning
                    self.remoteControlPid = RemoteControlService.shared.currentStatus.pid
                    self.updateStatusBarDisplay()
                    self.rebuildMenu()
                }
            }
        }
        rebuildMenu()
    }
    
    private func rebuildMenu() {
        menu.removeAllItems()
        
        // 1. Account Header (Top Item)
        if let account = lastAccountInfo {
            let accountItem = NSMenuItem()
            let accountView = AccountMenuItemView(account: account)
            accountItem.view = accountView
            menu.addItem(accountItem)
            menu.addItem(NSMenuItem.separator())
        }
        
        // 2. Quota Cards
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
        
        // 3. Remote Control Controls
        let openWebItem = NSMenuItem(title: "Open Remote Control Web...", action: #selector(openRemoteControlWebClicked(_:)), keyEquivalent: "")
        openWebItem.target = self
        openWebItem.toolTip = "Open https://antigravity.google.com"
        menu.addItem(openWebItem)
        
        let isBusy = RemoteControlService.shared.isBusy
        let toggleTitle: String
        if RemoteControlService.shared.actionState == .starting {
            toggleTitle = "Starting Remote Control..."
        } else if RemoteControlService.shared.actionState == .stopping {
            toggleTitle = "Stopping Remote Control..."
        } else if isRemoteControlActive {
            toggleTitle = "Stop Remote Control"
        } else {
            toggleTitle = "Start Remote Control"
        }
        let toggleItem = NSMenuItem(title: toggleTitle, action: #selector(toggleRemoteControlClicked(_:)), keyEquivalent: "")
        toggleItem.target = self
        toggleItem.isEnabled = !isBusy
        if let pid = remoteControlPid, isRemoteControlActive {
            toggleItem.toolTip = "Daemon PID: \(pid). Click to stop."
        }
        menu.addItem(toggleItem)
        
        // 4. Token Usage Dashboard
        let tokenStatsItem = NSMenuItem(title: "Token Usage Dashboard...", action: #selector(openTokenStatsDashboard(_:)), keyEquivalent: "t")
        tokenStatsItem.target = self
        menu.addItem(tokenStatsItem)
        
        menu.addItem(NSMenuItem.separator())
        
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
            self.updateStatusBar(displayText: "G--", color: nil)
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
        
        // Also poll Remote Control status concurrently
        RemoteControlService.shared.checkStatus { [weak self] rcStatus in
            guard let self = self else { return }
            let changed = (self.isRemoteControlActive != rcStatus.isRunning) || (self.remoteControlPid != rcStatus.pid)
            self.isRemoteControlActive = rcStatus.isRunning
            self.remoteControlPid = rcStatus.pid
            if changed {
                self.updateStatusBarDisplay()
                self.rebuildMenu()
            }
        }
        
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
                    case .enhanced(let groups, _, let account):
                        self.retryTimer?.invalidate()
                        self.retryTimer = nil
                        self.isOffline = false
                        self.lastEnhancedGroups = groups
                        self.lastConfigs = nil
                        if let account = account {
                            self.lastAccountInfo = account
                        }
                        
                        let repGroup = groups.first(where: { $0.title.localizedCaseInsensitiveContains("Gemini") }) ?? groups[0]
                        let fraction = repGroup.fiveHourFraction
                        let pct = self.formatPct(fraction)
                        let displayText = "G\(pct)"
                        let color: NSColor = (fraction > 0.50) ? .systemGreen : ((fraction >= 0.20) ? .systemOrange : .systemRed)
                        self.updateStatusBar(displayText: displayText, color: color)
                        self.rebuildMenu()
                        NSLog("AgyUsage: successfully fetched quota summary %@", displayText)
                        
                    case .legacy(let configs, _, let account):
                        self.retryTimer?.invalidate()
                        self.retryTimer = nil
                        self.isOffline = false
                        self.lastEnhancedGroups = nil
                        self.lastConfigs = configs
                        if let account = account {
                            self.lastAccountInfo = account
                        }
                        
                        if let repConfig = self.findStatusBarConfig(from: configs),
                           let fraction = repConfig.quotaInfo?.remainingFraction {
                            let pct = self.formatPct(fraction)
                            let displayText = "G\(pct)"
                            let color: NSColor = (fraction > 0.50) ? .systemGreen : ((fraction >= 0.20) ? .systemOrange : .systemRed)
                            self.updateStatusBar(displayText: displayText, color: color)
                            NSLog("AgyUsage: successfully fetched legacy quota %@", displayText)
                        } else {
                            self.updateStatusBar(displayText: "G--", color: nil)
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
