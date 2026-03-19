import Cocoa

class IconManager {
    private let statusItem: NSStatusItem
    private var pulseTimer: Timer?
    private var pulseState = false
    private(set) var currentState: AppState = .idle

    init(statusItem: NSStatusItem) {
        self.statusItem = statusItem
        setDotColor(nil)
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

    func flashCompletion() {
        setDotColor(.green)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            self?.setDotColor(MLColor.verde)
        }
    }

    func flashPreference() {
        setDotColor(MLColor.info)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self = self else { return }
            self.setState(self.currentState)
        }
    }

    // MARK: - Icon Composition (ported from pre-migration menu bar app)

    private func setDotColor(_ dotColor: NSColor?) {
        guard let button = statusItem.button else { return }

        let symConfig = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular, scale: .medium)
        guard let baseSymbol = NSImage(systemSymbolName: "clock.arrow.circlepath",
                                        accessibilityDescription: "RustyMacBackup")?
                .withSymbolConfiguration(symConfig) else { return }
        baseSymbol.isTemplate = true

        guard let dotColor = dotColor else {
            button.image = baseSymbol
            return
        }

        let baseSize = baseSymbol.size
        let totalWidth = baseSize.width + 5
        let finalSize = NSSize(width: totalWidth, height: baseSize.height)

        let composite = NSImage(size: finalSize, flipped: false) { _ in
            let iconColor = NSAppearance.currentDrawing().bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor.white : NSColor.black
            let tinted = baseSymbol.copy() as! NSImage
            tinted.isTemplate = false
            tinted.lockFocus()
            iconColor.set()
            NSRect(origin: .zero, size: baseSize).fill(using: .sourceAtop)
            tinted.unlockFocus()
            tinted.draw(in: NSRect(x: 0, y: 0, width: baseSize.width, height: baseSize.height))

            let dotD: CGFloat = 6
            let dotX = totalWidth - dotD - 0.5
            let dotY: CGFloat = 0.5
            let dotRect = NSRect(x: dotX, y: dotY, width: dotD, height: dotD)

            let outlineRect = dotRect.insetBy(dx: -1.2, dy: -1.2)
            let bgColor = NSAppearance.currentDrawing().bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(white: 0.15, alpha: 1) : NSColor.white
            bgColor.setFill()
            NSBezierPath(ovalIn: outlineRect).fill()

            dotColor.setFill()
            NSBezierPath(ovalIn: dotRect).fill()

            return true
        }
        composite.isTemplate = false
        button.image = composite
    }

    // MARK: - Animations

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

    private func stopAnimations() {
        pulseTimer?.invalidate()
        pulseTimer = nil
    }
}
