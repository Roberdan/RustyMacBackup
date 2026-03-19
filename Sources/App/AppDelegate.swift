import Cocoa
import UserNotifications

class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    var config: Config?
    var statusManager = StatusManager()
    private var iconManager: IconManager!
    private var pollTimer: Timer?
    private var liveUpdateTimer: Timer?
    var availableUpdate: String?
    private var menuBuilder: MenuBuilder!
    // Keep references to live-updating views
    var liveProgressBar: ProgressBarView?
    var liveSpeedometer: SpeedometerView?
    var liveFilesItem: NSMenuItem?
    var liveFileItem: NSMenuItem?
    var liveErrorItem: NSMenuItem?

    func setInitialConfig(_ config: Config?) {
        self.config = config
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Create status bar item immediately (fast startup)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        iconManager = IconManager(statusItem: statusItem)
        iconManager.setState(.idle)
        rebuildMenu()

        // Defer heavy work after first paint
        DispatchQueue.main.async { [weak self] in self?.deferredInit() }
    }

    private func deferredInit() {
        if config == nil {
            config = try? Config.load(from: Config.defaultPath)
        }

        menuBuilder = MenuBuilder(delegate: self)

        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }

        let ws = NSWorkspace.shared
        ws.notificationCenter.addObserver(self, selector: #selector(volumeDidMount(_:)),
                                          name: NSWorkspace.didMountNotification, object: nil)
        ws.notificationCenter.addObserver(self, selector: #selector(volumeDidUnmount(_:)),
                                          name: NSWorkspace.didUnmountNotification, object: nil)

        pollTimer = Timer.scheduledTimer(withTimeInterval: 10.0, repeats: true) { [weak self] _ in
            self?.pollStatus()
        }
        pollTimer?.tolerance = 2.0
        pollStatus()

        // On first launch or if FDA missing, open Privacy settings so user sees the app
        let fda = FDACheck.checkFullDiskAccess()
        if !fda.hasAccess {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                FDACheck.openFDASettings()
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            self?.checkForUpdates()
        }

        rebuildMenu()
    }

    // MARK: - Actions

    @objc func backupNow() {
        guard let config = config else { return }
        iconManager.setState(.running)
        rebuildMenu()
        Task.detached {
            do {
                try await BackupEngine.run(config: config)
                await MainActor.run {
                    self.iconManager.flashCompletion()
                    self.sendNotification(title: "✅ Backup completato",
                                         body: "Backup terminato con successo")
                    self.pollStatus()
                    self.rebuildMenu()
                }
            } catch {
                await MainActor.run {
                    self.iconManager.setState(.error)
                    self.sendNotification(title: "❌ Backup fallito",
                                         body: error.localizedDescription)
                    self.rebuildMenu()
                }
            }
        }
    }

    @objc func stopBackup() {
        BackupEngine.stop()
        iconManager.setState(.idle)
        rebuildMenu()
    }

    @objc func ejectDisk() {
        guard let config = config else { return }
        let volumePath = URL(fileURLWithPath: config.destination.path)
            .deletingLastPathComponent()
        iconManager.flashPreference()

        DispatchQueue.global(qos: .userInitiated).async {
            let success = NSWorkspace.shared.unmountAndEjectDevice(atPath: volumePath.path)
            DispatchQueue.main.async {
                if success {
                    self.sendNotification(title: "✅ Disco espulso",
                                         body: "\(volumePath.lastPathComponent) rimosso in sicurezza")
                    self.iconManager.setState(.diskAbsent)
                    self.rebuildMenu()
                } else {
                    self.sendNotification(title: "❌ Espulsione fallita",
                                         body: "Impossibile espellere \(volumePath.lastPathComponent)")
                }
            }
        }
    }

    // MARK: - Volume notifications

    @objc func volumeDidMount(_ notification: Notification) {
        pollStatus()
        rebuildMenu()
    }

    @objc func volumeDidUnmount(_ notification: Notification) {
        iconManager.setState(.diskAbsent)
        rebuildMenu()
    }

    // MARK: - Status polling

    private func pollStatus() {
        let newState = statusManager.poll(config: config)
        iconManager.setState(newState)
        rebuildMenu()
    }

    // MARK: - NSMenuDelegate (live updates while menu is open)

    func menuWillOpen(_ menu: NSMenu) {
        // Start fast live updates while menu is visible
        liveUpdateTimer?.invalidate()
        liveUpdateTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.updateLiveViews()
        }
    }

    func menuDidClose(_ menu: NSMenu) {
        liveUpdateTimer?.invalidate()
        liveUpdateTimer = nil
    }

    private func updateLiveViews() {
        guard statusManager.currentState == .running else { return }
        // Re-read status from disk
        let sw = StatusWriter()
        guard let s = sw.read() else { return }
        statusManager.lastStatus = s

        // Update progress bar in-place
        if let bar = liveProgressBar, s.filesTotal > 0 {
            bar.progress = CGFloat(s.filesDone) / CGFloat(s.filesTotal)
            bar.needsDisplay = true
        }

        // Update speedometer in-place
        if let speedo = liveSpeedometer {
            speedo.speed = Double(s.bytesPerSec) / 1_048_576.0
            speedo.eta = s.etaSecs
            speedo.needsDisplay = true
        }

        // Update text items
        if let filesItem = liveFilesItem {
            let ft = NSMutableAttributedString()
            ft.append(MLText.colored("  \(Fmt.formatBytes(s.bytesCopied))", color: MLColor.gold))
            ft.append(MLText.plain(" copiati  "))
            ft.append(MLText.small("\(Fmt.formatFileCount(s.filesDone)) / \(Fmt.formatFileCount(s.filesTotal)) file",
                                    color: MLColor.grigio))
            filesItem.attributedTitle = ft
        }

        if let fileItem = liveFileItem, !s.currentFile.isEmpty {
            fileItem.attributedTitle = MLText.small("  ▸ \(MLText.cleanPath(s.currentFile))", color: MLColor.grigio)
        }

        if let errItem = liveErrorItem, s.errors > 0 {
            let et = NSMutableAttributedString()
            et.append(MLText.small("  \(s.errors) file protetti ignorati", color: MLColor.warning))
            et.append(MLText.small(" (normale)", color: MLColor.grigio))
            errItem.attributedTitle = et
        }
    }

    // MARK: - Menu building

    func rebuildMenu() {
        guard let menuBuilder = menuBuilder else {
            let menu = NSMenu()
            menu.addItem(NSMenuItem(title: "RustyMacBackup", action: nil, keyEquivalent: ""))
            menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
            statusItem.menu = menu
            return
        }
        let menu = menuBuilder.buildMenu(
            state: statusManager.currentState,
            status: statusManager.lastStatus,
            config: config,
            availableUpdate: availableUpdate
        )
        menu.delegate = self
        statusItem.menu = menu
    }

    // MARK: - Additional Actions

    @objc func openBackupFolder() {
        guard let config = config else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: config.destination.path))
    }

    @objc func openBackupLog() {
        let logPath = NSHomeDirectory() + "/.local/share/rusty-mac-backup/backup.log"
        NSWorkspace.shared.open(URL(fileURLWithPath: logPath))
    }

    @objc func changeScheduleInterval(_ sender: NSMenuItem) {
        let minutes = sender.tag
        let plist = ScheduleManager.generatePlist(intervalSeconds: minutes * 60)
        try? ScheduleManager.installSchedule(plistContent: plist)
        iconManager.flashPreference()
        rebuildMenu()
    }

    @objc func changeScheduleDaily(_ sender: NSMenuItem) {
        let hour = sender.tag
        let plist = ScheduleManager.generatePlistDaily(hour: hour)
        try? ScheduleManager.installSchedule(plistContent: plist)
        iconManager.flashPreference()
        rebuildMenu()
    }

    @objc func disableSchedule() {
        try? ScheduleManager.removeSchedule()
        iconManager.flashPreference()
        rebuildMenu()
    }

    @objc func toggleExclude(_ sender: NSMenuItem) {
        guard var config = config, let pattern = sender.representedObject as? String else { return }
        if let idx = config.exclude.patterns.firstIndex(of: pattern) {
            config.exclude.patterns.remove(at: idx)
        } else {
            config.exclude.patterns.append(pattern)
        }
        try? config.save(to: Config.defaultPath)
        self.config = config
        iconManager.flashPreference()
        rebuildMenu()
    }

    @objc func openFDASettings() {
        FDACheck.openFDASettings()
        // Reset cached FDA so next poll re-checks after user grants access
        statusManager.resetFDACache()
    }

    // MARK: - First-Run Setup (from menu bar — no terminal needed)

    @objc func selectBackupDisk(_ sender: NSMenuItem) {
        guard let volumeURL = sender.representedObject as? URL else { return }
        let backupDir = volumeURL.appendingPathComponent("RustyMacBackup")

        // Create backup directory
        do {
            try FileManager.default.createDirectory(at: backupDir, withIntermediateDirectories: true)
        } catch {
            sendNotification(title: "❌ Errore", body: "Impossibile creare la cartella di backup: \(error.localizedDescription)")
            return
        }

        // Generate and save config
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let configContent = generateDefaultConfig(homePath: home, backupPath: backupDir.path)
        let configURL = Config.defaultPath
        do {
            try FileManager.default.createDirectory(at: configURL.deletingLastPathComponent(),
                                                     withIntermediateDirectories: true)
            try configContent.write(to: configURL, atomically: true, encoding: .utf8)
            config = try Config.load(from: configURL)
        } catch {
            sendNotification(title: "❌ Errore", body: "Impossibile salvare la configurazione: \(error.localizedDescription)")
            return
        }

        iconManager.flashCompletion()
        sendNotification(title: "✅ Configurazione completata",
                        body: "Backup su \(volumeURL.lastPathComponent). Pronto per il primo backup!")
        pollStatus()
        rebuildMenu()
    }

    @objc func setupAndBackup(_ sender: NSMenuItem) {
        selectBackupDisk(sender)
        // Give a moment for config to settle, then backup
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.backupNow()
        }
    }

    private func iconColorForState(_ state: AppState) -> NSColor {
        switch state {
        case .needsSetup: return MLColor.gold
        case .idle:       return MLColor.verde
        case .running:    return MLColor.info
        case .error:      return MLColor.rosso
        case .diskAbsent: return MLColor.rosso
        case .fdaMissing: return MLColor.warning
        case .stale:      return MLColor.warning
        }
    }

    // MARK: - Helpers

    private func sendNotification(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString,
                                            content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    @objc func installUpdate() {
        guard let tag = availableUpdate else { return }
        let zipURL = "https://github.com/Roberdan/RustyMacBackup/releases/download/\(tag)/RustyMacBackup.app.zip"

        sendNotification(title: "⏳ Aggiornamento in corso...", body: "Scaricamento \(tag)")

        Task.detached {
            do {
                let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent("rmb-update-\(UUID().uuidString)")
                try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)

                let zipFile = tmpDir.appendingPathComponent("RustyMacBackup.app.zip")
                let (data, response) = try await URLSession.shared.data(from: URL(string: zipURL)!)
                guard let httpResp = response as? HTTPURLResponse, httpResp.statusCode == 200 else {
                    throw NSError(domain: "Update", code: 1, userInfo: [NSLocalizedDescriptionKey: "Download fallito"])
                }
                try data.write(to: zipFile)

                let unzipProcess = Process()
                unzipProcess.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
                unzipProcess.arguments = ["-o", zipFile.path, "-d", tmpDir.path]
                unzipProcess.standardOutput = FileHandle.nullDevice
                unzipProcess.standardError = FileHandle.nullDevice
                try unzipProcess.run()
                unzipProcess.waitUntilExit()

                let newApp = tmpDir.appendingPathComponent("RustyMacBackup.app")
                guard FileManager.default.fileExists(atPath: newApp.path) else {
                    throw NSError(domain: "Update", code: 2, userInfo: [NSLocalizedDescriptionKey: "App non trovata nello zip"])
                }

                let appPath = "/Applications/RustyMacBackup.app"
                try? FileManager.default.removeItem(atPath: appPath)
                try FileManager.default.moveItem(at: newApp, to: URL(fileURLWithPath: appPath))

                try? FileManager.default.removeItem(at: tmpDir)

                await MainActor.run {
                    self.sendNotification(title: "✅ Aggiornamento completato", body: "Riavvio \(tag)...")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                        let task = Process()
                        task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
                        task.arguments = ["-n", appPath]
                        try? task.run()
                        NSApplication.shared.terminate(nil)
                    }
                }
            } catch {
                await MainActor.run {
                    self.sendNotification(title: "❌ Aggiornamento fallito", body: error.localizedDescription)
                }
            }
        }
    }

    private func checkForUpdates() {
        let url = URL(string: "https://api.github.com/repos/Roberdan/RustyMacBackup/releases/latest")!
        URLSession.shared.dataTask(with: url) { data, _, _ in
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tagName = json["tag_name"] as? String else { return }
            let remoteVersion = tagName.trimmingCharacters(in: CharacterSet(charactersIn: "v"))
            let currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
            // Only show update if remote is NEWER (not just different)
            if remoteVersion.compare(currentVersion, options: .numeric) == .orderedDescending {
                DispatchQueue.main.async {
                    self.availableUpdate = tagName
                    self.rebuildMenu()
                }
            }
        }.resume()
    }
}
