import Cocoa
import UserNotifications

class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    var config: Config?
    private var statusManager = StatusManager()
    private var iconManager: IconManager!
    private var pollTimer: Timer?
    var availableUpdate: String?
    private var menuBuilder: MenuBuilder!

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

        pollTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.pollStatus()
        }
        pollTimer?.tolerance = 0.5
        pollStatus()

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

    // MARK: - Menu building

    func rebuildMenu() {
        guard let menuBuilder = menuBuilder else {
            // Early call before deferredInit — show minimal placeholder
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

    private func checkForUpdates() {
        let url = URL(string: "https://api.github.com/repos/Roberdan/RustyMacBackup/releases/latest")!
        URLSession.shared.dataTask(with: url) { data, _, _ in
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tagName = json["tag_name"] as? String else { return }
            let current = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
            let currentTag = current.hasPrefix("v") ? current : "v\(current)"
            if tagName != currentTag {
                DispatchQueue.main.async {
                    self.availableUpdate = tagName
                    self.rebuildMenu()
                }
            }
        }.resume()
    }
}
