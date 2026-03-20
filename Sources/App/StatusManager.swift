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
            currentState = .diskAbsent
            return currentState
        }

        if let status = lastStatus {
            if status.state == "running" {
                let lockPath = config.destination.path + "/rustymacbackup.lock"
                let lockAlive: Bool = {
                    guard let pidStr = try? String(contentsOfFile: lockPath, encoding: .utf8),
                          let pid = pid_t(pidStr.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                        return false
                    }
                    return kill(pid, 0) == 0  // 0 = alive, -1 = dead/zombie
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
        return currentState
    }
}
