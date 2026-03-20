import Cocoa

protocol RestoreWindowDelegate: AnyObject {
    func restoreWindowDidConfirm(snapshotURL: URL, selectedItems: [String], brewInstall: Bool)
}

/// Standalone restore window with per-item checkboxes, conflict indicators,
/// and pre-restore backup guarantee. Opened from the popover.
class RestoreWindowController: NSWindowController {
    weak var restoreDelegate: RestoreWindowDelegate?
    private let snapshotURL: URL
    private let items: [RestoreItem]
    private let hasBrewfile: Bool
    private var checkboxes: [(path: String, checkbox: NSButton)] = []
    private var brewCheckbox: NSButton?

    init(snapshotURL: URL) {
        self.snapshotURL = snapshotURL
        self.items = RestoreEngine.scanSnapshot(at: snapshotURL)
        self.hasBrewfile = FileManager.default.fileExists(
            atPath: snapshotURL.appendingPathComponent("_environment/Brewfile").path)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 500),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered, defer: false)
        window.title = "Restore: \(snapshotURL.lastPathComponent)"
        window.center()
        window.isReleasedWhenClosed = false
        super.init(window: window)
        setupUI()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func setupUI() {
        guard let window = window else { return }

        let contentView = NSView(frame: window.contentView!.bounds)
        contentView.autoresizingMask = [.width, .height]
        window.contentView = contentView

        // Main vertical stack
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: contentView.topAnchor),
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
        ])

        // Header
        let header = NSTextField(labelWithString: "Select items to restore")
        header.font = .boldSystemFont(ofSize: 14)
        stack.addArrangedSubview(header)

        let subtitle = NSTextField(labelWithString:
            "Existing files will be backed up to ~/.rustybackup-pre-restore/ before overwriting.")
        subtitle.font = .systemFont(ofSize: 11)
        subtitle.textColor = .secondaryLabelColor
        subtitle.maximumNumberOfLines = 2
        subtitle.preferredMaxLayoutWidth = 388
        stack.addArrangedSubview(subtitle)

        // Select all / none
        let btnRow = NSStackView()
        btnRow.orientation = .horizontal
        btnRow.spacing = 8
        let selAll = NSButton(title: "Select All", target: self, action: #selector(selectAllItems))
        selAll.bezelStyle = .inline; selAll.font = .systemFont(ofSize: 11)
        let selNone = NSButton(title: "Select None", target: self, action: #selector(selectNone))
        selNone.bezelStyle = .inline; selNone.font = .systemFont(ofSize: 11)
        let selNew = NSButton(title: "New Only", target: self, action: #selector(selectNewOnly))
        selNew.bezelStyle = .inline; selNew.font = .systemFont(ofSize: 11)
        btnRow.addArrangedSubview(selAll)
        btnRow.addArrangedSubview(selNone)
        btnRow.addArrangedSubview(selNew)
        stack.addArrangedSubview(btnRow)

        addSep(to: stack)

        // Scrollable item list
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 200).isActive = true
        scrollView.widthAnchor.constraint(equalToConstant: 388).isActive = true

        let itemStack = NSStackView()
        itemStack.orientation = .vertical
        itemStack.alignment = .leading
        itemStack.spacing = 3
        itemStack.translatesAutoresizingMaskIntoConstraints = false

        for item in items {
            let row = NSStackView()
            row.orientation = .horizontal
            row.alignment = .centerY
            row.spacing = 6
            row.translatesAutoresizingMaskIntoConstraints = false
            row.widthAnchor.constraint(equalToConstant: 370).isActive = true

            let cb = NSButton(checkboxWithTitle: "", target: nil, action: nil)
            cb.state = .on
            row.addArrangedSubview(cb)

            let icon: String
            if item.existsAtDest {
                icon = "~"  // will overwrite
            } else {
                icon = "+"  // new
            }

            let label = NSTextField(labelWithString: "~/\(item.relativePath)")
            label.font = .systemFont(ofSize: 12)
            label.textColor = .labelColor
            label.lineBreakMode = .byTruncatingMiddle
            row.addArrangedSubview(label)

            let spacer = NSView()
            spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
            row.addArrangedSubview(spacer)

            let status = NSTextField(labelWithString: item.existsAtDest ? "overwrite" : "new")
            status.font = .systemFont(ofSize: 10)
            status.textColor = item.existsAtDest ? .systemOrange : .systemGreen
            row.addArrangedSubview(status)

            itemStack.addArrangedSubview(row)
            checkboxes.append((item.relativePath, cb))
        }

        let clipView = NSClipView()
        clipView.documentView = itemStack
        clipView.drawsBackground = false
        scrollView.contentView = clipView
        stack.addArrangedSubview(scrollView)

        // Brewfile option
        if hasBrewfile {
            addSep(to: stack)
            let bc = NSButton(checkboxWithTitle: "Reinstall Homebrew packages (brew bundle install)",
                              target: nil, action: nil)
            bc.state = .on
            bc.font = .systemFont(ofSize: 12)
            brewCheckbox = bc
            stack.addArrangedSubview(bc)
        }

        addSep(to: stack)

        // Bottom buttons
        let bottomRow = NSStackView()
        bottomRow.orientation = .horizontal
        bottomRow.spacing = 8
        bottomRow.translatesAutoresizingMaskIntoConstraints = false
        bottomRow.widthAnchor.constraint(equalToConstant: 388).isActive = true

        let countLabel = NSTextField(labelWithString: "\(items.count) items")
        countLabel.font = .systemFont(ofSize: 11)
        countLabel.textColor = .secondaryLabelColor
        bottomRow.addArrangedSubview(countLabel)

        let bspacer = NSView()
        bspacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        bottomRow.addArrangedSubview(bspacer)

        let cancelBtn = NSButton(title: "Cancel", target: self, action: #selector(cancelTapped))
        cancelBtn.bezelStyle = .rounded
        cancelBtn.keyEquivalent = "\u{1b}" // Escape
        bottomRow.addArrangedSubview(cancelBtn)

        let restoreBtn = NSButton(title: "Restore Selected", target: self, action: #selector(restoreConfirmed))
        restoreBtn.bezelStyle = .rounded
        restoreBtn.keyEquivalent = "\r" // Enter
        bottomRow.addArrangedSubview(restoreBtn)

        stack.addArrangedSubview(bottomRow)
    }

    // MARK: - Actions

    @objc private func selectAllItems() {
        checkboxes.forEach { $0.checkbox.state = .on }
    }

    @objc private func selectNone() {
        checkboxes.forEach { $0.checkbox.state = .off }
    }

    @objc private func selectNewOnly() {
        let existingPaths = Set(items.filter(\.existsAtDest).map(\.relativePath))
        for (path, cb) in checkboxes {
            cb.state = existingPaths.contains(path) ? .off : .on
        }
    }

    @objc private func cancelTapped() {
        window?.close()
    }

    @objc private func restoreConfirmed() {
        let selected = checkboxes.filter { $0.checkbox.state == .on }.map(\.path)
        guard !selected.isEmpty else {
            window?.close()
            return
        }

        let overwrites = selected.filter { path in
            items.first(where: { $0.relativePath == path })?.existsAtDest == true
        }

        if !overwrites.isEmpty {
            let alert = NSAlert()
            alert.messageText = "Overwrite \(overwrites.count) existing files?"
            alert.informativeText = "Originals will be saved to ~/.rustybackup-pre-restore/ so you can undo."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Overwrite & Restore")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }

        let brew = brewCheckbox?.state == .on
        window?.close()
        restoreDelegate?.restoreWindowDidConfirm(
            snapshotURL: snapshotURL, selectedItems: selected, brewInstall: brew)
    }

    private func addSep(to stack: NSStackView) {
        let sep = NSBox(); sep.boxType = .separator
        sep.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(sep)
        sep.widthAnchor.constraint(equalToConstant: 388).isActive = true
    }
}
