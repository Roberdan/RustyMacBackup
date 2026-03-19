import Cocoa

class IconManager {
    private let statusItem: NSStatusItem
    private var pulseTimer: Timer?
    private var pulseState = false
    private(set) var currentState: AppState = .idle

    init(statusItem: NSStatusItem) {
        self.statusItem = statusItem
        setupIcon()
    }

    private func setupIcon() {
        guard let button = statusItem.button else { return }
        if let image = NSImage(systemSymbolName: "externaldrive.badge.timemachine",
                               accessibilityDescription: "RustyMacBackup") {
            image.isTemplate = true
            button.image = image
        }
    }

    func setState(_ state: AppState) {
        currentState = state
        stopAnimations()
        switch state {
        case .needsSetup:  setDotColor(MLColor.gold)
        case .idle:        setDotColor(MLColor.verde)
        case .running:     startRunningAnimation()
        case .error:       pulseError()
        case .diskAbsent:  setDotColor(MLColor.rosso)
        case .fdaMissing:  setDotColor(MLColor.warning)
        case .stale:       setDotColor(MLColor.warning)
        }
    }

    // Completion flash: bright green briefly then settle to normal verde
    func flashCompletion() {
        setDotColor(.green)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            self?.setDotColor(MLColor.verde)
        }
    }

    // Preference flash: brief blue, then restore current state
    func flashPreference() {
        setDotColor(MLColor.info)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self = self else { return }
            self.setState(self.currentState)
        }
    }

    // MARK: - Private

    private func startRunningAnimation() {
        pulseState = false
        setDotColor(MLColor.info)
        pulseTimer = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.pulseState.toggle()
            self.setDotColor(self.pulseState ? .cyan : MLColor.info)
        }
    }

    private func pulseError() {
        var count = 0
        setDotColor(MLColor.rosso)
        Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] timer in
            count += 1
            if count >= 4 {
                timer.invalidate()
                self?.setDotColor(MLColor.rosso)
            } else {
                self?.setDotColor(count % 2 == 0 ? MLColor.rosso : .clear)
            }
        }
    }

    private func setDotColor(_ color: NSColor) {
        guard let button = statusItem.button else { return }
        let size = NSSize(width: 22, height: 22)
        let image = NSImage(size: size, flipped: false) { _ in
            if let baseIcon = NSImage(systemSymbolName: "externaldrive.badge.timemachine",
                                      accessibilityDescription: nil) {
                baseIcon.draw(in: NSRect(x: 1, y: 3, width: 18, height: 18))
            }
            let dotRect = NSRect(x: 15, y: 1, width: 7, height: 7)
            color.setFill()
            NSBezierPath(ovalIn: dotRect).fill()
            NSColor.black.withAlphaComponent(0.3).setStroke()
            let border = NSBezierPath(ovalIn: dotRect.insetBy(dx: 0.5, dy: 0.5))
            border.lineWidth = 0.5
            border.stroke()
            return true
        }
        image.isTemplate = false
        button.image = image
    }

    private func stopAnimations() {
        pulseTimer?.invalidate()
        pulseTimer = nil
    }
}
