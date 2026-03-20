import Foundation

enum UpdatePhase {
    case downloading
    case verifying
    case installing
}

/// Shared observable state consumed by all SwiftUI views.
/// All mutations must occur on the main thread (guaranteed by AppDelegate's dispatch patterns).
final class AppUIState: ObservableObject {
    @Published var appState: AppState = .idle
    @Published var status: BackupStatusFile?
    @Published var config: Config?
    @Published var scheduleLabel: String = "Off"   // human-readable current schedule

    /// Non-nil when a newer version is available on GitHub.
    @Published var updateAvailable: String?
    /// True while downloading + installing an update.
    @Published var isUpdating: Bool = false
    /// Current update installation phase — nil when not updating.
    @Published var updatePhase: UpdatePhase?

    // MARK: - Action callbacks — set by AppDelegate before popover is shown

    var onRequestBackup: (() -> Void)?
    var onRequestRestore: (() -> Void)?
    var onRequestStop: (() -> Void)?
    var onRequestEject: (() -> Void)?
    var onRequestOpenFolder: (() -> Void)?
    var onRequestQuit: (() -> Void)?
    var onSelectDisk: ((URL) -> Void)?
    var onRequestUndoRestore: (() -> Void)?
    var onRequestUpdate: (() -> Void)?
    /// nil = disable, >0 = intervalMinutes, <0 = daily at abs(value):00
    var onSetSchedule: ((Int?) -> Void)?
    var onRequestScheduleMenu: (() -> Void)?

    // MARK: - Computed helpers

    var isRunning: Bool { appState == .running }

    var hasBackups: Bool {
        guard config != nil else { return false }
        return !RestoreEngine.findBackupSnapshots().isEmpty
    }

    var canUndo: Bool { RestoreEngine.hasPreRestoreBackup() }
}
