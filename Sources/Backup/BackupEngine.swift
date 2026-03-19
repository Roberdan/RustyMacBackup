import Foundation

enum BackupEngine {
    static let STATUS_UPDATE_INTERVAL: Int = 500
    static let DISK_CHECK_INTERVAL: Int = 100
    static let MIN_FREE_SPACE: UInt64 = 1_073_741_824 // 1 GB

    private static var shouldCancel = false

    static func stop() { shouldCancel = true }

    static func run(config: Config, statusWriter: StatusWriter = StatusWriter()) async throws {
        shouldCancel = false
        let destPath = config.destination.path
        let destURL = URL(fileURLWithPath: destPath)

        // 1. Verify source paths exist
        let allPaths = config.source.allPaths()
        for path in allPaths {
            guard FileManager.default.fileExists(atPath: path) else {
                throw BackupError.sourceNotFound(path)
            }
        }

        // 2. Verify destination volume is mounted
        guard isVolumeReallyMounted(destPath) else {
            throw BackupError.volumeNotMounted(destPath)
        }

        // 3. Set I/O priority (throttle on battery)
        IOPriority.setIOPriority(throttle: IOPriority.isOnBattery())

        // 4. Preflight write test
        guard preflightWriteTest(at: destURL) else {
            throw BackupError.notWritable(destPath)
        }

        // 5. Clean stale in-progress directories
        cleanStaleInProgress(at: destURL)

        // 6. Check disk space (auto-prune wired in T4-01)
        let freeSpace = diskFreeSpace(at: destPath)
        if freeSpace < MIN_FREE_SPACE {
            print("⚠ Low disk space, auto-pruning...")
            let _ = RetentionManager.pruneBackups(at: destURL, policy: config.retention, dryRun: false)
            if diskFreeSpace(at: destPath) < MIN_FREE_SPACE {
                throw BackupError.insufficientSpace(freeSpace)
            }
        }

        // 7. Find latest completed backup for hard-link baseline
        let latestBackup = findLatestBackup(at: destURL)

        // 8. Create in-progress directory
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HHmmss"
        let timestamp = formatter.string(from: Date())
        let inProgressURL = destURL.appendingPathComponent("in-progress-\(timestamp)")
        try FileManager.default.createDirectory(at: inProgressURL, withIntermediateDirectories: true)

        // 9. Acquire lock file
        let lockPath = destURL.appendingPathComponent("rustymacbackup.lock").path
        try acquireLock(at: lockPath)
        defer { try? FileManager.default.removeItem(atPath: lockPath) }

        // 10. Scan files
        let excludeFilter = ExcludeFilter(patterns: config.exclude.patterns)
        let sourceURLs = allPaths.map { URL(fileURLWithPath: $0) }
        let files = try FileScanner.scanFiles(sources: sourceURLs, basePaths: allPaths,
                                               excludeFilter: excludeFilter)

        let startTime = Date()
        var status = BackupStatusFile()
        status.state = "running"
        status.startedAt = ISO8601DateFormatter().string(from: startTime)
        status.filesTotal = UInt64(files.count)
        try? statusWriter.write(status: status)

        // 11. Process files with TaskGroup (max 8 concurrent workers)
        var stats = BackupStats()
        var errorList: [(path: String, error: Error)] = []
        let totalFiles = files.count

        try await withThrowingTaskGroup(of: FileResult.self) { group in
            var activeTasks = 0
            let maxConcurrent = 8
            var fileIndex = 0

            for file in files {
                if shouldCancel { break }

                // Every DISK_CHECK_INTERVAL files: verify destination still accessible
                if fileIndex > 0 && fileIndex % DISK_CHECK_INTERVAL == 0 {
                    guard FileManager.default.fileExists(atPath: inProgressURL.path) else {
                        throw BackupError.diskDisconnected
                    }
                }

                // Throttle: drain one task before adding more when at capacity
                if activeTasks >= maxConcurrent {
                    if let result = try await group.next() {
                        processResult(result, stats: &stats, errors: &errorList)
                        activeTasks -= 1
                    }
                }

                let destFile = inProgressURL.appendingPathComponent(file.relativePath).path
                let prevFile = latestBackup.map { $0.appendingPathComponent(file.relativePath).path }
                let capturedFile = file
                group.addTask {
                    await processFile(entry: capturedFile, destFile: destFile, prevFile: prevFile)
                }
                activeTasks += 1
                fileIndex += 1

                // Every STATUS_UPDATE_INTERVAL files: update progress
                if fileIndex % STATUS_UPDATE_INTERVAL == 0 {
                    let elapsed = Date().timeIntervalSince(startTime)
                    status.filesDone = UInt64(fileIndex)
                    status.bytesCopied = stats.bytesCopied
                    status.bytesPerSec = elapsed > 0 ? UInt64(Double(stats.bytesCopied) / elapsed) : 0
                    status.etaSecs = status.bytesPerSec > 0 && stats.bytesCopied > 0
                        ? UInt64(Double(totalFiles - fileIndex) / Double(fileIndex) * elapsed) : 0
                    status.errors = UInt64(errorList.count)
                    status.currentFile = file.relativePath
                    try? statusWriter.write(status: status)
                }
            }

            // Drain remaining tasks
            for try await result in group {
                processResult(result, stats: &stats, errors: &errorList)
            }
        }

        // 12. Atomic rename in-progress → final timestamp
        let finalURL = destURL.appendingPathComponent(timestamp)
        try FileManager.default.moveItem(at: inProgressURL, to: finalURL)

        // 13. Write error file if any
        if !errorList.isEmpty {
            try? statusWriter.writeErrors(errors: categorizeErrors(errorList))
        }

        // 14. Final status
        let duration = Date().timeIntervalSince(startTime)
        status.state = "idle"
        status.filesDone = UInt64(totalFiles)
        status.lastCompleted = ISO8601DateFormatter().string(from: Date())
        status.lastDurationSecs = duration
        status.bytesPerSec = duration > 0 ? UInt64(Double(stats.bytesCopied) / duration) : 0
        status.etaSecs = 0
        status.currentFile = ""
        status.errors = UInt64(errorList.count)
        try? statusWriter.write(status: status)

        print("✅ Backup completato in \(String(format: "%.1f", duration))s")
        print("   \(stats.filesHardlinked) hard-linked, \(stats.filesCopied) copied, \(stats.dirsCreated) dirs")
        print("   \(formatBytes(stats.bytesCopied)) copied, \(errorList.count) errors")
    }
}
