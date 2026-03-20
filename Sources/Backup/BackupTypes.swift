import Foundation

struct BackupStats {
    var filesHardlinked: UInt64 = 0
    var filesCopied: UInt64 = 0
    var dirsCreated: UInt64 = 0
    var bytesCopied: UInt64 = 0
}

enum FileResult {
    case hardlinked
    case copied(bytes: UInt64)
    case error(path: String, error: Error)
}

enum BackupError: LocalizedError {
    case sourceNotFound(String)
    case volumeNotMounted(String)
    case notWritable(String)
    case insufficientSpace(UInt64)
    case diskDisconnected
    case lockExists
    case cancelled
    case forbiddenPath(String)
    case sourceFilesVanishing

    var errorDescription: String? {
        switch self {
        case .sourceNotFound(let p):    return "Source not found: \(p)"
        case .volumeNotMounted(let p):  return "Volume not mounted at: \(p)"
        case .notWritable(let p):       return "Destination not writable: \(p)"
        case .insufficientSpace(let b): return "Insufficient disk space: \(b / 1_048_576) MB free"
        case .diskDisconnected:         return "Destination disk disconnected during backup"
        case .lockExists:               return "Another backup is already running (lock file exists)"
        case .cancelled:                return "Backup was cancelled"
        case .forbiddenPath(let p):     return "Forbidden path (system/TCC protected): \(p)"
        case .sourceFilesVanishing:     return "EMERGENCY STOP: source files are disappearing (possible iCloud eviction). Backup halted to protect your data."
        }
    }
}

extension BackupStatusFile {
    init() {
        state = "idle"
        phase = ""
        startedAt = ""
        lastCompleted = ""
        lastDurationSecs = 0
        filesTotal = 0
        filesDone = 0
        bytesCopied = 0
        bytesPerSec = 0
        etaSecs = 0
        errors = 0
        currentFile = ""
    }
}
