import Foundation
#if canImport(AppKit)
import AppKit
#endif

enum FDACheck {
    private static let protectedPaths = [
        "Library/Mail",
        "Library/Messages",
        "Library/Safari"
    ]

    struct FDAResult {
        let hasAccess: Bool
        let missingPaths: [String]
    }

    static func checkFullDiskAccess() -> FDAResult {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var missing: [String] = []

        for dir in protectedPaths {
            let fullPath = "\(home)/\(dir)"
            if FileManager.default.fileExists(atPath: fullPath) {
                do {
                    _ = try FileManager.default.contentsOfDirectory(atPath: fullPath)
                } catch {
                    missing.append(dir)
                }
            }
        }

        return FDAResult(hasAccess: missing.isEmpty, missingPaths: missing)
    }

    static func openFDASettings() {
        #if canImport(AppKit)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
        #endif
    }
}
