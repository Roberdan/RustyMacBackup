import Foundation
import Darwin

// MARK: - Utility helpers for BackupEngine

extension BackupEngine {

    static func isVolumeReallyMounted(_ path: String) -> Bool {
        var buf = statfs()
        return statfs(path, &buf) == 0
    }

    static func preflightWriteTest(at destURL: URL) -> Bool {
        let testURL = destURL.appendingPathComponent(".rustymacbackup-write-test-\(Int.random(in: 0...999_999))")
        do {
            try "test".write(to: testURL, atomically: true, encoding: .utf8)
            try FileManager.default.removeItem(at: testURL)
            return true
        } catch {
            return false
        }
    }

    static func cleanStaleInProgress(at destURL: URL) {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: destURL, includingPropertiesForKeys: nil) else { return }
        for url in contents where url.lastPathComponent.hasPrefix("in-progress-") {
            try? FileManager.default.removeItem(at: url)
        }
    }

    static func diskFreeSpace(at path: String) -> UInt64 {
        var buf = statfs()
        guard statfs(path, &buf) == 0 else { return 0 }
        return buf.f_bavail * UInt64(buf.f_bsize)
    }

    static func findLatestBackup(at destURL: URL) -> URL? {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: destURL, includingPropertiesForKeys: nil) else { return nil }
        // Match YYYY-MM-DD_HHMMSS format
        let candidates = contents.filter { url in
            let name = url.lastPathComponent
            guard name.count == 17 else { return false }
            let parts = name.split(separator: "_", maxSplits: 1)
            return parts.count == 2 && parts[0].count == 10 && parts[1].count == 6
                && parts[0].allSatisfy({ $0.isNumber || $0 == "-" })
                && parts[1].allSatisfy({ $0.isNumber })
        }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        return candidates.last
    }

    static func acquireLock(at path: String) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: path) {
            if let pidStr = try? String(contentsOfFile: path, encoding: .utf8),
               let pid = Int32(pidStr.trimmingCharacters(in: .whitespacesAndNewlines)),
               Darwin.kill(pid, 0) == 0 {
                throw BackupError.lockExists
            }
            try? fm.removeItem(atPath: path)
        }
        let pid = ProcessInfo.processInfo.processIdentifier
        try String(pid).write(toFile: path, atomically: true, encoding: .utf8)
    }

    static func categorizeErrors(_ errorList: [(path: String, error: Error)]) -> BackupErrorFile {
        var categories: [String: ErrorCategoryInfo] = [:]
        for item in errorList {
            let key = "\(type(of: item.error))"
            var info = categories[key] ?? ErrorCategoryInfo(count: 0, files: [])
            info.count += 1
            if info.files.count < 20 { info.files.append(item.path) }
            categories[key] = info
        }
        return BackupErrorFile(
            total: errorList.count,
            timestamp: ISO8601DateFormatter().string(from: Date()),
            categories: categories
        )
    }

    static func formatBytes(_ bytes: UInt64) -> String {
        if bytes >= 1_073_741_824 { return String(format: "%.1f GB", Double(bytes) / 1_073_741_824) }
        if bytes >= 1_048_576    { return String(format: "%.1f MB", Double(bytes) / 1_048_576) }
        if bytes >= 1_024        { return String(format: "%.1f KB", Double(bytes) / 1_024) }
        return "\(bytes) B"
    }

    static func processFile(entry: FileEntry, destFile: String, prevFile: String?) async -> FileResult {
        let fm = FileManager.default
        let destDir = URL(fileURLWithPath: destFile).deletingLastPathComponent().path
        if !fm.fileExists(atPath: destDir) {
            do {
                try fm.createDirectory(atPath: destDir, withIntermediateDirectories: true)
            } catch {
                return .error(path: entry.relativePath, error: error)
            }
        }

        // Attempt hard link from previous backup
        if let prev = prevFile,
           HardLinker.shouldHardLink(sourcePath: entry.absolutePath, sourceSize: entry.size,
                                     sourceMtime: entry.mtime, previousBackupPath: prev) {
            if (try? HardLinker.hardLink(from: prev, to: destFile)) != nil {
                return .hardlinked
            }
        }

        // Fall back to copyfile with APFS clone support
        do {
            try HardLinker.copyFile(from: entry.absolutePath, to: destFile)
            HardLinker.preserveModificationTime(at: destFile, mtime: entry.mtime)
            return .copied(bytes: entry.size)
        } catch {
            return .error(path: entry.relativePath, error: error)
        }
    }

    static func processResult(_ result: FileResult, stats: inout BackupStats,
                               errors: inout [(path: String, error: Error)]) {
        switch result {
        case .hardlinked:
            stats.filesHardlinked += 1
        case .copied(let bytes):
            stats.filesCopied += 1
            stats.bytesCopied += bytes
        case .error(let path, let err):
            errors.append((path: path, error: err))
        }
    }
}
