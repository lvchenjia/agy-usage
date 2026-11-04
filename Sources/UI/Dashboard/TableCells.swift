import Cocoa

class ModelCellView: NSTableCellView {
    let iconBadge = NSBox()
    let iconView = NSImageView()
    let titleLabel = NSTextField(labelWithString: "")
    let subtitleLabel = NSTextField(labelWithString: "")
    
    override init(frame: NSRect) {
        super.init(frame: frame)
        setup()
    }
    
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }
    
    private func setup() {
        iconBadge.boxType = .custom
        iconBadge.cornerRadius = 7
        iconBadge.borderWidth = 0
        iconBadge.translatesAutoresizingMaskIntoConstraints = false
        addSubview(iconBadge)
        
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconBadge.contentView?.addSubview(iconView)
        
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = NSFont.systemFont(ofSize: 12.5, weight: .semibold)
        titleLabel.textColor = .labelColor
        titleLabel.lineBreakMode = .byTruncatingTail
        addSubview(titleLabel)
        
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        subtitleLabel.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
        subtitleLabel.textColor = .tertiaryLabelColor
        subtitleLabel.lineBreakMode = .byTruncatingTail
        addSubview(subtitleLabel)
        
        if let bcv = iconBadge.contentView {
            NSLayoutConstraint.activate([
                iconView.centerXAnchor.constraint(equalTo: bcv.centerXAnchor),
                iconView.centerYAnchor.constraint(equalTo: bcv.centerYAnchor)
            ])
        }
        
        NSLayoutConstraint.activate([
            iconBadge.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            iconBadge.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconBadge.widthAnchor.constraint(equalToConstant: 28),
            iconBadge.heightAnchor.constraint(equalToConstant: 28),
            
            titleLabel.leadingAnchor.constraint(equalTo: iconBadge.trailingAnchor, constant: 9),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 7),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -4),
            
            subtitleLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 1),
            subtitleLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -4)
        ])
    }
    
    func configure(modelName: String) {
        titleLabel.stringValue = modelName
        let lower = modelName.lowercased()
        let tint: NSColor
        let symName: String
        let vendor: String
        if lower.contains("gemini") {
            symName = "sparkles"
            tint = .systemBlue
            vendor = "Google · Multimodal"
        } else if lower.contains("claude") {
            symName = "brain.head.profile"
            tint = .systemOrange
            vendor = "Anthropic · Reasoning"
        } else if lower.contains("gpt") {
            symName = "bolt.fill"
            tint = .systemGreen
            vendor = "OpenAI · GPT-OSS"
        } else {
            symName = "cpu"
            tint = .secondaryLabelColor
            vendor = "Core Engine"
        }
        subtitleLabel.stringValue = vendor
        iconBadge.fillColor = tint.withAlphaComponent(0.12)
        let config = NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
        iconView.image = NSImage(systemSymbolName: symName, accessibilityDescription: modelName)?.withSymbolConfiguration(config)
        iconView.contentTintColor = tint
    }
}

class MetricTextCellView: NSTableCellView {
    let label = NSTextField(labelWithString: "")
    
    override init(frame: NSRect) {
        super.init(frame: frame)
        setup()
    }
    
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }
    
    private func setup() {
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        label.alignment = .right
        label.textColor = .labelColor
        addSubview(label)
        
        NSLayoutConstraint.activate([
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4)
        ])
    }
    
    func configure(text: String, isBold: Bool = false) {
        label.stringValue = text
        label.font = isBold
            ? NSFont.monospacedDigitSystemFont(ofSize: 12.5, weight: .bold)
            : NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
    }
}

class SpeedCellView: NSTableCellView {
    let stackView = NSStackView()
    let valueLabel = NSTextField(labelWithString: "")
    let unitLabel = NSTextField(labelWithString: "")
    
    override init(frame: NSRect) {
        super.init(frame: frame)
        setup()
    }
    
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }
    
    private func setup() {
        stackView.orientation = .horizontal
        stackView.alignment = .firstBaseline
        stackView.spacing = 3
        stackView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stackView)
        
        valueLabel.translatesAutoresizingMaskIntoConstraints = false
        valueLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        valueLabel.alignment = .right
        valueLabel.textColor = .labelColor
        stackView.addArrangedSubview(valueLabel)
        
        unitLabel.translatesAutoresizingMaskIntoConstraints = false
        unitLabel.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
        unitLabel.textColor = .tertiaryLabelColor
        stackView.addArrangedSubview(unitLabel)
        
        NSLayoutConstraint.activate([
            stackView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            stackView.centerYAnchor.constraint(equalTo: centerYAnchor),
            stackView.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 4)
        ])
    }
    
    func configure(speed: Double?) {
        let formatted = formatTokenSpeed(speed)
        valueLabel.stringValue = formatted.value
        if let unit = formatted.unit {
            unitLabel.stringValue = unit
            unitLabel.isHidden = false
        } else {
            unitLabel.stringValue = ""
            unitLabel.isHidden = true
        }
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
    
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }
    
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
                pillLabel.leadingAnchor.constraint(equalTo: bcv.leadingAnchor, constant: 5),
                pillLabel.trailingAnchor.constraint(equalTo: bcv.trailingAnchor, constant: -5),
                pillLabel.centerYAnchor.constraint(equalTo: bcv.centerYAnchor)
            ])
        }
        
        NSLayoutConstraint.activate([
            pillBadge.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            pillBadge.centerYAnchor.constraint(equalTo: centerYAnchor),
            pillBadge.heightAnchor.constraint(equalToConstant: 18),
            
            valueLabel.trailingAnchor.constraint(equalTo: pillBadge.leadingAnchor, constant: -6),
            valueLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            valueLabel.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 4)
        ])
    }
    
    func configure(tokens: Int64, ratio: Double) {
        valueLabel.stringValue = formatKMB(tokens)
        pillLabel.stringValue = String(format: "%.1f%%", ratio)
        pillBadge.isHidden = (tokens == 0)
    }
}

class ShareCellView: NSTableCellView {
    let progressBar = ProgressBarView()
    let percentLabel = NSTextField(labelWithString: "")
    
    override init(frame: NSRect) {
        super.init(frame: frame)
        setup()
    }
    
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }
    
    private func setup() {
        progressBar.translatesAutoresizingMaskIntoConstraints = false
        addSubview(progressBar)
        
        percentLabel.translatesAutoresizingMaskIntoConstraints = false
        percentLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        percentLabel.alignment = .right
        percentLabel.textColor = .secondaryLabelColor
        addSubview(percentLabel)
        
        NSLayoutConstraint.activate([
            percentLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            percentLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            percentLabel.widthAnchor.constraint(equalToConstant: 44),
            
            progressBar.trailingAnchor.constraint(equalTo: percentLabel.leadingAnchor, constant: -8),
            progressBar.centerYAnchor.constraint(equalTo: centerYAnchor),
            progressBar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            progressBar.heightAnchor.constraint(equalToConstant: 5)
        ])
    }
    
    func configure(share: Double) {
        progressBar.progress = share / 100.0
        percentLabel.stringValue = String(format: "%.1f%%", share)
        progressBar.color = share > 50 ? .systemBlue : .systemCyan
    }
}
