import Cocoa

protocol PopoverDelegate: AnyObject {
    func popoverDidRequestBackup()
    func popoverDidRequestStop()
    func popoverDidRequestEject()
    func popoverDidRequestOpenFolder()
    func popoverDidRequestAddFolder()
    func popoverDidTogglePath(_ path: String, enabled: Bool)
    func popoverDidRequestQuit()
    func popoverGetState() -> AppState
    func popoverGetStatus() -> BackupStatusFile?
    func popoverGetConfig() -> Config?
}

class PopoverViewController: NSViewController {
    weak var popoverDelegate: PopoverDelegate?
    private var updateTimer: Timer?

    private let stack = NSStackView()
    private let headerLabel = NSTextField(labelWithString: "RustyMacBackup")
    private let statusLabel = NSTextField(labelWithString: "")
    private let backupButton = NSButton()
    private let progressBar = ProgressBarView()
    private let progressLabel = NSTextField(labelWithString: "")
    private let statsLabel = NSTextField(labelWithString: "")
    private var folderStack = NSStackView()
    private let folderHeader = NSTextField(labelWithString: "")

    override func loadView() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 400))
        self.view = container
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
        refresh()
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        refresh()
        updateTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        updateTimer?.invalidate()
        updateTimer = nil
    }

    private func setupUI() {
        let effect = NSVisualEffectView()
        effect.blendingMode = .behindWindow
        effect.material = .popover
        effect.state = .active
        effect.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(effect)
        NSLayoutConstraint.activate([
            effect.topAnchor.constraint(equalTo: view.topAnchor),
            effect.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            effect.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            effect.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: effect.topAnchor),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: effect.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
        ])

        // Header row
        let headerRow = makeRow()
        headerLabel.font = .boldSystemFont(ofSize: 15)
        headerLabel.textColor = .labelColor
        headerRow.addArrangedSubview(headerLabel)
        headerRow.addArrangedSubview(spacer())
        backupButton.bezelStyle = .rounded
        backupButton.controlSize = .regular
        backupButton.target = self
        backupButton.action = #selector(backupTapped)
        headerRow.addArrangedSubview(backupButton)
        addRow(headerRow)

        // Status
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = MLColor.secondary
        addRow(statusLabel)
        addSeparator()

        // Stats row
        statsLabel.font = .systemFont(ofSize: 12)
        statsLabel.textColor = .labelColor
        statsLabel.maximumNumberOfLines = 2
        addRow(statsLabel)

        // Progress (hidden when idle)
        progressBar.translatesAutoresizingMaskIntoConstraints = false
        progressBar.heightAnchor.constraint(equalToConstant: 20).isActive = true
        progressBar.widthAnchor.constraint(equalToConstant: 288).isActive = true
        addRow(progressBar)

        progressLabel.font = .systemFont(ofSize: 11)
        progressLabel.textColor = MLColor.secondary
        addRow(progressLabel)
        addSeparator()

        // Folders section
        let folderTitleRow = makeRow()
        folderHeader.font = .systemFont(ofSize: 12, weight: .semibold)
        folderHeader.textColor = .labelColor
        folderTitleRow.addArrangedSubview(folderHeader)
        folderTitleRow.addArrangedSubview(spacer())
        let addBtn = NSButton(title: "+", target: self, action: #selector(addFolderTapped))
        addBtn.bezelStyle = .inline
        addBtn.font = .systemFont(ofSize: 12, weight: .bold)
        folderTitleRow.addArrangedSubview(addBtn)
        addRow(folderTitleRow)

        folderStack.orientation = .vertical
        folderStack.alignment = .leading
        folderStack.spacing = 2
        addRow(folderStack)
        addSeparator()

        // Action buttons
        addActionRow("Open Backup Folder", icon: "folder", action: #selector(openFolderTapped))
        addActionRow("Eject Disk", icon: "eject", action: #selector(ejectTapped))
        addSeparator()
        addActionRow("Quit", icon: "power", action: #selector(quitTapped), key: "q")
    }

    func refresh() {
        guard let delegate = popoverDelegate else { return }
        let state = delegate.popoverGetState()
        let status = delegate.popoverGetStatus()
        let config = delegate.popoverGetConfig()

        // Status label + button
        switch state {
        case .needsSetup:
            statusLabel.stringValue = "Setup required -- select backup disk"
            backupButton.title = "Setup"
            backupButton.isEnabled = false
        case .idle:
            statusLabel.stringValue = "Ready"
            backupButton.title = "Backup Now"
            backupButton.isEnabled = true
        case .running:
            statusLabel.stringValue = "Backup in progress..."
            backupButton.title = "Stop"
            backupButton.isEnabled = true
        case .error:
            statusLabel.stringValue = "Last backup failed"
            backupButton.title = "Retry"
            backupButton.isEnabled = true
        case .diskAbsent:
            let name = config.map {
                URL(fileURLWithPath: $0.destination.path).deletingLastPathComponent().lastPathComponent
            } ?? "disk"
            statusLabel.stringValue = "Disk \"\(name)\" not connected"
            backupButton.title = "Backup Now"
            backupButton.isEnabled = false
        case .stale:
            statusLabel.stringValue = "Backup overdue (>24h)"
            backupButton.title = "Backup Now"
            backupButton.isEnabled = true
        }

        // Stats
        if let s = status, !s.lastCompleted.isEmpty {
            let timeAgo = Fmt.timeAgo(from: s.lastCompleted)
            let bytes = Fmt.formatBytes(s.bytesCopied)
            let files = Fmt.formatFileCount(s.filesTotal)
            statsLabel.stringValue = "Last: \(timeAgo)  --  \(files) files  --  \(bytes)"
        } else {
            statsLabel.stringValue = "No backups yet"
        }

        // Disk space
        if let c = config {
            let (free, total) = DiskDiagnostics.diskSpace(at: c.destination.path)
            if total > 0 {
                let volName = URL(fileURLWithPath: c.destination.path)
                    .deletingLastPathComponent().lastPathComponent
                statsLabel.stringValue += "\n\(volName): \(Fmt.formatBytes(free)) free / \(Fmt.formatBytes(total))"
            }
        }

        // Progress
        let isRunning = state == .running
        progressBar.isHidden = !isRunning
        progressLabel.isHidden = !isRunning
        if isRunning, let s = status {
            if s.filesTotal > 0 {
                progressBar.progress = CGFloat(s.filesDone) / CGFloat(s.filesTotal)
            }
            let speed = Fmt.formatBytes(s.bytesPerSec) + "/s"
            let eta = s.etaSecs > 0 ? "ETA: \(Fmt.formatDuration(Double(s.etaSecs)))" : "scanning..."
            let pct = s.filesTotal > 0 ? "\(Int(Double(s.filesDone) / Double(s.filesTotal) * 100))%" : ""
            progressLabel.stringValue = "\(pct)  \(speed)  \(eta)"
        }

        // Folders
        rebuildFolderList(config: config)
    }

    private func rebuildFolderList(config: Config?) {
        for v in folderStack.arrangedSubviews { folderStack.removeArrangedSubview(v); v.removeFromSuperview() }

        guard let paths = config?.source.paths else {
            folderHeader.stringValue = "Backup Folders (0)"
            return
        }
        folderHeader.stringValue = "Backup Folders (\(paths.count))"

        for path in paths.prefix(15) {
            let display = ConfigDiscovery.contract(ConfigDiscovery.expand(path))
            let label = NSTextField(labelWithString: display)
            label.font = .systemFont(ofSize: 11)
            label.textColor = MLColor.secondary
            label.lineBreakMode = .byTruncatingMiddle
            label.widthAnchor.constraint(lessThanOrEqualToConstant: 270).isActive = true
            folderStack.addArrangedSubview(label)
        }
        if paths.count > 15 {
            let more = NSTextField(labelWithString: "... and \(paths.count - 15) more")
            more.font = .systemFont(ofSize: 10)
            more.textColor = MLColor.tertiary
            folderStack.addArrangedSubview(more)
        }
    }

    // MARK: - Actions

    @objc private func backupTapped() {
        guard let delegate = popoverDelegate else { return }
        if delegate.popoverGetState() == .running {
            delegate.popoverDidRequestStop()
        } else {
            delegate.popoverDidRequestBackup()
        }
    }

    @objc private func addFolderTapped() {
        popoverDelegate?.popoverDidRequestAddFolder()
    }

    @objc private func openFolderTapped() {
        popoverDelegate?.popoverDidRequestOpenFolder()
    }

    @objc private func ejectTapped() {
        popoverDelegate?.popoverDidRequestEject()
    }

    @objc private func quitTapped() {
        popoverDelegate?.popoverDidRequestQuit()
    }

    // MARK: - Layout helpers

    private func addRow(_ v: NSView) {
        v.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(v)
        if let textField = v as? NSTextField {
            textField.widthAnchor.constraint(lessThanOrEqualToConstant: 288).isActive = true
        }
    }

    private func addSeparator() {
        let sep = NSBox()
        sep.boxType = .separator
        sep.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(sep)
        sep.widthAnchor.constraint(equalToConstant: 288).isActive = true
    }

    private func addActionRow(_ title: String, icon: String, action: Selector, key: String = "") {
        let btn = NSButton(title: title, target: self, action: action)
        btn.bezelStyle = .inline
        btn.font = .systemFont(ofSize: 13)
        btn.isBordered = false
        btn.alignment = .left
        btn.keyEquivalent = key
        if !key.isEmpty { btn.keyEquivalentModifierMask = .command }
        if let img = NSImage(systemSymbolName: icon, accessibilityDescription: title) {
            btn.image = img
            btn.imagePosition = .imageLeading
        }
        addRow(btn)
    }

    private func makeRow() -> NSStackView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false
        row.widthAnchor.constraint(equalToConstant: 288).isActive = true
        return row
    }

    private func spacer() -> NSView {
        let s = NSView()
        s.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return s
    }
}
