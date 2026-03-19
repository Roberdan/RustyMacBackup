import Foundation
import Darwin

enum HardLinker {
    /// Compare size + mtime to decide if file should be hard-linked from previous backup.
    static func shouldHardLink(sourcePath: String, sourceSize: UInt64, sourceMtime: Date,
                                previousBackupPath: String) -> Bool {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: previousBackupPath),
              let prevSize = attrs[.size] as? UInt64,
              let prevMtime = attrs[.modificationDate] as? Date else {
            return false
        }
        return sourceSize == prevSize && abs(sourceMtime.timeIntervalSince(prevMtime)) < 1.0
    }

    /// Create hard link from an existing backup file to the new destination.
    static func hardLink(from source: String, to destination: String) throws {
        try FileManager.default.linkItem(atPath: source, toPath: destination)
    }

    /// Copy file using Apple's copyfile() with APFS clone support.
    /// COPYFILE_CLONE attempts a copy-on-write clone first, falling back to a byte copy.
    static func copyFile(from source: String, to destination: String) throws {
        // COPYFILE_CLONE = 1<<20, COPYFILE_ALL = DATA|XATTR|STAT|ACL = 0x0F
        let flags = copyfile_flags_t((UInt32(1) << 20) | UInt32(0x0F))
        let result = Darwin.copyfile(source, destination, nil, flags)
        if result != 0 {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno),
                          userInfo: [NSLocalizedDescriptionKey: "copyfile failed: \(String(cString: strerror(errno)))"])
        }
    }

    /// Preserve modification time on a copied file.
    static func preserveModificationTime(at path: String, mtime: Date) {
        try? FileManager.default.setAttributes([.modificationDate: mtime], ofItemAtPath: path)
    }
}
