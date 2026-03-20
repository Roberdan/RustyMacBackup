import SwiftUI

/// SwiftUI content of the menu bar popover.
/// Observes AppUIState via @EnvironmentObject; all actions go through state callbacks.
struct PopoverView: View {
    @EnvironmentObject var state: AppUIState
    @State private var volumes: [URL] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerSection
            Divider()
            statusSection
            if state.appState == .needsSetup {
                Divider()
                diskSetupSection
            }
            Divider()
            actionSection
            Divider()
            footerSection
        }
        .frame(width: 300)
        .onAppear { if state.appState == .needsSetup { refreshVolumes() } }
        .onChange(of: state.appState) { _, newState in
            if newState == .needsSetup { refreshVolumes() }
        }
    }

    // MARK: - Header

    private var headerSection: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(statusDotColor)
                .frame(width: 8, height: 8)
            Text("RustyMacBackup")
                .font(.headline)
            Spacer()
            Text(statusBadge)
                .font(.caption.weight(.semibold))
                .foregroundColor(statusDotColor)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: - Status / Stats / Progress

    private var statusSection: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(statusText)
                .font(.subheadline)
                .foregroundColor(.secondary)

            if let s = state.status, !s.lastCompleted.isEmpty {
                Text("\(Fmt.timeAgo(from: s.lastCompleted))  ·  \(Fmt.formatFileCount(s.filesTotal)) files  ·  \(Fmt.formatBytes(s.bytesCopied))")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else if state.appState != .running {
                Text("No backups yet")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            if let c = state.config {
                diskSpaceRow(for: c)
            }

            if state.isRunning, let s = state.status {
                progressSection(status: s)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private func diskSpaceRow(for config: Config) -> some View {
        let (free, total) = DiskDiagnostics.diskSpace(at: config.destination.path)
        if total > 0 {
            let vol = URL(fileURLWithPath: config.destination.path)
                .deletingLastPathComponent().lastPathComponent
            Text("\(vol): \(Fmt.formatBytes(free)) free")
                .font(.caption)
                .foregroundColor(diskSpaceColor(free: free))
        }
    }

    @ViewBuilder
    private func progressSection(status s: BackupStatusFile) -> some View {
        let pct = s.filesTotal > 0 ? Double(s.filesDone) / Double(s.filesTotal) : 0

        VStack(alignment: .leading, spacing: 3) {
            ProgressView(value: pct)
                .tint(.mlGold)

            HStack(spacing: 8) {
                if s.filesTotal > 0 {
                    Text("\(Int(pct * 100))%")
                        .font(.caption.monospacedDigit())
                        .foregroundColor(.secondary)
                }
                Spacer()
                if s.bytesPerSec > 0 {
                    Text(Fmt.formatBytes(s.bytesPerSec) + "/s")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                if s.etaSecs > 0 {
                    Text("ETA: \(Fmt.formatDuration(Double(s.etaSecs)))")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            if !s.currentFile.isEmpty {
                Text(s.currentFile)
                    .font(.caption2)
                    .foregroundColor(Color(.tertiaryLabelColor))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(.top, 4)
    }

    // MARK: - Disk Setup

    private var diskSetupSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Select Backup Disk")
                .font(.subheadline.weight(.semibold))

            if volumes.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundColor(.mlRosso)
                    Text("No external disk connected")
                        .font(.caption)
                        .foregroundColor(.mlRosso)
                }
            } else {
                ForEach(volumes, id: \.path) { vol in
                    diskButton(for: vol)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private func diskButton(for vol: URL) -> some View {
        let (free, total) = DiskDiagnostics.diskSpace(at: vol.path)
        Button { state.onSelectDisk?(vol) } label: {
            HStack(spacing: 8) {
                Image(systemName: "externaldrive")
                    .foregroundColor(.mlInfo)
                Text(vol.lastPathComponent)
                    .font(.body)
                Spacer()
                if total > 0 {
                    Text(Fmt.formatBytes(free) + " free")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .padding(7)
            .background(Color(.controlBackgroundColor))
            .cornerRadius(6)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Actions

    private var actionSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !state.isRunning && state.appState != .needsSetup && state.appState != .diskAbsent {
                actionButton("Backup…", icon: "arrow.up.doc") { state.onRequestBackup?() }
            }
            if state.isRunning {
                actionButton("Stop Backup", icon: "stop.circle", tint: .mlRosso) { state.onRequestStop?() }
            }
            if state.hasBackups {
                actionButton("Restore…", icon: "arrow.down.doc") { state.onRequestRestore?() }
            }
            if state.canUndo {
                actionButton("Undo Last Restore", icon: "arrow.uturn.backward", tint: .orange) {
                    state.onRequestUndoRestore?()
                }
            }
            actionButton("Open Backup Folder", icon: "folder") { state.onRequestOpenFolder?() }
            actionButton("Eject Disk", icon: "eject") { state.onRequestEject?() }
        }
        .padding(.vertical, 4)
    }

    private var footerSection: some View {
        actionButton("Quit", icon: "power") { state.onRequestQuit?() }
            .padding(.bottom, 2)
    }

    @ViewBuilder
    private func actionButton(_ title: String, icon: String, tint: Color = .primary,
                               action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .frame(maxWidth: .infinity, alignment: .leading)
                .foregroundColor(tint == .primary ? Color(.labelColor) : tint)
        }
        .buttonStyle(.plain)
        .font(.body)
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }

    // MARK: - Helpers

    private var statusDotColor: Color {
        switch state.appState {
        case .idle:       return .mlVerde
        case .running:    return .mlGold
        case .error:      return .mlRosso
        case .diskAbsent: return .mlRosso
        case .stale:      return .orange
        case .needsSetup: return .mlInfo
        }
    }

    private var statusBadge: String {
        switch state.appState {
        case .idle, .needsSetup: return ""
        case .running:    return "RUNNING"
        case .error:      return "ERROR"
        case .diskAbsent: return "NO DISK"
        case .stale:      return "OVERDUE"
        }
    }

    private var statusText: String {
        switch state.appState {
        case .needsSetup: return "Setup required — select a disk"
        case .idle:       return "Ready"
        case .running:    return "Backup in progress…"
        case .error:      return "Last backup failed"
        case .diskAbsent: return "Backup disk not connected"
        case .stale:      return "Backup overdue (>24h)"
        }
    }

    private func diskSpaceColor(free: UInt64) -> Color {
        if free > 50 * 1_073_741_824 { return .mlVerde }
        if free > 10 * 1_073_741_824 { return .orange }
        return .mlRosso
    }

    private func refreshVolumes() {
        guard let vols = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: [.volumeNameKey],
            options: [.skipHiddenVolumes]) else { return }
        volumes = vols.filter {
            let p = $0.path
            return p != "/" && p != "/System/Volumes/Data"
                && $0.lastPathComponent != "Macintosh HD" && p.hasPrefix("/Volumes/")
        }
    }
}
