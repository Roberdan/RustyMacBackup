import Foundation
import Darwin

enum CLIHandler {
    static let version = "1.0.0"

    static func run(args: [String], config: Config? = nil) {
        _ = config

        var configPath: String?
        var commandArgs = args
        if let idx = commandArgs.firstIndex(of: "-c") ?? commandArgs.firstIndex(of: "--config") {
            guard idx + 1 < commandArgs.count else {
                printError("Manca il percorso dopo -c/--config")
                exit(1)
            }
            configPath = commandArgs[idx + 1]
            commandArgs.removeSubrange(idx...idx + 1)
        }

        guard let command = commandArgs.first else {
            printUsage()
            exit(1)
        }

        let subArgs = Array(commandArgs.dropFirst())

        do {
            switch command {
            case "version", "--version", "-v":
                print("RustyMacBackup v\(version)")
            case "help", "--help", "-h":
                printUsage()
            case "init":
                try runInitWizard(configPath: configPath)
            case "backup":
                try runBackup(configPath: configPath)
            case "stop":
                try runStop(configPath: configPath)
            case "status":
                try runStatus(configPath: configPath)
            case "prune":
                try runPrune(subArgs: subArgs, configPath: configPath)
            case "list":
                try runList(configPath: configPath)
            case "restore":
                try runRestore(subArgs: subArgs, configPath: configPath)
            case "config":
                try runConfig(subArgs: subArgs, configPath: configPath)
            case "schedule":
                try runSchedule(subArgs: subArgs)
            case "errors":
                runErrors(subArgs: subArgs)
            default:
                printError("Comando sconosciuto: \(command)")
                printUsage()
                exit(1)
            }
            exit(0)
        } catch {
            printError(error.localizedDescription)
            exit(1)
        }
    }

    static func commandNeedsConfig(_ command: String) -> Bool {
        switch command {
        case "backup", "stop", "list", "status", "prune", "restore", "config", "schedule", "errors":
            return true
        default:
            return false
        }
    }

    static func printUsage() {
        print("""
        \(bold("RustyMacBackup v\(version) — Native macOS Backup Tool"))

        Usage: RustyMacBackup [global-options] <command> [options]

        Global options:
          -c, --config <path>    Usa file config personalizzato

        Commands:
          init            First-time setup wizard
          backup          Run backup now
          stop            Stop running backup
          status          Show backup status
          list            List backup snapshots
          prune           Clean up old backups
          restore         Restore file from backup
          config          Manage configuration
          schedule        Manage backup schedule
          errors          Show backup errors
          version         Show version
          help            Show this help
        """)
    }

    static func printError(_ message: String) {
        FileHandle.standardError.write(Data("\(red("Error")): \(message)\n".utf8))
    }

    private static func runBackup(configPath: String?) throws {
        let cfg = try loadConfig(configPath: configPath)
        let fda = FDACheck.checkFullDiskAccess()
        if !fda.hasAccess {
            print(yellow("⚠ Full Disk Access non disponibile per: \(fda.missingPaths.joined(separator: ", "))"))
            print(yellow("  Apri Impostazioni → Privacy → Full Disk Access e aggiungi RustyMacBackup"))
        }

        let sem = DispatchSemaphore(value: 0)
        var backupError: Error?
        Task {
            do {
                try await BackupEngine.run(config: cfg)
            } catch {
                backupError = error
            }
            sem.signal()
        }
        sem.wait()
        if let backupError { throw backupError }
    }

    private static func runStop(configPath: String?) throws {
        let cfg = try loadConfig(configPath: configPath)
        let lockURL = URL(fileURLWithPath: cfg.destination.path).appendingPathComponent("rustyback.lock")
        let fm = FileManager.default

        guard fm.fileExists(atPath: lockURL.path) else {
            print("Nessun backup in esecuzione.")
            return
        }

        let content = try String(contentsOf: lockURL, encoding: .utf8)
        let pidValue = parsePID(from: content)

        guard let pid = pidValue else {
            try? fm.removeItem(at: lockURL)
            print(green("✅ Lock file non valido rimosso."))
            return
        }

        if Darwin.kill(pid, 0) != 0 {
            try? fm.removeItem(at: lockURL)
            print(green("✅ Nessun processo attivo (lock stale rimosso)."))
            return
        }

        if Darwin.kill(pid, SIGTERM) == 0 {
            print(green("✅ Segnale di stop inviato al backup (PID \(pid))."))
        } else {
            throw NSError(domain: "CLI", code: 1, userInfo: [NSLocalizedDescriptionKey: "Impossibile terminare processo PID \(pid)"])
        }
    }

    private static func runStatus(configPath: String?) throws {
        let cfg = try loadConfig(configPath: configPath)
        let statusURL = URL(fileURLWithPath: StatusWriter.statusPath)

        print(bold(blue("RustyMacBackup Status")))
        print("")

        if FileManager.default.fileExists(atPath: statusURL.path),
           let data = try? Data(contentsOf: statusURL),
           let status = try? JSONDecoder().decode(BackupStatusFile.self, from: data) {
            switch status.state {
            case "running":
                print("Stato: \(yellow(bold("RUNNING")))")
                print("Progress: \(status.filesDone)/\(status.filesTotal) file")
                print("ETA: \(status.etaSecs)s")
                print("Velocità: \(BackupEngine.formatBytes(status.bytesPerSec))/s")
                if !status.currentFile.isEmpty {
                    print("File corrente: \(status.currentFile)")
                }
            case "idle":
                print("Stato: \(green("IDLE"))")
                if !status.lastCompleted.isEmpty {
                    print("Ultimo backup: \(status.lastCompleted)")
                    print("Durata: \(String(format: "%.1f", status.lastDurationSecs))s")
                    print("File: \(status.filesTotal)")
                }
            case "error":
                print("Stato: \(red(bold("ERROR")))")
                print("Errori: \(status.errors)")
                if !status.currentFile.isEmpty {
                    print("Ultimo file: \(status.currentFile)")
                }
            default:
                print("Stato: \(status.state)")
            }
        } else {
            print(yellow("Nessun file status.json trovato."))
        }

        print("")
        let destPath = cfg.destination.path
        let diskInfo = DiskDiagnostics.diskSpace(at: destPath)
        let free = BackupEngine.formatBytes(diskInfo.free)
        let total = BackupEngine.formatBytes(diskInfo.total)
        let volumeName = volumeDisplayName(path: destPath)
        let level = DiskDiagnostics.spaceColorLevel(free: diskInfo.free)
        let freeLabel: String
        switch level {
        case .verde: freeLabel = green(free)
        case .warning: freeLabel = yellow(free)
        case .rosso: freeLabel = red(free)
        }

        print(bold("Disco"))
        print("Volume: \(volumeName)")
        print("Spazio libero: \(freeLabel) / \(total)")

        let backups = RetentionManager.listBackups(at: URL(fileURLWithPath: destPath))
        print("Snapshot: \(backups.count)")
        if let latest = backups.first {
            print("Ultimo snapshot: \(latest.name)")
        }
    }

    private static func runPrune(subArgs: [String], configPath: String?) throws {
        let cfg = try loadConfig(configPath: configPath)
        let dryRun = subArgs.contains("--dry-run")
        let destURL = URL(fileURLWithPath: cfg.destination.path)
        let pruned = RetentionManager.pruneBackups(at: destURL, policy: cfg.retention, dryRun: dryRun)
        if pruned.isEmpty {
            print(green("Nothing to prune."))
        } else {
            print("\(dryRun ? "Would prune" : "Pruned") \(pruned.count) backup(s)")
        }
    }

    private static func runList(configPath: String?) throws {
        let cfg = try loadConfig(configPath: configPath)
        let backups = RetentionManager.listBackups(at: URL(fileURLWithPath: cfg.destination.path))
        if backups.isEmpty {
            print("No backups found.")
            return
        }

        print(bold("📦 Backups"))
        for backup in backups {
            let size = RetentionManager.directorySize(at: backup.url)
            print("  \(backup.name)  \(BackupEngine.formatBytes(size))")
        }
        print("\n\(backups.count) backup(s)")
    }

    private static func runRestore(subArgs: [String], configPath: String?) throws {
        guard let snapshot = subArgs.first else {
            throw usageError("Usage: restore <snapshot-name> [path] --to <destination>")
        }

        var relativePath: String?
        var toPath: String?
        var i = 1
        while i < subArgs.count {
            let arg = subArgs[i]
            if arg == "--to" {
                guard i + 1 < subArgs.count else {
                    throw usageError("Usage: restore <snapshot-name> [path] --to <destination>")
                }
                toPath = subArgs[i + 1]
                i += 2
            } else if relativePath == nil {
                relativePath = arg
                i += 1
            } else {
                throw usageError("Argomento inatteso: \(arg)")
            }
        }

        let cfg = try loadConfig(configPath: configPath)
        let snapshotURL = URL(fileURLWithPath: cfg.destination.path).appendingPathComponent(snapshot)
        guard FileManager.default.fileExists(atPath: snapshotURL.path) else {
            throw usageError("Snapshot non trovato: \(snapshot)")
        }

        let sourceURL = relativePath.map { snapshotURL.appendingPathComponent($0) } ?? snapshotURL
        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
            throw usageError("Percorso non trovato nello snapshot: \(relativePath ?? ".")")
        }

        let destinationBase: URL = {
            if let toPath {
                return URL(fileURLWithPath: expandPath(toPath))
            }
            if let relativePath {
                return URL(fileURLWithPath: cfg.source.path).appendingPathComponent(relativePath)
            }
            return URL(fileURLWithPath: cfg.source.path)
        }()

        let destinationURL = resolvedDestination(source: sourceURL, destination: destinationBase)
        let parent = destinationURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)

        if FileManager.default.fileExists(atPath: destinationURL.path) {
            throw usageError("Destinazione già esistente: \(destinationURL.path)")
        }

        try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
        print(green("✅ Ripristino completato"))
        print("Da: \(sourceURL.path)")
        print("A:  \(destinationURL.path)")
    }

    private static func runConfig(subArgs: [String], configPath: String?) throws {
        guard let action = subArgs.first else {
            throw usageError("Usage: config <show|source|dest|exclude|include|excludes|retention|edit>")
        }

        let pathURL = URL(fileURLWithPath: configPath.map(expandPath) ?? Config.defaultPath.path)

        switch action {
        case "show":
            let cfg = try loadConfig(configPath: configPath)
            print("\(bold("Config file:")) \(pathURL.path)")
            print("")
            print(bold(blue("[source]")))
            print("path = \"\(cfg.source.path)\"")
            print("extra_paths = [")
            for extra in cfg.source.extraPaths { print("  \"\(extra)\",") }
            print("]")
            print("")
            print(bold(blue("[destination]")))
            print("path = \"\(cfg.destination.path)\"")
            print("")
            print(bold(blue("[exclude]")))
            print("patterns = [")
            for pattern in cfg.exclude.patterns { print("  \"\(pattern)\",") }
            print("]")
            print("")
            print(bold(blue("[retention]")))
            print("hourly = \(cfg.retention.hourly)")
            print("daily = \(cfg.retention.daily)")
            print("weekly = \(cfg.retention.weekly)")
            print("monthly = \(cfg.retention.monthly)")

        case "source":
            guard subArgs.count >= 2 else { throw usageError("Usage: config source <path>") }
            var cfg = try loadConfig(configPath: configPath)
            cfg.source.path = expandPath(subArgs[1])
            try cfg.save(to: pathURL)
            print(green("✅ Source aggiornata: \(cfg.source.path)"))

        case "dest":
            guard subArgs.count >= 2 else { throw usageError("Usage: config dest <path>") }
            var cfg = try loadConfig(configPath: configPath)
            cfg.destination.path = expandPath(subArgs[1])
            try cfg.save(to: pathURL)
            print(green("✅ Destinazione aggiornata: \(cfg.destination.path)"))

        case "exclude":
            guard subArgs.count >= 2 else { throw usageError("Usage: config exclude <pattern>") }
            var cfg = try loadConfig(configPath: configPath)
            let pattern = subArgs[1]
            if cfg.exclude.patterns.contains(pattern) {
                print(yellow("Pattern già presente: \(pattern)"))
            } else {
                cfg.exclude.patterns.append(pattern)
                try cfg.save(to: pathURL)
                print(green("✅ Pattern aggiunto: \(pattern)"))
            }

        case "include":
            guard subArgs.count >= 2 else { throw usageError("Usage: config include <pattern>") }
            var cfg = try loadConfig(configPath: configPath)
            let pattern = subArgs[1]
            let oldCount = cfg.exclude.patterns.count
            cfg.exclude.patterns.removeAll { $0 == pattern }
            if cfg.exclude.patterns.count == oldCount {
                print(yellow("Pattern non trovato: \(pattern)"))
            } else {
                try cfg.save(to: pathURL)
                print(green("✅ Pattern rimosso: \(pattern)"))
            }

        case "excludes":
            let cfg = try loadConfig(configPath: configPath)
            print(bold("Exclude patterns"))
            if cfg.exclude.patterns.isEmpty {
                print("(nessuno)")
            } else {
                for (idx, pattern) in cfg.exclude.patterns.enumerated() {
                    print("  \(idx + 1). \(pattern)")
                }
            }

        case "retention":
            var cfg = try loadConfig(configPath: configPath)
            let updates = try parseRetentionArgs(Array(subArgs.dropFirst()))
            if let h = updates.hourly { cfg.retention.hourly = h }
            if let d = updates.daily { cfg.retention.daily = d }
            if let w = updates.weekly { cfg.retention.weekly = w }
            if let m = updates.monthly { cfg.retention.monthly = m }
            try cfg.save(to: pathURL)
            print(green("✅ Retention aggiornata"))
            print("hourly=\(cfg.retention.hourly) daily=\(cfg.retention.daily) weekly=\(cfg.retention.weekly) monthly=\(cfg.retention.monthly)")

        case "edit":
            let editor = ProcessInfo.processInfo.environment["EDITOR"] ?? "nano"
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = [editor, pathURL.path]
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus != 0 {
                throw usageError("Editor terminato con errore")
            }

        default:
            throw usageError("Azione config sconosciuta: \(action)")
        }
    }

    private static func runSchedule(subArgs: [String]) throws {
        guard let action = subArgs.first else {
            printScheduleStatus(ScheduleManager.scheduleStatus())
            return
        }

        switch action {
        case "on":
            let plist = ScheduleManager.generatePlist(intervalSeconds: 3600)
            try ScheduleManager.installSchedule(plistContent: plist)
            print(green("✅ Schedule attivato: ogni 60 minuti"))
        case "off":
            try ScheduleManager.removeSchedule()
            print(green("✅ Schedule disattivato"))
        case "status":
            printScheduleStatus(ScheduleManager.scheduleStatus())
        case "interval":
            guard subArgs.count > 1, let minutes = Int(subArgs[1]) else {
                throw usageError("Usage: schedule interval <minutes>")
            }
            let plist = ScheduleManager.generatePlist(intervalSeconds: minutes * 60)
            try ScheduleManager.installSchedule(plistContent: plist)
            print(green("✅ Schedule: ogni \(minutes) minuti"))
        case "daily":
            guard subArgs.count > 1, let hour = Int(subArgs[1]), (0...23).contains(hour) else {
                throw usageError("Usage: schedule daily <hour 0-23>")
            }
            let plist = ScheduleManager.generatePlistDaily(hour: hour)
            try ScheduleManager.installSchedule(plistContent: plist)
            print(green("✅ Schedule: ogni giorno alle \(hour):00"))
        default:
            throw usageError("Unknown schedule action: \(action)")
        }
    }

    private static func runErrors(subArgs: [String]) {
        let showAll = subArgs.contains("--all")
        let errorPath = StatusWriter.errorPath
        guard FileManager.default.fileExists(atPath: errorPath),
              let data = try? Data(contentsOf: URL(fileURLWithPath: errorPath)),
              let errorFile = try? JSONDecoder().decode(BackupErrorFile.self, from: data) else {
            print("No errors recorded.")
            return
        }
        print(ErrorReporter.formatActionableMessage(error: errorFile))
        if showAll {
            for (cat, info) in errorFile.categories where info.count > 0 {
                print("\n\(cat):")
                for file in info.files {
                    print("  \(file)")
                }
            }
        }
    }

    private static func runInitWizard(configPath: String?) throws {
        if configPath != nil {
            print(yellow("⚠ init usa sempre il path config indicato da -c/--config"))
        }

        let fda = FDACheck.checkFullDiskAccess()
        if !fda.hasAccess {
            print(yellow("⚠ Full Disk Access non disponibile"))
            print("  Percorsi non accessibili: \(fda.missingPaths.joined(separator: ", "))")
            print("  Apri Impostazioni → Privacy → Full Disk Access")
            print("  Aggiungi RustyMacBackup.app e riavvia")
            print("")
            print("Vuoi continuare comunque? (s/n): ", terminator: "")
            guard readLine()?.lowercased().starts(with: "s") == true else { exit(0) }
        } else {
            print(green("✅ Full Disk Access: OK"))
        }

        let volumes = discoverVolumes()
        if volumes.isEmpty {
            throw usageError("Nessun disco esterno trovato. Collega un disco e riprova.")
        }

        print("\nDischi disponibili:")
        for (i, vol) in volumes.enumerated() {
            let space = DiskDiagnostics.diskSpace(at: vol.path)
            let freeGB = space.free / 1_073_741_824
            print("  \(i + 1). \(vol.lastPathComponent)  (\(freeGB) GB liberi)")
        }

        print("Seleziona disco (1-\(volumes.count)): ", terminator: "")
        guard let raw = readLine(), let selected = Int(raw), (1...volumes.count).contains(selected) else {
            throw usageError("Selezione non valida")
        }
        let selectedVolume = volumes[selected - 1]

        let encrypted = DiskDiagnostics.checkEncryption(volume: selectedVolume.path)
        if !encrypted {
            print(yellow("⚠ Disco non crittografato!"))
            print("  Si consiglia di attivare la crittografia in Utility Disco")
            print("  Continuare comunque? (s/n): ", terminator: "")
            guard readLine()?.lowercased().starts(with: "s") == true else { exit(0) }
        }

        let backupDir = selectedVolume.appendingPathComponent("RustyMacBackup")
        try FileManager.default.createDirectory(at: backupDir, withIntermediateDirectories: true)
        print(green("✅ Directory creata: \(backupDir.path)"))

        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let configContent = generateDefaultConfig(homePath: home, backupPath: backupDir.path)
        let configURL = URL(fileURLWithPath: configPath.map(expandPath) ?? Config.defaultPath.path)
        try FileManager.default.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try configContent.write(to: configURL, atomically: true, encoding: .utf8)
        print(green("✅ Config salvata: \(configURL.path)"))

        print("\nVuoi eseguire il primo backup adesso? (s/n): ", terminator: "")
        if readLine()?.lowercased().starts(with: "s") == true {
            print("Avvio backup iniziale...")
            try runBackup(configPath: configURL.path)
        }
    }

    static func discoverVolumes() -> [URL] {
        let fm = FileManager.default
        guard let volumes = fm.mountedVolumeURLs(
            includingResourceValuesForKeys: [.volumeNameKey, .volumeIsRemovableKey],
            options: [.skipHiddenVolumes]
        ) else {
            return []
        }

        return volumes.filter { url in
            let path = url.path
            if path == "/" || path == "/System/Volumes/Data" { return false }
            if url.lastPathComponent == "Macintosh HD" { return false }
            return path.hasPrefix("/Volumes/")
        }
    }

    private static func printScheduleStatus(_ status: ScheduleStatus) {
        guard status.installed else {
            print("Schedule: off")
            return
        }
        if let mins = status.intervalMinutes {
            print("Schedule: every \(mins) minutes")
        } else if let hour = status.dailyHour {
            print("Schedule: daily at \(hour):00")
        } else {
            print("Schedule: on")
        }
    }

    private static func loadConfig(configPath: String? = nil) throws -> Config {
        let url = configPath.map { URL(fileURLWithPath: expandPath($0)) } ?? Config.defaultPath
        return try Config.load(from: url)
    }

    private static func parsePID(from lockContent: String) -> Int32? {
        for line in lockContent.split(separator: "\n") {
            let part = String(line).trimmingCharacters(in: .whitespacesAndNewlines)
            if part.hasPrefix("pid:") {
                if let value = Int32(part.replacingOccurrences(of: "pid:", with: "").trimmingCharacters(in: .whitespaces)) {
                    return value
                }
            } else if let value = Int32(part) {
                return value
            }
        }
        return nil
    }

    private static func parseRetentionArgs(_ args: [String]) throws -> (hourly: UInt32?, daily: UInt32?, weekly: UInt32?, monthly: UInt32?) {
        var hourly: UInt32?
        var daily: UInt32?
        var weekly: UInt32?
        var monthly: UInt32?

        var i = 0
        while i < args.count {
            guard i + 1 < args.count, let value = UInt32(args[i + 1]) else {
                throw usageError("Usage: config retention --hourly N --daily N --weekly N --monthly N")
            }
            switch args[i] {
            case "--hourly": hourly = value
            case "--daily": daily = value
            case "--weekly": weekly = value
            case "--monthly": monthly = value
            default:
                throw usageError("Flag retention sconosciuta: \(args[i])")
            }
            i += 2
        }
        return (hourly, daily, weekly, monthly)
    }

    private static func resolvedDestination(source: URL, destination: URL) -> URL {
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: destination.path, isDirectory: &isDirectory)
        if exists && isDirectory.boolValue {
            return destination.appendingPathComponent(source.lastPathComponent)
        }
        return destination
    }

    private static func volumeDisplayName(path: String) -> String {
        let components = URL(fileURLWithPath: path).pathComponents
        if components.count > 2, components[1] == "Volumes" {
            return components[2]
        }
        return URL(fileURLWithPath: path).lastPathComponent
    }

    private static func usageError(_ message: String) -> NSError {
        NSError(domain: "CLI", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    private static func expandPath(_ path: String) -> String {
        (path as NSString).expandingTildeInPath
    }

    private static func colored(_ text: String, _ code: String) -> String {
        guard isatty(STDOUT_FILENO) != 0 else { return text }
        return "\u{001B}[\(code)m\(text)\u{001B}[0m"
    }

    static func green(_ text: String) -> String { colored(text, "32") }
    static func red(_ text: String) -> String { colored(text, "31") }
    static func yellow(_ text: String) -> String { colored(text, "33") }
    static func blue(_ text: String) -> String { colored(text, "34") }
    static func bold(_ text: String) -> String { colored(text, "1") }
}
