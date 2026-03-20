import Foundation
import Darwin

enum ErrorReporter {
    static func categorizeErrors(_ errors: [(path: String, error: Error)]) -> BackupErrorFile {
        var categories: [String: (count: Int, files: [String])] = [
            "permission_denied": (0, []),
            "not_found": (0, []),
            "io_error": (0, []),
            "other": (0, [])
        ]

        for (path, error) in errors {
            let nsError = error as NSError
            let category: String

            switch nsError.code {
            case Int(EACCES), Int(EPERM):
                category = "permission_denied"
            case Int(ENOENT):
                category = "not_found"
            case Int(EIO), Int(EROFS), Int(ENOSPC):
                category = "io_error"
            default:
                if nsError.domain == NSCocoaErrorDomain {
                    switch nsError.code {
                    case NSFileReadNoPermissionError, NSFileWriteNoPermissionError:
                        category = "permission_denied"
                    case NSFileNoSuchFileError, NSFileReadNoSuchFileError:
                        category = "not_found"
                    default:
                        category = "other"
                    }
                } else {
                    category = "other"
                }
            }

            var cat = categories[category]!
            cat.count += 1
            if cat.files.count < 50 {
                cat.files.append(path)
            }
            categories[category] = cat
        }

        var catInfos: [String: ErrorCategoryInfo] = [:]
        for (key, value) in categories {
            catInfos[key] = ErrorCategoryInfo(count: value.count, files: value.files)
        }

        return BackupErrorFile(
            total: errors.count,
            timestamp: ISO8601DateFormatter().string(from: Date()),
            categories: catInfos
        )
    }

    static func localizedTitle(for category: String) -> String {
        switch category {
        case "permission_denied": return "Permesso negato"
        case "not_found":         return "File non trovato"
        case "no_space":          return "Disco pieno"
        case "io_error":          return "Errore di lettura/scrittura"
        default:                  return "Errore generico"
        }
    }

    static func suggestedAction(for category: String) -> String {
        switch category {
        case "permission_denied":
            return "Apri Impostazioni → Privacy → Accesso completo al disco e verifica che RustyMacBackup sia abilitato."
        case "not_found":
            return "Alcuni file sono stati spostati o eliminati durante il backup."
        case "no_space":
            return "Libera spazio sul disco di backup o aumenta lo spazio disponibile."
        case "io_error":
            return "Controlla la salute del disco di backup con Utility Disco."
        default:
            return "Apri il log per i dettagli."
        }
    }

    static var logURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/share/rusty-mac-backup/backup.log")
    }

    static func formatActionableMessage(error: BackupErrorFile) -> String {
        if error.total == 0 {
            return "Nessun errore durante il backup."
        }

        var lines = ["⚠ \(error.total) errori durante il backup:"]
        if let perm = error.categories["permission_denied"], perm.count > 0 {
            lines.append("  🔒 \(perm.count) file senza permesso — Verifica Full Disk Access in Impostazioni → Privacy")
        }
        if let notFound = error.categories["not_found"], notFound.count > 0 {
            lines.append("  ❓ \(notFound.count) file non trovati — File spostati o eliminati durante il backup")
        }
        if let io = error.categories["io_error"], io.count > 0 {
            lines.append("  💾 \(io.count) errori di lettura/scrittura — Controlla la salute del disco")
        }
        if let other = error.categories["other"], other.count > 0 {
            lines.append("  ⚙ \(other.count) altri errori")
        }
        return lines.joined(separator: "\n")
    }
}
