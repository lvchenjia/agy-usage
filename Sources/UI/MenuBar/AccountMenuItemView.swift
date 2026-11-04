import Cocoa

class AccountMenuItemView: NSView {
    private let avatarImageView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private let badgeLabel = NSTextField(labelWithString: "")
    private let badgeView = NSView()
    
    init(account: UserAccountInfo) {
        super.init(frame: NSRect(x: 0, y: 0, width: 290, height: 48))
        setupViews(account: account)
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    private func setupViews(account: UserAccountInfo) {
        wantsLayer = true
        
        // 1. Avatar Image
        avatarImageView.translatesAutoresizingMaskIntoConstraints = false
        avatarImageView.wantsLayer = true
        avatarImageView.layer?.cornerRadius = 14
        avatarImageView.layer?.masksToBounds = true
        avatarImageView.layer?.borderWidth = 0.5
        avatarImageView.layer?.borderColor = NSColor.separatorColor.cgColor
        avatarImageView.imageScaling = .scaleProportionallyUpOrDown
        
        var avatarImage: NSImage? = nil
        if let raw = account.profilePictureUrl {
            let base64Part: String
            if let commaRange = raw.range(of: "base64,") {
                base64Part = String(raw[commaRange.upperBound...])
            } else {
                base64Part = raw
            }
            if let data = Data(base64Encoded: base64Part), let img = NSImage(data: data) {
                avatarImage = img
            }
        }
        
        if let img = avatarImage {
            avatarImageView.image = img
        } else {
            avatarImageView.image = NSImage(systemSymbolName: "person.crop.circle.fill", accessibilityDescription: nil)
            avatarImageView.contentTintColor = .secondaryLabelColor
        }
        addSubview(avatarImageView)
        
        // 2. Determine Primary & Secondary text
        let name = account.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let email = account.email?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let tier = account.tierName ?? account.planName ?? "Pro"
        
        let hasName = !name.isEmpty && name.lowercased() != email.lowercased()
        let primaryText = hasName ? name : (email.isEmpty ? "Google Account" : email)
        let secondaryText = hasName ? email : ""
        
        // 3. Title Label
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = NSFont.systemFont(ofSize: 12.5, weight: .semibold)
        titleLabel.textColor = .labelColor
        titleLabel.stringValue = primaryText
        titleLabel.lineBreakMode = .byTruncatingTail
        addSubview(titleLabel)
        
        // 4. Badge View
        badgeLabel.translatesAutoresizingMaskIntoConstraints = false
        badgeLabel.font = NSFont.systemFont(ofSize: 9.5, weight: .semibold)
        badgeLabel.textColor = .systemBlue
        badgeLabel.stringValue = tier
        
        badgeView.translatesAutoresizingMaskIntoConstraints = false
        badgeView.wantsLayer = true
        badgeView.layer?.cornerRadius = 4
        badgeView.layer?.backgroundColor = NSColor.systemBlue.withAlphaComponent(0.12).cgColor
        badgeView.addSubview(badgeLabel)
        addSubview(badgeView)
        
        // 5. Subtitle Label
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        subtitleLabel.font = NSFont.systemFont(ofSize: 10.5, weight: .regular)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.stringValue = secondaryText
        subtitleLabel.lineBreakMode = .byTruncatingMiddle
        addSubview(subtitleLabel)
        
        NSLayoutConstraint.activate([
            avatarImageView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            avatarImageView.centerYAnchor.constraint(equalTo: centerYAnchor),
            avatarImageView.widthAnchor.constraint(equalToConstant: 28),
            avatarImageView.heightAnchor.constraint(equalToConstant: 28),
            
            // Badge internal constraints
            badgeLabel.leadingAnchor.constraint(equalTo: badgeView.leadingAnchor, constant: 5),
            badgeLabel.trailingAnchor.constraint(equalTo: badgeView.trailingAnchor, constant: -5),
            badgeLabel.topAnchor.constraint(equalTo: badgeView.topAnchor, constant: 1.5),
            badgeLabel.bottomAnchor.constraint(equalTo: badgeView.bottomAnchor, constant: -1.5),
            
            // Title & Badge row
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 7),
            titleLabel.leadingAnchor.constraint(equalTo: avatarImageView.trailingAnchor, constant: 10),
            
            badgeView.leadingAnchor.constraint(equalTo: titleLabel.trailingAnchor, constant: 6),
            badgeView.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            badgeView.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -14),
            
            // Subtitle row
            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 2),
            subtitleLabel.leadingAnchor.constraint(equalTo: avatarImageView.trailingAnchor, constant: 10),
            subtitleLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -14)
        ])
    }
    
    override func mouseUp(with event: NSEvent) {
        super.mouseUp(with: event)
        if let url = URL(string: "https://antigravity.google.com") {
            NSWorkspace.shared.open(url)
        }
        enclosingMenuItem?.menu?.cancelTracking()
    }
}
