import AppKit
import SwiftUI
import WhispCore

@MainActor
final class StatisticsWindowController {
    private let viewModel: StatisticsViewModel
    private var window: NSWindow?

    init(store: RuntimeStatsStore) {
        viewModel = StatisticsViewModel(store: store)
    }

    func show() {
        viewModel.refresh()

        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let hosting = NSHostingController(rootView: StatisticsView(viewModel: viewModel))
        let window = NSWindow(contentViewController: hosting)
        window.title = "Whisp Statistics"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 900, height: 560))
        window.center()

        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
