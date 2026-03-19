import Foundation

enum BackupEngine {
    static let STATUS_UPDATE_INTERVAL: Int = 500
    static let DISK_CHECK_INTERVAL: Int = 100
    static let MIN_FREE_SPACE: UInt64 = 1_073_741_824

    private static var shouldCancel = false

    static func stop() { shouldCancel = true }

    static func run(config: Config, statusWriter: StatusWriter = StatusWriter()) async throws {
        shouldCancel = false
        let destPath = config.destination.path
        let destURL = URL(fileURLWithPath: destPath)
        let allPaths = config.source.allPaths()

        // Preflight checks
        for path in allPaths {
            guard FileManager.default.fileExists(atPath: path) else {
                throw BackupError.sourceNotFound(path)
            }
        }
        guard isVolumeReallyMounted(destPath) else { throw BackupError.volumeNotMounted(destPath) }
        IOPriority.setIOPriority(throttle: IOPriority.isOnBattery())
        guard preflightWriteTest(at: destURL) else { throw BackupError.notWritable(destPath) }
        cleanStaleInProgress(at: destURL)

        if diskFreeSpace(at: destPath) < MIN_FREE_SPACE {
            let _ = RetentionManager.pruneBackups(at: destURL, policy: config.retention, dryRun: false)
            if diskFreeSpace(at: destPath) < MIN_FREE_SPACE {
                throw BackupError.insufficientSpace(diskFreeSpace(at: destPath))
            }
        }

        let latestBackup = findLatestBackup(at: destURL)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HHmmss"
        let timestamp = formatter.string(from: Date())
        let inProgressURL = destURL.appendingPathComponent("in-progress-\(timestamp)")
        try FileManager.default.createDirectory(at: inProgressURL, withIntermediateDirectories: true)

        let lockPath = destURL.appendingPathComponent("rustymacbackup.lock").path
        try acquireLock(at: lockPath)
        defer { try? FileManager.default.removeItem(atPath: lockPath) }

        // Write "running" status immediately
        let startTime = Date()
        var status = BackupStatusFile()
        status.state = "running"
        status.startedAt = ISO8601DateFormatter().string(from: startTime)
        status.currentFile = "Avvio backup..."
        try? statusWriter.write(status: status)
        print("🚀 Backup avviato...")

        let excludeFilter = ExcludeFilter(patterns: config.exclude.patterns)
        let sourceURLs = allPaths.map { URL(fileURLWithPath: $0) }

        // Use AsyncStream: producer (file walker) feeds consumer (TaskGroup copier)
        let (stream, continuation) = AsyncStream<FileEntry>.makeStream(bufferingPolicy: .bufferingNewest(256))

        // Producer: walk files on background thread, feed into stream
        let walkerTask = Task.detached(priority: .utility) {
            FileScanner.walk(sources: sourceURLs, basePaths: allPaths, excludeFilter: excludeFilter) { entry in
                if shouldCancel { return false }
                continuation.yield(entry)
                return true
            }
            continuation.finish()
        }

        // Consumer: process files as they arrive with bounded parallelism
        var stats = BackupStats()
        var errorList: [(path: String, error: Error)] = []
        var fileIndex: UInt64 = 0

        try await withThrowingTaskGroup(of: FileResult.self) { group in
            var activeTasks = 0
            let maxConcurrent = 8

            for await file in stream {
                if shouldCancel { break }
                fileIndex += 1

                // Disk check
                if fileIndex % UInt64(DISK_CHECK_INTERVAL) == 0 {
                    guard FileManager.default.fileExists(atPath: inProgressURL.path) else {
                        throw BackupError.diskDisconnected
                    }
                }

                // Throttle: drain before adding when at capacity
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

                // Status update
                if fileIndex % UInt64(STATUS_UPDATE_INTERVAL) == 0 {
                    let elapsed = Date().timeIntervalSince(startTime)
                    status.filesDone = fileIndex
                    status.filesTotal = fileIndex // grows as we discover more
                    status.bytesCopied = stats.bytesCopied
                    status.bytesPerSec = elapsed > 0 ? UInt64(Double(stats.bytesCopied) / elapsed) : 0
                    status.errors = UInt64(errorList.count)
                    status.currentFile = file.relativePath
                    try? statusWriter.write(status: status)
                }
            }

            // Drain remaining
            for try await result in group {
                processResult(result, stats: &stats, errors: &errorList)
            }
        }

        walkerTask.cancel()

        // Atomic rename
        let finalURL = destURL.appendingPathComponent(timestamp)
        try FileManager.default.moveItem(at: inProgressURL, to: finalURL)

        // Errors
        if !errorList.isEmpty {
            try? statusWriter.writeErrors(errors: categorizeErrors(errorList))
        }

        // Final status
        let duration = Date().timeIntervalSince(startTime)
        status.state = "idle"
        status.filesDone = fileIndex
        status.filesTotal = fileIndex
        status.lastCompleted = ISO8601DateFormatter().string(from: Date())
        status.lastDurationSecs = duration
        status.bytesPerSec = duration > 0 ? UInt64(Double(stats.bytesCopied) / duration) : 0
        status.etaSecs = 0
        status.currentFile = ""
        status.errors = UInt64(errorList.count)
        try? statusWriter.write(status: status)

        print("✅ Backup completato in \(String(format: "%.1f", duration))s")
        print("   \(stats.filesHardlinked) hard-linked, \(stats.filesCopied) copiati, \(stats.dirsCreated) dir")
        print("   \(formatBytes(stats.bytesCopied)) copiati, \(errorList.count) errori")
    }
}
