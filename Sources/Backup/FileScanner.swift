import Foundation

struct FileEntry {
    let relativePath: String
    let absolutePath: String
    let size: UInt64
    let mtime: Date
}

enum FileScanner {
    /// Scan source directories collecting file entries while respecting excludes.
    /// Uses FileManager.enumerator with resourceKeys for batch metadata.
    static func scanFiles(sources: [URL], basePaths: [String], excludeFilter: ExcludeFilter) throws -> [FileEntry] {
        var entries: [FileEntry] = []
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        let keySet = Set(keys)

        for (index, source) in sources.enumerated() {
            let basePath = basePaths[index].hasSuffix("/") ? basePaths[index] : basePaths[index] + "/"
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

                // Skip entire directory subtrees that are excluded
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

                entries.append(FileEntry(
                    relativePath: relativePath,
                    absolutePath: fullPath,
                    size: UInt64(size),
                    mtime: mtime
                ))
            }
        }
        return entries
    }
}
