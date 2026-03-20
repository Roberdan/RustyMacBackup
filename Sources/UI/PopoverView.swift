import SwiftUI

/// SwiftUI content of the menu bar popover.
/// Observes AppUIState via @EnvironmentObject; all actions go through state callbacks.
struct PopoverView: View {
    @EnvironmentObject var state: AppUIState
    @State private var volumes: [URL] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerSection
            updateBanner
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

    // MARK: - Update banner

    @ViewBuilder
    private var updateBanner: some View {
        if let version = state.updateAvailable,
           state.dismissedUpdateVersion != version {
            Divider()
            HStack(spacing: 8) {
                Button { state.onRequestUpdate?() } label: {
                    HStack(spacing: 8) {
                        if state.isUpdating {
                            ProgressView().controlSize(.small)
                            // F-17: explicit install phase text
                            Text(updatePhaseLabel)
                                .font(.subheadline).foregroundColor(.mlInfo)
                        } else {
                            Image(systemName: "arrow.down.circle.fill").foregroundColor(.mlInfo)
                            Text("Aggiornamento v\(version) disponibile")
                                .font(.subheadline).foregroundColor(.mlInfo)
                            Spacer()
                            Text("Installa").font(.subheadline.weight(.semibold)).foregroundColor(.mlInfo)
                        }
                    }
                }
                .buttonStyle(.plain)
                .disabled(state.isUpdating)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityHint("Scarica e installa la versione \(version)")

                // F-17: Dismiss button
                if !state.isUpdating {
                    Button {
                        state.dismissedUpdateVersion = version
                    } label: {
                        Image(systemName: "xmark").font(.caption).foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Ignora aggiornamento \(version)")
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Color.mlInfo.opacity(0.08))
        }
    }

    private var updatePhaseLabel: String {
        switch state.updatePhase {
        case .downloading: return "Scaricamento…"
        case .verifying:   return "Verifica firma…"
        case .installing:  return "Installazione…"
        case nil:          return "Aggiornamento in corso…"
        }
    }

    // MARK: - Header

    private var headerSection: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(statusDotColor)
                .frame(width: 8, height: 8)
                .accessibilityLabel("Stato: \(statusText)")  // F-16: non solo colore
            Text("RustyMacBackup")
                .font(.headline)
            Spacer()
            if !statusBadge.isEmpty {
                Text(statusBadge)
                    .font(.caption.weight(.semibold))
                    .foregroundColor(statusDotColor)
                    .accessibilityLabel(statusBadge)
            }
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
            } else if state.appState != .running && state.appState != .restoring && state.appState != .stopping {
                Text("No backups yet")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            if let c = state.config {
                diskSpaceRow(for: c)
            }

            // F-15: Diagnostics card when last backup failed
            if state.appState == .error {
                errorCard
            }

            // F-18: Restore result card visible for 60s after completion
            if let result = state.restoreResult {
                restoreResultCard(result)
            }

            if (state.appState == .running || state.appState == .restoring || state.appState == .stopping),
               let s = state.status {
                progressSection(status: s)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: - F-15: Error diagnostics card

    @ViewBuilder
    private var errorCard: some View {
        if let errors = loadErrors(), let topCategory = topErrorCategory(errors) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.mlRosso)
                        .font(.caption)
                    Text(ErrorReporter.localizedTitle(for: topCategory))
                        .font(.caption.weight(.semibold))
                        .foregroundColor(.mlRosso)
                }
                Text(ErrorReporter.suggestedAction(for: topCategory))
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Button("Mostra log") {
                        NSWorkspace.shared.open(ErrorReporter.logURL)
                    }
                    .font(.caption)
                    .buttonStyle(.plain)
                    .foregroundColor(.mlInfo)
                    .accessibilityHint("Apre il file di log in Console")
                    Button("Riprova") { state.onRequestBackup?() }
                        .font(.caption)
                        .buttonStyle(.plain)
                        .foregroundColor(.mlInfo)
                        .accessibilityHint("Avvia un nuovo backup")
                }
            }
            .padding(8)
            .background(Color.mlRosso.opacity(0.07))
            .cornerRadius(6)
            .padding(.top, 4)
        }
    }

    private func loadErrors() -> BackupErrorFile? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: StatusWriter.errorPath)) else { return nil }
        return try? JSONDecoder().decode(BackupErrorFile.self, from: data)
    }

    private func topErrorCategory(_ errors: BackupErrorFile) -> String? {
        errors.categories
            .filter { $0.value.count > 0 }
            .max(by: { $0.value.count < $1.value.count })?.key
    }

    // MARK: - F-18: Restore result card

    @ViewBuilder
    private func restoreResultCard(_ result: RestoreResultSummary) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill").foregroundColor(.mlVerde).font(.caption)
                Text("Restore completato").font(.caption.weight(.semibold)).foregroundColor(.mlVerde)
            }
            Text("\(result.restored) ripristinati · \(result.overwritten) sovrascritti · \(result.failed) falliti")
                .font(.caption2).foregroundColor(.secondary)
            if !result.backedUpTo.isEmpty {
                Text("Originali in ~/.rustybackup-pre-restore/")
                    .font(.caption2).foregroundColor(.secondary)
            }
        }
        .padding(8)
        .background(Color.mlVerde.opacity(0.07))
        .cornerRadius(6)
        .padding(.top, 4)
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
        // F-21: color reflects current backup phase
        let phaseColor: Color = {
            switch s.phase {
            case "scanning":   return .secondary
            case "copying":    return .mlGold
            case "linking":    return .mlVerde
            case "finalizing": return .mlVerde
            case "cancelled":  return .mlRosso
            default:           return .mlGold
            }
        }()

        VStack(alignment: .leading, spacing: 3) {
            ProgressView(value: pct)
                .tint(phaseColor)
                .accessibilityValue("\(Int(pct * 100)) percento completato")  // F-16

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
                actionButton("Backup…", icon: "arrow.up.doc",
                             hint: "Apre la selezione dei file e avvia il backup") { state.onRequestBackup?() }
            }
            if state.isRunning {
                actionButton("Stop", icon: "stop.circle", tint: .mlRosso,
                             hint: "Interrompe il backup in corso") { state.onRequestStop?() }
            }
            if state.hasBackups {
                actionButton("Restore…", icon: "arrow.down.doc",
                             hint: "Ripristina file da uno snapshot di backup") { state.onRequestRestore?() }
            }
            if state.canUndo {
                actionButton("Undo Last Restore", icon: "arrow.uturn.backward", tint: .orange,
                             hint: "Ripristina i file originali sovrascritti dall'ultimo restore") {
                    state.onRequestUndoRestore?()
                }
            }
            scheduleRow
            actionButton("Open Backup Folder", icon: "folder",
                         hint: "Apre la cartella di backup nel Finder") { state.onRequestOpenFolder?() }
            actionButton("Eject Disk", icon: "eject",
                         hint: "Smonta il disco di backup in modo sicuro") { state.onRequestEject?() }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var scheduleRow: some View {
        if state.onRequestScheduleMenu != nil {
            actionButton("Schedule: \(state.scheduleLabel)", icon: "clock") {
                state.onRequestScheduleMenu?()
            }
        }
    }

    private var footerSection: some View {
        actionButton("Quit", icon: "power") { state.onRequestQuit?() }
            .padding(.bottom, 2)
    }

    @ViewBuilder
    private func actionButton(_ title: String, icon: String, tint: Color = .primary,
                               hint: String = "",
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
        .accessibilityHint(hint)  // F-16
    }

    // MARK: - Helpers

    private var statusDotColor: Color {
        switch state.appState {
        case .idle:           return .mlVerde
        case .running:        return .mlGold
        case .stopping:       return .orange
        case .restoring:      return .mlInfo
        case .error:          return .mlRosso
        case .diskAbsent:     return .mlRosso
        case .stale:          return .orange
        case .needsSetup:     return .mlInfo
        }
    }

    private var statusBadge: String {
        switch state.appState {
        case .idle, .needsSetup: return ""
        case .running:    return "RUNNING"
        case .stopping:   return "STOPPING"
        case .restoring:  return "RESTORING"
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
        case .stopping:   return "Stopping backup…"
        case .restoring:  return "Restore in progress…"
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
