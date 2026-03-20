import Foundation

/// Shared observable state consumed by all SwiftUI views.
/// AppDelegate creates this, populates callbacks, and updates published properties.
/// All mutations must occur on the main thread (guaranteed by AppDelegate's dispatch patterns).
final class AppUIState: ObservableObject {
    @Published var appState: AppState = .idle
    @Published var status: BackupStatusFile?
    @Published var config: Config?

    // MARK: - Action callbacks — set by AppDelegate before popover is shown

    var onRequestBackup: (() -> Void)?
    var onRequestRestore: (() -> Void)?
    var onRequestStop: (() -> Void)?
    var onRequestEject: (() -> Void)?
    var onRequestOpenFolder: (() -> Void)?
    var onRequestQuit: (() -> Void)?
    var onSelectDisk: ((URL) -> Void)?
    var onRequestUndoRestore: (() -> Void)?

    // MARK: - Computed helpers

    var isRunning: Bool { appState == .running }

    var hasBackups: Bool {
        guard config != nil else { return false }
        return !RestoreEngine.findBackupSnapshots().isEmpty
    }

    var canUndo: Bool { RestoreEngine.hasPreRestoreBackup() }
}
