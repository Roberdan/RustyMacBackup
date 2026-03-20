import Foundation

struct RestoreItem {
    let relativePath: String
    let absoluteSource: String
    let absoluteDest: String
    let isDirectory: Bool
    let size: UInt64
}

enum RestoreEngine {
    /// Scan a backup snapshot and return all restorable items grouped by category.
    static func scanSnapshot(at snapshotURL: URL) -> [RestoreItem] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: snapshotURL,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var items: [RestoreItem] = []
        let home = fm.homeDirectoryForCurrentUser.path

        while let url = enumerator.nextObject() as? URL {
            let rel = url.path.replacingOccurrences(of: snapshotURL.path + "/", with: "")
            if rel == "_environment" || rel.hasPrefix("_environment/") {
                enumerator.skipDescendants()
                continue
            }
            guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .fileSizeKey]) else {
                continue
            }
            let isDir = values.isDirectory ?? false
            let size = UInt64(values.fileSize ?? 0)
            // Only top-level items (first path component)
            if rel.contains("/") && !isDir { continue }

            let dest = home + "/" + rel
            items.append(RestoreItem(
                relativePath: rel,
                absoluteSource: url.path,
                absoluteDest: dest,
                isDirectory: isDir,
                size: size
            ))

            if isDir { enumerator.skipDescendants() }
        }
        return items
    }

    /// Find the latest backup snapshot on any connected volume.
    static func findBackupSnapshots() -> [(volume: String, backupDir: URL, snapshots: [String])] {
        let fm = FileManager.default
        guard let volumes = fm.mountedVolumeURLs(
            includingResourceValuesForKeys: [.volumeNameKey],
            options: [.skipHiddenVolumes]) else { return [] }

        var results: [(volume: String, backupDir: URL, snapshots: [String])] = []
        for vol in volumes {
            let backupDir = vol.appendingPathComponent("RustyMacBackup")
            guard fm.fileExists(atPath: backupDir.path) else { continue }
            let snapshots = RetentionManager.listBackups(at: backupDir)
            if !snapshots.isEmpty {
                results.append((vol.lastPathComponent, backupDir,
                                snapshots.map(\.name)))
            }
        }
        return results
    }

    /// Restore selected items from a snapshot. Skips items that already exist.
    static func restore(snapshotURL: URL, items: [String],
                        progress: ((String, Int, Int) -> Void)? = nil) -> (restored: Int, skipped: Int, failed: Int) {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path
        var restored = 0, skipped = 0, failed = 0
        let total = items.count

        for (i, rel) in items.enumerated() {
            let source = snapshotURL.appendingPathComponent(rel)
            let dest = URL(fileURLWithPath: home + "/" + rel)
            progress?(rel, i + 1, total)

            if fm.fileExists(atPath: dest.path) {
                skipped += 1
                continue
            }

            do {
                try fm.createDirectory(at: dest.deletingLastPathComponent(),
                                       withIntermediateDirectories: true)
                try fm.copyItem(at: source, to: dest)
                restored += 1
            } catch {
                failed += 1
            }
        }
        return (restored, skipped, failed)
    }

    /// Run brew bundle install from the Brewfile in the snapshot.
    static func restoreHomebrew(snapshotURL: URL,
                                progress: ((String) -> Void)? = nil) -> Bool {
        let brewfile = snapshotURL
            .appendingPathComponent("_environment")
            .appendingPathComponent("Brewfile")
        guard FileManager.default.fileExists(atPath: brewfile.path) else { return false }

        progress?("Installing Homebrew packages...")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["brew", "bundle", "install",
                             "--file=\(brewfile.path)", "--no-lock"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }
}
