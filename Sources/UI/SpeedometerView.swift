import Cocoa

class SpeedometerView: NSView {
    var speed: Double = 0.0 { // MB/s
        didSet {
            targetNeedleAngle = angleForSpeed(speed)
            animateNeedle()
        }
    }
    var eta: UInt64 = 0 { didSet { needsDisplay = true } }

    private var currentNeedleAngle: CGFloat = 210 // Start at red (slow)
    private var targetNeedleAngle: CGFloat = 210
    private var displayLink: Timer?

    private let startAngle: CGFloat = 210  // degrees, left side (slow/red)
    private let endAngle: CGFloat = -30    // degrees, right side (fast/green)
    private let maxSpeed: Double = 200     // MB/s for full scale

    override var intrinsicContentSize: NSSize { NSSize(width: 220, height: 90) }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let center = NSPoint(x: bounds.width / 2, y: 10)
        let radius = bounds.width / 2 - 20

        let zoneSweep: CGFloat = (endAngle - startAngle) / 3 // -80° per zone
        let redEnd = startAngle + zoneSweep
        let goldEnd = redEnd + zoneSweep

        // Arc background
        let bgArc = NSBezierPath()
        bgArc.lineWidth = 3
        bgArc.appendArc(withCenter: center, radius: radius, startAngle: startAngle, endAngle: endAngle, clockwise: true)
        NSColor.quaternaryLabelColor.setStroke()
        bgArc.stroke()

        // Colored arc segments (red -> gold -> green)
        let redArc = NSBezierPath()
        redArc.lineWidth = 4
        redArc.appendArc(withCenter: center, radius: radius, startAngle: startAngle, endAngle: redEnd, clockwise: true)
        MLColor.rosso.setStroke()
        redArc.stroke()

        let goldArc = NSBezierPath()
        goldArc.lineWidth = 4
        goldArc.appendArc(withCenter: center, radius: radius, startAngle: redEnd, endAngle: goldEnd, clockwise: true)
        MLColor.gold.setStroke()
        goldArc.stroke()

        let greenArc = NSBezierPath()
        greenArc.lineWidth = 4
        greenArc.appendArc(withCenter: center, radius: radius, startAngle: goldEnd, endAngle: endAngle, clockwise: true)
        MLColor.verde.setStroke()
        greenArc.stroke()

        // Tick marks every 30°
        for angle in stride(from: Int(startAngle), through: Int(endAngle), by: -30) {
            let rad = CGFloat(angle) * .pi / 180
            let outer = NSPoint(x: center.x + cos(rad) * radius, y: center.y + sin(rad) * radius)
            let inner = NSPoint(x: center.x + cos(rad) * (radius - 7), y: center.y + sin(rad) * (radius - 7))
            let tick = NSBezierPath()
            tick.lineWidth = 1.5
            tick.move(to: outer)
            tick.line(to: inner)
            NSColor.secondaryLabelColor.setStroke()
            tick.stroke()
        }

        // Needle color by zone
        let ratioDenominator = endAngle - startAngle
        let progress = ratioDenominator == 0 ? 0 : (currentNeedleAngle - startAngle) / ratioDenominator
        let needleColor: NSColor
        if progress < (1.0 / 3.0) {
            needleColor = MLColor.rosso
        } else if progress < (2.0 / 3.0) {
            needleColor = MLColor.gold
        } else {
            needleColor = MLColor.verde
        }

        // Needle
        let needleRad = currentNeedleAngle * .pi / 180
        let needleEnd = NSPoint(x: center.x + cos(needleRad) * (radius - 2), y: center.y + sin(needleRad) * (radius - 2))
        let needle = NSBezierPath()
        needle.lineWidth = 2
        needle.move(to: center)
        needle.line(to: needleEnd)
        needleColor.setStroke()
        needle.stroke()

        let hub = NSBezierPath(ovalIn: NSRect(x: center.x - 3, y: center.y - 3, width: 6, height: 6))
        needleColor.setFill()
        hub.fill()

        // Labels
        let speedString = String(format: "%.1f MB/s", speed)
        let speedAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.boldSystemFont(ofSize: 16),
            .foregroundColor: NSColor.labelColor
        ]
        let speedSize = (speedString as NSString).size(withAttributes: speedAttrs)
        let speedPoint = NSPoint(x: bounds.midX - speedSize.width / 2, y: 24)
        (speedString as NSString).draw(at: speedPoint, withAttributes: speedAttrs)

        let etaString = "ETA: \(eta)s"
        let etaAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.secondaryLabelColor
        ]
        let etaSize = (etaString as NSString).size(withAttributes: etaAttrs)
        let etaPoint = NSPoint(x: bounds.midX - etaSize.width / 2, y: 9)
        (etaString as NSString).draw(at: etaPoint, withAttributes: etaAttrs)
    }

    private func angleForSpeed(_ speed: Double) -> CGFloat {
        let clamped = min(max(speed, 0), maxSpeed)
        let ratio = CGFloat(clamped / maxSpeed)
        return startAngle + (endAngle - startAngle) * ratio
    }

    private func animateNeedle() {
        displayLink?.invalidate()
        displayLink = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] timer in
            guard let self = self else { timer.invalidate(); return }
            let diff = self.targetNeedleAngle - self.currentNeedleAngle
            if abs(diff) < 0.5 {
                self.currentNeedleAngle = self.targetNeedleAngle
                timer.invalidate()
            } else {
                self.currentNeedleAngle += diff * 0.15
            }
            self.needsDisplay = true
        }
    }
}
