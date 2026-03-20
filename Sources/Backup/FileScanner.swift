import Foundation

struct FileEntry {
    let relativePath: String
    let absolutePath: String
    let size: UInt64
    let mtime: Date
}

/// Streaming file scanner -- yields files one at a time via callback.
/// Never loads entire file tree into memory.
/// Skips symbolic links to prevent loops and TCC-protected target access.
/// Bird-safe: yields in batches with micro-pauses to avoid triggering
/// iCloud eviction cascades (CCC uses similar technique).
enum FileScanner {
    /// Bird-safe: pause every N files to let iCloud daemon settle.
    /// 100ms on battery (conservative), 5ms on AC (20x faster).
    static let BIRD_SAFE_BATCH_SIZE = 50
    static let BIRD_SAFE_PAUSE_US: UInt32 = IOPriority.isOnBattery() ? 100_000 : 5_000
    static func walk(
        sources: [URL],
        basePaths: [String],
        excludeFilter: ExcludeFilter,
        onTraversalError: ((String, Error) -> Void)? = nil,
        handler: (FileEntry) -> Bool
    ) {
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey,
                                       .fileSizeKey, .contentModificationDateKey]
        let keySet = Set(keys)

        for (index, source) in sources.enumerated() {
            // Always use HOME as base — ensures snapshot preserves full relative paths
            // e.g. ~/GitHub/MyRepo/file.swift → "GitHub/MyRepo/file.swift" (not "file.swift")
            let basePath = basePaths[index].hasSuffix("/") ? basePaths[index] : basePaths[index] + "/"
            guard FileManager.default.fileExists(atPath: source.path) else { continue }

            // Check if source is a single file (not a directory)
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: source.path, isDirectory: &isDir)
            if !isDir.boolValue {
                guard let values = try? source.resourceValues(forKeys: keySet),
                      values.isSymbolicLink != true,
                      let size = values.fileSize,
                      let mtime = values.contentModificationDate else { continue }
                // Use home-relative path for single files too
                let rel: String
                if source.path.hasPrefix(basePath) {
                    rel = String(source.path.dropFirst(basePath.count))
                } else {
                    rel = source.lastPathComponent
                }
                let entry = FileEntry(
                    relativePath: rel,
                    absolutePath: source.path,
                    size: UInt64(size),
                    mtime: mtime
                )
                if !handler(entry) { return }
                continue
            }

            guard let enumerator = FileManager.default.enumerator(
                at: source,
                includingPropertiesForKeys: keys,
                options: [.skipsPackageDescendants],
                // F-08: Record traversal errors instead of silently swallowing them.
                // Distinguishes permission skips from genuine I/O failures.
                errorHandler: { url, error in
                    onTraversalError?(url.path, error)
                    return true  // continue traversal past unreadable entries
                }
            ) else { continue }

            var batchCount = 0
            while let url = enumerator.nextObject() as? URL {
                let fullPath = url.path
                let relativePath: String
                if fullPath.hasPrefix(basePath) {
                    relativePath = String(fullPath.dropFirst(basePath.count))
                } else {
                    relativePath = url.lastPathComponent
                }

                // Skip iCloud placeholder files (evicted by bird)
                if url.lastPathComponent.hasSuffix(".icloud") && url.lastPathComponent.hasPrefix(".") {
                    continue
                }

                if excludeFilter.shouldSkipDirectory(relativePath: relativePath) {
                    enumerator.skipDescendants()
                    continue
                }
                if excludeFilter.isExcluded(relativePath: relativePath) {
                    continue
                }

                guard let values = try? url.resourceValues(forKeys: keySet) else { continue }

                // Skip symbolic links entirely
                if values.isSymbolicLink == true {
                    enumerator.skipDescendants()
                    continue
                }

                guard values.isRegularFile == true,
                      let size = values.fileSize,
                      let mtime = values.contentModificationDate else {
                    continue
                }

                let entry = FileEntry(
                    relativePath: relativePath,
                    absolutePath: fullPath,
                    size: UInt64(size),
                    mtime: mtime
                )
                if !handler(entry) { return }

                // Bird-safe: pause every N files to let iCloud settle
                batchCount += 1
                if batchCount >= BIRD_SAFE_BATCH_SIZE {
                    batchCount = 0
                    usleep(BIRD_SAFE_PAUSE_US)
                }
            }
        }
    }
}
