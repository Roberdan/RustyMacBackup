import Cocoa

enum TreeWindowMode {
    case backup
    case restore(snapshotURL: URL)
}

protocol TreeWindowDelegate: AnyObject {
    func treeWindowDidConfirmBackup(selectedPaths: [String])
    func treeWindowDidConfirmRestore(snapshotURL: URL, selectedItems: [String], brewInstall: Bool)
}

/// Unified tree window for both backup and restore.
/// Shows categorized items with checkboxes. Color and labels change by mode.
class TreeWindowController: NSWindowController {
    weak var treeDelegate: TreeWindowDelegate?
    private let mode: TreeWindowMode
    private var checkboxes: [(path: String, checkbox: NSButton, isConflict: Bool)] = []
    private var brewCheckbox: NSButton?
    private let accentColor: NSColor
    private let actionTitle: String

    init(mode: TreeWindowMode, enabledPaths: Set<String> = []) {
        self.mode = mode
        switch mode {
        case .backup:
            accentColor = .systemBlue
            actionTitle = "Start Backup"
        case .restore:
            accentColor = .systemGreen
            actionTitle = "Restore Selected"
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 540),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered, defer: false)
        window.center()
        window.isReleasedWhenClosed = false

        switch mode {
        case .backup:
            window.title = "Backup -- Select Sources"
        case .restore(let url):
            window.title = "Restore -- \(url.lastPathComponent)"
        }

        super.init(window: window)
        setupUI(enabledPaths: enabledPaths)
    }

    required init?(coder: NSCoder) { fatalError() }

    private func setupUI(enabledPaths: Set<String>) {
        guard let window = window else { return }
        let root = NSView(frame: window.contentView!.bounds)
        root.autoresizingMask = [.width, .height]
        window.contentView = root

        let outerStack = NSStackView()
        outerStack.orientation = .vertical
        outerStack.alignment = .leading
        outerStack.spacing = 8
        outerStack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        outerStack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(outerStack)
        NSLayoutConstraint.activate([
            outerStack.topAnchor.constraint(equalTo: root.topAnchor),
            outerStack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            outerStack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            outerStack.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])

        // Mode banner
        let banner = NSTextField(labelWithString: mode.isBackup
            ? "Select what to back up"
            : "Select what to restore (originals backed up before overwrite)")
        banner.font = .boldSystemFont(ofSize: 13)
        banner.textColor = accentColor
        outerStack.addArrangedSubview(banner)

        // Quick buttons
        let btnRow = NSStackView()
        btnRow.orientation = .horizontal; btnRow.spacing = 8
        for (title, action) in [("All", #selector(doAll)), ("None", #selector(doNone))] {
            let b = NSButton(title: title, target: self, action: action)
            b.bezelStyle = .inline; b.font = .systemFont(ofSize: 11)
            btnRow.addArrangedSubview(b)
        }
        if case .restore = mode {
            let newOnly = NSButton(title: "New Only", target: self, action: #selector(doNewOnly))
            newOnly.bezelStyle = .inline; newOnly.font = .systemFont(ofSize: 11)
            btnRow.addArrangedSubview(newOnly)
        }
        outerStack.addArrangedSubview(btnRow)
        addSep(to: outerStack)

        // Tree
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 280).isActive = true
        scroll.widthAnchor.constraint(equalToConstant: 428).isActive = true

        let treeStack = NSStackView()
        treeStack.orientation = .vertical
        treeStack.alignment = .leading
        treeStack.spacing = 1
        treeStack.translatesAutoresizingMaskIntoConstraints = false

        buildTree(into: treeStack, enabledPaths: enabledPaths)

        let clip = NSClipView()
        clip.documentView = treeStack
        clip.drawsBackground = false
        scroll.contentView = clip
        outerStack.addArrangedSubview(scroll)

        // Brewfile (restore only)
        if case .restore(let url) = mode {
            let brewPath = url.appendingPathComponent("_environment/Brewfile").path
            if FileManager.default.fileExists(atPath: brewPath) {
                addSep(to: outerStack)
                let bc = NSButton(checkboxWithTitle: "Reinstall Homebrew packages",
                                  target: nil, action: nil)
                bc.state = .on; bc.font = .systemFont(ofSize: 12)
                brewCheckbox = bc
                outerStack.addArrangedSubview(bc)
            }
        }

        addSep(to: outerStack)

        // Bottom bar
        let bottom = NSStackView()
        bottom.orientation = .horizontal; bottom.spacing = 8
        bottom.translatesAutoresizingMaskIntoConstraints = false
        bottom.widthAnchor.constraint(equalToConstant: 428).isActive = true

        let count = NSTextField(labelWithString: "\(checkboxes.count) items")
        count.font = .systemFont(ofSize: 11)
        count.textColor = .secondaryLabelColor
        bottom.addArrangedSubview(count)
        let sp = NSView(); sp.setContentHuggingPriority(.defaultLow, for: .horizontal)
        bottom.addArrangedSubview(sp)

        let cancel = NSButton(title: "Cancel", target: self, action: #selector(doCancel))
        cancel.bezelStyle = .rounded; cancel.keyEquivalent = "\u{1b}"
        bottom.addArrangedSubview(cancel)

        let go = NSButton(title: actionTitle, target: self, action: #selector(doConfirm))
        go.bezelStyle = .rounded; go.keyEquivalent = "\r"
        go.contentTintColor = accentColor
        bottom.addArrangedSubview(go)
        outerStack.addArrangedSubview(bottom)
    }

    // MARK: - Tree

    private func buildTree(into stack: NSStackView, enabledPaths: Set<String>) {
        switch mode {
        case .backup:
            buildBackupTree(into: stack, enabledPaths: enabledPaths)
        case .restore(let url):
            buildRestoreTree(into: stack, snapshotURL: url)
        }
    }

    private func buildBackupTree(into stack: NSStackView, enabledPaths: Set<String>) {
        let discovered = ConfigDiscovery.discover()
        var grouped: [(String, [DiscoveredConfig])] = []
        var seen: [String: Int] = [:]
        for item in discovered {
            if let idx = seen[item.category] { grouped[idx].1.append(item) }
            else { seen[item.category] = grouped.count; grouped.append((item.category, [item])) }
        }

        for (cat, items) in grouped {
            stack.addArrangedSubview(makeCatHeader(cat))
            for item in items {
                let on = item.paths.allSatisfy { enabledPaths.contains($0) }
                let row = makeRow(
                    label: item.label,
                    path: item.paths.first ?? "",
                    checked: on,
                    sensitive: item.sensitive,
                    conflict: false)
                stack.addArrangedSubview(row)
                for p in item.paths { checkboxes.append((p, row.checkbox!, false)) }
            }
            stack.addArrangedSubview(makeSpacer(6))
        }
    }

    private func buildRestoreTree(into stack: NSStackView, snapshotURL: URL) {
        let items = RestoreEngine.scanSnapshot(at: snapshotURL)
        // Group by first path component or known categories
        var folders: [RestoreItem] = []
        var dotfiles: [RestoreItem] = []
        for item in items {
            if item.relativePath.hasPrefix(".") && !item.isDirectory {
                dotfiles.append(item)
            } else {
                folders.append(item)
            }
        }

        if !dotfiles.isEmpty {
            stack.addArrangedSubview(makeCatHeader("Dotfiles"))
            for item in dotfiles {
                let row = makeRow(
                    label: item.relativePath,
                    path: "~/\(item.relativePath)",
                    checked: true,
                    sensitive: false,
                    conflict: item.existsAtDest)
                stack.addArrangedSubview(row)
                checkboxes.append((item.relativePath, row.checkbox!, item.existsAtDest))
            }
            stack.addArrangedSubview(makeSpacer(6))
        }

        if !folders.isEmpty {
            stack.addArrangedSubview(makeCatHeader("Folders & Repos"))
            for item in folders {
                let row = makeRow(
                    label: item.relativePath,
                    path: "~/\(item.relativePath)",
                    checked: true,
                    sensitive: false,
                    conflict: item.existsAtDest)
                stack.addArrangedSubview(row)
                checkboxes.append((item.relativePath, row.checkbox!, item.existsAtDest))
            }
        }
    }

    // MARK: - Row builders

    private func makeCatHeader(_ text: String) -> NSView {
        let l = NSTextField(labelWithString: text.uppercased())
        l.font = .systemFont(ofSize: 10, weight: .bold)
        l.textColor = accentColor.withAlphaComponent(0.7)
        return l
    }

    private func makeRow(label: String, path: String, checked: Bool,
                          sensitive: Bool, conflict: Bool) -> NSStackView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 6
        row.translatesAutoresizingMaskIntoConstraints = false
        row.widthAnchor.constraint(equalToConstant: 420).isActive = true

        let cb = NSButton(checkboxWithTitle: "", target: nil, action: nil)
        cb.state = checked ? .on : .off
        row.addArrangedSubview(cb)

        let name = NSTextField(labelWithString: label)
        name.font = .systemFont(ofSize: 12)
        name.textColor = .labelColor
        name.lineBreakMode = .byTruncatingTail
        row.addArrangedSubview(name)

        let sp = NSView(); sp.setContentHuggingPriority(.defaultLow, for: .horizontal)
        row.addArrangedSubview(sp)

        if sensitive {
            let badge = NSTextField(labelWithString: "sensitive")
            badge.font = .systemFont(ofSize: 9)
            badge.textColor = .systemOrange
            row.addArrangedSubview(badge)
        }

        if conflict {
            let badge = NSTextField(labelWithString: "overwrite")
            badge.font = .systemFont(ofSize: 9)
            badge.textColor = .systemOrange
            row.addArrangedSubview(badge)
        } else if case .restore = mode {
            let badge = NSTextField(labelWithString: "new")
            badge.font = .systemFont(ofSize: 9)
            badge.textColor = .systemGreen
            row.addArrangedSubview(badge)
        }

        let short = path.count > 28 ? "..." + String(path.suffix(25)) : path
        let pathLabel = NSTextField(labelWithString: short)
        pathLabel.font = .systemFont(ofSize: 10)
        pathLabel.textColor = .tertiaryLabelColor
        row.addArrangedSubview(pathLabel)

        return row
    }

    // MARK: - Actions

    @objc private func doAll() { checkboxes.forEach { $0.checkbox.state = .on } }
    @objc private func doNone() { checkboxes.forEach { $0.checkbox.state = .off } }
    @objc private func doNewOnly() {
        for (_, cb, isConflict) in checkboxes { cb.state = isConflict ? .off : .on }
    }
    @objc private func doCancel() { window?.close() }

    @objc private func doConfirm() {
        let selected = Array(Set(checkboxes.filter { $0.checkbox.state == .on }.map(\.path)))
        guard !selected.isEmpty else { window?.close(); return }

        switch mode {
        case .backup:
            window?.close()
            treeDelegate?.treeWindowDidConfirmBackup(selectedPaths: selected)

        case .restore(let url):
            let overwrites = checkboxes.filter { $0.checkbox.state == .on && $0.isConflict }
            if !overwrites.isEmpty {
                let alert = NSAlert()
                alert.messageText = "Overwrite \(overwrites.count) existing items?"
                alert.informativeText = "Originals saved to ~/.rustybackup-pre-restore/"
                alert.alertStyle = .warning
                alert.addButton(withTitle: "Overwrite & Restore")
                alert.addButton(withTitle: "Cancel")
                guard alert.runModal() == .alertFirstButtonReturn else { return }
            }
            window?.close()
            treeDelegate?.treeWindowDidConfirmRestore(
                snapshotURL: url, selectedItems: selected,
                brewInstall: brewCheckbox?.state == .on)
        }
    }

    // MARK: - Helpers

    private func addSep(to s: NSStackView) {
        let sep = NSBox(); sep.boxType = .separator
        sep.translatesAutoresizingMaskIntoConstraints = false
        s.addArrangedSubview(sep)
        sep.widthAnchor.constraint(equalToConstant: 428).isActive = true
    }

    private func makeSpacer(_ h: CGFloat) -> NSView {
        let v = NSView()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.heightAnchor.constraint(equalToConstant: h).isActive = true
        return v
    }
}

extension TreeWindowMode {
    var isBackup: Bool {
        if case .backup = self { return true }
        return false
    }
}

extension NSStackView {
    var checkbox: NSButton? {
        arrangedSubviews.compactMap { $0 as? NSButton }.first { $0.bezelStyle == .regularSquare || $0.allowsMixedState || $0.title.isEmpty }
    }
}
