import Foundation

enum AppState {
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

    /// Poll status.json and determine current app state.
    func poll(config: Config?) -> AppState {
        lastStatus = statusWriter.read()

        let fda = FDACheck.checkFullDiskAccess()
        if !fda.hasAccess {
            currentState = .fdaMissing
            return currentState
        }

        if let config = config {
            if !FileManager.default.fileExists(atPath: config.destination.path) {
                currentState = .diskAbsent
                return currentState
            }
        }

        if let status = lastStatus {
            if status.state == "running" {
                currentState = .running
                return currentState
            }
            if status.state == "error" {
                currentState = .error
                return currentState
            }
            // Stale: >24h since last completed backup
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
