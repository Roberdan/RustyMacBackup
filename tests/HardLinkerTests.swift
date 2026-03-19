import Foundation

final class HardLinkerTests {
    func test_sameFileSameSizeMtime() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let file = tmp.appendingPathComponent("test.txt")
        try "hello world".write(to: file, atomically: true, encoding: .utf8)
        let attrs = try FileManager.default.attributesOfItem(atPath: file.path)
        let size = attrs[.size] as! UInt64
        let mtime = attrs[.modificationDate] as! Date

        let shouldLink = HardLinker.shouldHardLink(sourcePath: file.path, sourceSize: size, sourceMtime: mtime, previousBackupPath: file.path)
        try expect(shouldLink, "Identical file should be hard-linkable")
    }

    func test_differentSize() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let file1 = tmp.appendingPathComponent("a.txt")
        let file2 = tmp.appendingPathComponent("b.txt")
        try "short".write(to: file1, atomically: true, encoding: .utf8)
        try "much longer content here".write(to: file2, atomically: true, encoding: .utf8)

        let attrs1 = try FileManager.default.attributesOfItem(atPath: file1.path)
        let shouldLink = HardLinker.shouldHardLink(sourcePath: file1.path, sourceSize: attrs1[.size] as! UInt64, sourceMtime: attrs1[.modificationDate] as! Date, previousBackupPath: file2.path)
        try expect(!shouldLink, "Different size files should not be hard-linkable")
    }

    func test_hardLinkCreation() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let original = tmp.appendingPathComponent("original.txt")
        let link = tmp.appendingPathComponent("link.txt")
        try "test content".write(to: original, atomically: true, encoding: .utf8)
        try HardLinker.hardLink(from: original.path, to: link.path)

        let origInode = (try FileManager.default.attributesOfItem(atPath: original.path))[.systemFileNumber] as? UInt64
        let linkInode = (try FileManager.default.attributesOfItem(atPath: link.path))[.systemFileNumber] as? UInt64
        try expectEqual(origInode, linkInode, "Hard link should share inode with original")
    }

    func test_copyFileCreation() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let original = tmp.appendingPathComponent("original.txt")
        let copy = tmp.appendingPathComponent("copy.txt")
        let expectedContent = "test content"
        try expectedContent.write(to: original, atomically: true, encoding: .utf8)

        let originalInode = (try FileManager.default.attributesOfItem(atPath: original.path))[.systemFileNumber] as? UInt64
        try HardLinker.copyFile(from: original.path, to: copy.path)

        let copyAttrs = try FileManager.default.attributesOfItem(atPath: copy.path)
        let copyInode = copyAttrs[.systemFileNumber] as? UInt64
        try expect(copyInode != nil, "Copied file should exist")
        try expect(copyInode != originalInode, "Copied file should have different inode")
        let copyContent = try String(contentsOf: copy, encoding: .utf8)
        try expectEqual(copyContent, expectedContent, "Copied file content mismatch")
    }
}
