import Foundation

final class RightsManagementTests {
    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("rmb-rms-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func process(_ source: URL, destination: URL, previous: URL? = nil,
                         includeProtected: Bool = false) throws -> FileResult? {
        let attrs = try FileManager.default.attributesOfItem(atPath: source.path)
        guard let size = attrs[.size] as? UInt64, let mtime = attrs[.modificationDate] as? Date else {
            throw TestFailure.failed("missing fixture metadata")
        }
        let entry = FileEntry(relativePath: source.lastPathComponent, absolutePath: source.path,
                              size: size, mtime: mtime)
        let semaphore = DispatchSemaphore(value: 0)
        let box = ResultBox<FileResult>()
        Task {
            box.value = await BackupEngine.processFile(
                entry: entry, destFile: destination.path, prevFile: previous?.path,
                protectionGuard: RightsManagementGuard(
                    config: ProtectionConfig(includeRightsManagedFiles: includeProtected)))
            semaphore.signal()
        }
        semaphore.wait()
        return box.value
    }

    /// Synthetic CFB metadata only, never a real protected document or identity.
    private func compound(marker: String, sectorSize: Int = 512, fragmented: Bool = false,
                          cycle: Bool = false) -> Data {
        let directoryID = fragmented ? 2600 : 1
        let fatCount = (directoryID + sectorSize / 4) / (sectorSize / 4)
        var data = Data(repeating: 0, count: (directoryID + 2) * sectorSize)
        func put16(_ value: UInt16, _ offset: Int) {
            data[offset] = UInt8(truncatingIfNeeded: value)
            data[offset + 1] = UInt8(truncatingIfNeeded: value >> 8)
        }
        func put32(_ value: UInt32, _ offset: Int) {
            for byte in 0..<4 { data[offset + byte] = UInt8(truncatingIfNeeded: value >> (byte * 8)) }
        }
        data.replaceSubrange(0..<8, with: [0xd0, 0xcf, 0x11, 0xe0, 0xa1, 0xb1, 0x1a, 0xe1])
        put16(sectorSize == 512 ? 3 : 4, 26)
        put16(0xfffe, 28)
        put16(sectorSize == 512 ? 9 : 12, 30)
        put16(6, 32)
        put32(UInt32(fatCount), 44)
        put32(UInt32(directoryID), 48)
        put32(4096, 56)
        put32(0xfffffffe, 60)
        put32(0xfffffffe, 68)
        for index in 0..<109 {
            put32(index < fatCount ? UInt32(index) : 0xffffffff, 76 + index * 4)
        }
        for index in 0..<(fatCount * sectorSize / 4) {
            let value: UInt32 = index < fatCount ? 0xfffffffd
                : (index == directoryID ? (cycle ? UInt32(directoryID) : 0xfffffffe) : 0xffffffff)
            put32(value, sectorSize + index * 4)
        }
        func directoryEntry(_ name: String, type: UInt8, offset: Int) {
            let bytes = Array((name + "\0").utf16).flatMap {
                [UInt8(truncatingIfNeeded: $0), UInt8(truncatingIfNeeded: $0 >> 8)]
            }
            data.replaceSubrange(offset..<(offset + bytes.count), with: bytes)
            put16(UInt16(bytes.count), offset + 64)
            data[offset + 66] = type
            put32(0xffffffff, offset + 68)
            put32(0xffffffff, offset + 72)
            put32(0xffffffff, offset + 76)
        }
        let base = (directoryID + 1) * sectorSize
        directoryEntry("Root Entry", type: 5, offset: base)
        directoryEntry(marker, type: marker == "DRMEncryptedDataSpace" ? 2 : 1, offset: base + 128)
        return data
    }

    func test_protectedContainersAcrossFormats() throws {
        for ext in RightsManagementGuard.protectedExtensions {
            let reason = try RightsManagementGuard().skipReason(forFileAt: "/absent/file.\(ext.uppercased())")
            try expectNotNil(reason,
                             "protected format must be excluded without opening it: \(ext)")
            let optInReason = try RightsManagementGuard(isActive: false).skipReason(forFileAt: "/absent/file.\(ext)")
            try expectNil(optInReason,
                          "opt-in must bypass inspection")
        }
        for ext in ["pfile", "ppdf", "ptxt", "pjpg", "pxml", "rpmsg"] {
            try expect(RightsManagementGuard.protectedExtensions.contains(ext), "missing protected format")
        }
    }

    func test_compoundProtectionAndPasswordDistinction() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        for sectorSize in [512, 4096] {
            for fragmented in [false, true] {
                for marker in ["DRMEncryptedTransform", "DRMEncryptedDataSpace", "StrongEncryptionTransform"] {
                    // No Office suffix: classification follows container structure.
                    let file = dir.appendingPathComponent("container.bin")
                    try compound(marker: marker, sectorSize: sectorSize, fragmented: fragmented).write(to: file)
                    let reason = try RightsManagementGuard().skipReason(forFileAt: file.path)
                    if marker.hasPrefix("DRM") {
                        try expect(reason?.contains("Rights Management") == true,
                                   "must detect fragmented/v3/v4 RMS metadata, not merely skip on error")
                    } else {
                        try expectNil(reason, "password encryption alone is not Rights Management")
                    }
                }
            }
        }
    }

    func test_pdfProtectionAndOrdinaryText() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("document.pdf")
        let cases: [(String, Bool)] = [
            ("<< /Filter /MicrosoftIRMServices >>", true),
            ("<< /Filter % a comment\n /Micro#73oftIRMServices >>", true),
            ("<< /Filter /Standard >>", false),
            ("(Documentation about /Filter /MicrosoftIRMServices)", false),
            ("% /Filter /MicrosoftIRMServices\n<< /Title (ordinary) >>", false),
            ("stream\n/Filter /MicrosoftIRMServices\nendstream\n", false),
            ("<< /Type /Filespec /F (MicrosoftIRMServices Protected PDF.pdf) >>", true),
            ("(MicrosoftIRMServices Protected PDF.pdf)", false),
            ("<< /Title (MicrosoftIRMServices Protected PDF.pdf) >>", false),
            ("(MSIP_Label_example_Enabled true)", false)
        ]
        for (body, protected) in cases {
            let content = "%PDF-1.7\n" + String(repeating: " ", count: 65_514) + body + "\n%%EOF"
            try Data(content.utf8).write(to: file)
            let reason = try RightsManagementGuard().skipReason(forFileAt: file.path)
            try expectEqual(reason != nil, protected, "PDF protection classification mismatch for \(body)")
        }
        // A metadata dictionary deep in the middle must not be lost by head/tail sampling.
        let content = "%PDF-1.7\n" + String(repeating: " ", count: 1_100_000)
            + "<< /Filter /MicrosoftIRMServices >>" + String(repeating: " ", count: 1_100_000)
        try Data(content.utf8).write(to: file)
        let middleReason = try RightsManagementGuard().skipReason(forFileAt: file.path)
        try expectNotNil(middleReason, "middle metadata missed")
    }

    func test_ordinaryOfficeAndOtherFilesRemainIncluded() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        for name in ["unlabeled.docx", "labeled.xlsx", "deck.pptx", "notes.txt", "photo.jpg", "source.swift"] {
            let file = dir.appendingPathComponent(name)
            let contents = Data("PK\u{3}\u{4} synthetic MSIP_Label_classification_only".utf8)
            try contents.write(to: file)
            let reason = try RightsManagementGuard().skipReason(forFileAt: file.path)
            try expectNil(reason,
                          "extension or sensitivity label alone must not exclude \(name)")
            let destination = dir.appendingPathComponent("snapshot/\(name)")
            guard case .copied = try process(file, destination: destination) else {
                return try fail("ordinary file should be copied by default: \(name)")
            }
            let copied = try Data(contentsOf: destination)
            try expectEqual(copied, contents, "copy content mismatch")
        }
    }

    func test_preferenceBeforeCopyAndHardLink() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        for name in ["notes.ptxt", "image.pjpg", "document.pfile", "managed.docx", "managed.pdf"] {
            let source = dir.appendingPathComponent(name)
            let contents = name.hasSuffix(".docx") ? compound(marker: "DRMEncryptedTransform")
                : Data("%PDF-1.7\n<< /Filter /MicrosoftIRMServices >>".utf8)
            try contents.write(to: source)
            let previous = dir.appendingPathComponent("previous-\(name)")
            try FileManager.default.copyItem(at: source, to: previous)
            for usePrevious in [false, true] {
                let excluded = dir.appendingPathComponent("excluded-\(usePrevious)/\(name)")
                guard case .skipped = try process(source, destination: excluded,
                                                  previous: usePrevious ? previous : nil) else {
                    return try fail("default should exclude protected \(name) before copy or link")
                }
                try expect(!FileManager.default.fileExists(atPath: excluded.path), "excluded file appeared")
                let included = dir.appendingPathComponent("included-\(usePrevious)/\(name)")
                let result = try process(source, destination: included,
                                         previous: usePrevious ? previous : nil, includeProtected: true)
                switch result {
                case .copied where !usePrevious, .hardlinked where usePrevious: break
                default: return try fail("opt-in failed to copy/link \(name)")
                }
                let copied = try Data(contentsOf: included)
                let original = try Data(contentsOf: source)
                let oldSnapshot = try Data(contentsOf: previous)
                try expectEqual(copied, contents, "opt-in content mismatch")
                try expectEqual(original, contents, "source altered")
                try expectEqual(oldSnapshot, contents, "previous snapshot altered")
            }
        }
    }

    func test_inspectionFailuresAreNotClaimedAsProtection() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("corrupt.docx")
        for data in [Data([0xd0, 0xcf, 0x11, 0xe0, 0xa1, 0xb1, 0x1a, 0xe1]),
                     compound(marker: "Ordinary", cycle: true)] {
            try data.write(to: file)
            let reason = try RightsManagementGuard().skipReason(forFileAt: file.path)
            try expect(reason?.hasPrefix("Protection inspection failed") == true,
                       "malformed metadata must be an explicit inspection failure")
        }
        try expectInspectionError(at: dir.appendingPathComponent("missing"), code: ENOENT)
        let fifo = dir.appendingPathComponent("pipe.docx")
        try expectEqual(mkfifo(fifo.path, 0o600), 0, "create synthetic FIFO")
        try expectInspectionError(at: fifo, code: EINVAL)
        let link = dir.appendingPathComponent("link.docx")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        try expectInspectionError(at: link, code: ELOOP)
    }

    private func expectInspectionError(at url: URL, code: Int32) throws {
        do {
            _ = try RightsManagementGuard().skipReason(forFileAt: url.path)
            try fail("expected an actionable I/O error, not a protection skip")
        } catch let error as NSError where error.domain == NSPOSIXErrorDomain {
            try expectEqual(error.code, Int(code), "inspection must preserve the POSIX error")
        }
    }

    func test_permissionErrorsKeepActionableCategory() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("unreadable.txt")
        try Data("ordinary text".utf8).write(to: source)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: source.path)
        defer { _ = chmod(source.path, 0o600) }
        let result = try process(source, destination: dir.appendingPathComponent("snapshot/unreadable.txt"))
        guard case .error(let path, let error) = result else {
            return try fail("unreadable ordinary file must remain a copy/read error, not a protected-file skip")
        }
        let report = ErrorReporter.categorizeErrors([(path: path, error: error)])
        try expectEqual(report.categories["permission_denied"]?.count, 1, "permission category lost")
        try expectEqual(report.categories[ErrorReporter.protectionInspectionCategory]?.count, 0,
                        "ordinary I/O error mislabeled as uncertain protection")
        try expect(ErrorReporter.formatActionableMessage(error: report).contains("Full Disk Access"),
                   "actionable permissions guidance must survive inspection")
    }

    func test_skipsAreReportedSeparately() throws {
        let report = ErrorReporter.categorizeErrors([], skips: [
            (path: "document.pfile", reason: "Rights Management protected container excluded by preference"),
            (path: "unreadable.docx", reason: "Protection inspection failed; file not attempted")
        ])
        try expectEqual(report.categories[ErrorReporter.protectionSkippedCategory]?.count, 1, "protected count")
        try expectEqual(report.categories[ErrorReporter.protectionInspectionCategory]?.count, 1, "unknown count")
        try expectEqual(report.total, 0, "skips must remain distinct from copy errors")
        let message = ErrorReporter.formatActionableMessage(error: report)
        try expect(message.contains("Rights Management"), "report must identify rights protection")
        try expect(message.contains("non verificabile"), "report must expose uncertainty")
        try expect(!message.contains("Nessun errore"), "skips must be visible")
    }
}
