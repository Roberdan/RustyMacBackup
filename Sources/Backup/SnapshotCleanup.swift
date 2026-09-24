import Foundation

enum CleanupAge: Int, CaseIterable {
    case oneMonth = 1
    case sixMonths = 6
    case oneYear = 12

    var label: String {
        switch self {
        case .oneMonth: return "1 mese"
        case .sixMonths: return "6 mesi"
        case .oneYear: return "1 anno"
        }
    }

    func cutoff(from now: Date, calendar: Calendar = .current) -> Date {
        // All cases are fixed, valid calendar-month offsets.
        calendar.date(byAdding: .month, value: -rawValue, to: now)!
    }
}

/// Holds the destination lock from preview until cancellation or execution.
final class SnapshotCleanup {
    let destination: URL
    let cutoff: Date
    let candidates: [BackupEntry]
    let latest: BackupEntry?
    private let lock: DestinationLock

    init(at destination: URL, age: CleanupAge, now: Date = Date()) throws {
        try RetentionManager.validateDestination(destination)
        let lock = try DestinationLock(at: destination)
        let backups = try RetentionManager.readBackups(at: destination)
        let cutoff = age.cutoff(from: now)
        self.destination = destination
        self.cutoff = cutoff
        self.latest = backups.first
        self.candidates = backups.dropFirst().filter { $0.timestamp < cutoff }
        self.lock = lock
    }

    func execute() throws -> [String] {
        try withExtendedLifetime(lock) {
            try RetentionManager.validateDestination(destination)
            let current = try RetentionManager.readBackups(at: destination)
            let eligible = current.dropFirst().filter { $0.timestamp < cutoff }.map(\.name)
            guard eligible == candidates.map(\.name) else {
                throw NSError(domain: "SnapshotCleanup", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: "I backup sono cambiati. Ripeti l'anteprima prima di eliminare."
                ])
            }
            return try RetentionManager.deleteBackups(candidates, at: destination)
        }
    }
}
