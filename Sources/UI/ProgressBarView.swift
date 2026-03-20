import Cocoa

class ProgressBarView: NSView {
    var progress: CGFloat = 0 { didSet { needsDisplay = true } }

    override var intrinsicContentSize: NSSize { NSSize(width: 280, height: 20) }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        let barRect = bounds.insetBy(dx: 0, dy: 4)
        let cornerR: CGFloat = barRect.height / 2

        // Background track
        let bgPath = CGPath(roundedRect: barRect, cornerWidth: cornerR, cornerHeight: cornerR, transform: nil)
        ctx.addPath(bgPath)
        ctx.setFillColor(NSColor.separatorColor.withAlphaComponent(0.3).cgColor)
        ctx.fillPath()

        // Fill
        let pct = min(max(progress, 0), 1)
        if pct > 0 {
            let fillW = max(barRect.width * pct, cornerR * 2)
            let fillRect = CGRect(x: barRect.minX, y: barRect.minY, width: fillW, height: barRect.height)
            let fillPath = CGPath(roundedRect: fillRect, cornerWidth: cornerR, cornerHeight: cornerR, transform: nil)
            ctx.addPath(fillPath)
            ctx.setFillColor(NSColor.controlAccentColor.cgColor)
            ctx.fillPath()
        }
    }
}
