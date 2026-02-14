import AppKit
import SwiftUI
import WhispCore

@MainActor
final class SettingsWindowController {
    private var window: NSWindow?

    func show(
        config: Config,
        generationCandidates: [BenchmarkCandidate],
        preserveGenerationPrimaryOnSave: Bool = false,
        onSave: @escaping @MainActor (Config) -> Bool
    ) {
        let rootView = SettingsView(
            config: config,
            generationCandidates: generationCandidates,
            preserveGenerationPrimaryOnSave: preserveGenerationPrimaryOnSave,
            onSave: { [weak self] updated in
                let saved = onSave(updated)
                if saved {
                    self?.window?.orderOut(nil)
                }
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
