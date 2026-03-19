import Cocoa

class MenuBuilder {
    weak var delegate: AppDelegate?

    init(delegate: AppDelegate) {
        self.delegate = delegate
    }

    func buildMenu(state: AppState, status: BackupStatusFile?, config: Config?, availableUpdate: String?) -> NSMenu {
        let menu = NSMenu()
        switch state {
        case .needsSetup:
            buildSetupMenu(menu: menu)
        case .idle, .stale:
            buildIdleMenu(menu: menu, status: status, config: config, state: state, availableUpdate: availableUpdate)
        case .running:
            buildRunningMenu(menu: menu, status: status)
        case .error:
            buildErrorMenu(menu: menu, status: status, config: config)
        case .diskAbsent:
            buildDiskAbsentMenu(menu: menu, config: config)
        case .fdaMissing:
            buildFDAMissingMenu(menu: menu)
        }
        return menu
    }

    // MARK: - First-Run Setup Menu

    private func buildSetupMenu(menu: NSMenu) {
        menu.addItem(makeHeader("RustyMacBackup", dotColor: MLColor.gold))
        menu.addItem(.separator())

        let welcome = NSMenuItem()
        welcome.attributedTitle = MLText.bold("👋 Benvenuto! Configura il backup")
        menu.addItem(welcome)
        menu.addItem(smallItem("  Seleziona il disco dove salvare i backup:"))
        menu.addItem(.separator())

        // Discover available volumes
        let volumes = discoverVolumes()
        if volumes.isEmpty {
            menu.addItem(coloredBullet("Nessun disco esterno collegato", color: MLColor.rosso))
            menu.addItem(smallItem("  Collega un disco esterno e riprova"))
        } else {
            for volume in volumes {
                let (free, total) = DiskDiagnostics.diskSpace(at: volume.path)
                let freeGB = free / 1_073_741_824
                let totalGB = total / 1_073_741_824
                let spaceLevel = DiskDiagnostics.spaceColorLevel(free: free)
                let spaceColor = spaceLevel == .verde ? MLColor.verde : spaceLevel == .warning ? MLColor.warning : MLColor.rosso

                // "Select and configure" item
                let item = NSMenuItem()
                let text = NSMutableAttributedString()
                text.append(MLText.dot(color: spaceColor))
                text.append(MLText.bold("\(volume.lastPathComponent)"))
                text.append(MLText.plain("  \(freeGB) GB liberi / \(totalGB) GB"))
                item.attributedTitle = text
                item.representedObject = volume
                item.action = #selector(AppDelegate.selectBackupDisk(_:))
                item.target = delegate
                menu.addItem(item)

                // Sub-option: configure AND start first backup
                let quickItem = NSMenuItem()
                quickItem.attributedTitle = MLText.colored("    ▸ Configura e avvia primo backup", color: MLColor.verde)
                quickItem.representedObject = volume
                quickItem.action = #selector(AppDelegate.setupAndBackup(_:))
                quickItem.target = delegate
                menu.addItem(quickItem)
            }
        }

        menu.addItem(.separator())

        // FDA check info
        let fda = FDACheck.checkFullDiskAccess()
        if fda.hasAccess {
            menu.addItem(coloredBullet("Full Disk Access: OK", color: MLColor.verde))
        } else {
            menu.addItem(coloredBullet("Full Disk Access: mancante", color: MLColor.warning))
            let fdaItem = plainAction("  Apri Impostazioni Privacy...", action: #selector(AppDelegate.openFDASettings), key: "")
            menu.addItem(fdaItem)
        }

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    // Discover external volumes (skip system disk)
    private func discoverVolumes() -> [URL] {
        let fm = FileManager.default
        guard let volumes = fm.mountedVolumeURLs(includingResourceValuesForKeys: [.volumeNameKey],
                                                  options: [.skipHiddenVolumes]) else { return [] }
        return volumes.filter { url in
            let path = url.path
            if path == "/" || path == "/System/Volumes/Data" { return false }
            if url.lastPathComponent == "Macintosh HD" { return false }
            return path.hasPrefix("/Volumes/")
        }
    }

    // MARK: - Idle / Stale

    private func buildIdleMenu(menu: NSMenu, status: BackupStatusFile?, config: Config?, state: AppState, availableUpdate: String?) {
        let dotColor = state == .stale ? MLColor.warning : MLColor.verde
        menu.addItem(makeHeader("RustyMacBackup", dotColor: dotColor))
        menu.addItem(.separator())

        if let s = status, !s.lastCompleted.isEmpty {
            let age = Date().timeIntervalSince(ISO8601DateFormatter().date(from: s.lastCompleted) ?? Date())
            let ageColor = age < 14400 ? MLColor.verde : age < 86400 ? MLColor.gold : MLColor.rosso
            menu.addItem(coloredBullet("Ultimo backup: \(Fmt.timeAgo(from: s.lastCompleted))", color: ageColor))
            menu.addItem(smallItem("  \(Fmt.formatDuration(s.lastDurationSecs)) · \(Fmt.formatFileCount(s.filesTotal)) file · \(Fmt.formatBytes(s.bytesCopied))"))
            if s.errors > 0 { menu.addItem(smallItem("  \(s.errors) file ignorati (normale)", color: MLColor.dimmed)) }
        }

        if let c = config {
            let (free, _) = DiskDiagnostics.diskSpace(at: c.destination.path)
            let dc = DiskDiagnostics.spaceColorLevel(free: free)
            let diskColor = dc == .verde ? MLColor.verde : dc == .warning ? MLColor.warning : MLColor.rosso
            let volName = URL(fileURLWithPath: c.destination.path).deletingLastPathComponent().lastPathComponent
            menu.addItem(coloredBullet("\(volName)  \(Fmt.formatBytes(free)) liberi", color: diskColor))
            let sched = ScheduleManager.scheduleStatus()
            if sched.installed {
                if let mins = sched.intervalMinutes {
                    menu.addItem(smallItem("  Prossimo: tra \(mins) min", color: MLColor.gold))
                } else if let hour = sched.dailyHour {
                    menu.addItem(smallItem("  Ogni giorno alle \(hour):00", color: MLColor.gold))
                }
            }
        }

        menu.addItem(.separator())
        menu.addItem(coloredAction("Backup Now", color: MLColor.verde,
                                   action: #selector(AppDelegate.backupNow), key: "b"))
        menu.addItem(plainAction("Open Backup Folder", action: #selector(AppDelegate.openBackupFolder), key: "o"))
        menu.addItem(coloredAction("Espelli disco", color: MLColor.info,
                                   action: #selector(AppDelegate.ejectDisk), key: "e"))
        menu.addItem(.separator())

        let sched = ScheduleManager.scheduleStatus()
        let schedLabel: String
        if let mins = sched.intervalMinutes { schedLabel = "Schedule: Ogni \(mins) min" }
        else if let h = sched.dailyHour    { schedLabel = "Schedule: Ogni giorno alle \(h):00" }
        else                               { schedLabel = "Schedule: Off" }
        let schedItem = NSMenuItem(title: schedLabel, action: nil, keyEquivalent: "")
        schedItem.submenu = buildScheduleSubmenu(config: config)
        menu.addItem(schedItem)

        menu.addItem(.separator())
        let prefsItem = NSMenuItem(title: "Preferenze", action: nil, keyEquivalent: "")
        prefsItem.submenu = buildPreferencesSubmenu(config: config)
        menu.addItem(prefsItem)
        menu.addItem(.separator())

        if let update = availableUpdate {
            let upItem = NSMenuItem()
            upItem.attributedTitle = MLText.colored("🆕 Aggiornamento \(update) disponibile", color: MLColor.info)
            menu.addItem(upItem)
        }
        menu.addItem(plainAction("View Backup Log", action: #selector(AppDelegate.openBackupLog), key: ""))
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    // MARK: - Running

    private func buildRunningMenu(menu: NSMenu, status: BackupStatusFile?) {
        let hdr = NSMenuItem()
        let t = NSMutableAttributedString(attributedString: MLText.dot(color: MLColor.gold))
        t.append(MLText.bold("RustyMacBackup"))
        t.append(MLText.colored("  BACKUP IN CORSO", color: MLColor.gold))
        hdr.attributedTitle = t
        menu.addItem(hdr)
        menu.addItem(.separator())

        let progressItem = NSMenuItem()
        let progressBar = ProgressBarView()
        progressBar.frame = NSRect(x: 0, y: 0, width: 250, height: 32)
        if let s = status { progressBar.progress = CGFloat(s.filesDone) / max(CGFloat(s.filesTotal), 1) }
        progressItem.view = progressBar
        menu.addItem(progressItem)

        if let s = status {
            let statsItem = NSMenuItem()
            statsItem.attributedTitle = MLText.small(
                "  \(Fmt.formatBytes(s.bytesCopied)) copiati  \(Fmt.formatFileCount(s.filesDone)) / \(Fmt.formatFileCount(s.filesTotal)) file")
            menu.addItem(statsItem)
        }

        let speedItem = NSMenuItem()
        let speedo = SpeedometerView()
        speedo.frame = NSRect(x: 0, y: 0, width: 220, height: 90)
        if let s = status { speedo.speed = Double(s.bytesPerSec) / 1_048_576.0; speedo.eta = s.etaSecs }
        speedItem.view = speedo
        menu.addItem(speedItem)

        if let s = status {
            let mbps = String(format: "%.1f MB/s", Double(s.bytesPerSec) / 1_048_576.0)
            let eta = s.etaSecs > 0 ? "  ETA: \(Fmt.formatDuration(Double(s.etaSecs)))" : ""
            menu.addItem(smallItem("  Speed: \(mbps)\(eta)"))
            if !s.currentFile.isEmpty { menu.addItem(smallItem("  ▸ \(MLText.cleanPath(s.currentFile))")) }
        }

        menu.addItem(.separator())
        menu.addItem(coloredAction("● Ferma backup", color: MLColor.gold,
                                   action: #selector(AppDelegate.stopBackup), key: "b"))
    }

    // MARK: - Error

    private func buildErrorMenu(menu: NSMenu, status: BackupStatusFile?, config: Config?) {
        menu.addItem(makeHeader("RustyMacBackup  ERRORE", dotColor: MLColor.rosso))
        menu.addItem(.separator())
        menu.addItem(coloredBullet("Backup fallito", color: MLColor.rosso))

        let fda = FDACheck.checkFullDiskAccess()
        if !fda.hasAccess {
            let fdaItem = NSMenuItem()
            fdaItem.attributedTitle = MLText.colored("  ⚠ Serve Full Disk Access", color: MLColor.rosso)
            menu.addItem(fdaItem)
            menu.addItem(plainAction("  Apri Impostazioni Privacy...", action: #selector(AppDelegate.openFDASettings), key: ""))
        }

        if let s = status, !s.lastCompleted.isEmpty {
            let age = Date().timeIntervalSince(ISO8601DateFormatter().date(from: s.lastCompleted) ?? Date())
            menu.addItem(coloredBullet("Ultimo OK: \(Fmt.timeAgo(from: s.lastCompleted))",
                                       color: age > 86400 ? MLColor.rosso : MLColor.gold))
        }

        if let c = config {
            let (free, _) = DiskDiagnostics.diskSpace(at: c.destination.path)
            let volName = URL(fileURLWithPath: c.destination.path).deletingLastPathComponent().lastPathComponent
            menu.addItem(plainBullet("\(volName)  \(Fmt.formatBytes(free)) liberi"))
        }

        let retryItem = NSMenuItem()
        retryItem.attributedTitle = MLText.small("  Premi Backup Now per riprovare", color: MLColor.dimmed)
        menu.addItem(retryItem)
        menu.addItem(.separator())
        menu.addItem(coloredAction("Backup Now", color: MLColor.verde,
                                   action: #selector(AppDelegate.backupNow), key: "b"))
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    // MARK: - Disk Absent

    private func buildDiskAbsentMenu(menu: NSMenu, config: Config?) {
        menu.addItem(makeHeader("RustyMacBackup", dotColor: MLColor.rosso))
        menu.addItem(.separator())

        let diskName = config.map {
            URL(fileURLWithPath: $0.destination.path).deletingLastPathComponent().lastPathComponent
        } ?? "disco"
        menu.addItem(coloredBullet("Disco \"\(diskName)\" non collegato", color: MLColor.rosso))

        let hintItem = NSMenuItem()
        hintItem.attributedTitle = MLText.small("  Collega il disco per avviare il backup", color: MLColor.dimmed)
        menu.addItem(hintItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    // MARK: - FDA Missing

    private func buildFDAMissingMenu(menu: NSMenu) {
        let hdr = NSMenuItem()
        hdr.attributedTitle = MLText.bold("RustyMacBackup")
        menu.addItem(hdr)
        menu.addItem(.separator())
        menu.addItem(coloredBullet("Full Disk Access richiesto", color: MLColor.rosso))

        let hintItem = NSMenuItem()
        hintItem.attributedTitle = MLText.small("  Senza FDA il backup non può accedere ai tuoi file", color: MLColor.dimmed)
        menu.addItem(hintItem)
        menu.addItem(.separator())
        menu.addItem(plainAction("Apri Impostazioni Privacy...", action: #selector(AppDelegate.openFDASettings), key: ""))

        let addItem = NSMenuItem()
        addItem.attributedTitle = MLText.small("  Aggiungi RustyMacBackup.app a FDA", color: MLColor.dimmed)
        menu.addItem(addItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    // MARK: - Submenus

    private func buildScheduleSubmenu(config: Config?) -> NSMenu {
        let sub = NSMenu()
        let status = ScheduleManager.scheduleStatus()
        for (title, mins) in [("Ogni 15 min", 15), ("Ogni 30 min", 30), ("Ogni 60 min", 60),
                               ("Ogni 2 ore", 120), ("Ogni 6 ore", 360)] {
            let item = NSMenuItem(title: title, action: #selector(AppDelegate.changeScheduleInterval(_:)), keyEquivalent: "")
            item.target = delegate; item.tag = mins
            item.state = (status.intervalMinutes == mins) ? .on : .off
            sub.addItem(item)
        }
        sub.addItem(.separator())
        for hour in [0, 6, 8, 12, 18, 22] {
            let item = NSMenuItem(title: "Ogni giorno alle \(hour):00",
                                  action: #selector(AppDelegate.changeScheduleDaily(_:)), keyEquivalent: "")
            item.target = delegate; item.tag = hour
            item.state = (status.dailyHour == hour) ? .on : .off
            sub.addItem(item)
        }
        sub.addItem(.separator())
        let offItem = NSMenuItem(title: "Off", action: #selector(AppDelegate.disableSchedule), keyEquivalent: "")
        offItem.target = delegate
        offItem.state = !status.installed ? .on : .off
        sub.addItem(offItem)
        return sub
    }

    private func buildPreferencesSubmenu(config: Config?) -> NSMenu {
        let sub = NSMenu()
        sub.addItem(NSMenuItem(title: "Destinazione: \(config?.destination.path ?? "non configurata")",
                               action: nil, keyEquivalent: ""))
        sub.addItem(.separator())
        if let r = config?.retention {
            sub.addItem(NSMenuItem(title: "Retention:", action: nil, keyEquivalent: ""))
            sub.addItem(NSMenuItem(title: "  Orari: \(r.hourly)", action: nil, keyEquivalent: ""))
            sub.addItem(NSMenuItem(title: "  Giornalieri: \(r.daily)", action: nil, keyEquivalent: ""))
            sub.addItem(NSMenuItem(title: "  Settimanali: \(r.weekly)", action: nil, keyEquivalent: ""))
            sub.addItem(NSMenuItem(title: "  Mensili: \(r.monthly == 0 ? "∞" : "\(r.monthly)")",
                                   action: nil, keyEquivalent: ""))
        }
        sub.addItem(.separator())
        sub.addItem(NSMenuItem(title: "Escludi:", action: nil, keyEquivalent: ""))
        for pattern in ["node_modules", ".git/objects", "Library/Caches", "*.tmp", "__pycache__"] {
            let item = NSMenuItem(title: "  \(pattern)", action: #selector(AppDelegate.toggleExclude(_:)), keyEquivalent: "")
            item.target = delegate
            item.representedObject = pattern
            item.state = config?.exclude.patterns.contains(pattern) == true ? .on : .off
            sub.addItem(item)
        }
        return sub
    }

    // MARK: - Item Factories

    private func smallItem(_ text: String, color: NSColor = .secondaryLabelColor) -> NSMenuItem {
        let item = NSMenuItem()
        item.attributedTitle = MLText.small(text, color: color)
        return item
    }

    private func makeHeader(_ text: String, dotColor: NSColor) -> NSMenuItem {
        let item = NSMenuItem()
        let t = NSMutableAttributedString(attributedString: MLText.dot(color: dotColor))
        t.append(MLText.bold(text))
        item.attributedTitle = t
        return item
    }

    private func coloredBullet(_ text: String, color: NSColor) -> NSMenuItem {
        let item = NSMenuItem()
        let t = NSMutableAttributedString(attributedString: MLText.dot(color: color))
        t.append(MLText.colored(text, color: color))
        item.attributedTitle = t
        return item
    }

    private func plainBullet(_ text: String) -> NSMenuItem {
        let item = NSMenuItem()
        item.attributedTitle = MLText.plain("● \(text)")
        return item
    }

    private func coloredAction(_ title: String, color: NSColor, action: Selector, key: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = delegate
        item.attributedTitle = MLText.colored(title, color: color)
        return item
    }

    private func plainAction(_ title: String, action: Selector, key: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = delegate
        return item
    }
}
