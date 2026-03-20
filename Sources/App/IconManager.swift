import Cocoa

class IconManager {
    private let statusItem: NSStatusItem
    private var pulseTimer: Timer?
    private(set) var currentState: AppState = .idle

    init(statusItem: NSStatusItem) {
        self.statusItem = statusItem
        setIcon(color: nil)
    }

    func setState(_ state: AppState) {
        currentState = state
        stopAnimations()
        switch state {
        case .needsSetup:  setIcon(color: MLColor.warning)
        case .idle:        setIcon(color: MLColor.success)
        case .running:     startPulse()
        case .error:       setIcon(color: MLColor.error)
        case .diskAbsent:  setIcon(color: MLColor.error)
        case .stale:       setIcon(color: MLColor.warning)
        }
    }

    private func setIcon(color: NSColor?) {
        guard let button = statusItem.button else { return }
        let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular, scale: .medium)
        guard let symbol = NSImage(systemSymbolName: "clock.arrow.circlepath",
                                    accessibilityDescription: "RustyMacBackup")?
                .withSymbolConfiguration(config) else { return }

        guard let dotColor = color else {
            symbol.isTemplate = true
            button.image = symbol
            return
        }

        let baseSize = symbol.size
        let totalW = baseSize.width + 5
        let finalSize = NSSize(width: totalW, height: baseSize.height)

        let composite = NSImage(size: finalSize, flipped: false) { _ in
            let tinted = symbol.copy() as! NSImage
            tinted.isTemplate = true
            tinted.draw(in: NSRect(origin: .zero, size: baseSize))

            let dotD: CGFloat = 6
            let dotRect = NSRect(x: totalW - dotD - 0.5, y: 0.5, width: dotD, height: dotD)
            dotColor.setFill()
            NSBezierPath(ovalIn: dotRect).fill()
            return true
        }
        composite.isTemplate = false
        button.image = composite
    }

    private func startPulse() {
        setIcon(color: MLColor.accent)
        var on = true
        pulseTimer = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: true) { [weak self] _ in
            on.toggle()
            self?.setIcon(color: on ? MLColor.accent : MLColor.accent.withAlphaComponent(0.3))
        }
    }

    private func stopAnimations() {
        pulseTimer?.invalidate()
        pulseTimer = nil
    }
}
