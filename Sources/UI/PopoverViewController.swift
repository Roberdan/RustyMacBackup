import Cocoa
import SwiftUI

/// Thin wrapper that hosts PopoverView (SwiftUI) inside an NSViewController.
/// AppDelegate owns `uiState` and passes it in; this class just hosts the view.
class PopoverViewController: NSViewController {

    private let uiState: AppUIState
    private var hostingController: NSHostingController<AnyView>?

    init(uiState: AppUIState) {
        self.uiState = uiState
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let hosting = NSHostingController(
            rootView: AnyView(PopoverView().environmentObject(uiState))
        )
        hostingController = hosting
        addChild(hosting)
        view = hosting.view
    }

    /// Called by AppDelegate after updating uiState — SwiftUI observes changes automatically.
    func refresh() {
        // No manual refresh needed; SwiftUI reacts to @Published properties on uiState.
    }
}

