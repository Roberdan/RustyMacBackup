import Cocoa

protocol PopoverDelegate: AnyObject {
    func popoverDidRequestStop()
    func popoverDidRequestEject()
    func popoverDidRequestOpenFolder()
    func popoverDidSelectDisk(_ volumeURL: URL)
    func popoverDidRequestQuit()
    func popoverDidStartBackup(selectedPaths: [String])
    func popoverDidStartRestore(snapshotURL: URL, items: [String], brewInstall: Bool)
    func popoverDidTogglePath(_ path: String, enabled: Bool)
    func popoverDidRequestUndoRestore()
    func popoverGetState() -> AppState
    func popoverGetStatus() -> BackupStatusFile?
    func popoverGetConfig() -> Config?
}

class PopoverViewController: NSViewController, TreeWindowDelegate {
    weak var popoverDelegate: PopoverDelegate?
    private var isSetupDone = false
    private var treeWindow: TreeWindowController?

    // UI elements
    private let outerStack = NSStackView()
    private let headerLabel = NSTextField(labelWithString: "RustyMacBackup")
    private let statusLabel = NSTextField(labelWithString: "")
    private let statsLabel = NSTextField(labelWithString: "")
    private let progressBar = ProgressBarView()
    private let progressLabel = NSTextField(labelWithString: "")
    private var diskStack = NSStackView()
    private let diskHeader = NSTextField(labelWithString: "")
    private var restoreRow: NSView?
    private var undoBtn: NSButton?
    private var backupBtn: NSButton!
    private var stopBtn: NSButton!

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 340))
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        buildUI()
        isSetupDone = true
        refresh()
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        refresh()
    }

    // MARK: - Build

    private func buildUI() {
        let effect = NSVisualEffectView()
        effect.blendingMode = .behindWindow
        effect.material = .popover
        effect.state = .active
        effect.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(effect)
        pin(effect, to: view)

        outerStack.orientation = .vertical
        outerStack.alignment = .leading
        outerStack.spacing = 6
        outerStack.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
        outerStack.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(outerStack)
        pin(outerStack, to: effect)

        // Header
        headerLabel.font = .boldSystemFont(ofSize: 15)
        add(headerLabel)
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        add(statusLabel)
        sep()

        // Stats
        statsLabel.font = .systemFont(ofSize: 12)
        statsLabel.maximumNumberOfLines = 3
        add(statsLabel)

        // Progress
        progressBar.translatesAutoresizingMaskIntoConstraints = false
        progressBar.heightAnchor.constraint(equalToConstant: 16).isActive = true
        progressBar.widthAnchor.constraint(equalToConstant: 272).isActive = true
        add(progressBar)
        progressLabel.font = .systemFont(ofSize: 11)
        progressLabel.textColor = .secondaryLabelColor
        add(progressLabel)
        sep()

        // Disk selection (setup)
        diskHeader.font = .systemFont(ofSize: 12, weight: .semibold)
        diskHeader.stringValue = "Select Backup Disk"
        add(diskHeader)
        diskStack.orientation = .vertical
        diskStack.alignment = .leading
        diskStack.spacing = 4
        add(diskStack)
        sep()

        // Action buttons
        backupBtn = makeActionBtn("Backup...", icon: "arrow.up.doc", action: #selector(backupTapped))
        add(backupBtn)
        stopBtn = makeActionBtn("Stop Backup", icon: "stop.circle", action: #selector(stopTapped))
        stopBtn.contentTintColor = .systemRed
        add(stopBtn)

        // Restore row
        let rRow = makeActionBtn("Restore...", icon: "arrow.down.doc", action: #selector(restoreTapped))
        restoreRow = rRow
        add(rRow)

        // Undo
        let ub = makeActionBtn("Undo Last Restore", icon: "arrow.uturn.backward", action: #selector(undoTapped))
        ub.contentTintColor = .systemOrange
        undoBtn = ub
        add(ub)

        sep()
        add(makeActionBtn("Open Backup Folder", icon: "folder", action: #selector(openFolderTapped)))
        add(makeActionBtn("Eject Disk", icon: "eject", action: #selector(ejectTapped)))
        sep()
        let quitBtn = makeActionBtn("Quit", icon: "power", action: #selector(quitTapped))
        quitBtn.keyEquivalent = "q"
        quitBtn.keyEquivalentModifierMask = .command
        add(quitBtn)
    }

    // MARK: - Refresh

    func refresh() {
        guard isSetupDone, let delegate = popoverDelegate else { return }
        let state = delegate.popoverGetState()
        let status = delegate.popoverGetStatus()
        let config = delegate.popoverGetConfig()
        let running = state == .running

        // Status
        switch state {
        case .needsSetup: statusLabel.stringValue = "Setup required"
        case .idle:       statusLabel.stringValue = "Ready"
        case .running:    statusLabel.stringValue = "Backup in progress..."
        case .error:      statusLabel.stringValue = "Last backup failed"
        case .diskAbsent: statusLabel.stringValue = "Backup disk not connected"
        case .stale:      statusLabel.stringValue = "Backup overdue (>24h)"
        }

        // Stats
        var stats = ""
        if let s = status, !s.lastCompleted.isEmpty {
            stats = "Last: \(Fmt.timeAgo(from: s.lastCompleted))  --  \(Fmt.formatFileCount(s.filesTotal)) files  --  \(Fmt.formatBytes(s.bytesCopied))"
        } else {
            stats = "No backups yet"
        }
        if let c = config {
            let pathCount = c.source.paths.count
            stats += "\n\(pathCount) sources configured"
            let (free, total) = DiskDiagnostics.diskSpace(at: c.destination.path)
            if total > 0 {
                let vol = URL(fileURLWithPath: c.destination.path).deletingLastPathComponent().lastPathComponent
                stats += "\n\(vol): \(Fmt.formatBytes(free)) free"
            }
        }
        statsLabel.stringValue = stats

        // Progress
        progressBar.isHidden = !running
        progressLabel.isHidden = !running
        if running, let s = status {
            if s.filesTotal > 0 { progressBar.progress = CGFloat(s.filesDone) / CGFloat(s.filesTotal) }
            let pct = s.filesTotal > 0 ? "\(Int(Double(s.filesDone) / Double(s.filesTotal) * 100))%" : ""
            progressLabel.stringValue = "\(pct)  \(Fmt.formatBytes(s.bytesPerSec))/s  \(s.etaSecs > 0 ? "ETA: \(Fmt.formatDuration(Double(s.etaSecs)))" : "")"
        }

        // Disk setup
        let showDisk = state == .needsSetup
        diskHeader.isHidden = !showDisk
        diskStack.isHidden = !showDisk
        if showDisk { rebuildDiskList() }

        // Buttons
        backupBtn.isHidden = running || state == .needsSetup || state == .diskAbsent
        stopBtn.isHidden = !running

        // Restore -- visible when backups exist
        let hasBackups = config != nil && !RestoreEngine.findBackupSnapshots().isEmpty
        restoreRow?.isHidden = !hasBackups
        undoBtn?.isHidden = !RestoreEngine.hasPreRestoreBackup()
    }

    // MARK: - Actions

    @objc private func backupTapped() {
        guard let config = popoverDelegate?.popoverGetConfig() else { return }
        let wc = TreeWindowController(mode: .backup, enabledPaths: Set(config.source.paths))
        wc.treeDelegate = self
        wc.showWindow(nil)
        wc.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        treeWindow = wc
    }

    @objc private func restoreTapped() {
        let backups = RestoreEngine.findBackupSnapshots()
        guard let first = backups.first, let latest = first.snapshots.first else { return }
        let snapshotURL = first.backupDir.appendingPathComponent(latest)

        let wc = TreeWindowController(mode: .restore(snapshotURL: snapshotURL))
        wc.treeDelegate = self
        wc.showWindow(nil)
        wc.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        treeWindow = wc
    }

    @objc private func stopTapped() { popoverDelegate?.popoverDidRequestStop() }
    @objc private func openFolderTapped() { popoverDelegate?.popoverDidRequestOpenFolder() }
    @objc private func ejectTapped() { popoverDelegate?.popoverDidRequestEject() }
    @objc private func quitTapped() { popoverDelegate?.popoverDidRequestQuit() }
    @objc private func undoTapped() { popoverDelegate?.popoverDidRequestUndoRestore() }

    // MARK: - TreeWindowDelegate

    func treeWindowDidConfirmBackup(selectedPaths: [String]) {
        treeWindow = nil
        popoverDelegate?.popoverDidStartBackup(selectedPaths: selectedPaths)
    }

    func treeWindowDidConfirmRestore(snapshotURL: URL, selectedItems: [String], brewInstall: Bool) {
        treeWindow = nil
        popoverDelegate?.popoverDidStartRestore(snapshotURL: snapshotURL, items: selectedItems, brewInstall: brewInstall)
    }

    // MARK: - Disk selection

    @objc private func diskSelected(_ sender: NSButton) {
        let vols = discoverVolumes()
        guard sender.tag < vols.count else { return }
        popoverDelegate?.popoverDidSelectDisk(vols[sender.tag])
    }

    private func rebuildDiskList() {
        diskStack.arrangedSubviews.forEach { diskStack.removeArrangedSubview($0); $0.removeFromSuperview() }
        let vols = discoverVolumes()
        if vols.isEmpty {
            let l = NSTextField(labelWithString: "No external disk connected")
            l.font = .systemFont(ofSize: 11); l.textColor = .systemRed
            diskStack.addArrangedSubview(l)
            return
        }
        for (i, vol) in vols.enumerated() {
            let (free, total) = DiskDiagnostics.diskSpace(at: vol.path)
            let btn = NSButton(title: "\(vol.lastPathComponent)  --  \(free / 1_073_741_824) / \(total / 1_073_741_824) GB",
                               target: self, action: #selector(diskSelected(_:)))
            btn.bezelStyle = .rounded; btn.font = .systemFont(ofSize: 12); btn.tag = i
            btn.translatesAutoresizingMaskIntoConstraints = false
            btn.widthAnchor.constraint(equalToConstant: 260).isActive = true
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

    // MARK: - Layout

    private func add(_ v: NSView) {
        v.translatesAutoresizingMaskIntoConstraints = false
        outerStack.addArrangedSubview(v)
    }

    private func sep() {
        let s = NSBox(); s.boxType = .separator
        s.translatesAutoresizingMaskIntoConstraints = false
        outerStack.addArrangedSubview(s)
        s.widthAnchor.constraint(equalToConstant: 272).isActive = true
    }

    private func makeActionBtn(_ title: String, icon: String, action: Selector) -> NSButton {
        let btn = NSButton(title: title, target: self, action: action)
        btn.bezelStyle = .inline; btn.isBordered = false
        btn.font = .systemFont(ofSize: 13); btn.alignment = .left
        if let img = NSImage(systemSymbolName: icon, accessibilityDescription: title) {
            btn.image = img; btn.imagePosition = .imageLeading
        }
        return btn
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
