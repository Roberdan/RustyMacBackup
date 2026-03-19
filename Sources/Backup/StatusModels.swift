import Foundation

struct BackupStatusFile: Codable {
    var state: String
    var startedAt: String
    var lastCompleted: String
    var lastDurationSecs: Double
    var filesTotal: UInt64
    var filesDone: UInt64
    var bytesCopied: UInt64
    var bytesPerSec: UInt64
    var etaSecs: UInt64
    var errors: UInt64
    var currentFile: String

    enum CodingKeys: String, CodingKey {
        case state
        case startedAt = "started_at"
        case lastCompleted = "last_completed"
        case lastDurationSecs = "last_duration_secs"
        case filesTotal = "files_total"
        case filesDone = "files_done"
        case bytesCopied = "bytes_copied"
        case bytesPerSec = "bytes_per_sec"
        case etaSecs = "eta_secs"
        case errors
        case currentFile = "current_file"
    }
}

struct BackupErrorFile: Codable {
    var total: Int
    var timestamp: String
    var categories: [String: ErrorCategoryInfo]
}

struct ErrorCategoryInfo: Codable {
    var count: Int
    var files: [String]
}

final class StatusWriter {
    private static let home = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
    static let statusPath = "\(home)/.local/share/rusty-mac-backup/status.json"
    static let errorPath = "\(home)/.local/share/rusty-mac-backup/errors.json"

    func write(status: BackupStatusFile) throws {
        try writeJSON(status, to: URL(fileURLWithPath: Self.statusPath))
    }

    func writeErrors(errors: BackupErrorFile) throws {
        try writeJSON(errors, to: URL(fileURLWithPath: Self.errorPath))
    }

    func read() -> BackupStatusFile? {
        let url = URL(fileURLWithPath: Self.statusPath)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(BackupStatusFile.self, from: data)
    }

    private func writeJSON<T: Encodable>(_ payload: T, to fileURL: URL) throws {
        let fileManager = FileManager.default
        let dir = fileURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(payload)

        let tempURL = fileURL.appendingPathExtension("tmp")
        try data.write(to: tempURL, options: .atomic)

        if fileManager.fileExists(atPath: fileURL.path) {
            try fileManager.removeItem(at: fileURL)
        }
        try fileManager.moveItem(at: tempURL, to: fileURL)
    }
}
