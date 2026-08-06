import Carbon
import AppKit

@MainActor
final class GlobalShortcutService {
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    var onPress: (() -> Void)?

    func register(_ configuration: ShortcutConfiguration) -> Bool {
        unregister()
        guard configuration.isConfigured else { return true }
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let callback: EventHandlerUPP = { _, event, userData in
            guard let userData else { return noErr }
            let service = Unmanaged<GlobalShortcutService>.fromOpaque(userData).takeUnretainedValue()
            Task { @MainActor in service.onPress?() }
            return noErr
        }
        let status = InstallEventHandler(
            GetApplicationEventTarget(), callback, 1, &eventType,
            Unmanaged.passUnretained(self).toOpaque(), &handler
        )
        guard status == noErr else { return false }
        var modifiers: UInt32 = 0
        if configuration.command { modifiers |= UInt32(cmdKey) }
        if configuration.shift { modifiers |= UInt32(shiftKey) }
        if configuration.option { modifiers |= UInt32(optionKey) }
        if configuration.control { modifiers |= UInt32(controlKey) }
        let identifier = EventHotKeyID(signature: OSType(0x4341504D), id: 1)
        return RegisterEventHotKey(
            configuration.keyCode, modifiers, identifier,
            GetApplicationEventTarget(), 0, &hotKey
        ) == noErr
    }

    func unregister() {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let handler { RemoveEventHandler(handler) }
        hotKey = nil
        handler = nil
    }
}
