import Foundation
import Darwin

/// Local format inspection only: no Office launch, credentials, decryption or network.
/// This detects rights protection, not the endpoint's separate copy/USB policy.
struct RightsManagementGuard: Sendable {
    let isActive: Bool

    // Microsoft MIP SDK, "Supported file types for labeling and protection".
    static let protectedExtensions: Set<String> = [
        "pfile", "ptxt", "pxml", "pjpg", "pjpeg", "ppdf", "ppng",
        "ptif", "ptiff", "pbmp", "pgif", "pjpe", "pjfif", "rpmsg"
    ]

    init(isActive: Bool = true) {
        self.isActive = isActive
    }

    init(config: ProtectionConfig) {
        isActive = !config.includeRightsManagedFiles
    }

    func skipReason(forFileAt absolutePath: String) throws -> String? {
        guard isActive else { return nil }
        let url = URL(fileURLWithPath: absolutePath)
        if Self.protectedExtensions.contains(url.pathExtension.lowercased()) {
            return "Rights Management protected container excluded by preference"
        }
        do {
            let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
            guard descriptor >= 0 else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }
            let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            defer { try? file.close() }
            var metadata = stat()
            guard fstat(descriptor, &metadata) == 0 else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }
            guard metadata.st_mode & S_IFMT == S_IFREG else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(EINVAL),
                              userInfo: [NSLocalizedDescriptionKey: "Not a regular file"])
            }
            let header = try file.read(upToCount: 8) ?? Data()
            if header == Data([0xd0, 0xcf, 0x11, 0xe0, 0xa1, 0xb1, 0x1a, 0xe1]) {
                if try CompoundProtectionReader(file: file).isRightsManaged() {
                    return "Office Rights Management protection detected"
                }
            } else if header.starts(with: Data("%PDF-".utf8)) {
                try file.seek(toOffset: 0)
                if try PDFRightsProtection.containsProtection(in: file) {
                    return "PDF Rights Management protection detected"
                }
            }
            return nil
        } catch let error as CompoundProtectionReader.ParseError {
            // Malformed protection metadata is not proof of rights protection.
            // Ordinary I/O errors propagate unchanged to the backup error reporter.
            return "Protection inspection failed; file not attempted: \(error.localizedDescription)"
        }
    }
}
