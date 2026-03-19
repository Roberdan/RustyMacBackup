import Foundation

struct FileEntry {
    let relativePath: String
    let absolutePath: String
    let size: UInt64
    let mtime: Date
}

/// Streaming file scanner — yields files one at a time via callback.
/// Never loads entire file tree into memory.
enum FileScanner {
    static func walk(
        sources: [URL],
        basePaths: [String],
        excludeFilter: ExcludeFilter,
        handler: (FileEntry) -> Bool // return false to stop
    ) {
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        let keySet = Set(keys)

        for (index, source) in sources.enumerated() {
            let basePath = basePaths[index].hasSuffix("/") ? basePaths[index] : basePaths[index] + "/"
            guard FileManager.default.fileExists(atPath: source.path) else { continue }
            guard let enumerator = FileManager.default.enumerator(
                at: source,
                includingPropertiesForKeys: keys,
                options: [],
                errorHandler: { _, _ in true }
            ) else { continue }

            while let url = enumerator.nextObject() as? URL {
                let fullPath = url.path
                let relativePath: String
                if fullPath.hasPrefix(basePath) {
                    relativePath = String(fullPath.dropFirst(basePath.count))
                } else {
                    relativePath = url.lastPathComponent
                }

                if excludeFilter.shouldSkipDirectory(relativePath: relativePath) {
                    enumerator.skipDescendants()
                    continue
                }
                if excludeFilter.isExcluded(relativePath: relativePath) {
                    continue
                }

                guard let values = try? url.resourceValues(forKeys: keySet),
                      values.isRegularFile == true,
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
            }
        }
    }
}
