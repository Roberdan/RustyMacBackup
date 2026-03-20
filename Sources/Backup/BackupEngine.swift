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

        // Validate source paths: skip missing, block forbidden
        var allPaths: [String] = []
        for path in config.source.allExpandedPaths() {
            let contracted = ConfigDiscovery.contract(path)
            if ConfigDiscovery.isForbidden(contracted) {
                Log.error("BLOCKED forbidden path: \(path)")
                throw BackupError.forbiddenPath(path)
            }
            if FileManager.default.fileExists(atPath: path) {
                allPaths.append(path)
            } else {
                Log.info("Skipping missing path: \(path)")
            }
        }
        guard isVolumeReallyMounted(destPath) else { throw BackupError.volumeNotMounted(destPath) }
        // Security warning if backup disk is not encrypted
        if !DiskDiagnostics.checkEncryption(volume: destPath) {
            Log.warn("Backup disk is NOT encrypted -- sensitive data (SSH keys, tokens) at risk")
        }
        // Warn if iCloud Desktop & Documents is active (can cause bird evictions)
        if isiCloudDesktopActive() {
            Log.warn("iCloud Desktop & Documents sync is ACTIVE -- using bird-safe mode")
        }
        // Always throttle I/O to avoid triggering bird/iCloud eviction cascades
        IOPriority.setIOPriority(throttle: true)
        Log.info("I/O priority: throttled (bird-safe mode)")
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

        let startTime = Date()
        var status = BackupStatusFile()
        status.state = "running"
        status.startedAt = ISO8601DateFormatter().string(from: startTime)
        status.currentFile = "Avvio backup..."
        try? statusWriter.write(status: status)

        let excludeFilter = ExcludeFilter(patterns: config.exclude.patterns)
        let sourceURLs = allPaths.map { URL(fileURLWithPath: $0) }

        let discoveredCount = UnsafeMutablePointer<Int64>.allocate(capacity: 1)
        discoveredCount.initialize(to: 0)
        let walkerDone = UnsafeMutablePointer<Bool>.allocate(capacity: 1)
        walkerDone.initialize(to: false)
        defer { discoveredCount.deallocate(); walkerDone.deallocate() }

        let (stream, continuation) = AsyncStream<FileEntry>.makeStream(bufferingPolicy: .bufferingNewest(256))

        let walkerTask = Task.detached(priority: .utility) {
            FileScanner.walk(sources: sourceURLs, basePaths: allPaths,
                           excludeFilter: excludeFilter) { entry in
                if shouldCancel { return false }
                OSAtomicIncrement64(discoveredCount)
                continuation.yield(entry)
                return true
            }
            walkerDone.pointee = true
            continuation.finish()
        }

        var stats = BackupStats()
        var errorList: [(path: String, error: Error)] = []
        var processedCount: UInt64 = 0

        // Sequential processing -- one file at a time to avoid triggering bird/iCloud
        var vanishedCount = 0
        let VANISHED_THRESHOLD = 3

        for await file in stream {
            if shouldCancel { break }
            processedCount += 1

            // Disk check
            if processedCount % UInt64(DISK_CHECK_INTERVAL) == 0 {
                guard FileManager.default.fileExists(atPath: inProgressURL.path) else {
                    throw BackupError.diskDisconnected
                }
            }

            // Emergency stop: if source files are vanishing, bird is evicting
            if vanishedCount >= VANISHED_THRESHOLD {
                Log.error("EMERGENCY STOP: \(vanishedCount) source files vanished during backup -- bird eviction suspected")
                status.state = "error"
                status.currentFile = "STOPPED: source files vanishing (iCloud eviction)"
                try? statusWriter.write(status: status)
                throw BackupError.sourceFilesVanishing
            }

            let destFile = inProgressURL.appendingPathComponent(file.relativePath).path
            let prevFile = latestBackup.map { $0.appendingPathComponent(file.relativePath).path }

            let result = await processFile(entry: file, destFile: destFile, prevFile: prevFile)
            processResult(result, stats: &stats, errors: &errorList)

            // Post-copy verification: check source still exists
            // Skip shell dotfiles (can be temporarily absent during shell init)
            let isShellFile = file.relativePath.hasSuffix("shrc") || file.relativePath.hasSuffix("profile")
                || file.relativePath.hasSuffix("shenv") || file.relativePath.hasSuffix("history")
            if !isShellFile && !FileManager.default.fileExists(atPath: file.absolutePath) {
                vanishedCount += 1
                Log.warn("Source file vanished after copy: \(file.relativePath) (\(vanishedCount)/\(VANISHED_THRESHOLD))")
            }

            // Status update
            if processedCount % UInt64(STATUS_UPDATE_INTERVAL) == 0 {
                let elapsed = Date().timeIntervalSince(startTime)
                let discovered = UInt64(discoveredCount.pointee)
                let done = processedCount
                status.filesDone = done
                status.filesTotal = walkerDone.pointee ? discovered : discovered + 5000
                status.bytesCopied = stats.bytesCopied
                status.bytesPerSec = elapsed > 0 ? UInt64(Double(stats.bytesCopied) / elapsed) : 0
                if status.bytesPerSec > 0 && done > 0 {
                    let remaining = status.filesTotal > done ? status.filesTotal - done : 0
                    let avgBytesPerFile = stats.bytesCopied / done
                    status.etaSecs = UInt64(remaining * avgBytesPerFile / status.bytesPerSec)
                }
                status.errors = UInt64(errorList.count)
                status.currentFile = file.relativePath
                try? statusWriter.write(status: status)
            }
        }

        walkerTask.cancel()

        let finalURL = destURL.appendingPathComponent(timestamp)
        try FileManager.default.moveItem(at: inProgressURL, to: finalURL)

        // Capture portable environment snapshot (Brewfile, app list, restore script, app binary)
        // Run AFTER backup completes, in a non-interactive shell to avoid triggering kaku/dotfile managers
        Log.info("Capturing environment snapshot...")
        EnvironmentSnapshot.capture(to: finalURL)
        Log.info("Environment snapshot complete")

        if !errorList.isEmpty {
            try? statusWriter.writeErrors(errors: categorizeErrors(errorList))
        }

        let totalFiles = processedCount
        let duration = Date().timeIntervalSince(startTime)
        status.state = "idle"
        status.filesDone = totalFiles
        status.filesTotal = totalFiles
        status.lastCompleted = ISO8601DateFormatter().string(from: Date())
        status.lastDurationSecs = duration
        status.bytesPerSec = duration > 0 ? UInt64(Double(stats.bytesCopied) / duration) : 0
        status.etaSecs = 0
        status.currentFile = ""
        status.errors = UInt64(errorList.count)
        try? statusWriter.write(status: status)
    }
}
