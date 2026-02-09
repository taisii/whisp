import AppKit
import SwiftUI
import WhispCore

@MainActor
final class SettingsWindowController {
    private var window: NSWindow?

    func show(config: Config, onSave: @escaping @MainActor (Config) -> Void) {
        let rootView = SettingsView(
            config: config,
            onSave: { [weak self] updated in
                onSave(updated)
                self?.window?.orderOut(nil)
            },
            onCancel: { [weak self] in
                self?.window?.orderOut(nil)
            }
        )

        if let window, let hosting = window.contentViewController as? NSHostingController<SettingsView> {
            hosting.rootView = rootView
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let hosting = NSHostingController(rootView: rootView)
        let window = NSWindow(contentViewController: hosting)
        window.title = "Whisp Settings"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.setContentSize(NSSize(width: 520, height: 520))
        window.center()

        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
