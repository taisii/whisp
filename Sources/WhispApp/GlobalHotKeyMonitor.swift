import AppKit
import Carbon
import CoreGraphics
import Foundation
import WhispCore

final class GlobalHotKeyMonitor {
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?
    private var modifierEventTap: CFMachPort?
    private var modifierRunLoopSource: CFRunLoopSource?
    private var modifierShortcut: SingleModifierShortcut?
    private var isModifierPressed = false
    private var pendingReleaseWorkItem: DispatchWorkItem?
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
        let parsed = try parseShortcut(shortcutString)

        unregister()

        switch parsed {
        case .hotKey(let hotKey):
            try registerHotKey(hotKey, shortcutString: shortcutString)
        case .singleModifier(let modifier):
            try registerSingleModifier(modifier, shortcutString: shortcutString)
        }

        self.onPressed = onPressed
        self.onReleased = onReleased
    }

    func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        if let modifierRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), modifierRunLoopSource, .commonModes)
            self.modifierRunLoopSource = nil
        }
        if let modifierEventTap {
            CFMachPortInvalidate(modifierEventTap)
            self.modifierEventTap = nil
        }
        modifierShortcut = nil
        isModifierPressed = false
        pendingReleaseWorkItem?.cancel()
        pendingReleaseWorkItem = nil
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

    private func registerHotKey(_ parsed: ParsedHotKey, shortcutString: String) throws {
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
    }

    private func registerSingleModifier(_ modifier: SingleModifierShortcut, shortcutString: String) throws {
        let eventMask = CGEventMask(1) << CGEventType.flagsChanged.rawValue
        let userData = Unmanaged.passUnretained(self).toOpaque()

        guard let eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: { _, type, event, userData in
                guard let userData else {
                    return nil
                }
                let monitor = Unmanaged<GlobalHotKeyMonitor>.fromOpaque(userData).takeUnretainedValue()
                return monitor.handleModifierEvent(type: type, event: event)
            },
            userInfo: userData
        ) else {
            throw AppError.invalidArgument("ショートカット登録に失敗: \(shortcutString)")
        }

        guard let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0) else {
            CFMachPortInvalidate(eventTap)
            throw AppError.invalidArgument("ショートカット登録に失敗: \(shortcutString)")
        }

        modifierEventTap = eventTap
        modifierRunLoopSource = runLoopSource
        modifierShortcut = modifier
        isModifierPressed = false

        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: eventTap, enable: true)
    }

    private func handleModifierEvent(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let modifierEventTap {
                CGEvent.tapEnable(tap: modifierEventTap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        guard type == .flagsChanged, let modifierShortcut else {
            return Unmanaged.passUnretained(event)
        }

        handleSingleModifierFlagsChanged(event, modifier: modifierShortcut)
        return Unmanaged.passUnretained(event)
    }

    private func handleSingleModifierFlagsChanged(_ event: CGEvent, modifier: SingleModifierShortcut) {
        guard event.getIntegerValueField(.keyboardEventKeycode) == keyCode(for: modifier) else {
            return
        }

        let isPressed = event.flags.contains(.maskAlternate)

        if isPressed {
            pendingReleaseWorkItem?.cancel()
            pendingReleaseWorkItem = nil
            guard !isModifierPressed else {
                return
            }
            isModifierPressed = true
            onPressed?()
            return
        }

        guard isModifierPressed else {
            return
        }
        pendingReleaseWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, self.isModifierPressed else {
                return
            }
            self.isModifierPressed = false
            self.pendingReleaseWorkItem = nil
            self.onReleased?()
        }
        pendingReleaseWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(30), execute: workItem)
    }

    private func keyCode(for modifier: SingleModifierShortcut) -> Int64 {
        switch modifier {
        case .rightOption:
            return 61
        }
    }
}

extension GlobalHotKeyMonitor: @unchecked Sendable {}
