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

// MARK: - Config Manager

struct ParsedConfig {
    var sourcePath: String = ""
    var extraPaths: [String] = []
    var destPath: String = ""
    var excludePatterns: [String] = []
    var hourly: Int = 24
    var daily: Int = 30
    var weekly: Int = 52
    var monthly: Int = 0

    var allSourcePaths: [String] {
        var paths = [sourcePath]
        paths.append(contentsOf: extraPaths)
        return paths.filter { !$0.isEmpty }
    }
}

enum ConfigManager {
    private static let home = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
    static let configPath = "\(home)/.config/rusty-mac-backup/config.toml"

    static func load() -> ParsedConfig {
        guard let content = try? String(contentsOfFile: configPath, encoding: .utf8) else {
            return ParsedConfig()
        }
        return parseTOML(content)
    }

    private static func parseTOML(_ content: String) -> ParsedConfig {
        var config = ParsedConfig()
        var section = ""
        var inArray = false
        var arrayKey = ""
        var arrayValues: [String] = []

        for rawLine in content.components(separatedBy: "\n") {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") {
                if inArray && trimmed.hasPrefix("#") { continue }
                if !inArray { continue }
                continue
            }

            if trimmed.hasPrefix("[") && !trimmed.hasPrefix("[[") && trimmed.hasSuffix("]") && !inArray {
                section = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
                continue
            }

            if inArray {
                if trimmed.hasPrefix("]") {
                    switch "\(section).\(arrayKey)" {
                    case "source.extra_paths": config.extraPaths = arrayValues
                    case "exclude.patterns": config.excludePatterns = arrayValues
                    default: break
                    }
                    inArray = false
                    arrayValues = []
                    continue
                }
                if let val = extractQuoted(trimmed) {
                    arrayValues.append(val)
                }
                continue
            }

            guard let eqIdx = trimmed.firstIndex(of: "=") else { continue }
            let key = String(trimmed[..<eqIdx]).trimmingCharacters(in: .whitespaces)
            var value = String(trimmed[trimmed.index(after: eqIdx)...]).trimmingCharacters(in: .whitespaces)

            if let commentRange = value.range(of: " #") {
                value = String(value[..<commentRange.lowerBound]).trimmingCharacters(in: .whitespaces)
            }

            if value.hasPrefix("[") && !value.hasSuffix("]") {
                inArray = true
                arrayKey = key
                arrayValues = []
                continue
            }

            if value.hasPrefix("[") && value.hasSuffix("]") {
                let inner = String(value.dropFirst().dropLast())
                let vals = inner.components(separatedBy: ",").compactMap { extractQuoted($0) }
                switch "\(section).\(key)" {
                case "source.extra_paths": config.extraPaths = vals
                case "exclude.patterns": config.excludePatterns = vals
                default: break
                }
                continue
            }

            switch "\(section).\(key)" {
            case "source.path": config.sourcePath = extractQuoted(value) ?? value
            case "destination.path": config.destPath = extractQuoted(value) ?? value
            case "retention.hourly": config.hourly = Int(value) ?? 24
            case "retention.daily": config.daily = Int(value) ?? 30
            case "retention.weekly": config.weekly = Int(value) ?? 52
            case "retention.monthly": config.monthly = Int(value) ?? 0
            default: break
            }
        }
        return config
    }

    private static func extractQuoted(_ s: String) -> String? {
        let t = s.trimmingCharacters(in: CharacterSet(charactersIn: " ,\t"))
        guard t.count >= 2, t.hasPrefix("\""), t.hasSuffix("\"") else { return nil }
        return String(t.dropFirst().dropLast())
    }

    // MARK: Extra Paths Management

    static func addExtraPath(_ path: String) {
        guard var content = try? String(contentsOfFile: configPath, encoding: .utf8) else { return }
        if let range = content.range(of: "extra_paths") {
            var searchStart = range.upperBound
            if let bracketStart = content.range(of: "[", range: searchStart..<content.endIndex) {
                searchStart = bracketStart.upperBound
            }
            if let closeRange = content.range(of: "]", range: searchStart..<content.endIndex) {
                let insertion = "    \"\(path)\",\n"
                content.insert(contentsOf: insertion, at: closeRange.lowerBound)
                try? content.write(toFile: configPath, atomically: true, encoding: .utf8)
            }
        } else {
            // No extra_paths yet — add after the path line in [source]
            let searchStart: String.Index
            if let sourceRange = content.range(of: "[source]") {
                searchStart = sourceRange.upperBound
            } else {
                searchStart = content.startIndex
            }
            if let pathLine = content.range(of: "path = ", range: searchStart..<content.endIndex) {
                if let lineEnd = content.range(of: "\n", range: pathLine.upperBound..<content.endIndex) {
                    let insertion = "extra_paths = [\n    \"\(path)\",\n]\n"
                    content.insert(contentsOf: insertion, at: lineEnd.upperBound)
                    try? content.write(toFile: configPath, atomically: true, encoding: .utf8)
                }
            }
        }
    }

    static func removeExtraPath(_ path: String) {
        guard var content = try? String(contentsOfFile: configPath, encoding: .utf8) else { return }
        let escaped = path.replacingOccurrences(of: "/", with: "\\/")
        let _ = escaped // suppress unused warning
        let patterns = [
            "    \"\(path)\",\n",
            "    \"\(path)\"\n",
            "    \"\(path)\",",
            "    \"\(path)\"",
        ]
        for p in patterns {
            if content.contains(p) {
                content = content.replacingOccurrences(of: p, with: "")
                break
            }
        }
        try? content.write(toFile: configPath, atomically: true, encoding: .utf8)
    }
}

// MARK: - Volume Scanner

struct VolumeInfo {
    let name: String
    let path: String
    let freeSpace: Int64
    let isEncrypted: Bool

    var freeSpaceFormatted: String { Fmt.bytes(freeSpace) }
    var encryptionIcon: String { isEncrypted ? "🔒" : "⚠️" }
}

enum VolumeScanner {
    static func connectedVolumes() -> [VolumeInfo] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: "/Volumes") else { return [] }

        return entries.sorted().compactMap { name -> VolumeInfo? in
            guard !name.hasPrefix("."),
                  name != "Macintosh HD",
                  name != "Recovery" else { return nil }
            let volumePath = "/Volumes/\(name)"
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: volumePath, isDirectory: &isDir), isDir.boolValue else { return nil }

            let url = URL(fileURLWithPath: volumePath)
            let free: Int64
            if let vals = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
               let f = vals.volumeAvailableCapacityForImportantUsage {
                free = f
            } else {
                free = 0
            }

            let encrypted = checkEncryption(volumePath)
            return VolumeInfo(name: name, path: volumePath, freeSpace: free, isEncrypted: encrypted)
        }
    }

    static func checkEncryption(_ volumePath: String) -> Bool {
        let output = Shell.run("diskutil info \"\(volumePath)\" 2>/dev/null")
        let lower = output.lowercased()
        return lower.contains("filevault: yes")
            || lower.contains("encrypted: yes")
            || (lower.contains("file system personality") && lower.contains("encrypted"))
    }
}

// MARK: - Disk Info

struct DiskDetail {
    let volumeName: String
    let freeSpace: String
    let isEncrypted: Bool

    var summary: String {
        "\(volumeName) — \(freeSpace) free \(isEncrypted ? "🔒" : "⚠️")"
    }
}

enum DiskInfo {
    static func detail(for config: ParsedConfig) -> DiskDetail? {
        let destPath = config.destPath
        guard !destPath.isEmpty else { return nil }

        let volumeName: String
        let volumeRoot: String
        if destPath.hasPrefix("/Volumes/") {
            let parts = destPath.split(separator: "/", maxSplits: 3)
            volumeName = parts.count >= 2 ? String(parts[1]) : "Unknown"
            volumeRoot = "/Volumes/\(volumeName)"
        } else {
            volumeName = "Macintosh HD"
            volumeRoot = "/"
        }

        let url = URL(fileURLWithPath: volumeRoot)
        var free: Int64 = 0
        if let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
           let cap = values.volumeAvailableCapacityForImportantUsage, cap > 0 {
            free = cap
        } else if let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityKey]),
                  let cap = values.volumeAvailableCapacity, cap > 0 {
            free = Int64(cap)
        } else {
            // Fallback: use df command
            let dfOutput = Shell.run("df -k '\(volumeRoot)' | tail -1 | awk '{print $4}'")
            if let kb = Int64(dfOutput.trimmingCharacters(in: .whitespacesAndNewlines)) {
                free = kb * 1024
            }
        }

        guard free > 0 else { return nil }

        let encrypted = VolumeScanner.checkEncryption(volumeRoot)
        return DiskDetail(volumeName: volumeName, freeSpace: Fmt.bytes(free), isEncrypted: encrypted)
    }

    static func freeSpace() -> String? {
        return detail(for: ConfigManager.load())?.freeSpace
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
    private var cachedConfig: ParsedConfig = ParsedConfig()
    private var cachedDiskDetail: DiskDetail?
    private var diskDetailLastChecked: Date = .distantPast

    private let statusFilePath: String = {
        let home = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
        return "\(home)/.local/share/rusty-mac-backup/status.json"
    }()

    // MARK: Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
        readScheduleState()
        reloadConfig()
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

        let symbolName: String
        if hasError {
            symbolName = "externaldrive.badge.xmark"
        } else if stale {
            symbolName = "externaldrive.badge.exclamationmark"
        } else {
            symbolName = "externaldrive.fill.badge.checkmark"
        }

        if let img = NSImage(systemSymbolName: symbolName,
                              accessibilityDescription: "RustyMacBackup") {
            img.isTemplate = true
            button.image = img
            button.title = ""
        } else {
            button.image = nil
            button.title = hasError ? "⚠" : "💾"
        }
    }

    private func startAnimation() {
        guard animationTimer == nil else { return }
        animationFrame = 0

        // Use SF Symbol for sync animation
        let syncImg = NSImage(systemSymbolName: "arrow.triangle.2.circlepath",
                               accessibilityDescription: "Backing up")
        let driveImg = NSImage(systemSymbolName: "externaldrive.fill",
                                accessibilityDescription: "Backing up")
        syncImg?.isTemplate = true
        driveImg?.isTemplate = true

        animationTimer = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: true) { [weak self] _ in
            guard let self = self, let button = self.statusItem.button else { return }
            self.animationFrame = (self.animationFrame + 1) % 2
            button.image = self.animationFrame == 0 ? syncImg : driveImg
            button.title = ""
        }
        if let button = statusItem.button {
            button.image = syncImg
            button.title = ""
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

        // Check if setup is needed
        let configExists = FileManager.default.fileExists(atPath: ConfigManager.configPath)
        let hasFullDiskAccess = checkFullDiskAccess()

        if !configExists {
            // No config — show setup required
            let header = NSMenuItem(title: "⚠️ Setup Required", action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)
            menu.addItem(NSMenuItem.separator())

            let setupItem = NSMenuItem(title: "Run First-Time Setup...", action: #selector(runSetup), keyEquivalent: "")
            setupItem.target = self
            menu.addItem(setupItem)

            let helpItem = NSMenuItem(title: "Open in terminal: rustyback init", action: nil, keyEquivalent: "")
            helpItem.isEnabled = false
            menu.addItem(helpItem)

            menu.addItem(NSMenuItem.separator())
            let quitItem = NSMenuItem(title: "Quit", action: #selector(quitApp), keyEquivalent: "q")
            quitItem.target = self
            menu.addItem(quitItem)
            statusItem.menu = menu
            return
        }

        if !hasFullDiskAccess {
            // Config exists but no FDA
            let header = NSMenuItem(title: "RustyMacBackup", action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)
            menu.addItem(NSMenuItem.separator())

            let fdaItem = NSMenuItem(title: "⚠️ Full Disk Access Required", action: nil, keyEquivalent: "")
            fdaItem.isEnabled = false
            menu.addItem(fdaItem)

            let fixItem = NSMenuItem(title: "Open Privacy Settings...", action: #selector(openFDASettings), keyEquivalent: "")
            fixItem.target = self
            menu.addItem(fixItem)

            let helpItem = NSMenuItem(title: "Add RustyBackMenu.app to Full Disk Access", action: nil, keyEquivalent: "")
            helpItem.isEnabled = false
            menu.addItem(helpItem)

            menu.addItem(NSMenuItem.separator())
            let quitItem = NSMenuItem(title: "Quit", action: #selector(quitApp), keyEquivalent: "q")
            quitItem.target = self
            menu.addItem(quitItem)
            statusItem.menu = menu
            return
        }

        // Normal menu — config exists and FDA granted
        // Header
        let header = NSMenuItem(title: "RustyMacBackup", action: nil, keyEquivalent: "")
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

        // Schedule submenu
        addScheduleSubmenu(to: menu)

        menu.addItem(NSMenuItem.separator())

        // Preferences submenu
        addPreferencesSubmenu(to: menu)

        menu.addItem(NSMenuItem.separator())

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

        // Disk info with volume name and encryption
        refreshDiskDetailIfStale()
        if let detail = cachedDiskDetail {
            let diskItem = NSMenuItem(title: "Disk: \(detail.summary)", action: nil, keyEquivalent: "")
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

    private func addScheduleSubmenu(to menu: NSMenu) {
        let schedLabel = scheduleEnabled
            ? (scheduleIntervalMinutes >= 1440
                ? "Schedule: Daily at \(scheduleIntervalMinutes / 60 - 24 + (scheduleIntervalMinutes % 60 == 0 ? 0 : 1)):00"
                : "Schedule: Every \(scheduleIntervalMinutes) min")
            : "Schedule: Disabled"
        let schedItem = NSMenuItem(title: "  \(schedLabel)", action: nil, keyEquivalent: "")
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

        submenu.addItem(NSMenuItem.separator())

        // Daily schedule options
        let dailyHeader = NSMenuItem(title: "Daily at:", action: nil, keyEquivalent: "")
        dailyHeader.isEnabled = false
        submenu.addItem(dailyHeader)
        for hour in [2, 3, 4, 6] {
            let label = String(format: "%02d:00 AM", hour)
            let item = NSMenuItem(title: label, action: #selector(changeDailySchedule(_:)), keyEquivalent: "")
            item.tag = hour
            item.target = self
            submenu.addItem(item)
        }

        submenu.addItem(NSMenuItem.separator())

        if scheduleEnabled {
            let disableItem = NSMenuItem(title: "Disable", action: #selector(disableSchedule), keyEquivalent: "")
            disableItem.target = self
            submenu.addItem(disableItem)
        } else {
            let enableItem = NSMenuItem(title: "Enable", action: #selector(enableSchedule), keyEquivalent: "")
            enableItem.target = self
            submenu.addItem(enableItem)
        }

        schedItem.submenu = submenu
        menu.addItem(schedItem)
    }

    // MARK: Preferences Submenu

    private func addPreferencesSubmenu(to menu: NSMenu) {
        let prefsItem = NSMenuItem(title: "  Preferences", action: nil, keyEquivalent: ",")
        prefsItem.keyEquivalentModifierMask = .command
        let prefsMenu = NSMenu()

        // Backup Disk >
        let diskItem = NSMenuItem(title: "Backup Disk", action: nil, keyEquivalent: "")
        diskItem.submenu = buildBackupDiskSubmenu()
        prefsMenu.addItem(diskItem)

        // Source Paths >
        let sourcesItem = NSMenuItem(title: "Source Paths", action: nil, keyEquivalent: "")
        sourcesItem.submenu = buildSourcePathsSubmenu()
        prefsMenu.addItem(sourcesItem)

        // Excludes >
        let excludesItem = NSMenuItem(title: "Excludes", action: nil, keyEquivalent: "")
        excludesItem.submenu = buildExcludesSubmenu()
        prefsMenu.addItem(excludesItem)

        // Retention >
        let retentionItem = NSMenuItem(title: "Retention", action: nil, keyEquivalent: "")
        retentionItem.submenu = buildRetentionSubmenu()
        prefsMenu.addItem(retentionItem)

        prefsItem.submenu = prefsMenu
        menu.addItem(prefsItem)
    }

    private func buildBackupDiskSubmenu() -> NSMenu {
        let sub = NSMenu()
        let volumes = VolumeScanner.connectedVolumes()
        let currentDest = cachedConfig.destPath

        if volumes.isEmpty {
            let noDisks = NSMenuItem(title: "No external disks found", action: nil, keyEquivalent: "")
            noDisks.isEnabled = false
            sub.addItem(noDisks)
        } else {
            for vol in volumes {
                let label = "\(vol.name) — \(vol.freeSpaceFormatted) \(vol.encryptionIcon)"
                let item = NSMenuItem(title: label, action: #selector(selectBackupDisk(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = vol.path as NSString
                if currentDest.hasPrefix(vol.path) {
                    item.state = .on
                }
                sub.addItem(item)
            }
        }

        return sub
    }

    private func buildSourcePathsSubmenu() -> NSMenu {
        let sub = NSMenu()
        let paths = cachedConfig.allSourcePaths

        // Show current paths as disabled info items
        for path in paths {
            let item = NSMenuItem(title: path, action: nil, keyEquivalent: "")
            item.isEnabled = false
            sub.addItem(item)
        }

        sub.addItem(NSMenuItem.separator())

        // Add Path...
        let addItem = NSMenuItem(title: "Add Path…", action: #selector(addSourcePath), keyEquivalent: "")
        addItem.target = self
        sub.addItem(addItem)

        // Remove Path >
        if !cachedConfig.extraPaths.isEmpty {
            let removeItem = NSMenuItem(title: "Remove Path", action: nil, keyEquivalent: "")
            let removeSub = NSMenu()
            for path in cachedConfig.extraPaths {
                let item = NSMenuItem(title: path, action: #selector(removeSourcePath(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = path as NSString
                removeSub.addItem(item)
            }
            removeItem.submenu = removeSub
            sub.addItem(removeItem)
        }

        return sub
    }

    private func buildExcludesSubmenu() -> NSMenu {
        let sub = NSMenu()
        let patterns = cachedConfig.excludePatterns

        // Count
        let countItem = NSMenuItem(title: "\(patterns.count) patterns active", action: nil, keyEquivalent: "")
        countItem.isEnabled = false
        sub.addItem(countItem)

        sub.addItem(NSMenuItem.separator())

        // Add Exclude...
        let addItem = NSMenuItem(title: "Add Exclude…", action: #selector(addExcludePattern), keyEquivalent: "")
        addItem.target = self
        sub.addItem(addItem)

        // Remove Exclude >
        if !patterns.isEmpty {
            let removeItem = NSMenuItem(title: "Remove Exclude", action: nil, keyEquivalent: "")
            let removeSub = NSMenu()
            for pattern in patterns {
                let item = NSMenuItem(title: pattern, action: #selector(removeExcludePattern(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = pattern as NSString
                removeSub.addItem(item)
            }
            removeItem.submenu = removeSub
            sub.addItem(removeItem)
        }

        sub.addItem(NSMenuItem.separator())

        // Common Excludes >
        let commonItem = NSMenuItem(title: "Common Excludes", action: nil, keyEquivalent: "")
        commonItem.submenu = buildCommonExcludesSubmenu()
        sub.addItem(commonItem)

        return sub
    }

    private func buildCommonExcludesSubmenu() -> NSMenu {
        let sub = NSMenu()
        let current = Set(cachedConfig.excludePatterns)
        let presets: [(String, Bool)] = [
            ("node_modules", true),
            (".git/objects", true),
            ("OneDrive*", true),
            ("Library/Caches", true),
            ("Downloads", false),
            ("Movies", false),
            (".ollama/models", false),
        ]

        for (pattern, _) in presets {
            let isActive = current.contains(pattern)
            let item = NSMenuItem(title: pattern, action: #selector(toggleCommonExclude(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = pattern as NSString
            item.state = isActive ? .on : .off
            sub.addItem(item)
        }

        return sub
    }

    private func buildRetentionSubmenu() -> NSMenu {
        let sub = NSMenu()
        let cfg = cachedConfig

        let hourlyLabel = "Hourly: \(cfg.hourly)"
        let hourlyItem = NSMenuItem(title: hourlyLabel, action: nil, keyEquivalent: "")
        let hourlySub = NSMenu()
        for val in [6, 12, 24, 48] {
            let item = NSMenuItem(title: "\(val)", action: #selector(changeRetentionHourly(_:)), keyEquivalent: "")
            item.tag = val
            item.target = self
            if val == cfg.hourly { item.state = .on }
            hourlySub.addItem(item)
        }
        hourlyItem.submenu = hourlySub
        sub.addItem(hourlyItem)

        let dailyLabel = "Daily: \(cfg.daily)"
        let dailyItem = NSMenuItem(title: dailyLabel, action: nil, keyEquivalent: "")
        let dailySub = NSMenu()
        for val in [7, 14, 30, 60] {
            let item = NSMenuItem(title: "\(val)", action: #selector(changeRetentionDaily(_:)), keyEquivalent: "")
            item.tag = val
            item.target = self
            if val == cfg.daily { item.state = .on }
            dailySub.addItem(item)
        }
        dailyItem.submenu = dailySub
        sub.addItem(dailyItem)

        let weeklyLabel = "Weekly: \(cfg.weekly)"
        let weeklyItem = NSMenuItem(title: weeklyLabel, action: nil, keyEquivalent: "")
        let weeklySub = NSMenu()
        for val in [12, 26, 52, 104] {
            let item = NSMenuItem(title: "\(val)", action: #selector(changeRetentionWeekly(_:)), keyEquivalent: "")
            item.tag = val
            item.target = self
            if val == cfg.weekly { item.state = .on }
            weeklySub.addItem(item)
        }
        weeklyItem.submenu = weeklySub
        sub.addItem(weeklyItem)

        let monthlyDisplay = cfg.monthly == 0 ? "forever" : "\(cfg.monthly)"
        let monthlyLabel = "Monthly: \(monthlyDisplay)"
        let monthlyItem = NSMenuItem(title: monthlyLabel, action: nil, keyEquivalent: "")
        let monthlySub = NSMenu()
        for val in [6, 12, 0] {
            let label = val == 0 ? "forever" : "\(val)"
            let item = NSMenuItem(title: label, action: #selector(changeRetentionMonthly(_:)), keyEquivalent: "")
            item.tag = val
            item.target = self
            if val == cfg.monthly { item.state = .on }
            monthlySub.addItem(item)
        }
        monthlyItem.submenu = monthlySub
        sub.addItem(monthlyItem)

        return sub
    }

    // MARK: Config & Disk Caching

    private func reloadConfig() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let config = ConfigManager.load()
            let detail = DiskInfo.detail(for: config)
            DispatchQueue.main.async {
                self?.cachedConfig = config
                self?.cachedDiskDetail = detail
                self?.diskDetailLastChecked = Date()
                self?.buildMenu()
            }
        }
    }

    private func refreshDiskDetailIfStale() {
        if -diskDetailLastChecked.timeIntervalSinceNow > 300 {
            refreshDiskDetail()
        }
    }

    private func refreshDiskDetail() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let detail = DiskInfo.detail(for: self?.cachedConfig ?? ConfigManager.load())
            DispatchQueue.main.async {
                self?.cachedDiskDetail = detail
                self?.diskDetailLastChecked = Date()
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

    @objc private func changeDailySchedule(_ sender: NSMenuItem) {
        let hour = sender.tag
        scheduleEnabled = true
        scheduleIntervalMinutes = 1440 // mark as daily
        Shell.runAsync("rustyback schedule daily \(hour) 2>&1") { [weak self] _ in
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

    @objc private func selectBackupDisk(_ sender: NSMenuItem) {
        guard let volumePath = sender.representedObject as? String else { return }
        let destPath = "\(volumePath)/RustyMacBackup"

        // Check encryption
        let vol = VolumeScanner.connectedVolumes().first { $0.path == volumePath }
        if let v = vol, !v.isEncrypted {
            DispatchQueue.main.async {
                let alert = NSAlert()
                alert.messageText = "Disk Not Encrypted"
                alert.informativeText = """
                \(v.name) is not encrypted. Your backups will be stored unencrypted.

                To encrypt: open Disk Utility → select \(v.name) → File → Encrypt "\(v.name)…"

                Or use Finder: right-click the disk → Encrypt "\(v.name)…"
                """
                alert.alertStyle = .warning
                alert.addButton(withTitle: "Use Anyway")
                alert.addButton(withTitle: "Cancel")
                NSApp.activate(ignoringOtherApps: true)
                let response = alert.runModal()
                if response != .alertFirstButtonReturn { return }

                Shell.runAsync("rustyback config dest \"\(destPath)\" 2>&1") { [weak self] _ in
                    self?.reloadConfig()
                }
            }
            return
        }

        Shell.runAsync("rustyback config dest \"\(destPath)\" 2>&1") { [weak self] _ in
            self?.reloadConfig()
        }
    }

    @objc private func addSourcePath() {
        DispatchQueue.main.async { [weak self] in
            let panel = NSOpenPanel()
            panel.title = "Select Source Directory"
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.allowsMultipleSelection = false
            panel.canCreateDirectories = false
            NSApp.activate(ignoringOtherApps: true)

            if panel.runModal() == .OK, let url = panel.url {
                let path = url.path
                DispatchQueue.global(qos: .userInitiated).async {
                    ConfigManager.addExtraPath(path)
                    DispatchQueue.main.async {
                        self?.reloadConfig()
                    }
                }
            }
        }
    }

    @objc private func removeSourcePath(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            ConfigManager.removeExtraPath(path)
            DispatchQueue.main.async {
                self?.reloadConfig()
            }
        }
    }

    @objc private func addExcludePattern() {
        DispatchQueue.main.async { [weak self] in
            let alert = NSAlert()
            alert.messageText = "Add Exclude Pattern"
            alert.informativeText = "Enter a glob pattern to exclude from backups.\nExamples: *.log, Downloads, .cache"
            alert.addButton(withTitle: "Add")
            alert.addButton(withTitle: "Cancel")

            let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
            input.placeholderString = "pattern (e.g. *.log)"
            alert.accessoryView = input
            alert.window.initialFirstResponder = input
            NSApp.activate(ignoringOtherApps: true)

            let response = alert.runModal()
            if response == .alertFirstButtonReturn {
                let pattern = input.stringValue.trimmingCharacters(in: .whitespaces)
                guard !pattern.isEmpty else { return }
                Shell.runAsync("rustyback config exclude \"\(pattern)\" 2>&1") { _ in
                    self?.reloadConfig()
                }
            }
        }
    }

    @objc private func removeExcludePattern(_ sender: NSMenuItem) {
        guard let pattern = sender.representedObject as? String else { return }
        Shell.runAsync("rustyback config include \"\(pattern)\" 2>&1") { [weak self] _ in
            self?.reloadConfig()
        }
    }

    @objc private func toggleCommonExclude(_ sender: NSMenuItem) {
        guard let pattern = sender.representedObject as? String else { return }
        let isCurrentlyActive = cachedConfig.excludePatterns.contains(pattern)
        if isCurrentlyActive {
            Shell.runAsync("rustyback config include \"\(pattern)\" 2>&1") { [weak self] _ in
                self?.reloadConfig()
            }
        } else {
            Shell.runAsync("rustyback config exclude \"\(pattern)\" 2>&1") { [weak self] _ in
                self?.reloadConfig()
            }
        }
    }

    @objc private func changeRetentionHourly(_ sender: NSMenuItem) {
        Shell.runAsync("rustyback config retention --hourly \(sender.tag) 2>&1") { [weak self] _ in
            self?.reloadConfig()
        }
    }

    @objc private func changeRetentionDaily(_ sender: NSMenuItem) {
        Shell.runAsync("rustyback config retention --daily \(sender.tag) 2>&1") { [weak self] _ in
            self?.reloadConfig()
        }
    }

    @objc private func changeRetentionWeekly(_ sender: NSMenuItem) {
        Shell.runAsync("rustyback config retention --weekly \(sender.tag) 2>&1") { [weak self] _ in
            self?.reloadConfig()
        }
    }

    @objc private func changeRetentionMonthly(_ sender: NSMenuItem) {
        Shell.runAsync("rustyback config retention --monthly \(sender.tag) 2>&1") { [weak self] _ in
            self?.reloadConfig()
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

    @objc private func runSetup() {
        // Open terminal and run rustyback init
        let script = "tell application \"Terminal\" to do script \"rustyback init\""
        NSAppleScript(source: script)?.executeAndReturnError(nil)
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app"))
    }

    @objc private func openFDASettings() {
        // Open System Settings > Privacy > Full Disk Access
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }

    private func checkFullDiskAccess() -> Bool {
        // Try to list contents of a TCC-protected directory
        // If FDA is not granted, this will return nil/empty
        let home = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
        let testPaths = ["\(home)/Library/Safari", "\(home)/Library/Mail", "\(home)/Library/Messages"]
        for path in testPaths {
            if FileManager.default.fileExists(atPath: path) {
                if let contents = try? FileManager.default.contentsOfDirectory(atPath: path) {
                    return !contents.isEmpty || true // directory exists and is listable = FDA OK
                }
                // Can't list = no FDA
                return false
            }
        }
        // None of the test dirs exist — assume FDA is OK (can't determine)
        return true
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
