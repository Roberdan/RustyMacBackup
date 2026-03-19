import Foundation

enum AppState {
    case needsSetup // No config — first launch
    case idle
    case running
    case error
    case diskAbsent
    case fdaMissing
    case stale // >24h since last backup
}

class StatusManager {
    var currentState: AppState = .idle
    var lastStatus: BackupStatusFile?
    private let statusWriter = StatusWriter()
    private var fdaChecked = false
    private var fdaOK = false

    /// Reset cached FDA result (call after user grants FDA)
    func resetFDACache() {
        fdaChecked = false
    }

    /// Poll status.json and determine current app state.
    func poll(config: Config?) -> AppState {
        // No config = first-time setup needed
        guard let config = config else {
            currentState = .needsSetup
            return currentState
        }

        lastStatus = statusWriter.read()

        // FDA check only once, then cache result (repeated checks crash tccd)
        if !fdaChecked {
            let fda = FDACheck.checkFullDiskAccess()
            fdaOK = fda.hasAccess
            fdaChecked = true
        }
        if !fdaOK {
            currentState = .fdaMissing
            return currentState
        }

        if !FileManager.default.fileExists(atPath: config.destination.path) {
            currentState = .diskAbsent
            return currentState
        }

        if let status = lastStatus {
            if status.state == "running" {
                // Verify backup is actually running — check lock file exists
                let lockPath = config.destination.path + "/rustymacbackup.lock"
                if FileManager.default.fileExists(atPath: lockPath) {
                    currentState = .running
                    return currentState
                }
                // Stale "running" status — process died, reset to idle
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
