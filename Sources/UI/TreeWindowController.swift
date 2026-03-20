import Cocoa
import SwiftUI

// MARK: - Mode

enum TreeWindowMode {
    case backup
    case restore(snapshotURL: URL)

    var isBackup: Bool {
        if case .backup = self { return true }
        return false
    }
}

// MARK: - Controller

/// Thin NSWindowController wrapping a SwiftUI TreeView via NSHostingController.
/// Callers pass completion closures instead of using a delegate.
class TreeWindowController: NSWindowController {

    init(mode: TreeWindowMode,
         enabledPaths: Set<String> = [],
         onConfirmBackup: @escaping ([String]) -> Void = { _ in },
         onConfirmRestore: @escaping (URL, [String], Bool) -> Void = { _, _, _ in }) {

        let model = TreeSelectionModel(mode: mode, enabledPaths: enabledPaths)
        model.onConfirmBackup = onConfirmBackup
        model.onConfirmRestore = onConfirmRestore

        let hosting = NSHostingController(rootView: TreeView(model: model))

        let window = NSWindow(contentViewController: hosting)
        window.styleMask = [.titled, .closable, .resizable, .miniaturizable]
        window.setContentSize(NSSize(width: 540, height: 580))
        window.center()
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 480, height: 460)

        switch mode {
        case .backup:
            window.title = "Backup — Select Sources"
        case .restore(let url):
            window.title = "Restore — \(url.lastPathComponent)"
        }

        super.init(window: window)

        // Wire cancel to close the window.
        model.onCancel = { [weak self] in self?.window?.close() }

        // After confirm, close the window then call through.
        model.onConfirmBackup = { [weak self, onConfirmBackup] paths in
            self?.window?.close()
            onConfirmBackup(paths)
        }
        model.onConfirmRestore = { [weak self, onConfirmRestore] url, items, brew in
            self?.window?.close()
            onConfirmRestore(url, items, brew)
        }
    }

    required init?(coder: NSCoder) { fatalError() }
}

