import Foundation

/// Skips documents that Microsoft Purview Endpoint DLP refuses to let leave the machine.
///
/// The block is not a permission problem and no amount of Full Disk Access fixes it: the
/// endpoint agent vetoes the write itself, `copyfile()` comes back with `EPERM`, and macOS
/// raises a modal "Prevenzione della perdita dei dati" dialog asking for a business
/// justification. On an hourly unattended backup that dialog is pure noise — nobody is there
/// to answer it, and the file is never copied anyway.
///
/// So the guard decides BEFORE the copy is attempted. The policy that bites here is the
/// common one: *unlabeled Office files may not be copied to removable media*. A file
/// therefore needs three things to be true at once to be skipped — the destination is
/// removable, the file is an Office document, and it carries no Microsoft Information
/// Protection (MIP) sensitivity label.
///
/// A skip is a declared outcome, never a silent one: it is counted and reported under
/// `dlp_skipped` so "not in the backup" is always something the report says out loud.
struct DLPGuard: Sendable {
    /// Whether the guard does anything at all. False when the destination is not removable
    /// media, or when the operator turned the check off in config.
    let isActive: Bool

    /// What to do with an Office file whose label cannot be determined (legacy binary
    /// formats, corrupt archives). Skipping is the default: attempting the copy is what
    /// raises the modal dialog, which is the thing we are here to prevent.
    let skipWhenLabelUnknown: Bool

    /// Extensions Purview treats as Office documents for the removable-media rule.
    /// Both the OOXML formats (zip containers, label readable) and the legacy binary
    /// formats (OLE compound files, label not readable here) are covered.
    static let officeExtensions: Set<String> = [
        "docx", "docm", "dotx", "dotm", "doc", "dot",
        "xlsx", "xlsm", "xltx", "xltm", "xlsb", "xls", "xlt",
        "pptx", "pptm", "potx", "potm", "ppsx", "ppsm", "ppt", "pot", "pps",
        "vsdx", "vsdm", "vssx", "vstx"
    ]

    init(isActive: Bool, skipWhenLabelUnknown: Bool = true) {
        self.isActive = isActive
        self.skipWhenLabelUnknown = skipWhenLabelUnknown
    }

    /// Build a guard for a concrete backup run. Inactive unless the destination is removable
    /// media, because the DLP rule this guard models only fires on removable media — skipping
    /// Office files while backing up to an internal folder would drop data for no reason.
    static func forDestination(_ destinationPath: String, enabled: Bool,
                               skipWhenLabelUnknown: Bool = true) -> DLPGuard {
        guard enabled else {
            return DLPGuard(isActive: false, skipWhenLabelUnknown: skipWhenLabelUnknown)
        }
        return DLPGuard(isActive: isRemovableVolume(destinationPath),
                        skipWhenLabelUnknown: skipWhenLabelUnknown)
    }

    /// The reason a file is being skipped, or nil when it should be copied normally.
    func skipReason(forFileAt absolutePath: String) -> String? {
        guard isActive else { return nil }
        guard Self.isOfficeDocument(absolutePath) else { return nil }

        switch Self.sensitivityLabelState(ofFileAt: absolutePath) {
        case .labeled:
            return nil
        case .unlabeled:
            return "unlabeled Office file — blocked by endpoint DLP on removable media"
        case .unknown:
            guard skipWhenLabelUnknown else { return nil }
            return "Office file with undeterminable sensitivity label — not risking a DLP prompt"
        }
    }

    static func isOfficeDocument(_ path: String) -> Bool {
        let ext = URL(fileURLWithPath: path).pathExtension.lowercased()
        return officeExtensions.contains(ext)
    }

    enum LabelState: Equatable {
        case labeled
        case unlabeled
        case unknown
    }

    /// Read the MIP sensitivity label out of an OOXML package.
    ///
    /// Office stores it as custom document properties named `MSIP_Label_<guid>_Enabled` in
    /// `docProps/custom.xml` inside the zip container. Legacy binary formats keep it
    /// somewhere this code cannot cheaply reach, so they answer `.unknown` rather than
    /// pretending to be sure.
    static func sensitivityLabelState(ofFileAt absolutePath: String) -> LabelState {
        guard FileManager.default.isReadableFile(atPath: absolutePath) else { return .unknown }
        guard isOOXMLContainer(absolutePath) else { return .unknown }
        guard let customXML = readZipEntry(archive: absolutePath, entry: "docProps/custom.xml") else {
            // No custom properties part at all: the package is readable and simply carries
            // no label. That is a real answer, not a failure.
            return zipEntryListing(archive: absolutePath) == nil ? .unknown : .unlabeled
        }
        return customXML.contains("MSIP_Label") ? .labeled : .unlabeled
    }

    /// OOXML packages are zip archives: they start with the local file header magic "PK\u{03}\u{04}".
    /// Legacy OLE compound files start with 0xD0CF11E0 and are rejected here.
    static func isOOXMLContainer(_ path: String) -> Bool {
        guard let handle = FileHandle(forReadingAtPath: path) else { return false }
        defer { try? handle.close() }
        guard let magic = try? handle.read(upToCount: 4), magic.count == 4 else { return false }
        return Array(magic) == [0x50, 0x4B, 0x03, 0x04]
    }

    // MARK: - Zip access

    /// Read one entry out of a zip archive as text.
    ///
    /// Delegates to `/usr/bin/unzip` rather than hand-rolling a deflate parser: this runs
    /// against the operator's real documents during a backup, and a subtle bug in a
    /// hand-written zip reader would silently mis-classify files. `unzip` ships with macOS.
    /// Returns nil when the entry is absent or unreadable.
    static func readZipEntry(archive: String, entry: String) -> String? {
        guard let output = runUnzip(arguments: ["-p", archive, entry]), !output.isEmpty else {
            return nil
        }
        return output
    }

    /// Cheap check that the archive is structurally readable at all, used to tell
    /// "no label" apart from "cannot tell".
    static func zipEntryListing(archive: String) -> String? {
        runUnzip(arguments: ["-l", archive])
    }

    private static func runUnzip(arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = arguments
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        process.standardInput = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return nil
        }

        // Read before waiting so a large entry cannot deadlock on a full pipe buffer.
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        _ = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)
    }

    // MARK: - Volume inspection

    /// True when the path lives on removable or external media — the only place the
    /// removable-media DLP rule applies.
    static func isRemovableVolume(_ path: String) -> Bool {
        let url = URL(fileURLWithPath: path)
        let keys: Set<URLResourceKey> = [.volumeIsRemovableKey, .volumeIsInternalKey, .volumeIsEjectableKey]
        guard let values = try? url.resourceValues(forKeys: keys) else {
            // Cannot tell. Fall back to the conventional mount point for external media so a
            // failed probe does not quietly disable the guard on a real external disk.
            return path.hasPrefix("/Volumes/")
        }
        if values.volumeIsRemovable == true || values.volumeIsEjectable == true { return true }
        if let internalVolume = values.volumeIsInternal { return !internalVolume }
        return path.hasPrefix("/Volumes/")
    }
}
