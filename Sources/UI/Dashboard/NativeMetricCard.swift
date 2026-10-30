import Cocoa

class NativeMetricCard: NSView {
    private let titleLabel = NSTextField(labelWithString: "")
    private let valueLabel = NSTextField(labelWithString: "--")
    private let iconBadge = NSBox()
    private let iconView = NSImageView()
    
    init(title: String, systemImage: String, tint: NSColor) {
        super.init(frame: .zero)
        setup(title: title, systemImage: systemImage, tint: tint)
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    private func setup(title: String, systemImage: String, tint: NSColor) {
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.12).cgColor
        layer?.borderWidth = 0.5
        updateBackground()
        
        // Icon badge in top right
        iconBadge.boxType = .custom
        iconBadge.cornerRadius = 8
        iconBadge.borderWidth = 0
        iconBadge.fillColor = tint.withAlphaComponent(0.12)
        iconBadge.translatesAutoresizingMaskIntoConstraints = false
        addSubview(iconBadge)
        
        iconView.translatesAutoresizingMaskIntoConstraints = false
        let cfg = NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
        iconView.image = NSImage(systemSymbolName: systemImage, accessibilityDescription: title)?.withSymbolConfiguration(cfg)
        iconView.contentTintColor = tint
        iconBadge.contentView?.addSubview(iconView)
        
        if let bcv = iconBadge.contentView {
            NSLayoutConstraint.activate([
                iconView.centerXAnchor.constraint(equalTo: bcv.centerXAnchor),
                iconView.centerYAnchor.constraint(equalTo: bcv.centerYAnchor)
            ])
        }
        
        titleLabel.stringValue = title
        titleLabel.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        titleLabel.textColor = .secondaryLabelColor
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)
        
        valueLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 26, weight: .bold)
        valueLabel.textColor = .labelColor
        valueLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(valueLabel)
        
        NSLayoutConstraint.activate([
            // Icon Badge Top Right
            iconBadge.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            iconBadge.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            iconBadge.widthAnchor.constraint(equalToConstant: 30),
            iconBadge.heightAnchor.constraint(equalToConstant: 30),
            
            // Title Top Left
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: iconBadge.leadingAnchor, constant: -8),
            
            // Value Bottom Left
            valueLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            valueLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 6),
            valueLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -14),
            valueLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -14)
        ])
    }
    
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateBackground()
    }
    
    private func updateBackground() {
        let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        layer?.backgroundColor = isDark
            ? NSColor(white: 0.16, alpha: 0.65).cgColor
            : NSColor(white: 0.99, alpha: 0.95).cgColor
    }
    
    func update(value: String, valueColor: NSColor = .labelColor) {
        valueLabel.stringValue = value
        valueLabel.textColor = valueColor
    }
}
