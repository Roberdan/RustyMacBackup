import Foundation

/// Tests for the endpoint-DLP guard.
///
/// Fixtures are built on the fly — a real labeled Office document cannot be committed here,
/// and would carry an identity besides. What the guard needs is a shape: a zip container that
/// either does or does not hold an `MSIP_Label_*` custom property.
final class DLPGuardTests {

    // MARK: - Fixtures

    private func makeTempDir() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("rmb-dlp-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Build a minimal OOXML-shaped package. When `labeled` is true it carries the same
    /// custom property Office writes for a MIP sensitivity label.
    private func makeOfficeFile(at url: URL, labeled: Bool) throws {
        let staging = url.deletingLastPathComponent()
            .appendingPathComponent("staging-\(UUID().uuidString)")
        let docProps = staging.appendingPathComponent("docProps")
        try FileManager.default.createDirectory(at: docProps, withIntermediateDirectories: true)

        let properties: String
        if labeled {
            properties = """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <Properties>
              <property name="MSIP_Label_8b0e1a4c_Enabled"><vt:lpwstr>true</vt:lpwstr></property>
            </Properties>
            """
        } else {
            properties = """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <Properties>
              <property name="Company"><vt:lpwstr>Example</vt:lpwstr></property>
            </Properties>
            """
        }
        try properties.write(to: docProps.appendingPathComponent("custom.xml"),
                             atomically: true, encoding: .utf8)
        try "<Types/>".write(to: staging.appendingPathComponent("[Content_Types].xml"),
                             atomically: true, encoding: .utf8)

        let zip = Process()
        zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        zip.arguments = ["-q", "-r", url.path, "."]
        zip.currentDirectoryURL = staging
        zip.standardOutput = FileHandle.nullDevice
        zip.standardError = FileHandle.nullDevice
        try zip.run()
        zip.waitUntilExit()
        try? FileManager.default.removeItem(at: staging)
    }

    // MARK: - Extension classification

    func test_officeExtensionsRecognised() throws {
        try expect(DLPGuard.isOfficeDocument("/tmp/deck.pptx"), "pptx is an Office document")
        try expect(DLPGuard.isOfficeDocument("/tmp/Report.DOCX"), "extension match is case-insensitive")
        try expect(DLPGuard.isOfficeDocument("/tmp/legacy.xls"), "legacy binary formats count too")
    }

    func test_nonOfficeFilesAreNeverSkipped() throws {
        let guardOn = DLPGuard(isActive: true)
        try expectNil(guardOn.skipReason(forFileAt: "/tmp/notes.md"), "markdown is not an Office file")
        try expectNil(guardOn.skipReason(forFileAt: "/tmp/archive.zip"), "a plain zip is not an Office file")
        try expectNil(guardOn.skipReason(forFileAt: "/tmp/id_ed25519"), "extensionless files are not Office files")
    }

    // MARK: - Label detection

    func test_unlabeledOfficeFileIsSkipped() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("unlabeled.pptx")
        try makeOfficeFile(at: file, labeled: false)

        try expectEqual(DLPGuard.sensitivityLabelState(ofFileAt: file.path), .unlabeled,
                        "a package without MSIP_Label is unlabeled")
        try expectNotNil(DLPGuard(isActive: true).skipReason(forFileAt: file.path),
                         "an unlabeled Office file must be skipped")
    }

    func test_labeledOfficeFileIsCopied() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("labeled.pptx")
        try makeOfficeFile(at: file, labeled: true)

        try expectEqual(DLPGuard.sensitivityLabelState(ofFileAt: file.path), .labeled,
                        "MSIP_Label in custom.xml means labeled")
        try expectNil(DLPGuard(isActive: true).skipReason(forFileAt: file.path),
                      "a labeled Office file is not blocked by the policy, so it must be backed up")
    }

    /// A legacy binary Office file is not a zip, so the label cannot be read. The guard must
    /// say "unknown" rather than guessing "unlabeled".
    func test_legacyBinaryFormatIsUnknown() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("old.doc")
        // OLE compound file magic, not a zip.
        try Data([0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1]).write(to: file)

        try expectEqual(DLPGuard.sensitivityLabelState(ofFileAt: file.path), .unknown,
                        "a non-OOXML Office file has an undeterminable label")
        try expectNotNil(DLPGuard(isActive: true, skipWhenLabelUnknown: true)
                            .skipReason(forFileAt: file.path),
                         "unknown label is skipped by default")
        try expectNil(DLPGuard(isActive: true, skipWhenLabelUnknown: false)
                        .skipReason(forFileAt: file.path),
                      "the operator can opt back in to attempting unknown-label files")
    }

    // MARK: - Activation

    /// The guard must do nothing when it is off, otherwise a config toggle would not be a
    /// toggle. This is the leg that protects against silently dropping Office files.
    func test_inactiveGuardSkipsNothing() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("unlabeled.pptx")
        try makeOfficeFile(at: file, labeled: false)

        try expectNil(DLPGuard(isActive: false).skipReason(forFileAt: file.path),
                      "an inactive guard must never skip a file")
        try expect(!DLPGuard.forDestination("/Volumes/Backup", enabled: false).isActive,
                   "disabling in config disables the guard regardless of destination")
    }

    /// The removable-media rule only applies to removable media: backing up to an internal
    /// folder must not drop Office files.
    func test_internalDestinationDoesNotActivateGuard() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try expect(!DLPGuard.forDestination(dir.path, enabled: true).isActive,
                   "a destination on the internal disk must leave the guard inactive")
    }

    // MARK: - Ordering against hard links

    /// The DLP skip must come AFTER the hard-link attempt.
    ///
    /// Endpoint DLP vetoes the copy, not the link: a file already present in the previous
    /// snapshot is linked inside the destination volume without content crossing the
    /// removable-media boundary. Checking DLP first would evict every unlabeled Office file
    /// from the backup chain on the next run — files that are, right now, safely preserved.
    func test_hardLinkWinsOverDLPSkip() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let source = dir.appendingPathComponent("unlabeled.pptx")
        try makeOfficeFile(at: source, labeled: false)

        // A previous snapshot holding an identical copy — what shouldHardLink() looks for.
        let previous = dir.appendingPathComponent("previous.pptx")
        try FileManager.default.copyItem(at: source, to: previous)
        let attrs = try FileManager.default.attributesOfItem(atPath: source.path)
        let size = (attrs[.size] as? UInt64) ?? 0
        let mtime = (attrs[.modificationDate] as? Date) ?? Date()
        try FileManager.default.setAttributes([.modificationDate: mtime], ofItemAtPath: previous.path)

        let entry = FileEntry(relativePath: "unlabeled.pptx", absolutePath: source.path,
                              size: size, mtime: mtime)
        let destination = dir.appendingPathComponent("snapshot/unlabeled.pptx")

        let semaphore = DispatchSemaphore(value: 0)
        let box = ResultBox<FileResult>()
        Task {
            box.value = await BackupEngine.processFile(entry: entry, destFile: destination.path,
                                                       prevFile: previous.path,
                                                       dlpGuard: DLPGuard(isActive: true))
            semaphore.signal()
        }
        semaphore.wait()

        switch box.value {
        case .hardlinked:
            try expect(FileManager.default.fileExists(atPath: destination.path),
                       "the hard-linked file must exist in the new snapshot")
        case .skipped(_, let reason):
            try fail("DLP skipped a file that could have been hard-linked (\(reason)) — "
                     + "this would drop it from the backup chain")
        default:
            try fail("expected a hard link, got \(String(describing: box.value))")
        }
    }

    // MARK: - Reporting

    /// A skipped file must be visible in the report. "Not in the backup" is never allowed to
    /// be silent.
    func test_skipsAreReportedInTheirOwnCategory() throws {
        let report = ErrorReporter.categorizeErrors(
            [],
            skips: [(path: "GitHub/x/deck.pptx", reason: "unlabeled Office file")]
        )
        let category = report.categories[ErrorReporter.dlpSkippedCategory]
        try expectNotNil(category, "the DLP category must exist in the report")
        try expectEqual(category?.count ?? 0, 1, "the skip must be counted")
        try expectEqual(category?.files.first, "GitHub/x/deck.pptx", "the skipped path must be named")
        try expectEqual(report.total, 0, "a skip is a decision, not an error, so it must not inflate the error total")

        let message = ErrorReporter.formatActionableMessage(error: report)
        try expect(message.contains("DLP"), "the summary must mention the DLP exclusion: \(message)")
        try expect(!message.contains("Nessun errore"),
                   "a run with skips must not claim there is nothing to report")
        try expect(ErrorReporter.suggestedAction(for: ErrorReporter.dlpSkippedCategory)
                    .contains("Endpoint DLP"),
                   "the advice must name the real cause, not Full Disk Access")
    }
}
