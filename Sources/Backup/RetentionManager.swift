import Foundation

struct BackupEntry {
    let name: String
    let timestamp: Date
    let url: URL
}

enum RetentionManager {
    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HHmmss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    /// Parse backup directory name to timestamp.
    /// Format: YYYY-MM-DD_HHMMSS (17 chars)
    static func parseBackupName(_ name: String) -> Date? {
        guard name.count == 17 else { return nil }
        return formatter.date(from: name)
    }

    /// List all backup snapshots at destination, sorted newest first.
    static func listBackups(at destination: URL) -> [BackupEntry] {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: destination,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        return contents.compactMap { url -> BackupEntry? in
            let name = url.lastPathComponent
            guard !name.hasPrefix("in-progress-") else { return nil }
            guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey]),
                  values.isDirectory == true else { return nil }
            guard let timestamp = parseBackupName(name) else { return nil }
            return BackupEntry(name: name, timestamp: timestamp, url: url)
        }.sorted { $0.timestamp > $1.timestamp }
    }

    /// Prune backups according to retention policy.
    /// Returns list of pruned backup names.
    static func pruneBackups(at destination: URL, policy: RetentionConfig, dryRun: Bool) -> [String] {
        let backups = listBackups(at: destination)
        guard backups.count > 1 else { return [] } // Always keep at least one

        var keep = Set<String>()

        if let latest = backups.first { keep.insert(latest.name) }

        keepBySlot(backups: backups, keep: &keep, count: Int(policy.hourly)) { entry in
            Calendar.current.dateComponents([.year, .month, .day, .hour], from: entry.timestamp)
        }

        keepBySlot(backups: backups, keep: &keep, count: Int(policy.daily)) { entry in
            Calendar.current.dateComponents([.year, .month, .day], from: entry.timestamp)
        }

        keepBySlot(backups: backups, keep: &keep, count: Int(policy.weekly)) { entry in
            Calendar.current.dateComponents([.yearForWeekOfYear, .weekOfYear], from: entry.timestamp)
        }

        if policy.monthly == 0 {
            keepBySlot(backups: backups, keep: &keep, count: Int.max) { entry in
                Calendar.current.dateComponents([.year, .month], from: entry.timestamp)
            }
        } else {
            keepBySlot(backups: backups, keep: &keep, count: Int(policy.monthly)) { entry in
                Calendar.current.dateComponents([.year, .month], from: entry.timestamp)
            }
        }

        var pruned: [String] = []
        for backup in backups where !keep.contains(backup.name) {
            if dryRun {
                print("  Would prune: \(backup.name)")
            } else {
                try? FileManager.default.removeItem(at: backup.url)
                print("  Pruned: \(backup.name)")
            }
            pruned.append(backup.name)
        }
        return pruned
    }

    /// Helper: keep one backup per unique slot (hour/day/week/month), up to `count` slots.
    private static func keepBySlot(
        backups: [BackupEntry],
        keep: inout Set<String>,
        count: Int,
        slotKey: (BackupEntry) -> DateComponents
    ) {
        guard count > 0 else { return }
        var seen: [DateComponents: String] = [:]
        for backup in backups {
            let slot = slotKey(backup)
            if seen[slot] == nil {
                seen[slot] = backup.name
            }
        }

        var slotsKept = 0
        var seenSlots = Set<DateComponents>()
        for backup in backups {
            if slotsKept >= count { break }
            let slot = slotKey(backup)
            if !seenSlots.contains(slot) {
                seenSlots.insert(slot)
                if let name = seen[slot] { keep.insert(name) }
                slotsKept += 1
            }
        }
    }

    /// Print retention summary for CLI.
    static func printRetentionSummary(policy: RetentionConfig, backups: [BackupEntry]) {
        print("Retention policy:")
        print("  Hourly:  keep \(policy.hourly)")
        print("  Daily:   keep \(policy.daily)")
        print("  Weekly:  keep \(policy.weekly)")
        print("  Monthly: \(policy.monthly == 0 ? "keep forever" : "keep \(policy.monthly)")")
        print("Current backups: \(backups.count)")
    }

    /// Calculate directory size (for list command).
    static func directorySize(at url: URL) -> UInt64 {
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }

        var totalSize: UInt64 = 0
        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true else { continue }
            totalSize += UInt64(values.fileSize ?? 0)
        }
        return totalSize
    }
}
