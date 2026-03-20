import Cocoa

protocol PopoverDelegate: AnyObject {
    func popoverDidRequestBackup()
    func popoverDidRequestStop()
    func popoverDidRequestEject()
    func popoverDidRequestOpenFolder()
    func popoverDidRequestAddFolder()
    func popoverDidSelectDisk(_ volumeURL: URL)
    func popoverDidTogglePath(_ path: String, enabled: Bool)
    func popoverDidRequestRestore(_ snapshotURL: URL, items: [String], brewInstall: Bool)
    func popoverDidRequestUndoRestore()
    func popoverDidRequestQuit()
    func popoverGetState() -> AppState
    func popoverGetStatus() -> BackupStatusFile?
    func popoverGetConfig() -> Config?
}

class PopoverViewController: NSViewController, ToolToggleDelegate, RestoreWindowDelegate {
    weak var popoverDelegate: PopoverDelegate?

    private let outerStack = NSStackView()
    private let headerLabel = NSTextField(labelWithString: "RustyMacBackup")
    private let statusLabel = NSTextField(labelWithString: "")
    private let backupButton = NSButton()
    private let progressBar = ProgressBarView()
    private let progressLabel = NSTextField(labelWithString: "")
    private let statsLabel = NSTextField(labelWithString: "")
    private var diskStack = NSStackView()
    private let diskHeader = NSTextField(labelWithString: "")
    private var restoreStack = NSStackView()
    private let restoreHeader = NSTextField(labelWithString: "")
    private let toolsHeaderRow = NSStackView()
    private let toolsHeaderLabel = NSTextField(labelWithString: "")
    private var toolsScroll = NSScrollView()
    private var toolsStack = NSStackView()
    private var categoryViews: [ToolsCategoryView] = []
    private var undoRestoreButton: NSButton?
    private var isSetupComplete = false

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 480))
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
        refresh()
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        refresh()
    }

    private func setupUI() {
        // Vibrancy background
        let effect = NSVisualEffectView()
        effect.blendingMode = .behindWindow
        effect.material = .popover
        effect.state = .active
        effect.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(effect)
        pin(effect, to: view)

        outerStack.orientation = .vertical
        outerStack.alignment = .leading
        outerStack.spacing = 4
        outerStack.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
        outerStack.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(outerStack)
        pin(outerStack, to: effect)

        // -- Header row --
        let headerRow = makeRow()
        headerLabel.font = .boldSystemFont(ofSize: 15)
        headerLabel.textColor = .labelColor
        headerRow.addArrangedSubview(headerLabel)
        headerRow.addArrangedSubview(hSpacer())
        backupButton.bezelStyle = .rounded
        backupButton.controlSize = .regular
        backupButton.target = self
        backupButton.action = #selector(backupTapped)
        headerRow.addArrangedSubview(backupButton)
        addToOuter(headerRow)

        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = MLColor.secondary
        addToOuter(statusLabel)
        addSep()

        // -- Stats --
        statsLabel.font = .systemFont(ofSize: 12)
        statsLabel.textColor = .labelColor
        statsLabel.maximumNumberOfLines = 2
        addToOuter(statsLabel)

        // -- Progress --
        progressBar.translatesAutoresizingMaskIntoConstraints = false
        progressBar.heightAnchor.constraint(equalToConstant: 18).isActive = true
        progressBar.widthAnchor.constraint(equalToConstant: 292).isActive = true
        addToOuter(progressBar)
        progressLabel.font = .systemFont(ofSize: 11)
        progressLabel.textColor = MLColor.secondary
        addToOuter(progressLabel)
        addSep()

        // -- Disk selection (setup only) --
        diskHeader.font = .systemFont(ofSize: 12, weight: .semibold)
        diskHeader.textColor = .labelColor
        diskHeader.stringValue = "Select Backup Disk"
        addToOuter(diskHeader)
        diskStack.orientation = .vertical
        diskStack.alignment = .leading
        diskStack.spacing = 4
        addToOuter(diskStack)
        addSep()

        // -- Restore section (visible when backups found but no config) --
        restoreHeader.font = .systemFont(ofSize: 12, weight: .semibold)
        restoreHeader.textColor = .labelColor
        restoreHeader.stringValue = "Restore from Backup"
        addToOuter(restoreHeader)
        restoreStack.orientation = .vertical
        restoreStack.alignment = .leading
        restoreStack.spacing = 4
        addToOuter(restoreStack)
        addSep()

        // -- Tools section header --
        toolsHeaderRow.orientation = .horizontal
        toolsHeaderRow.alignment = .centerY
        toolsHeaderRow.spacing = 8
        toolsHeaderRow.translatesAutoresizingMaskIntoConstraints = false
        toolsHeaderRow.widthAnchor.constraint(equalToConstant: 292).isActive = true
        toolsHeaderLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        toolsHeaderLabel.textColor = .labelColor
        toolsHeaderRow.addArrangedSubview(toolsHeaderLabel)
        toolsHeaderRow.addArrangedSubview(hSpacer())
        let selectAllBtn = NSButton(title: "All", target: self, action: #selector(selectAllTapped))
        selectAllBtn.bezelStyle = .inline
        selectAllBtn.font = .systemFont(ofSize: 11, weight: .medium)
        toolsHeaderRow.addArrangedSubview(selectAllBtn)
        let addBtn = NSButton(title: "+ Add", target: self, action: #selector(addFolderTapped))
        addBtn.bezelStyle = .inline
        addBtn.font = .systemFont(ofSize: 11, weight: .medium)
        toolsHeaderRow.addArrangedSubview(addBtn)
        addToOuter(toolsHeaderRow)

        // -- Scrollable tools list --
        toolsStack.orientation = .vertical
        toolsStack.alignment = .leading
        toolsStack.spacing = 6
        toolsStack.translatesAutoresizingMaskIntoConstraints = false

        let clipView = NSClipView()
        clipView.documentView = toolsStack
        clipView.drawsBackground = false
        toolsScroll.contentView = clipView
        toolsScroll.drawsBackground = false
        toolsScroll.hasVerticalScroller = true
        toolsScroll.autohidesScrollers = true
        toolsScroll.borderType = .noBorder
        toolsScroll.translatesAutoresizingMaskIntoConstraints = false
        toolsScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 60).isActive = true
        toolsScroll.heightAnchor.constraint(lessThanOrEqualToConstant: 220).isActive = true
        toolsScroll.widthAnchor.constraint(equalToConstant: 292).isActive = true
        addToOuter(toolsScroll)
        addSep()

        // -- Actions --
        addAction("Open Backup Folder", icon: "folder", action: #selector(openFolderTapped))
        addAction("Eject Disk", icon: "eject", action: #selector(ejectTapped))
        let undoBtn = NSButton(title: "Undo Last Restore", target: self, action: #selector(undoRestoreTapped))
        undoBtn.bezelStyle = .inline
        undoBtn.isBordered = false
        undoBtn.font = .systemFont(ofSize: 13)
        undoBtn.alignment = .left
        undoBtn.contentTintColor = MLColor.warning
        if let img = NSImage(systemSymbolName: "arrow.uturn.backward", accessibilityDescription: "Undo Restore") {
            undoBtn.image = img
            undoBtn.imagePosition = .imageLeading
        }
        undoRestoreButton = undoBtn
        addToOuter(undoBtn)
        addSep()
        addAction("Quit", icon: "power", action: #selector(quitTapped), key: "q")

        isSetupComplete = true
    }

    // MARK: - Refresh

    func refresh() {
        guard isSetupComplete, let delegate = popoverDelegate else { return }
        let state = delegate.popoverGetState()
        let status = delegate.popoverGetStatus()
        let config = delegate.popoverGetConfig()

        // Header button
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
            statsLabel.stringValue = "Last: \(Fmt.timeAgo(from: s.lastCompleted))  --  \(Fmt.formatFileCount(s.filesTotal)) files  --  \(Fmt.formatBytes(s.bytesCopied))"
        } else {
            statsLabel.stringValue = "No backups yet"
        }
        if let c = config {
            let (free, total) = DiskDiagnostics.diskSpace(at: c.destination.path)
            if total > 0 {
                let vol = URL(fileURLWithPath: c.destination.path).deletingLastPathComponent().lastPathComponent
                statsLabel.stringValue += "\n\(vol): \(Fmt.formatBytes(free)) free / \(Fmt.formatBytes(total))"
            }
        }

        // Disk selection (setup mode only)
        let showDisks = state == .needsSetup
        diskHeader.isHidden = !showDisks
        diskStack.isHidden = !showDisks
        if showDisks { rebuildDiskList() }

        // Restore section -- check for backups but don't crash if volumes are in flux
        var backups: [(volume: String, backupDir: URL, snapshots: [String])] = []
        if let config = config, FileManager.default.fileExists(atPath: config.destination.path) {
            backups = RestoreEngine.findBackupSnapshots()
        }
        let showRestore = !backups.isEmpty && state != .needsSetup
        restoreHeader.isHidden = !showRestore
        restoreStack.isHidden = !showRestore
        if showRestore { rebuildRestoreList(backups: backups) }

        // Progress
        let running = state == .running
        isBackupRunning = running
        progressBar.isHidden = !running
        progressLabel.isHidden = !running
        if running, let s = status {
            if s.filesTotal > 0 { progressBar.progress = CGFloat(s.filesDone) / CGFloat(s.filesTotal) }
            let pct = s.filesTotal > 0 ? "\(Int(Double(s.filesDone) / Double(s.filesTotal) * 100))%" : ""
            progressLabel.stringValue = "\(pct)  \(Fmt.formatBytes(s.bytesPerSec))/s  \(s.etaSecs > 0 ? "ETA: \(Fmt.formatDuration(Double(s.etaSecs)))" : "scanning...")"
        }

        // Undo restore -- visible only if pre-restore backups exist
        undoRestoreButton?.isHidden = !RestoreEngine.hasPreRestoreBackup()

        // Tools -- rebuild list (skip during running to avoid flicker, but show if empty)
        if !running || categoryViews.isEmpty { rebuildToolsList(config: config) }
    }

    // MARK: - Tools list with categories

    private var isBackupRunning = false

    private func rebuildToolsList(config: Config?) {
        categoryViews.forEach { $0.removeFromSuperview() }
        categoryViews.removeAll()
        toolsStack.arrangedSubviews.forEach { toolsStack.removeArrangedSubview($0); $0.removeFromSuperview() }

        let discovered = ConfigDiscovery.discover()
        let enabledPaths = Set(config?.source.paths ?? [])
        let pathCount = enabledPaths.count
        toolsHeaderLabel.stringValue = "Backup Sources (\(pathCount))"

        // Group by category
        var grouped: [(category: String, items: [(label: String, paths: [String], sensitive: Bool)])] = []
        var seen: [String: Int] = [:]
        for item in discovered {
            if let idx = seen[item.category] {
                grouped[idx].items.append((item.label, item.paths, item.sensitive))
            } else {
                seen[item.category] = grouped.count
                grouped.append((item.category, [(item.label, item.paths, item.sensitive)]))
            }
        }

        // Custom paths not in any discovered tool
        let allDiscoveredPaths = Set(discovered.flatMap(\.paths))
        let customPaths = (config?.source.paths ?? []).filter { !allDiscoveredPaths.contains($0) }
        if !customPaths.isEmpty {
            let customItems = customPaths.map { (label: ConfigDiscovery.contract(ConfigDiscovery.expand($0)),
                                                  paths: [$0], sensitive: false) }
            grouped.append(("Custom Folders", customItems))
        }

        for group in grouped {
            let catView = ToolsCategoryView(category: group.category)
            catView.toggleDelegate = self
            catView.isReadOnly = isBackupRunning
            catView.configure(items: group.items, enabledPaths: enabledPaths)
            catView.translatesAutoresizingMaskIntoConstraints = false
            toolsStack.addArrangedSubview(catView)
            categoryViews.append(catView)
        }
    }

    // MARK: - RestoreWindowDelegate

    func restoreWindowDidConfirm(snapshotURL: URL, selectedItems: [String], brewInstall: Bool) {
        restoreWindowController = nil
        popoverDelegate?.popoverDidRequestRestore(snapshotURL, items: selectedItems, brewInstall: brewInstall)
    }

    // MARK: - ToolToggleDelegate

    func toolPathToggled(_ path: String, enabled: Bool) {
        popoverDelegate?.popoverDidTogglePath(path, enabled: enabled)
        // Refresh immediately to update counts
        DispatchQueue.main.async { [weak self] in self?.refresh() }
    }

    // MARK: - Restore

    private var foundBackups: [(volume: String, backupDir: URL, snapshots: [String])] = []

    private func rebuildRestoreList(backups: [(volume: String, backupDir: URL, snapshots: [String])]) {
        restoreStack.arrangedSubviews.forEach { restoreStack.removeArrangedSubview($0); $0.removeFromSuperview() }
        foundBackups = backups

        for (i, backup) in backups.enumerated() {
            guard let latest = backup.snapshots.first else { continue }
            let snapshotURL = backup.backupDir.appendingPathComponent(latest)
            let items = RestoreEngine.scanSnapshot(at: snapshotURL)
            let hasBrewfile = FileManager.default.fileExists(
                atPath: snapshotURL.appendingPathComponent("_environment/Brewfile").path)
            let conflictCount = items.filter(\.existsAtDest).count

            let row = NSStackView()
            row.orientation = .horizontal
            row.alignment = .centerY
            row.spacing = 6
            row.translatesAutoresizingMaskIntoConstraints = false
            row.widthAnchor.constraint(equalToConstant: 272).isActive = true

            let info = NSTextField(labelWithString:
                "\(backup.volume): \(latest)\n\(items.count) items\(hasBrewfile ? " + Brew" : "")\(conflictCount > 0 ? " (\(conflictCount) exist)" : "")")
            info.font = .systemFont(ofSize: 10)
            info.textColor = MLColor.secondary
            info.maximumNumberOfLines = 2
            row.addArrangedSubview(info)

            let sp = NSView()
            sp.setContentHuggingPriority(.defaultLow, for: .horizontal)
            row.addArrangedSubview(sp)

            let btn = NSButton(title: "Restore", target: self, action: #selector(restoreTapped(_:)))
            btn.bezelStyle = .rounded
            btn.font = .systemFont(ofSize: 11, weight: .medium)
            btn.tag = i
            row.addArrangedSubview(btn)

            restoreStack.addArrangedSubview(row)
        }
    }

    private var restoreWindowController: RestoreWindowController?

    @objc private func restoreTapped(_ sender: NSButton) {
        guard sender.tag < foundBackups.count else { return }
        let backup = foundBackups[sender.tag]
        guard let latest = backup.snapshots.first else { return }
        let snapshotURL = backup.backupDir.appendingPathComponent(latest)

        // Open restore window with per-item selection
        let wc = RestoreWindowController(snapshotURL: snapshotURL)
        wc.restoreDelegate = self
        wc.showWindow(nil)
        wc.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        restoreWindowController = wc  // retain
    }

    // MARK: - Disk selection

    private func rebuildDiskList() {
        diskStack.arrangedSubviews.forEach { diskStack.removeArrangedSubview($0); $0.removeFromSuperview() }
        let volumes = discoverVolumes()
        if volumes.isEmpty {
            let lbl = NSTextField(labelWithString: "No external disk connected")
            lbl.font = .systemFont(ofSize: 11)
            lbl.textColor = MLColor.error
            diskStack.addArrangedSubview(lbl)
            return
        }
        for (i, vol) in volumes.enumerated() {
            let (free, total) = DiskDiagnostics.diskSpace(at: vol.path)
            let btn = NSButton(title: "\(vol.lastPathComponent)  --  \(free / 1_073_741_824) / \(total / 1_073_741_824) GB",
                               target: self, action: #selector(diskSelected(_:)))
            btn.bezelStyle = .rounded
            btn.font = .systemFont(ofSize: 12)
            btn.tag = i
            btn.translatesAutoresizingMaskIntoConstraints = false
            btn.widthAnchor.constraint(equalToConstant: 272).isActive = true
            diskStack.addArrangedSubview(btn)
        }
    }

    private func discoverVolumes() -> [URL] {
        guard let vols = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: [.volumeNameKey],
            options: [.skipHiddenVolumes]) else { return [] }
        return vols.filter { u in
            let p = u.path
            return p != "/" && p != "/System/Volumes/Data"
                && u.lastPathComponent != "Macintosh HD" && p.hasPrefix("/Volumes/")
        }
    }

    // MARK: - Actions

    @objc private func diskSelected(_ sender: NSButton) {
        let vols = discoverVolumes()
        guard sender.tag < vols.count else { return }
        popoverDelegate?.popoverDidSelectDisk(vols[sender.tag])
    }

    @objc private func undoRestoreTapped() {
        guard let latest = RestoreEngine.latestPreRestoreBackup() else { return }
        let items = RestoreEngine.scanPreRestoreBackup(at: latest)

        let alert = NSAlert()
        alert.messageText = "Undo last restore?"
        var details = "This will restore \(items.count) original files from before the last restore:\n"
        for item in items.prefix(10) {
            details += "\n  ~/\(item)"
        }
        if items.count > 10 { details += "\n  ... and \(items.count - 10) more" }
        details += "\n\nThe restored versions will be overwritten with your originals."
        alert.informativeText = details
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Undo Restore")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        popoverDelegate?.popoverDidRequestUndoRestore()
    }

    @objc private func selectAllTapped() {
        let discovered = ConfigDiscovery.discover()
        for item in discovered {
            for path in item.paths {
                popoverDelegate?.popoverDidTogglePath(path, enabled: true)
            }
        }
        refresh()
    }

    @objc private func backupTapped() {
        guard let d = popoverDelegate else { return }
        d.popoverGetState() == .running ? d.popoverDidRequestStop() : d.popoverDidRequestBackup()
    }

    @objc private func addFolderTapped() { popoverDelegate?.popoverDidRequestAddFolder() }
    @objc private func openFolderTapped() { popoverDelegate?.popoverDidRequestOpenFolder() }
    @objc private func ejectTapped() { popoverDelegate?.popoverDidRequestEject() }
    @objc private func quitTapped() { popoverDelegate?.popoverDidRequestQuit() }

    // MARK: - Layout

    private func addToOuter(_ v: NSView) {
        v.translatesAutoresizingMaskIntoConstraints = false
        outerStack.addArrangedSubview(v)
    }

    private func addSep() {
        let sep = NSBox(); sep.boxType = .separator
        sep.translatesAutoresizingMaskIntoConstraints = false
        outerStack.addArrangedSubview(sep)
        sep.widthAnchor.constraint(equalToConstant: 292).isActive = true
    }

    private func addAction(_ title: String, icon: String, action: Selector, key: String = "") {
        let btn = NSButton(title: title, target: self, action: action)
        btn.bezelStyle = .inline; btn.isBordered = false
        btn.font = .systemFont(ofSize: 13); btn.alignment = .left
        btn.keyEquivalent = key
        if !key.isEmpty { btn.keyEquivalentModifierMask = .command }
        if let img = NSImage(systemSymbolName: icon, accessibilityDescription: title) {
            btn.image = img; btn.imagePosition = .imageLeading
        }
        addToOuter(btn)
    }

    private func makeRow() -> NSStackView {
        let r = NSStackView(); r.orientation = .horizontal
        r.alignment = .centerY; r.spacing = 8
        r.translatesAutoresizingMaskIntoConstraints = false
        r.widthAnchor.constraint(equalToConstant: 292).isActive = true
        return r
    }

    private func hSpacer() -> NSView {
        let s = NSView(); s.setContentHuggingPriority(.defaultLow, for: .horizontal); return s
    }

    private func pin(_ child: NSView, to parent: NSView) {
        NSLayoutConstraint.activate([
            child.topAnchor.constraint(equalTo: parent.topAnchor),
            child.bottomAnchor.constraint(equalTo: parent.bottomAnchor),
            child.leadingAnchor.constraint(equalTo: parent.leadingAnchor),
            child.trailingAnchor.constraint(equalTo: parent.trailingAnchor),
        ])
    }
}
