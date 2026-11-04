import Cocoa

class QuotaMenuItemView: NSView {
    private let logoImageView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    
    // Primary / 5h row
    private let primaryLabel = NSTextField(labelWithString: "")
    private let primaryPercentLabel = NSTextField(labelWithString: "")
    private let primaryProgressBar = ProgressBarView()
    
    // Weekly row (when dual limit is available)
    private let weeklyLabel = NSTextField(labelWithString: "")
    private let weeklyPercentLabel = NSTextField(labelWithString: "")
    private let weeklyProgressBar = ProgressBarView()
    
    // Fallback single-bar reset label
    private let fallbackResetLabel = NSTextField(labelWithString: "")
    
    init(title: String, fraction: Double, resetText: String, weeklyFraction: Double? = nil, weeklyResetText: String? = nil) {
        let isDual = (weeklyFraction != nil && weeklyResetText != nil)
        let height: CGFloat = isDual ? 84 : 64
        super.init(frame: NSRect(x: 0, y: 0, width: 290, height: height))
        setupViews(title: title, fraction: fraction, resetText: resetText, weeklyFraction: weeklyFraction, weeklyResetText: weeklyResetText)
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    private func setupViews(title: String, fraction: Double, resetText: String, weeklyFraction: Double?, weeklyResetText: String?) {
        wantsLayer = true
        
        logoImageView.translatesAutoresizingMaskIntoConstraints = false
        logoImageView.imageScaling = .scaleProportionallyUpOrDown
        
        let imageName: String
        if title.localizedCaseInsensitiveContains("Gemini") {
            imageName = "gemini"
        } else if title.localizedCaseInsensitiveContains("Claude") || title.localizedCaseInsensitiveContains("3p") {
            imageName = "claude"
        } else {
            imageName = ""
        }
        
        if !imageName.isEmpty, let image = NSImage(named: imageName) {
            logoImageView.image = image
        } else {
            let sym = title.localizedCaseInsensitiveContains("Gemini") ? "sparkles" : "brain.head.profile"
            logoImageView.image = NSImage(systemSymbolName: sym, accessibilityDescription: title)
            logoImageView.contentTintColor = title.localizedCaseInsensitiveContains("Gemini") ? .systemBlue : .systemOrange
        }
        
        addSubview(logoImageView)
        
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor = .labelColor
        titleLabel.stringValue = title
        titleLabel.lineBreakMode = .byTruncatingTail
        addSubview(titleLabel)
        
        let contentLeading = logoImageView.trailingAnchor
        let contentLeadingConstant: CGFloat = 12
        
        let isDual = (weeklyFraction != nil && weeklyResetText != nil)
        
        if isDual, let wFrac = weeklyFraction, let wReset = weeklyResetText {
            // === DUAL PROGRESS BAR MODE (5h + Weekly) ===
            
            // 5h Limit row
            primaryLabel.translatesAutoresizingMaskIntoConstraints = false
            primaryLabel.font = NSFont.systemFont(ofSize: 10, weight: .regular)
            primaryLabel.textColor = .secondaryLabelColor
            primaryLabel.stringValue = "5h Limit · \(resetText)"
            addSubview(primaryLabel)
            
            primaryPercentLabel.translatesAutoresizingMaskIntoConstraints = false
            primaryPercentLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .bold)
            primaryPercentLabel.alignment = .right
            primaryPercentLabel.stringValue = "\(formatPct(fraction))%"
            primaryPercentLabel.textColor = .labelColor
            addSubview(primaryPercentLabel)
            
            primaryProgressBar.translatesAutoresizingMaskIntoConstraints = false
            primaryProgressBar.progress = fraction
            primaryProgressBar.color = statusColor(for: fraction)
            addSubview(primaryProgressBar)
            
            // Weekly Limit row
            weeklyLabel.translatesAutoresizingMaskIntoConstraints = false
            weeklyLabel.font = NSFont.systemFont(ofSize: 10, weight: .regular)
            weeklyLabel.textColor = .secondaryLabelColor
            weeklyLabel.stringValue = "Weekly Limit · \(wReset)"
            addSubview(weeklyLabel)
            
            weeklyPercentLabel.translatesAutoresizingMaskIntoConstraints = false
            weeklyPercentLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .bold)
            weeklyPercentLabel.alignment = .right
            weeklyPercentLabel.stringValue = "\(formatPct(wFrac))%"
            weeklyPercentLabel.textColor = .labelColor
            addSubview(weeklyPercentLabel)
            
            weeklyProgressBar.translatesAutoresizingMaskIntoConstraints = false
            weeklyProgressBar.progress = wFrac
            weeklyProgressBar.color = statusColor(for: wFrac)
            addSubview(weeklyProgressBar)
            
            NSLayoutConstraint.activate([
                logoImageView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
                logoImageView.centerYAnchor.constraint(equalTo: centerYAnchor),
                logoImageView.widthAnchor.constraint(equalToConstant: 28),
                logoImageView.heightAnchor.constraint(equalToConstant: 28),
                
                titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 7),
                titleLabel.leadingAnchor.constraint(equalTo: contentLeading, constant: contentLeadingConstant),
                
                // 5-Hour Label & Percent
                primaryLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 4),
                primaryLabel.leadingAnchor.constraint(equalTo: contentLeading, constant: contentLeadingConstant),
                
                primaryPercentLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
                primaryPercentLabel.centerYAnchor.constraint(equalTo: primaryLabel.centerYAnchor),
                
                // 5-Hour Bar
                primaryProgressBar.topAnchor.constraint(equalTo: primaryLabel.bottomAnchor, constant: 3),
                primaryProgressBar.leadingAnchor.constraint(equalTo: contentLeading, constant: contentLeadingConstant),
                primaryProgressBar.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
                primaryProgressBar.heightAnchor.constraint(equalToConstant: 4),
                
                // Weekly Label & Percent
                weeklyLabel.topAnchor.constraint(equalTo: primaryProgressBar.bottomAnchor, constant: 6),
                weeklyLabel.leadingAnchor.constraint(equalTo: contentLeading, constant: contentLeadingConstant),
                
                weeklyPercentLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
                weeklyPercentLabel.centerYAnchor.constraint(equalTo: weeklyLabel.centerYAnchor),
                
                // Weekly Bar
                weeklyProgressBar.topAnchor.constraint(equalTo: weeklyLabel.bottomAnchor, constant: 3),
                weeklyProgressBar.leadingAnchor.constraint(equalTo: contentLeading, constant: contentLeadingConstant),
                weeklyProgressBar.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
                weeklyProgressBar.heightAnchor.constraint(equalToConstant: 4),
                weeklyProgressBar.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8)
            ])
        } else {
            // === SINGLE PROGRESS BAR MODE (Fallback) ===
            primaryPercentLabel.translatesAutoresizingMaskIntoConstraints = false
            primaryPercentLabel.font = NSFont.systemFont(ofSize: 13, weight: .bold)
            primaryPercentLabel.alignment = .right
            primaryPercentLabel.stringValue = "\(formatPct(fraction))%"
            primaryPercentLabel.textColor = .labelColor
            addSubview(primaryPercentLabel)
            
            primaryProgressBar.translatesAutoresizingMaskIntoConstraints = false
            primaryProgressBar.progress = fraction
            primaryProgressBar.color = statusColor(for: fraction)
            addSubview(primaryProgressBar)
            
            fallbackResetLabel.translatesAutoresizingMaskIntoConstraints = false
            fallbackResetLabel.font = NSFont.systemFont(ofSize: 10, weight: .regular)
            fallbackResetLabel.textColor = .secondaryLabelColor
            fallbackResetLabel.stringValue = resetText
            fallbackResetLabel.lineBreakMode = .byTruncatingTail
            addSubview(fallbackResetLabel)
            
            NSLayoutConstraint.activate([
                logoImageView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
                logoImageView.centerYAnchor.constraint(equalTo: centerYAnchor),
                logoImageView.widthAnchor.constraint(equalToConstant: 28),
                logoImageView.heightAnchor.constraint(equalToConstant: 28),
                
                titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 8),
                titleLabel.leadingAnchor.constraint(equalTo: contentLeading, constant: contentLeadingConstant),
                
                primaryPercentLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
                primaryPercentLabel.topAnchor.constraint(equalTo: topAnchor, constant: 8),
                primaryPercentLabel.leadingAnchor.constraint(greaterThanOrEqualTo: titleLabel.trailingAnchor, constant: 8),
                
                primaryProgressBar.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
                primaryProgressBar.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 6),
                primaryProgressBar.leadingAnchor.constraint(equalTo: contentLeading, constant: contentLeadingConstant),
                primaryProgressBar.heightAnchor.constraint(equalToConstant: 6),
                
                fallbackResetLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
                fallbackResetLabel.topAnchor.constraint(equalTo: primaryProgressBar.bottomAnchor, constant: 4),
                fallbackResetLabel.leadingAnchor.constraint(equalTo: contentLeading, constant: contentLeadingConstant),
                fallbackResetLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8)
            ])
        }
    }
    
    private func formatPct(_ fraction: Double) -> Int {
        let rawPct = fraction * 100.0
        if fraction >= 0.9999 { return 100 }
        if fraction < 1.0 && rawPct >= 99.0 { return 99 }
        if fraction > 0.0 && rawPct < 1.0 { return 1 }
        return Int(round(rawPct))
    }
    
    private func statusColor(for fraction: Double) -> NSColor {
        if fraction > 0.50 { return .systemGreen }
        else if fraction >= 0.20 { return .systemOrange }
        else { return .systemRed }
    }
}
