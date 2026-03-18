import Cocoa
import UserNotifications

// MARK: - Status Model

struct BackupStatus: Codable {
    let state: String
    let started_at: String?
    let last_completed: String?
    let last_duration_secs: Double?
    let files_total: Int?
    let files_done: Int?
    let bytes_copied: Int64?
    let bytes_per_sec: Int64?
    let eta_secs: Int?
    let errors: Int?
    let current_file: String?
}

// MARK: - Formatting Helpers

enum Fmt {
    static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    static let isoFormatterNoFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static func parseISO(_ s: String) -> Date? {
        return isoFormatter.date(from: s) ?? isoFormatterNoFrac.date(from: s)
    }

    static func relativeTime(from date: Date) -> String {
        let secs = Int(-date.timeIntervalSinceNow)
        if secs < 60 { return "just now" }
        if secs < 3600 { return "\(secs / 60) min ago" }
        if secs < 86400 {
            let h = secs / 3600
            return "\(h) hour\(h == 1 ? "" : "s") ago"
        }
        let d = secs / 86400
        return "\(d) day\(d == 1 ? "" : "s") ago"
    }

    static func duration(_ secs: Double) -> String {
        if secs < 60 { return "\(Int(secs))s" }
        let m = Int(secs) / 60
        let s = Int(secs) % 60
        return s > 0 ? "\(m)m \(s)s" : "\(m)m"
    }

    static func number(_ n: Int) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        return f.string(from: NSNumber(value: n)) ?? "\(n)"
    }

    static func bytes(_ b: Int64) -> String {
        let bf = ByteCountFormatter()
        bf.allowedUnits = [.useBytes, .useKB, .useMB, .useGB, .useTB]
        bf.countStyle = .file
        return bf.string(fromByteCount: b)
    }

    static func speed(_ bps: Int64) -> String {
        return "\(bytes(bps))/s"
    }

    static func timeUntil(minutes: Int, lastCompleted: Date?) -> String {
        guard let last = lastCompleted else { return "not scheduled" }
        let next = last.addingTimeInterval(Double(minutes * 60))
        let remaining = Int(next.timeIntervalSinceNow)
        if remaining <= 0 { return "due now" }
        if remaining < 60 { return "in \(remaining)s" }
        return "in \(remaining / 60) min"
    }
}

// MARK: - Shell Runner

enum Shell {
    private static let home = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
    private static let pathPrefix = "\(home)/.local/bin:/opt/homebrew/bin:/usr/local/bin"

    @discardableResult
    static func run(_ command: String) -> String {
        let task = Process()
        let pipe = Pipe()
        task.executableURL = URL(fileURLWithPath: "/bin/zsh")
        task.arguments = ["-c", "export PATH=\"\(pathPrefix):$PATH\"; \(command)"]
        task.standardOutput = pipe
        task.standardError = pipe
        task.environment = ProcessInfo.processInfo.environment
        do {
            try task.run()
            task.waitUntilExit()
        } catch {
            return "error: \(error.localizedDescription)"
        }
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    static func runAsync(_ command: String, completion: @escaping (String) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let result = run(command)
            DispatchQueue.main.async { completion(result) }
        }
    }
}

// MARK: - Disk Info

enum DiskInfo {
    static func freeSpace() -> String? {
        let configOutput = Shell.run("rustyback config show 2>/dev/null | grep -E '\"[/]' | head -1")
        let components = configOutput.components(separatedBy: "\"")
        var path: String? = nil
        for c in components {
            if c.hasPrefix("/") { path = c; break }
        }
        guard let mountPath = path else { return nil }

        let volumeRoot: String
        if mountPath.hasPrefix("/Volumes/") {
            let parts = mountPath.split(separator: "/", maxSplits: 3)
            volumeRoot = parts.count >= 2 ? "/Volumes/\(parts[1])" : mountPath
        } else {
            volumeRoot = "/"
        }

        let url = URL(fileURLWithPath: volumeRoot)
        guard let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
              let free = values.volumeAvailableCapacityForImportantUsage else {
            return nil
        }
        return Fmt.bytes(free)
    }
}

// MARK: - App Delegate

class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var pollTimer: Timer?
    private var animationTimer: Timer?
    private var animationFrame: Int = 0

    private var currentStatus: BackupStatus?
    private var previousState: String = "idle"
    private var scheduleIntervalMinutes: Int = 60
    private var scheduleEnabled: Bool = true
    private var cachedDiskFree: String?
    private var diskFreeLastChecked: Date = .distantPast

    private let statusFilePath: String = {
        let home = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
        return "\(home)/.local/share/rusty-mac-backup/status.json"
    }()

    // MARK: Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
        readScheduleState()
        refreshDiskFree()
        pollStatus()
        schedulePollTimer(interval: 30)
        requestNotificationPermission()
    }

    func applicationWillTerminate(_ notification: Notification) {
        pollTimer?.invalidate()
        animationTimer?.invalidate()
    }

    // MARK: Status Bar Setup

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        setIdleIcon(stale: false, hasError: false)
        buildMenu()
    }

    // MARK: Icon Management

    private func loadBundleIcon(_ name: String) -> NSImage? {
        // Try loading PNG from app bundle Resources
        if let path = Bundle.main.path(forResource: name, ofType: "png") {
            if let img = NSImage(contentsOfFile: path) {
                img.isTemplate = true
                img.size = NSSize(width: 18, height: 18)
                return img
            }
        }
        return nil
    }

    private func setIdleIcon(stale: Bool, hasError: Bool) {
        stopAnimation()
        guard let button = statusItem.button else { return }

        if hasError {
            if let img = loadBundleIcon("icon-warning") {
                button.image = img
                button.title = ""
            } else {
                button.image = nil
                button.title = "✕"
            }
        } else if stale {
            if let img = loadBundleIcon("icon-warning") {
                button.image = img
                button.title = ""
            } else {
                button.image = nil
                button.title = "◐"
            }
        } else {
            if let img = loadBundleIcon("icon-idle") {
                button.image = img
                button.title = ""
            } else if let img = NSImage(systemSymbolName: "externaldrive.badge.checkmark",
                                        accessibilityDescription: "RustyMacBackup") {
                img.isTemplate = true
                button.image = img
                button.title = ""
            } else {
                button.image = nil
                button.title = "●"
            }
        }
    }

    private func startAnimation() {
        guard animationTimer == nil else { return }
        animationFrame = 0

        let iconRunning = loadBundleIcon("icon-running")
        let iconIdle = loadBundleIcon("icon-idle")

        if iconRunning != nil {
            // Alternate between running and idle icons
            animationTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                guard let self = self, let button = self.statusItem.button else { return }
                self.animationFrame = (self.animationFrame + 1) % 2
                button.image = self.animationFrame == 0 ? iconRunning : iconIdle
                button.title = ""
            }
            // Set initial frame
            if let button = statusItem.button {
                button.image = iconRunning
                button.title = ""
            }
        } else {
            // Fallback: rotating quarter-circle emoji
            let frames = ["◐", "◓", "◑", "◒"]
            animationTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                guard let self = self, let button = self.statusItem.button else { return }
                self.animationFrame = (self.animationFrame + 1) % frames.count
                button.image = nil
                button.title = frames[self.animationFrame]
            }
        }
    }

    private static func rotateImage(_ image: NSImage, degrees: CGFloat) -> NSImage {
        return image
    }

    private func stopAnimation() {
        animationTimer?.invalidate()
        animationTimer = nil
    }

    // MARK: Polling

    private func schedulePollTimer(interval: TimeInterval) {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.pollStatus()
        }
    }

    private func pollStatus() {
        let data: Data
        do {
            data = try Data(contentsOf: URL(fileURLWithPath: statusFilePath))
        } catch {
            // No status file yet — treat as idle with no data
            if currentStatus != nil || previousState != "idle" {
                currentStatus = nil
                previousState = "idle"
                DispatchQueue.main.async { [weak self] in
                    self?.setIdleIcon(stale: true, hasError: false)
                    self?.buildMenu()
                }
            }
            return
        }

        let decoder = JSONDecoder()
        guard let status = try? decoder.decode(BackupStatus.self, from: data) else { return }

        let oldState = previousState
        currentStatus = status
        previousState = status.state

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }

            switch status.state {
            case "running":
                self.startAnimation()
                if oldState != "running" {
                    self.schedulePollTimer(interval: 2)
                }

            case "error":
                self.setIdleIcon(stale: false, hasError: true)
                if oldState == "running" {
                    self.schedulePollTimer(interval: 30)
                    self.sendNotification(title: "Backup Error",
                                          body: "Backup encountered \(status.errors ?? 0) error(s).")
                }

            default: // idle
                let stale = self.isBackupStale(status)
                self.setIdleIcon(stale: stale, hasError: false)
                if oldState == "running" {
                    self.schedulePollTimer(interval: 30)
                    let dur = status.last_duration_secs.map { Fmt.duration($0) } ?? "?"
                    let files = status.files_total.map { Fmt.number($0) } ?? "?"
                    self.sendNotification(title: "Backup Complete",
                                          body: "Duration: \(dur) | \(files) files")
                }
            }

            self.buildMenu()
        }
    }

    private func isBackupStale(_ status: BackupStatus) -> Bool {
        guard let lastStr = status.last_completed,
              let lastDate = Fmt.parseISO(lastStr) else { return true }
        return -lastDate.timeIntervalSinceNow > 86400 // > 24 hours
    }

    private func isBackupRecent(_ status: BackupStatus) -> Bool {
        guard let lastStr = status.last_completed,
              let lastDate = Fmt.parseISO(lastStr) else { return false }
        return -lastDate.timeIntervalSinceNow < 7200 // < 2 hours
    }

    // MARK: Menu Building

    private func buildMenu() {
        let menu = NSMenu()
        menu.autoenablesItems = false

        // Header
        let header = NSMenuItem(title: "🦀 RustyMacBackup", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(NSMenuItem.separator())

        if let status = currentStatus, status.state == "running" {
            addRunningSection(to: menu, status: status)
        } else {
            addIdleSection(to: menu)
        }

        menu.addItem(NSMenuItem.separator())

        // Actions
        let backupNowItem = NSMenuItem(title: "Backup Now", action: #selector(backupNow), keyEquivalent: "b")
        backupNowItem.keyEquivalentModifierMask = .command
        backupNowItem.target = self
        if currentStatus?.state == "running" {
            backupNowItem.title = "⏳ Backup in Progress…"
            backupNowItem.isEnabled = false
        } else {
            backupNowItem.title = "● Backup Now"
        }
        menu.addItem(backupNowItem)

        let openItem = NSMenuItem(title: "  Open Backup Folder", action: #selector(openBackupFolder), keyEquivalent: "o")
        openItem.keyEquivalentModifierMask = .command
        openItem.target = self
        menu.addItem(openItem)

        menu.addItem(NSMenuItem.separator())

        // Schedule section
        addScheduleSection(to: menu)

        menu.addItem(NSMenuItem.separator())

        // Config
        let editItem = NSMenuItem(title: "  Edit Config…", action: #selector(editConfig), keyEquivalent: ",")
        editItem.keyEquivalentModifierMask = .command
        editItem.target = self
        menu.addItem(editItem)

        let logItem = NSMenuItem(title: "  View Backup Log", action: #selector(viewLog), keyEquivalent: "")
        logItem.target = self
        menu.addItem(logItem)

        menu.addItem(NSMenuItem.separator())

        // Quit
        let quitItem = NSMenuItem(title: "  Quit", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.keyEquivalentModifierMask = .command
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    private func addIdleSection(to menu: NSMenu) {
        // Last backup
        var lastLine = "Last backup: never"
        if let status = currentStatus,
           let lastStr = status.last_completed,
           let lastDate = Fmt.parseISO(lastStr) {
            lastLine = "Last backup: \(Fmt.relativeTime(from: lastDate))"
        }
        let lastItem = NSMenuItem(title: lastLine, action: nil, keyEquivalent: "")
        lastItem.isEnabled = false
        menu.addItem(lastItem)

        // Duration + files
        if let status = currentStatus,
           let dur = status.last_duration_secs,
           let files = status.files_total {
            let durLine = "Duration: \(Fmt.duration(dur)) | \(Fmt.number(files)) files"
            let durItem = NSMenuItem(title: durLine, action: nil, keyEquivalent: "")
            durItem.isEnabled = false
            menu.addItem(durItem)
        }

        // Disk free
        refreshDiskFreeIfStale()
        if let free = cachedDiskFree {
            let diskItem = NSMenuItem(title: "Disk: \(free) free", action: nil, keyEquivalent: "")
            diskItem.isEnabled = false
            menu.addItem(diskItem)
        }

        // Next backup
        if scheduleEnabled, let status = currentStatus,
           let lastStr = status.last_completed,
           let _ = Fmt.parseISO(lastStr) {
            let nextStr = Fmt.timeUntil(minutes: scheduleIntervalMinutes,
                                        lastCompleted: Fmt.parseISO(lastStr))
            let nextItem = NSMenuItem(title: "Next: \(nextStr)", action: nil, keyEquivalent: "")
            nextItem.isEnabled = false
            menu.addItem(nextItem)
        }

        // Show errors if any
        if let status = currentStatus, let errs = status.errors, errs > 0 {
            let errItem = NSMenuItem(title: "⚠ \(errs) error\(errs == 1 ? "" : "s") in last backup",
                                     action: nil, keyEquivalent: "")
            errItem.isEnabled = false
            menu.addItem(errItem)
        }
    }

    private func addRunningSection(to menu: NSMenu, status: BackupStatus) {
        let done = status.files_done ?? 0
        let total = status.files_total ?? 1
        let pct = total > 0 ? Int(Double(done) / Double(total) * 100) : 0

        let progressLine = "⏳ Backing up… \(pct)% (\(Fmt.number(done))/\(Fmt.number(total)))"
        let progressItem = NSMenuItem(title: progressLine, action: nil, keyEquivalent: "")
        progressItem.isEnabled = false
        menu.addItem(progressItem)

        var detailParts: [String] = []
        if let eta = status.eta_secs {
            detailParts.append("ETA: \(Fmt.duration(Double(eta)))")
        }
        if let bps = status.bytes_per_sec, bps > 0 {
            detailParts.append(Fmt.speed(bps))
        }
        if !detailParts.isEmpty {
            let detailItem = NSMenuItem(title: "   \(detailParts.joined(separator: " | "))",
                                        action: nil, keyEquivalent: "")
            detailItem.isEnabled = false
            menu.addItem(detailItem)
        }

        if let file = status.current_file, !file.isEmpty {
            let truncated = file.count > 40
                ? "…" + String(file.suffix(39))
                : file
            let fileItem = NSMenuItem(title: "   \(truncated)", action: nil, keyEquivalent: "")
            fileItem.isEnabled = false
            menu.addItem(fileItem)
        }

        if let errs = status.errors, errs > 0 {
            let errItem = NSMenuItem(title: "   ⚠ \(errs) error\(errs == 1 ? "" : "s")",
                                     action: nil, keyEquivalent: "")
            errItem.isEnabled = false
            menu.addItem(errItem)
        }
    }

    private func addScheduleSection(to menu: NSMenu) {
        let label = scheduleEnabled
            ? "Schedule: Every \(scheduleIntervalMinutes) min  ✓"
            : "Schedule: Disabled"
        let schedItem = NSMenuItem(title: label, action: nil, keyEquivalent: "")
        schedItem.isEnabled = false
        menu.addItem(schedItem)

        // Change Interval submenu
        let changeItem = NSMenuItem(title: "  Change Interval…", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        for mins in [15, 30, 60, 120] {
            let label = mins < 60 ? "Every \(mins) min" : "Every \(mins / 60) hour\(mins > 60 ? "s" : "")"
            let item = NSMenuItem(title: label, action: #selector(changeInterval(_:)), keyEquivalent: "")
            item.tag = mins
            item.target = self
            if mins == scheduleIntervalMinutes && scheduleEnabled {
                item.state = .on
            }
            submenu.addItem(item)
        }
        changeItem.submenu = submenu
        menu.addItem(changeItem)

        // Disable/Enable
        let toggleItem: NSMenuItem
        if scheduleEnabled {
            toggleItem = NSMenuItem(title: "  Disable Schedule", action: #selector(disableSchedule), keyEquivalent: "")
        } else {
            toggleItem = NSMenuItem(title: "  Enable Schedule", action: #selector(enableSchedule), keyEquivalent: "")
        }
        toggleItem.target = self
        menu.addItem(toggleItem)
    }

    // MARK: Disk Free (cached)

    private func refreshDiskFreeIfStale() {
        if -diskFreeLastChecked.timeIntervalSinceNow > 300 { // refresh every 5 min
            refreshDiskFree()
        }
    }

    private func refreshDiskFree() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let free = DiskInfo.freeSpace()
            DispatchQueue.main.async {
                self?.cachedDiskFree = free
                self?.diskFreeLastChecked = Date()
            }
        }
    }

    // MARK: Schedule State

    private func readScheduleState() {
        Shell.runAsync("rustyback schedule status 2>/dev/null") { [weak self] output in
            guard let self = self else { return }
            let lower = output.lowercased()
            self.scheduleEnabled = lower.contains("active") || lower.contains("enabled")

            // Try to parse interval from output (e.g. "every 60 min")
            let pattern = try? NSRegularExpression(pattern: "(\\d+)\\s*min", options: .caseInsensitive)
            if let match = pattern?.firstMatch(in: output, range: NSRange(output.startIndex..., in: output)),
               let range = Range(match.range(at: 1), in: output),
               let mins = Int(output[range]) {
                self.scheduleIntervalMinutes = mins
            }
            self.buildMenu()
        }
    }

    // MARK: Actions

    @objc private func backupNow() {
        guard currentStatus?.state != "running" else { return }
        Shell.runAsync("rustyback backup 2>&1") { _ in }
        // Polling will pick up the running state from status.json
        // Switch to fast polling immediately
        schedulePollTimer(interval: 2)
        pollStatus()
    }

    @objc private func openBackupFolder() {
        Shell.runAsync("rustyback config show 2>/dev/null") { output in
            let components = output.components(separatedBy: "\"")
            for c in components {
                if c.hasPrefix("/Volumes/") || c.hasPrefix("/") && c.contains("Backup") {
                    NSWorkspace.shared.open(URL(fileURLWithPath: c))
                    return
                }
            }
            // Fallback: open home
            NSWorkspace.shared.open(URL(fileURLWithPath: NSHomeDirectory()))
        }
    }

    @objc private func changeInterval(_ sender: NSMenuItem) {
        let mins = sender.tag
        scheduleIntervalMinutes = mins
        scheduleEnabled = true
        Shell.runAsync("rustyback schedule interval \(mins) 2>&1") { [weak self] _ in
            self?.readScheduleState()
        }
        buildMenu()
    }

    @objc private func disableSchedule() {
        scheduleEnabled = false
        Shell.runAsync("rustyback schedule off 2>&1") { [weak self] _ in
            self?.readScheduleState()
        }
        buildMenu()
    }

    @objc private func enableSchedule() {
        scheduleEnabled = true
        Shell.runAsync("rustyback schedule on 2>&1") { [weak self] _ in
            self?.readScheduleState()
        }
        buildMenu()
    }

    @objc private func editConfig() {
        let home = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
        let configPath = "\(home)/.config/rusty-mac-backup/config.toml"
        if FileManager.default.fileExists(atPath: configPath) {
            NSWorkspace.shared.open(URL(fileURLWithPath: configPath))
        } else {
            Shell.runAsync("rustyback config path 2>/dev/null") { output in
                let path = output.trimmingCharacters(in: .whitespacesAndNewlines)
                if !path.isEmpty && FileManager.default.fileExists(atPath: path) {
                    NSWorkspace.shared.open(URL(fileURLWithPath: path))
                }
            }
        }
    }

    @objc private func viewLog() {
        let home = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
        let logPath = "\(home)/.local/share/rusty-mac-backup/backup.log"
        if FileManager.default.fileExists(atPath: logPath) {
            NSWorkspace.shared.open(URL(fileURLWithPath: logPath))
        } else {
            // Try to find log via CLI
            Shell.runAsync("rustyback log path 2>/dev/null") { output in
                let path = output.trimmingCharacters(in: .whitespacesAndNewlines)
                if !path.isEmpty && FileManager.default.fileExists(atPath: path) {
                    NSWorkspace.shared.open(URL(fileURLWithPath: path))
                } else {
                    DispatchQueue.main.async {
                        let alert = NSAlert()
                        alert.messageText = "No Log Found"
                        alert.informativeText = "No backup log file was found."
                        alert.alertStyle = .informational
                        alert.addButton(withTitle: "OK")
                        alert.runModal()
                    }
                }
            }
        }
    }

    @objc private func quitApp() {
        NSApplication.shared.terminate(nil)
    }

    // MARK: Notifications

    private func requestNotificationPermission() {
        if #available(macOS 10.14, *) {
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
    }

    private func sendNotification(title: String, body: String) {
        if #available(macOS 10.14, *) {
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
            UNUserNotificationCenter.current().add(request)
        }
    }
}

// MARK: - Entry Point

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
