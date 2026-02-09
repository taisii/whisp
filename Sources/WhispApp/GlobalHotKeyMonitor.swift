import Carbon
import Foundation
import WhispCore

final class GlobalHotKeyMonitor {
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?
    private var onPressed: (() -> Void)?
    private var onReleased: (() -> Void)?

    private let hotKeyID: UInt32 = 1
    private let signature: OSType = 0x77687370 // whsp

    init() throws {
        var eventTypes = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
        ]

        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData in
                guard let event, let userData else {
                    return noErr
                }
                let monitor = Unmanaged<GlobalHotKeyMonitor>.fromOpaque(userData).takeUnretainedValue()
                monitor.handle(event: event)
                return noErr
            },
            eventTypes.count,
            &eventTypes,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandlerRef
        )

        guard status == noErr else {
            throw AppError.invalidArgument("ホットキーイベントハンドラの登録に失敗: \(status)")
        }
    }

    deinit {
        unregister()
        if let eventHandlerRef {
            RemoveEventHandler(eventHandlerRef)
        }
    }

    func register(
        shortcutString: String,
        onPressed: @escaping () -> Void,
        onReleased: @escaping () -> Void
    ) throws {
        let parsed = try parseHotKey(shortcutString)

        unregister()

        var registeredRef: EventHotKeyRef?
        let keyID = EventHotKeyID(signature: signature, id: hotKeyID)

        let status = RegisterEventHotKey(
            UInt32(parsed.keyCode),
            parsed.modifiers,
            keyID,
            GetApplicationEventTarget(),
            0,
            &registeredRef
        )

        guard status == noErr, let registeredRef else {
            throw AppError.invalidArgument("ショートカット登録に失敗: \(shortcutString)")
        }

        hotKeyRef = registeredRef
        self.onPressed = onPressed
        self.onReleased = onReleased
    }

    func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        onPressed = nil
        onReleased = nil
    }

    private func handle(event: EventRef) {
        let kind = GetEventKind(event)
        switch kind {
        case UInt32(kEventHotKeyPressed):
            onPressed?()
        case UInt32(kEventHotKeyReleased):
            onReleased?()
        default:
            break
        }
    }
}

extension GlobalHotKeyMonitor: @unchecked Sendable {}
