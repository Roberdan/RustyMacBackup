import Foundation

final class RetentionTests {
    func test_parseBackupName_valid() throws {
        try expectNotNil(RetentionManager.parseBackupName("2026-03-19_143000"), "Valid backup name should parse")
    }

    func test_parseBackupName_invalid() throws {
        try expectNil(RetentionManager.parseBackupName("not-a-date"), "Invalid name should fail parsing")
        try expectNil(RetentionManager.parseBackupName("2026-13-01_000000"), "Invalid month should fail parsing")
        try expectNil(RetentionManager.parseBackupName(""), "Empty name should fail parsing")
    }

    func test_alwaysKeepLatest() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        try FileManager.default.createDirectory(at: tmp.appendingPathComponent("2026-03-19_140000"), withIntermediateDirectories: true)
        let policy = RetentionConfig(hourly: 0, daily: 0, weekly: 0, monthly: 0)
        let pruned = RetentionManager.pruneBackups(at: tmp, policy: policy, dryRun: true)
        try expectEqual(pruned.count, 0, "Single backup should never be pruned")
    }

    func test_hourlyRetention() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        ["2026-03-19_100000", "2026-03-19_110000", "2026-03-19_120000", "2026-03-19_130000", "2026-03-19_140000"]
            .forEach { try? FileManager.default.createDirectory(at: tmp.appendingPathComponent($0), withIntermediateDirectories: true) }

        let policy = RetentionConfig(hourly: 2, daily: 0, weekly: 0, monthly: 0)
        let pruned = RetentionManager.pruneBackups(at: tmp, policy: policy, dryRun: true)
        try expect(pruned.count >= 2, "Should prune at least 2 old hourly backups")
    }

    func test_dryRunNoDeletion() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        for name in ["2026-01-01_100000", "2026-02-01_100000", "2026-03-01_100000"] {
            try FileManager.default.createDirectory(at: tmp.appendingPathComponent(name), withIntermediateDirectories: true)
        }

        let policy = RetentionConfig(hourly: 1, daily: 1, weekly: 1, monthly: 1)
        _ = RetentionManager.pruneBackups(at: tmp, policy: policy, dryRun: true)

        let remaining = try FileManager.default.contentsOfDirectory(atPath: tmp.path)
        try expectEqual(remaining.count, 3, "Dry run should not delete anything")
    }

    func test_monthlyForever() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        for month in 1...12 {
            let name = String(format: "2025-%02d-01_100000", month)
            try FileManager.default.createDirectory(at: tmp.appendingPathComponent(name), withIntermediateDirectories: true)
        }

        let policy = RetentionConfig(hourly: 0, daily: 0, weekly: 0, monthly: 0)
        let pruned = RetentionManager.pruneBackups(at: tmp, policy: policy, dryRun: true)
        try expectEqual(pruned.count, 0, "monthly=0 should keep one per month forever")
    }
}
