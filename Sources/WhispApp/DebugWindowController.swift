import AppKit
import SwiftUI
import WhispCore

@MainActor
final class DebugWindowController {
    private let viewModel: DebugViewModel
    private var window: NSWindow?

    init(store: DebugCaptureStore) {
        viewModel = DebugViewModel(store: store)
    }

    func show() {
        viewModel.refresh()

        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let hosting = NSHostingController(rootView: DebugView(viewModel: viewModel))
        let window = NSWindow(contentViewController: hosting)
        window.title = "Whisp Debug"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 1120, height: 760))
        window.center()

        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
