import Cocoa

class ModernHeaderCell: NSTableHeaderCell {
    override func draw(withFrame cellFrame: NSRect, in controlView: NSView) {
        let isDark = controlView.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let bgColor = isDark ? NSColor(white: 0.16, alpha: 0.8) : NSColor(white: 0.95, alpha: 0.9)
        bgColor.set()
        cellFrame.fill()
        
        let borderPath = NSBezierPath()
        borderPath.move(to: NSPoint(x: cellFrame.minX, y: cellFrame.maxY - 0.5))
        borderPath.line(to: NSPoint(x: cellFrame.maxX, y: cellFrame.maxY - 0.5))
        NSColor.separatorColor.withAlphaComponent(0.15).set()
        borderPath.lineWidth = 1.0
        borderPath.stroke()
        
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = self.alignment
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10, weight: .bold),
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: paragraphStyle
        ]
        let insetRect = NSRect(x: cellFrame.origin.x + 8, y: cellFrame.origin.y + (cellFrame.height - 13) / 2, width: cellFrame.width - 16, height: 13)
        self.stringValue.draw(in: insetRect, withAttributes: attrs)
    }
}

class ModernHeaderView: NSTableHeaderView {
    override var intrinsicContentSize: NSSize {
        var s = super.intrinsicContentSize
        s.height = 28
        return s
    }
}
