import Cocoa
import UserNotifications

class AppDelegate: NSObject, NSApplicationDelegate, PopoverDelegate {
    private var statusItem: NSStatusItem!
    var config: Config?
    var statusManager = StatusManager()
    private var iconManager: IconManager!
    private var pollTimer: Timer?
    private let popover = NSPopover()
    private var popoverVC: PopoverViewController!

    func setInitialConfig(_ config: Config?) {
        self.config = config
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Prevent macOS from auto-terminating this menu bar-only app
        ProcessInfo.processInfo.automaticTerminationSupportEnabled = false
        ProcessInfo.processInfo.disableAutomaticTermination("Menu bar app must stay alive")
        ProcessInfo.processInfo.disableSuddenTermination()
        Log.info("App launched")

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        iconManager = IconManager(statusItem: statusItem)
        iconManager.setState(.idle)

        // Setup popover
        popoverVC = PopoverViewController()
        popoverVC.popoverDelegate = self
        popover.contentViewController = popoverVC
        popover.behavior = .transient
        popover.animates = true

        statusItem.button?.action = #selector(togglePopover)
        statusItem.button?.target = self

        DispatchQueue.main.async { [weak self] in self?.deferredInit() }
    }

    private func deferredInit() {
        if config == nil {
            config = try? Config.load(from: Config.defaultPath)
        }
        Log.info("Config loaded: \(config != nil ? "\(config!.source.paths.count) paths" : "none")")

        // Only request notifications when running as a proper .app bundle
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

        // Light poll every 30s -- only checks status.json and destination path existence
        // No filesystem scanning, no volume enumeration
        pollTimer = Timer.scheduledTimer(withTimeInterval: 30.0, repeats: true) { [weak self] _ in
            self?.pollStatus()
        }
        pollTimer?.tolerance = 5.0
        pollStatus()
    }

    // MARK: - Popover

    @objc private func togglePopover() {
        if popover.isShown {
            popover.performClose(nil)
        } else if let button = statusItem.button {
            // Poll fresh state before showing
            pollStatus()
            popoverVC.refresh()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    // MARK: - PopoverDelegate

    func popoverDidRequestBackup() {
        guard let config = config else { return }
        popover.performClose(nil)
        iconManager.setState(.running)
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
                    self.sendNotification(title: "Backup failed",
                                         body: error.localizedDescription)
                }
            }
        }
    }

    func popoverDidRequestStop() {
        BackupEngine.stop()
        iconManager.setState(.idle)
    }

    func popoverDidRequestEject() {
        guard let config = config else { return }
        let volumePath = URL(fileURLWithPath: config.destination.path).deletingLastPathComponent()
        popover.performClose(nil)
        DispatchQueue.global(qos: .userInitiated).async {
            let success = NSWorkspace.shared.unmountAndEjectDevice(atPath: volumePath.path)
            DispatchQueue.main.async {
                if success {
                    self.sendNotification(title: "Disk ejected",
                                         body: "\(volumePath.lastPathComponent) safely removed")
                    self.iconManager.setState(.diskAbsent)
                } else {
                    self.sendNotification(title: "Eject failed",
                                         body: "Could not eject \(volumePath.lastPathComponent)")
                }
            }
        }
    }

    func popoverDidRequestOpenFolder() {
        guard let config = config else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: config.destination.path))
    }

    func popoverDidRequestAddFolder() {
        popover.performClose(nil)
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Add to Backup"
        panel.message = "Select files or folders to back up"

        panel.begin { [weak self] response in
            guard response == .OK, let self = self, var config = self.config else { return }
            for url in panel.urls {
                let contracted = ConfigDiscovery.contract(url.path)
                if ConfigDiscovery.isForbidden(contracted) {
                    self.sendNotification(title: "Path blocked",
                                         body: "\(contracted) is system-protected and cannot be backed up safely")
                    continue
                }
                if !config.source.paths.contains(contracted) {
                    config.source.paths.append(contracted)
                }
            }
            try? config.save(to: Config.defaultPath)
            self.config = config
            DispatchQueue.main.async { self.popoverVC.refresh() }
        }
    }

    func popoverDidSelectDisk(_ volumeURL: URL) {
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
        popoverVC.refresh()
    }

    func popoverDidTogglePath(_ path: String, enabled: Bool) {
        guard var config = config else { return }
        if enabled {
            if !config.source.paths.contains(path) {
                config.source.paths.append(path)
            }
        } else {
            config.source.paths.removeAll { $0 == path }
        }
        try? config.save(to: Config.defaultPath)
        self.config = config
    }

    func popoverDidRequestRestore(_ snapshotURL: URL, items: [String], brewInstall: Bool) {
        popover.performClose(nil)
        iconManager.setState(.running)

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = RestoreEngine.restore(snapshotURL: snapshotURL, items: items)

            var brewOK = true
            if brewInstall {
                brewOK = RestoreEngine.restoreHomebrew(snapshotURL: snapshotURL)
            }

            DispatchQueue.main.async {
                self?.iconManager.setState(.idle)
                let brewMsg = brewInstall ? (brewOK ? "\nHomebrew packages restored." : "\nHomebrew restore had errors.") : ""
                let backupMsg = result.backedUpTo.isEmpty ? "" : "\nPre-restore backup: ~/.rustybackup-pre-restore/"
                self?.sendNotification(
                    title: "Restore complete",
                    body: "\(result.restored) restored, \(result.overwritten) overwritten, \(result.failed) failed\(brewMsg)\(backupMsg)")

                // After restore, create config pointing to this backup disk
                let backupDir = snapshotURL.deletingLastPathComponent()
                let newConfig = generateDefaultConfig(backupPath: backupDir.path)
                try? newConfig.save(to: Config.defaultPath)
                self?.config = try? Config.load(from: Config.defaultPath)
                self?.pollStatus()
                self?.popoverVC.refresh()
            }
        }
    }

    func popoverDidRequestUndoRestore() {
        guard let backupDir = RestoreEngine.latestPreRestoreBackup() else { return }
        popover.performClose(nil)
        iconManager.setState(.running)

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = RestoreEngine.undoRestore(from: backupDir)
            DispatchQueue.main.async {
                self?.iconManager.setState(.idle)
                self?.sendNotification(
                    title: "Undo restore complete",
                    body: "\(result.restored) files restored to original state, \(result.failed) failed")
                self?.popoverVC.refresh()
            }
        }
    }

    func popoverDidRequestQuit() {
        NSApplication.shared.terminate(nil)
    }

    func popoverGetState() -> AppState { statusManager.currentState }
    func popoverGetStatus() -> BackupStatusFile? { statusManager.lastStatus }
    func popoverGetConfig() -> Config? { config }

    // MARK: - Volume notifications

    @objc private func volumeChanged() {
        pollStatus()
    }

    // MARK: - Status polling

    private func pollStatus() {
        let newState = statusManager.poll(config: config)
        iconManager.setState(newState)
    }

    // MARK: - Helpers

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
