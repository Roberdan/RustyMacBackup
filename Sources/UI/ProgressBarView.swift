import Cocoa

class ProgressBarView: NSView {
    var progress: CGFloat = 0 { didSet { needsDisplay = true } }

    override var intrinsicContentSize: NSSize { NSSize(width: 250, height: 32) }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        let barX: CGFloat = 14
        let barY: CGFloat = 10
        let barW: CGFloat = bounds.width - 70
        let barH: CGFloat = 12
        let cornerR: CGFloat = barH / 2

        // Background track
        let bgPath = CGPath(roundedRect: CGRect(x: barX, y: barY, width: barW, height: barH),
                            cornerWidth: cornerR, cornerHeight: cornerR, transform: nil)
        ctx.addPath(bgPath)
        ctx.setFillColor(NSColor.separatorColor.withAlphaComponent(0.3).cgColor)
        ctx.fillPath()

        // Filled portion with gradient rosso → gold → verde
        let pct = min(max(progress, 0), 1)
        let fillW = max(barW * pct, cornerR * 2)
        if pct > 0 {
            let fillRect = CGRect(x: barX, y: barY, width: fillW, height: barH)
            let fillPath = CGPath(roundedRect: fillRect,
                                  cornerWidth: cornerR, cornerHeight: cornerR, transform: nil)
            ctx.saveGState()
            ctx.addPath(fillPath)
            ctx.clip()

            let colors = [
                CGColor(red: 0.86, green: 0, blue: 0, alpha: 1),
                CGColor(red: 1.0, green: 0.78, blue: 0.17, alpha: 1),
                CGColor(red: 0, green: 0.65, blue: 0.32, alpha: 1),
            ] as CFArray
            if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                          colors: colors, locations: [0, 0.5, 1]) {
                ctx.drawLinearGradient(gradient,
                    start: CGPoint(x: barX, y: barY),
                    end: CGPoint(x: barX + barW, y: barY), options: [])
            }
            ctx.restoreGState()
        }

        // Percentage text to the right of bar
        let pctStr = "\(Int(pct * 100))%"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.boldSystemFont(ofSize: 13),
            .foregroundColor: NSColor.labelColor
        ]
        let sz = (pctStr as NSString).size(withAttributes: attrs)
        (pctStr as NSString).draw(
            at: CGPoint(x: barX + barW + 8, y: barY + (barH - sz.height) / 2),
            withAttributes: attrs)
    }
}
