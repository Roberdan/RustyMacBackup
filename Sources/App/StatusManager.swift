import Foundation

enum AppState {
    case needsSetup
    case idle
    case running
    case error
    case diskAbsent
    case stale
}

class StatusManager {
    var currentState: AppState = .idle
    var lastStatus: BackupStatusFile?
    private let statusWriter = StatusWriter()

    func poll(config: Config?) -> AppState {
        guard let config = config else {
            currentState = .needsSetup
            return currentState
        }

        lastStatus = statusWriter.read()

        if !FileManager.default.fileExists(atPath: config.destination.path) {
            // F-03: Only recreate backup dir if the volume is actually mounted — not just if
            // the parent path exists (a stale /Volumes/ mountpoint passes that check).
            let destURL = URL(fileURLWithPath: config.destination.path)
            if BackupEngine.isVolumeReallyMounted(destURL.deletingLastPathComponent().path) {
                try? FileManager.default.createDirectory(at: destURL, withIntermediateDirectories: true)
            }
            if !FileManager.default.fileExists(atPath: config.destination.path) {
                currentState = .diskAbsent
                return currentState
            }
        }

        if let status = lastStatus {
            if status.state == "running" {
                let lockPath = config.destination.path + "/rustymacbackup.lock"
                let lockAlive: Bool = {
                    // F-01: lock file now contains "PID\nTIMESTAMP\nUUID" — read first line only
                    guard let content = try? String(contentsOfFile: lockPath, encoding: .utf8),
                          let firstLine = content.split(separator: "\n").first.map(String.init),
                          let pid = pid_t(firstLine.trimmingCharacters(in: .whitespaces)) else {
                        return false
                    }
                    return kill(pid, 0) == 0
                }()
                if lockAlive {
                    currentState = .running
                    return currentState
                }
                // Stale lock (process crashed) — remove and mark idle
                try? FileManager.default.removeItem(atPath: lockPath)
                var fixed = status
                fixed.state = "idle"
                try? statusWriter.write(status: fixed)
                lastStatus = fixed
            }
            // F-02: "cancelled" is a terminal state — treat as idle, not error
            if status.state == "cancelled" {
                currentState = .idle
                return currentState
            }
            if status.state == "error" {
                currentState = .error
                return currentState
            }
            if !status.lastCompleted.isEmpty,
               let lastDate = ISO8601DateFormatter().date(from: status.lastCompleted),
               Date().timeIntervalSince(lastDate) > 86400 {
                currentState = .stale
                return currentState
            }
        }

        currentState = .idle

        // Synthesize lastCompleted from disk if status file is missing or incomplete.
        // Snapshot folders are named "YYYY-MM-DD_HHmmss" — convert to ISO8601.
        if lastStatus == nil || lastStatus?.lastCompleted.isEmpty == true {
            let destURL = URL(fileURLWithPath: config.destination.path)
            let entries = RetentionManager.listBackups(at: destURL)
            if let latest = entries.first {
                let iso = snapshotNameToISO8601(latest.name)
                var synthetic = lastStatus ?? BackupStatusFile(
                    state: "idle", startedAt: "", lastCompleted: "",
                    lastDurationSecs: 0, filesTotal: 0, filesDone: 0,
                    bytesCopied: 0, bytesPerSec: 0, etaSecs: 0,
                    errors: 0, currentFile: ""
                )
                synthetic.state = "idle"
                synthetic.lastCompleted = iso
                lastStatus = synthetic
                try? statusWriter.write(status: synthetic)
            }
        }

        return currentState
    }

    /// Convert "2026-03-20_143846" → "2026-03-20T14:38:46Z"
    private func snapshotNameToISO8601(_ name: String) -> String {
        let parts = name.split(separator: "_")
        guard parts.count == 2 else { return name }
        let t = Array(parts[1])
        guard t.count >= 6 else { return name }
        let hh = String(t[0...1]); let mm = String(t[2...3]); let ss = String(t[4...5])
        return "\(parts[0])T\(hh):\(mm):\(ss)Z"
    }
}
