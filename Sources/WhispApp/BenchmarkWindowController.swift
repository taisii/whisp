import AppKit
import SwiftUI
import WhispCore

@MainActor
final class BenchmarkWindowController {
    private let viewModel: BenchmarkViewModel
    private var window: NSWindow?

    init(store: BenchmarkStore) {
        viewModel = BenchmarkViewModel(store: store)
    }

    func show() {
        viewModel.refresh()

        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let hosting = NSHostingController(rootView: BenchmarkView(viewModel: viewModel))
        let window = NSWindow(contentViewController: hosting)
        window.title = "Whisp Benchmark"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 1340, height: 780))
        window.center()

        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
