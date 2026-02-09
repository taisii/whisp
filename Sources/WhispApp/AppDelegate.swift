import AppKit
import Foundation
import WhispCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var coordinator: AppCoordinator?

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()

    private lazy var stateItem = NSMenuItem(title: "状態: 待機中", action: nil, keyEquivalent: "")
    private lazy var accessibilityStateItem = NSMenuItem(title: "アクセシビリティ権限: 確認中", action: nil, keyEquivalent: "")
    private lazy var startStopItem = NSMenuItem(title: "録音開始", action: #selector(toggleRecording), keyEquivalent: "")
    private lazy var requestAccessibilityItem = NSMenuItem(title: "アクセシビリティ権限を要求", action: #selector(requestAccessibilityPermission), keyEquivalent: "")

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        if DevLog.isEnabled {
            DevLog.info("app_launch", fields: ["log_file": DevLog.filePath ?? "n/a"])
        }

        if let button = statusItem.button {
            button.title = "○"
        }

        buildMenu()
        menu.delegate = self
        statusItem.menu = menu

        do {
            let coordinator = try AppCoordinator()
            self.coordinator = coordinator

            coordinator.onStateChanged = { [weak self] state in
                self?.apply(state: state)
            }
            coordinator.onError = { [weak self] message in
                self?.showError(message)
            }

            apply(state: .idle)
            refreshAccessibilityPermissionState()
            coordinator.requestAccessibilityPermissionOnLaunch()
            refreshAccessibilityPermissionState()
        } catch {
            showError("アプリ初期化に失敗: \(error.localizedDescription)")
        }
    }

    @objc private func toggleRecording() {
        coordinator?.toggleRecording()
    }

    @objc private func openSettings() {
        coordinator?.openSettings()
    }

    @objc private func openDebugWindow() {
        coordinator?.openDebugWindow()
    }

    @objc private func openMicrophoneSettings() {
        coordinator?.openMicrophoneSettings()
    }

    @objc private func openAccessibilitySettings() {
        coordinator?.openAccessibilitySettings()
    }

    @objc private func requestAccessibilityPermission() {
        guard let coordinator else {
            return
        }

        let trusted = coordinator.requestAccessibilityPermission(prompt: true)
        refreshAccessibilityPermissionState()

        if trusted {
            showInfo("アクセシビリティ権限は許可済みです。")
            return
        }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "アクセシビリティ権限が未許可です"
        alert.informativeText = "システム設定で Whisp を有効化してください。"
        alert.addButton(withTitle: "設定を開く")
        alert.addButton(withTitle: "閉じる")

        if alert.runModal() == .alertFirstButtonReturn {
            coordinator.openAccessibilitySettings()
        }
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }

    private func buildMenu() {
        stateItem.isEnabled = false
        accessibilityStateItem.isEnabled = false

        menu.addItem(stateItem)
        menu.addItem(accessibilityStateItem)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(startStopItem)
        menu.addItem(NSMenuItem(title: "設定を開く", action: #selector(openSettings), keyEquivalent: ","))
        menu.addItem(NSMenuItem(title: "デバッグを開く", action: #selector(openDebugWindow), keyEquivalent: "d"))
        menu.addItem(requestAccessibilityItem)
        menu.addItem(NSMenuItem(title: "マイク設定を開く", action: #selector(openMicrophoneSettings), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "アクセシビリティ設定を開く", action: #selector(openAccessibilitySettings), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "終了", action: #selector(quitApp), keyEquivalent: "q"))
    }

    private func apply(state: PipelineState) {
        stateItem.title = "状態: \(state.label)"

        switch state {
        case .recording:
            startStopItem.title = "録音停止"
        case .sttStreaming, .postProcessing, .directInput:
            startStopItem.title = "処理中..."
        default:
            startStopItem.title = "録音開始"
        }

        startStopItem.isEnabled = !(state == .sttStreaming || state == .postProcessing || state == .directInput)

        statusItem.button?.title = state.symbol
    }

    private func refreshAccessibilityPermissionState() {
        let trusted = coordinator?.isAccessibilityTrusted() ?? false
        accessibilityStateItem.title = trusted ? "アクセシビリティ権限: 許可済み" : "アクセシビリティ権限: 未許可"
        requestAccessibilityItem.title = trusted ? "アクセシビリティ権限を再確認" : "アクセシビリティ権限を要求"
    }

    func menuWillOpen(_ menu: NSMenu) {
        refreshAccessibilityPermissionState()
    }

    private func showInfo(_ message: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Whisp"
        alert.informativeText = message
        alert.runModal()
    }

    private func showError(_ message: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Whisp"
        alert.informativeText = message
        alert.runModal()
    }
}
