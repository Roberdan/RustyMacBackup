import Cocoa

class ProgressBarView: NSView {
    var progress: CGFloat = 0.0 { // 0.0 to 1.0
        didSet { needsDisplay = true }
    }

    override var intrinsicContentSize: NSSize { NSSize(width: 250, height: 32) }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let bounds = self.bounds.insetBy(dx: 4, dy: 4)
        let radius: CGFloat = bounds.height / 2

        // Background track
        let bgPath = NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius)
        NSColor.quaternaryLabelColor.setFill()
        bgPath.fill()

        // Filled portion with gradient rosso → gold → verde
        if progress > 0 {
            let fillWidth = max(bounds.height, bounds.width * min(progress, 1.0))
            let fillRect = NSRect(x: bounds.origin.x, y: bounds.origin.y,
                                  width: fillWidth, height: bounds.height)
            let fillPath = NSBezierPath(roundedRect: fillRect, xRadius: radius, yRadius: radius)

            // Gradient: rosso (0%) → gold (50%) → verde (100%)
            let gradient = NSGradient(colorsAndLocations:
                (MLColor.rosso, 0.0),
                (MLColor.gold, 0.5),
                (MLColor.verde, 1.0)
            )
            gradient?.draw(in: fillPath, angle: 0)

            // Subtle glow on filled portion
            let glowColor = NSColor.white.withAlphaComponent(0.15)
            let glowRect = NSRect(x: fillRect.origin.x, y: fillRect.midY,
                                  width: fillRect.width, height: fillRect.height / 2)
            let glowPath = NSBezierPath(roundedRect: glowRect, xRadius: radius / 2, yRadius: radius / 2)
            glowColor.setFill()
            glowPath.fill()
        }

        // Percentage text centered
        let pct = "\(Int(progress * 100))%"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: progress > 0.5 ? NSColor.white : NSColor.labelColor
        ]
        let textSize = (pct as NSString).size(withAttributes: attrs)
        let textPoint = NSPoint(
            x: bounds.midX - textSize.width / 2,
            y: bounds.midY - textSize.height / 2
        )
        (pct as NSString).draw(at: textPoint, withAttributes: attrs)
    }
}
