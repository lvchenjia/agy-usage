import Cocoa

class ProgressBarView: NSView {
    var progress: Double = 0.0 {
        didSet { needsDisplay = true }
    }
    
    var color: NSColor = .systemBlue {
        didSet { needsDisplay = true }
    }
    
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        
        let trackPath = NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2)
        let trackColor = NSColor.quaternaryLabelColor.withAlphaComponent(0.2)
        trackColor.set()
        trackPath.fill()
        
        let fillWidth = bounds.width * CGFloat(max(0, min(1, progress)))
        if fillWidth > 0 {
            let fillRect = NSRect(x: 0, y: 0, width: fillWidth, height: bounds.height)
            let fillPath = NSBezierPath(roundedRect: fillRect, xRadius: bounds.height / 2, yRadius: bounds.height / 2)
            color.set()
            fillPath.fill()
        }
    }
}
