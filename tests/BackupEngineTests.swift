import Foundation

final class BackupEngineTests {
    func test_snapshotNaming() throws {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HHmmss"
        let name = formatter.string(from: Date())
        try expectEqual(name.count, 17, "Snapshot name length should be 17")
        try expectNotNil(RetentionManager.parseBackupName(name), "Snapshot name should parse")
    }

    func test_inProgressPrefix() throws {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HHmmss"
        let name = "in-progress-\(formatter.string(from: Date()))"
        try expect(name.hasPrefix("in-progress-"), "in-progress prefix missing")
    }

    func test_statusFileFormat() throws {
        let status = BackupStatusFile()
        let data = try JSONEncoder().encode(status)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            try fail("Status JSON should decode to dictionary")
            return
        }
        for key in ["state", "started_at", "last_completed", "files_total", "files_done", "bytes_copied", "bytes_per_sec", "eta_secs", "errors", "current_file"] {
            try expectNotNil(json[key], "Missing key in status JSON: \(key)")
        }
    }
}
