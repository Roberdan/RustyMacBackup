import Cocoa
import UserNotifications
import SwiftUI

class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    var config: Config?
    var statusManager = StatusManager()
    private var iconManager: IconManager!
    private var pollTimer: Timer?
    private let popover = NSPopover()
    private var uiState: AppUIState!
    private var popoverVC: PopoverViewController!
    private var treeWindowController: TreeWindowController?
    private var snapshotPickerWC: SnapshotPickerWindowController?

    func setInitialConfig(_ config: Config?) {
        self.config = config
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationDidFinishLaunching(_ notification: Notification) {
        ProcessInfo.processInfo.automaticTerminationSupportEnabled = false
        ProcessInfo.processInfo.disableAutomaticTermination("Menu bar app must stay alive")
        ProcessInfo.processInfo.disableSuddenTermination()
        Log.info("App launched")

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        iconManager = IconManager(statusItem: statusItem)
        iconManager.setState(.idle)

        // Create shared UI state and wire callbacks.
        uiState = AppUIState()
        wireCallbacks()

        // Setup popover with SwiftUI content.
        popoverVC = PopoverViewController(uiState: uiState)
        popover.contentViewController = popoverVC
        popover.behavior = .transient
        popover.animates = true

        statusItem.button?.action = #selector(togglePopover)
        statusItem.button?.target = self

        DispatchQueue.main.async { [weak self] in self?.deferredInit() }
    }

    // MARK: - Callbacks

    private func wireCallbacks() {
        uiState.onRequestBackup = { [weak self] in self?.handleRequestBackup() }
        uiState.onRequestRestore = { [weak self] in self?.handleRequestRestore() }
        uiState.onRequestStop = { [weak self] in self?.handleStop() }
        uiState.onRequestEject = { [weak self] in self?.handleEject() }
        uiState.onRequestOpenFolder = { [weak self] in self?.handleOpenFolder() }
        uiState.onRequestQuit = { NSApplication.shared.terminate(nil) }
        uiState.onSelectDisk = { [weak self] url in self?.handleSelectDisk(url) }
        uiState.onRequestUndoRestore = { [weak self] in self?.handleUndoRestore() }
        uiState.onRequestUpdate = { [weak self] in self?.handleRequestUpdate() }
        uiState.onSetSchedule = { [weak self] option in self?.handleSetSchedule(option) }
        uiState.onRequestScheduleMenu = { [weak self] in self?.handleRequestScheduleMenu() }
        refreshScheduleLabel()
    }

    private func refreshScheduleLabel() {
        let s = ScheduleManager.scheduleStatus()
        if !s.installed {
            uiState.scheduleLabel = "Off"
        } else if let mins = s.intervalMinutes {
            uiState.scheduleLabel = mins >= 60 ? "ogni \(mins / 60)h" : "ogni \(mins)min"
        } else if let hour = s.dailyHour {
            uiState.scheduleLabel = hour == 0 ? "mezzanotte" : "notte \(hour):00"
        } else {
            uiState.scheduleLabel = "On"
        }
    }

    private func handleRequestScheduleMenu() {
        let menu = NSMenu()
        func item(_ title: String, opt: Int?) -> NSMenuItem {
            let i = NSMenuItem(title: title, action: #selector(scheduleMenuAction(_:)), keyEquivalent: "")
            i.target = self
            i.tag = opt ?? Int.min
            return i
        }
        menu.addItem(item("Disabilita schedule", opt: nil))
        menu.addItem(.separator())
        menu.addItem(item("Ogni ora",  opt: 60))
        menu.addItem(item("Ogni 6 ore", opt: 360))
        menu.addItem(.separator())
        menu.addItem(item("Ogni notte (00:00)", opt: 0))
        menu.addItem(item("Ogni notte (02:00)", opt: -2))
        menu.addItem(item("Ogni notte (03:00)", opt: -3))

        if let button = statusItem.button {
            menu.popUp(positioning: nil,
                       at: NSPoint(x: 0, y: button.frame.height + 4),
                       in: button)
        }
    }

    @objc private func scheduleMenuAction(_ sender: NSMenuItem) {
        let opt: Int? = sender.tag == Int.min ? nil : sender.tag
        handleSetSchedule(opt)
    }

    private func handleSetSchedule(_ option: Int?) {
        do {
            if let opt = option {
                let plist: String
                if opt <= 0 {
                    plist = ScheduleManager.generatePlistDaily(hour: abs(opt))
                } else {
                    plist = ScheduleManager.generatePlist(intervalSeconds: opt * 60)
                }
                try ScheduleManager.installSchedule(plistContent: plist)
            } else {
                try ScheduleManager.removeSchedule()
            }
        } catch {
            sendNotification(title: "Schedule error", body: error.localizedDescription)
        }
        refreshScheduleLabel()
    }

    private func deferredInit() {
        if config == nil {
            config = try? Config.load(from: Config.defaultPath)
        }
        Log.info("Config loaded: \(config != nil ? "\(config!.source.paths.count) paths" : "none")")

        if Bundle.main.bundleIdentifier != nil {
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
                Log.info("Notification auth: granted=\(granted) error=\(error?.localizedDescription ?? "none")")
            }
        }

        let ws = NSWorkspace.shared
        ws.notificationCenter.addObserver(self, selector: #selector(volumeChanged),
                                          name: NSWorkspace.didMountNotification, object: nil)
        ws.notificationCenter.addObserver(self, selector: #selector(volumeChanged),
                                          name: NSWorkspace.didUnmountNotification, object: nil)

        pollTimer = Timer.scheduledTimer(withTimeInterval: 30.0, repeats: true) { [weak self] _ in
            self?.pollStatus()
        }
        pollTimer?.tolerance = 5.0
        pollStatus()

        // Check for updates 5s after launch (non-blocking).
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            Task {
                if let version = await AutoUpdater.checkForUpdate() {
                    DispatchQueue.main.async { self?.uiState.updateAvailable = version }
                }
            }
        }
    }

    // MARK: - Popover

    @objc private func togglePopover() {
        if popover.isShown {
            popover.performClose(nil)
        } else if let button = statusItem.button {
            pollStatus()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    // MARK: - Action handlers

    private func handleRequestBackup() {
        guard let config = config else { return }
        popover.performClose(nil)

        let treeWC = TreeWindowController(
            mode: .backup,
            enabledPaths: Set(config.source.paths),
            onConfirmBackup: { [weak self] selectedPaths in
                self?.treeWindowController = nil
                self?.startBackup(selectedPaths: selectedPaths)
            }
        )
        treeWC.showWindow(nil)
        treeWC.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        treeWindowController = treeWC
    }

    private func handleRequestRestore() {
        let backups = RestoreEngine.findBackupSnapshots()
        guard let first = backups.first, !first.snapshots.isEmpty else { return }
        popover.performClose(nil)

        let entries = first.snapshots.map {
            SnapshotEntry(url: first.backupDir.appendingPathComponent($0))
        }

        if entries.count == 1 {
            openRestoreTree(snapshotURL: entries[0].url)
            return
        }

        // Multiple snapshots — show picker first
        let picker = SnapshotPickerWindowController(
            entries: entries,
            onPick: { [weak self] url in
                self?.snapshotPickerWC = nil
                self?.openRestoreTree(snapshotURL: url)
            },
            onCancel: { [weak self] in self?.snapshotPickerWC = nil }
        )
        picker.showWindow(nil)
        picker.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        snapshotPickerWC = picker
    }

    private func openRestoreTree(snapshotURL: URL) {
        let treeWC = TreeWindowController(
            mode: .restore(snapshotURL: snapshotURL),
            onConfirmRestore: { [weak self] url, items, brewInstall, overrides in
                self?.treeWindowController = nil
                self?.startRestore(snapshotURL: url, items: items, brewInstall: brewInstall, overrides: overrides)
            }
        )
        treeWC.showWindow(nil)
        treeWC.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        treeWindowController = treeWC
    }

    private func startBackup(selectedPaths: [String]) {
        guard var config = config else { return }
        config.source.paths = selectedPaths
        try? config.save(to: Config.defaultPath)
        self.config = config
        iconManager.setState(.running)
        uiState.appState = .running
        Log.info("Backup started: \(config.source.paths.count) paths -> \(config.destination.path)")

        Task.detached {
            do {
                try await BackupEngine.run(config: config)
                await MainActor.run {
                    Log.info("Backup completed successfully")
                    self.sendNotification(title: "Backup completed",
                                          body: "Backup finished successfully")
                    self.pollStatus()
                }
            } catch {
                await MainActor.run {
                    Log.error("Backup failed: \(error.localizedDescription)")
                    self.iconManager.setState(.error)
                    self.uiState.appState = .error
                    self.sendNotification(title: "Backup failed",
                                          body: error.localizedDescription)
                }
            }
        }
    }

    private func handleStop() {
        BackupEngine.stop()
        iconManager.setState(.idle)
        pollStatus()
    }

    private func handleEject() {
        guard let config = config else { return }
        let volumePath = URL(fileURLWithPath: config.destination.path).deletingLastPathComponent()
        let volumeName = volumePath.lastPathComponent
        popover.performClose(nil)
        Log.info("Ejecting: \(volumePath.path)")

        DispatchQueue.global(qos: .userInitiated).async {
            let success = Self.runDiskutil(["eject", volumePath.path])
                || Self.runDiskutil(["unmount", "force", volumePath.path])
            DispatchQueue.main.async {
                if success {
                    Log.info("Disk ejected: \(volumeName)")
                    self.sendNotification(title: "Disk ejected",
                                          body: "\(volumeName) safely removed")
                    self.iconManager.setState(.diskAbsent)
                    self.pollStatus()
                } else {
                    Log.error("Eject failed: \(volumeName)")
                    self.sendNotification(title: "Eject failed",
                                          body: "Another app is using \(volumeName). Close it and retry.")
                }
            }
        }
    }

    private func handleOpenFolder() {
        guard let config = config else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: config.destination.path))
    }

    private func handleSelectDisk(_ volumeURL: URL) {
        let backupDir = volumeURL.appendingPathComponent("RustyMacBackup")
        do {
            try FileManager.default.createDirectory(at: backupDir, withIntermediateDirectories: true)
        } catch {
            sendNotification(title: "Error", body: "Cannot create backup folder: \(error.localizedDescription)")
            return
        }

        let newConfig = generateDefaultConfig(backupPath: backupDir.path)
        do {
            try newConfig.save(to: Config.defaultPath)
            config = try Config.load(from: Config.defaultPath)
        } catch {
            sendNotification(title: "Error", body: "Cannot save config: \(error.localizedDescription)")
            return
        }

        sendNotification(title: "Setup complete",
                         body: "Backing up \(newConfig.source.paths.count) paths to \(volumeURL.lastPathComponent)")
        pollStatus()
    }

    private func startRestore(snapshotURL: URL, items: [String], brewInstall: Bool, overrides: [String: String] = [:]) {
        // F-10: Preflight free-space check (payload × 2 to account for pre-restore backup copy)
        let estimate = RestoreEngine.estimateRestoreSize(snapshotURL: snapshotURL, items: items)
        let required = estimate * 2
        let available = BackupEngine.diskFreeSpace(at: NSHomeDirectory())
        if required > available && required > 0 {
            let alert = NSAlert()
            alert.messageText = "Spazio insufficiente per il restore"
            alert.informativeText = "Servono circa \(Fmt.formatBytes(required)) liberi, disponibili \(Fmt.formatBytes(available))."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Annulla")
            alert.runModal()
            return
        }

        iconManager.setState(.running)
        uiState.appState = .running
        Log.info("Restore started: \(items.count) items from \(snapshotURL.lastPathComponent)")
        sendNotification(title: "Restore avviato",
                         body: "Ripristino \(items.count) elementi da \(snapshotURL.lastPathComponent)…")

        // Reopen popover so user can see progress bar
        if let button = statusItem.button {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            // 1. Brew FIRST — installs missing tools before restoring their configs
            var brewOK = true
            if brewInstall {
                DispatchQueue.main.async {
                    self?.sendNotification(title: "Homebrew packages…",
                                           body: "Installing packages (may take a few minutes)…")
                    if var s = self?.uiState.status {
                        s.currentFile = "Installing Homebrew packages…"
                        self?.uiState.status = s
                    }
                }
                brewOK = RestoreEngine.restoreHomebrew(snapshotURL: snapshotURL)
            }

            // 2. Restore files
            let result = RestoreEngine.restore(snapshotURL: snapshotURL, items: items,
                                               destinationOverrides: overrides) { item, done, total in
                Log.info("Restoring [\(done)/\(total)] \(item)")
                DispatchQueue.main.async {
                    guard var s = self?.uiState.status else { return }
                    s.state = "running"
                    s.currentFile = item
                    s.filesDone = UInt64(done)
                    s.filesTotal = UInt64(total)
                    s.bytesCopied = 0
                    self?.uiState.status = s
                }
            }

            DispatchQueue.main.async {
                self?.iconManager.setState(.idle)
                let brewMsg = brewInstall ? (brewOK ? "\nHomebrew packages restored." : "\nHomebrew restore had errors.") : ""
                let backupMsg = result.backedUpTo.isEmpty ? "" : "\nOriginals saved to ~/.rustybackup-pre-restore/"
                Log.info("Restore complete: \(result.restored) restored, \(result.overwritten) overwritten, \(result.failed) failed")
                self?.sendNotification(
                    title: "Restore complete",
                    body: "\(result.restored) restored, \(result.overwritten) overwritten, \(result.failed) failed\(brewMsg)\(backupMsg)")

                let backupDir = snapshotURL.deletingLastPathComponent()
                let newConfig = generateDefaultConfig(backupPath: backupDir.path)
                try? newConfig.save(to: Config.defaultPath)
                self?.config = try? Config.load(from: Config.defaultPath)
                self?.pollStatus()
            }
        }
    }

    private func handleUndoRestore() {
        guard let backupDir = RestoreEngine.latestPreRestoreBackup() else { return }
        popover.performClose(nil)
        iconManager.setState(.running)
        uiState.appState = .running
        sendNotification(title: "Undoing restore…", body: "Restoring original files")
        Log.info("Undo restore started from \(backupDir.lastPathComponent)")

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = RestoreEngine.undoRestore(from: backupDir)
            DispatchQueue.main.async {
                self?.iconManager.setState(.idle)
                Log.info("Undo complete: \(result.restored) restored, \(result.failed) failed")
                self?.sendNotification(
                    title: "Undo restore complete",
                    body: "\(result.restored) files restored to original state, \(result.failed) failed")
                self?.pollStatus()
            }
        }
    }

    // MARK: - Auto-update

    private func handleRequestUpdate() {
        guard let version = uiState.updateAvailable else { return }
        uiState.isUpdating = true
        uiState.updatePhase = .downloading
        Task {
            do {
                try await AutoUpdater.downloadAndInstall(version: version) { [weak self] phase in
                    DispatchQueue.main.async { self?.uiState.updatePhase = phase }
                }
                DispatchQueue.main.async {
                    self.uiState.isUpdating = false
                    self.uiState.updatePhase = nil
                }
            } catch {
                Log.error("Update failed: \(error.localizedDescription)")
                DispatchQueue.main.async {
                    self.uiState.isUpdating = false
                    self.uiState.updatePhase = nil
                    self.sendNotification(title: "Aggiornamento fallito", body: error.localizedDescription)
                }
            }
        }
    }

    // MARK: - Volume notifications

    @objc private func volumeChanged() { pollStatus() }

    // MARK: - Status polling

    private func pollStatus() {
        let newState = statusManager.poll(config: config)
        iconManager.setState(newState)
        // Push updated state to SwiftUI via AppUIState.
        uiState.appState = newState
        uiState.status = statusManager.lastStatus
        uiState.config = config
    }

    // MARK: - Helpers

    private static func runDiskutil(_ args: [String]) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run(); p.waitUntilExit(); return p.terminationStatus == 0 }
        catch { return false }
    }

    private func sendNotification(title: String, body: String) {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString,
                                            content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
