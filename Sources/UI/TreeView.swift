import SwiftUI

// MARK: - Data Model

/// Three-state selection for category headers.
enum CheckState { case on, off, mixed }

/// Flat data model for an item in the tree.
struct ItemInfo: Identifiable {
    let id = UUID()
    /// All filesystem paths toggled together (e.g. zsh has 4 dotfiles, one row).
    let paths: [String]
    let label: String
    let sensitive: Bool
    let isConflict: Bool   // restore mode: file already exists at destination

    var primaryPath: String { paths.first ?? "" }
}

/// A category grouping items in the tree.
struct CategoryInfo: Identifiable {
    let id = UUID()
    let name: String
    let items: [ItemInfo]
}

// MARK: - ViewModel

/// All selection and expansion state. One `@Published` Set<String> drives everything
/// reactively — no nested ObservableObjects needed.
@MainActor
final class TreeSelectionModel: ObservableObject {
    let mode: TreeWindowMode
    let categories: [CategoryInfo]
    let hasBrewfile: Bool

    @Published var checkedPaths: Set<String>
    @Published var expandedCategories: Set<String>
    @Published var brewInstall: Bool = true

    // Completion closures set by the caller (AppDelegate).
    var onConfirmBackup: (([String]) -> Void)?
    var onConfirmRestore: ((URL, [String], Bool) -> Void)?
    var onCancel: (() -> Void)?

    init(mode: TreeWindowMode, enabledPaths: Set<String> = []) {
        self.mode = mode

        switch mode {
        case .backup:
            let discovered = ConfigDiscovery.discover()
            var catMap: [String: [ItemInfo]] = [:]
            var catOrder: [String] = []
            var initialChecked: Set<String> = []

            for item in discovered {
                if catMap[item.category] == nil {
                    catOrder.append(item.category)
                    catMap[item.category] = []
                }
                let info = ItemInfo(paths: item.paths, label: item.label,
                                    sensitive: item.sensitive, isConflict: false)
                catMap[item.category]!.append(info)

                // Pre-check paths that are already in the config, or everything if first run.
                let shouldCheck = enabledPaths.isEmpty
                    || item.paths.allSatisfy { enabledPaths.contains($0) }
                if shouldCheck {
                    item.paths.forEach { initialChecked.insert($0) }
                }
            }

            categories = catOrder.map { CategoryInfo(name: $0, items: catMap[$0]!) }
            checkedPaths = initialChecked
            // All categories start collapsed so the user sees a clean list of categories.
            expandedCategories = []
            hasBrewfile = false

        case .restore(let snapshotURL):
            let items = RestoreEngine.scanSnapshot(at: snapshotURL)
            var dotfiles: [ItemInfo] = []
            var folders: [ItemInfo] = []
            var initialChecked: Set<String> = []

            for item in items {
                let info = ItemInfo(paths: ["~/\(item.relativePath)"],
                                    label: item.relativePath,
                                    sensitive: false, isConflict: item.existsAtDest)
                if item.relativePath.hasPrefix(".") && !item.isDirectory {
                    dotfiles.append(info)
                } else {
                    folders.append(info)
                }
                initialChecked.insert("~/\(item.relativePath)")
            }

            var cats: [CategoryInfo] = []
            if !dotfiles.isEmpty { cats.append(CategoryInfo(name: "Dotfiles", items: dotfiles)) }
            if !folders.isEmpty { cats.append(CategoryInfo(name: "Folders & Repos", items: folders)) }
            categories = cats
            checkedPaths = initialChecked
            // In restore mode, expand all categories so the user sees what will be restored.
            expandedCategories = Set(cats.map(\.name))

            let brewPath = snapshotURL.appendingPathComponent("_environment/Brewfile").path
            hasBrewfile = FileManager.default.fileExists(atPath: brewPath)
        }
    }

    // MARK: - Queries

    func checkState(for category: CategoryInfo) -> CheckState {
        let allPaths = category.items.flatMap(\.paths)
        let count = allPaths.filter { checkedPaths.contains($0) }.count
        if count == 0 { return .off }
        if count == allPaths.count { return .on }
        return .mixed
    }

    func isItemChecked(_ item: ItemInfo) -> Bool {
        !item.paths.isEmpty && item.paths.allSatisfy { checkedPaths.contains($0) }
    }

    func isCategoryExpanded(_ category: CategoryInfo) -> Bool {
        expandedCategories.contains(category.name)
    }

    var selectedPaths: [String] { Array(checkedPaths) }

    var selectedItemCount: Int {
        categories.flatMap(\.items).filter { isItemChecked($0) }.count
    }

    // MARK: - Mutations

    func toggleCategory(_ category: CategoryInfo) {
        let allPaths = category.items.flatMap(\.paths)
        if checkState(for: category) == .on {
            allPaths.forEach { checkedPaths.remove($0) }
        } else {
            allPaths.forEach { checkedPaths.insert($0) }
        }
    }

    func toggleItem(_ item: ItemInfo) {
        if isItemChecked(item) {
            item.paths.forEach { checkedPaths.remove($0) }
        } else {
            item.paths.forEach { checkedPaths.insert($0) }
        }
    }

    func toggleExpansion(_ category: CategoryInfo) {
        if expandedCategories.contains(category.name) {
            expandedCategories.remove(category.name)
        } else {
            expandedCategories.insert(category.name)
        }
    }

    func selectAll()     { categories.flatMap(\.items).flatMap(\.paths).forEach { checkedPaths.insert($0) } }
    func selectNone()    { checkedPaths.removeAll() }
    func selectNewOnly() {
        checkedPaths.removeAll()
        for item in categories.flatMap(\.items) where !item.isConflict {
            item.paths.forEach { checkedPaths.insert($0) }
        }
    }
}

// MARK: - Tri-state Checkbox

/// Tri-state checkbox using SF Symbols. Tapping always calls `action`; the parent
/// decides what "mixed → on" or "on → off" means.
struct TriStateCheckbox: View {
    let state: CheckState
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Group {
                switch state {
                case .on:
                    Image(systemName: "checkmark.square.fill")
                        .foregroundColor(.accentColor)
                case .off:
                    Image(systemName: "square")
                        .foregroundColor(Color(.tertiaryLabelColor))
                case .mixed:
                    Image(systemName: "minus.square.fill")
                        .foregroundColor(.accentColor)
                }
            }
            .imageScale(.medium)
        }
        .buttonStyle(.plain)
        .frame(width: 18, height: 18)
    }
}

// MARK: - Category Header Row

struct CategoryHeaderRow: View {
    let category: CategoryInfo
    @ObservedObject var model: TreeSelectionModel

    var body: some View {
        HStack(spacing: 6) {
            // Tri-state checkbox — tap handled here, NOT propagated to the expand button.
            TriStateCheckbox(state: model.checkState(for: category)) {
                model.toggleCategory(category)
            }

            // Name + count + chevron — tapping this area expands/collapses.
            HStack(spacing: 4) {
                Text(category.name.uppercased())
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.secondary)
                Text("(\(category.items.count))")
                    .font(.system(size: 10))
                    .foregroundColor(Color(.tertiaryLabelColor))
                Spacer(minLength: 4)
                Image(systemName: model.isCategoryExpanded(category) ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(Color(.tertiaryLabelColor))
            }
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(.easeInOut(duration: 0.18)) {
                    model.toggleExpansion(category)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color(.windowBackgroundColor).opacity(0.6))
    }
}

// MARK: - Item Row

struct ItemRow: View {
    let item: ItemInfo
    @ObservedObject var model: TreeSelectionModel

    var body: some View {
        HStack(spacing: 6) {
            // Native macOS checkbox via Toggle + .checkboxStyle
            Toggle(isOn: Binding(
                get: { model.isItemChecked(item) },
                set: { _ in model.toggleItem(item) }
            )) { EmptyView() }
            .toggleStyle(.checkbox)
            .labelsHidden()

            Text(item.label)
                .font(.system(size: 12))
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 4)

            if item.sensitive {
                Text("sensitive")
                    .font(.system(size: 9))
                    .foregroundColor(.orange)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .overlay(RoundedRectangle(cornerRadius: 3).stroke(Color.orange.opacity(0.6), lineWidth: 0.5))
            }

            if case .restore = model.mode {
                if item.isConflict {
                    Text("overwrite")
                        .font(.system(size: 9))
                        .foregroundColor(.mlRosso)
                } else {
                    Text("new")
                        .font(.system(size: 9))
                        .foregroundColor(.mlVerde)
                }
            }

            Text(shortPath(item.primaryPath))
                .font(.system(size: 10))
                .foregroundColor(Color(.tertiaryLabelColor))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 160, alignment: .trailing)
        }
        .padding(.leading, 28)
        .padding(.trailing, 10)
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onTapGesture { model.toggleItem(item) }
    }

    private func shortPath(_ path: String) -> String {
        path.count > 34 ? "…" + String(path.suffix(32)) : path
    }
}

// MARK: - Main Tree View

struct TreeView: View {
    @StateObject var model: TreeSelectionModel
    @State private var showOverwriteAlert = false

    var body: some View {
        VStack(spacing: 0) {
            toolbarRow
            Divider()
            treeContent
            if model.hasBrewfile {
                Divider()
                Toggle("Reinstall Homebrew packages from Brewfile", isOn: $model.brewInstall)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 12))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
            }
            Divider()
            bottomBar
        }
        .frame(minWidth: 500, minHeight: 520)
        .alert("Overwrite existing files?", isPresented: $showOverwriteAlert) {
            Button("Overwrite & Restore", role: .destructive) { confirmRestore() }
            Button("Cancel", role: .cancel) { }
        } message: {
            let n = model.categories.flatMap(\.items)
                .filter { model.isItemChecked($0) && $0.isConflict }.count
            Text("You selected \(n) item(s) that already exist at their destination. " +
                 "Originals will be saved to ~/.rustybackup-pre-restore/ before overwriting.")
        }
    }

    // MARK: - Toolbar

    private var toolbarRow: some View {
        HStack(spacing: 12) {
            Text(model.mode.isBackup ? "Select what to back up" : "Select what to restore")
                .font(.headline)
                .foregroundColor(model.mode.isBackup ? .mlInfo : .mlVerde)

            Spacer()

            Button("All")  { model.selectAll() }  .buttonStyle(.plain).font(.callout)
            Button("None") { model.selectNone() } .buttonStyle(.plain).font(.callout)
            if !model.mode.isBackup {
                Button("New Only") { model.selectNewOnly() } .buttonStyle(.plain).font(.callout)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: - Tree

    private var treeContent: some View {
        ScrollView(.vertical, showsIndicators: true) {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(model.categories) { category in
                    // Category header
                    CategoryHeaderRow(category: category, model: model)

                    // Expanded items
                    if model.isCategoryExpanded(category) {
                        ForEach(category.items) { item in
                            ItemRow(item: item, model: model)
                        }
                        Divider().padding(.leading, 10)
                    }
                }
            }
        }
        .background(Color(.textBackgroundColor))
    }

    // MARK: - Bottom Bar

    private var bottomBar: some View {
        HStack(spacing: 12) {
            Text("\(model.selectedItemCount) items selected")
                .font(.caption)
                .foregroundColor(.secondary)

            Spacer()

            Button("Cancel") { model.onCancel?() }
                .keyboardShortcut(.cancelAction)

            Button(model.mode.isBackup ? "Start Backup" : "Restore Selected") {
                handleConfirm()
            }
            .keyboardShortcut(.defaultAction)
            .disabled(model.selectedPaths.isEmpty)
            .buttonStyle(.borderedProminent)
            .tint(model.mode.isBackup ? .mlInfo : .mlVerde)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    // MARK: - Actions

    private func handleConfirm() {
        switch model.mode {
        case .backup:
            model.onConfirmBackup?(model.selectedPaths)

        case .restore(_):
            let conflictsSelected = model.categories.flatMap(\.items)
                .filter { model.isItemChecked($0) && $0.isConflict }
            if conflictsSelected.isEmpty {
                confirmRestore()
            } else {
                showOverwriteAlert = true
            }
        }
    }

    private func confirmRestore() {
        guard case .restore(let url) = model.mode else { return }
        let items = model.categories.flatMap(\.items)
            .filter { model.isItemChecked($0) }
            .flatMap(\.paths)
        model.onConfirmRestore?(url, items, model.brewInstall)
    }
}
