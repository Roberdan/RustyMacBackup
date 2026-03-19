import Cocoa

class SpeedometerView: NSView {
    var speed: Double = 0 { didSet { needsDisplay = true } }
    var maxSpeed: Double = 200
    var eta: UInt64 = 0 { didSet { needsDisplay = true } }

    override var intrinsicContentSize: NSSize { NSSize(width: 220, height: 90) }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        let gaugeSize: CGFloat = 76
        let centerX: CGFloat = gaugeSize / 2 + 14
        let centerY: CGFloat = 20
        let radius: CGFloat = gaugeSize / 2 - 4

        let startAngle: CGFloat = 210 * .pi / 180
        let endAngle: CGFloat = -30 * .pi / 180
        let totalSweep: CGFloat = 240

        // Background arc
        ctx.setStrokeColor(NSColor.separatorColor.withAlphaComponent(0.4).cgColor)
        ctx.setLineWidth(5)
        ctx.addArc(center: CGPoint(x: centerX, y: centerY), radius: radius,
                   startAngle: startAngle, endAngle: endAngle, clockwise: true)
        ctx.strokePath()

        // Active arc — gold
        let valuePct = min(speed / maxSpeed, 1.0)
        let valueAngle = startAngle - CGFloat(valuePct * Double(totalSweep)) * .pi / 180

        if valuePct > 0.01 {
            ctx.setStrokeColor(MLColor.gold.cgColor)
            ctx.setLineWidth(5)
            ctx.addArc(center: CGPoint(x: centerX, y: centerY), radius: radius,
                       startAngle: startAngle, endAngle: valueAngle, clockwise: true)
            ctx.strokePath()
        }

        // Tick marks: 0, 50, 100, 150, 200
        for i in 0...4 {
            let tickPct = Double(i) / 4.0
            let tickAngle = startAngle - CGFloat(tickPct * Double(totalSweep)) * .pi / 180
            let inner = radius - 8
            let outer = radius + 1
            ctx.setStrokeColor(NSColor.tertiaryLabelColor.cgColor)
            ctx.setLineWidth(1)
            ctx.move(to: CGPoint(x: centerX + cos(tickAngle) * inner,
                                  y: centerY + sin(tickAngle) * inner))
            ctx.addLine(to: CGPoint(x: centerX + cos(tickAngle) * outer,
                                     y: centerY + sin(tickAngle) * outer))
            ctx.strokePath()

            let label = "\(i * 50)"
            let labelAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 7, weight: .medium),
                .foregroundColor: NSColor.tertiaryLabelColor
            ]
            let labelSize = (label as NSString).size(withAttributes: labelAttrs)
            let labelR = radius + 8
            let lx = centerX + cos(tickAngle) * labelR - labelSize.width / 2
            let ly = centerY + sin(tickAngle) * labelR - labelSize.height / 2
            (label as NSString).draw(at: CGPoint(x: lx, y: ly), withAttributes: labelAttrs)
        }

        // Needle — rosso corsa
        let needleLen = radius - 14
        let nx = centerX + cos(valueAngle) * needleLen
        let ny = centerY + sin(valueAngle) * needleLen
        ctx.setStrokeColor(CGColor(red: 0.86, green: 0, blue: 0, alpha: 1))
        ctx.setLineWidth(2)
        ctx.move(to: CGPoint(x: centerX, y: centerY))
        ctx.addLine(to: CGPoint(x: nx, y: ny))
        ctx.strokePath()

        // Center hub
        ctx.setFillColor(CGColor(red: 0.86, green: 0, blue: 0, alpha: 1))
        ctx.fillEllipse(in: CGRect(x: centerX - 3, y: centerY - 3, width: 6, height: 6))

        // Speed value — bold center
        let speedStr = String(format: "%.0f", speed)
        let speedAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.boldSystemFont(ofSize: 16),
            .foregroundColor: NSColor.labelColor
        ]
        let speedSize = (speedStr as NSString).size(withAttributes: speedAttrs)
        (speedStr as NSString).draw(
            at: CGPoint(x: centerX - speedSize.width / 2, y: centerY - speedSize.height / 2 - 5),
            withAttributes: speedAttrs)

        // "MB/s" unit
        let unitAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 7, weight: .medium),
            .foregroundColor: NSColor.secondaryLabelColor
        ]
        let unitSize = ("MB/s" as NSString).size(withAttributes: unitAttrs)
        ("MB/s" as NSString).draw(
            at: CGPoint(x: centerX - unitSize.width / 2, y: centerY - speedSize.height / 2 - 16),
            withAttributes: unitAttrs)

        // ETA to the right of gauge
        let rightX: CGFloat = gaugeSize + 24
        if eta > 0 {
            let etaStr = Fmt.formatDuration(Double(eta))
            let labelAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: NSColor.secondaryLabelColor
            ]
            let valueAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.boldSystemFont(ofSize: 13),
                .foregroundColor: MLColor.gold
            ]
            ("finisce tra" as NSString).draw(at: CGPoint(x: rightX, y: 50), withAttributes: labelAttrs)
            (etaStr as NSString).draw(at: CGPoint(x: rightX, y: 30), withAttributes: valueAttrs)
        } else {
            let scanAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: NSColor.secondaryLabelColor
            ]
            ("scansione..." as NSString).draw(at: CGPoint(x: rightX, y: 40), withAttributes: scanAttrs)
        }
    }
}
