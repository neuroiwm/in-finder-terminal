import Carbon.HIToolbox

/// ⌥⌘Tのグローバルホットキー(Carbon RegisterEventHotKey。追加権限不要)
final class HotkeyManager {
    var onHotkey: (() -> Void)?
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?

    func register() {
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: OSType(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, userData in
            guard let userData else { return noErr }
            Unmanaged<HotkeyManager>.fromOpaque(userData)
                .takeUnretainedValue().onHotkey?()
            return noErr
        }, 1, &eventType, Unmanaged.passUnretained(self).toOpaque(), &handlerRef)

        let hotKeyID = EventHotKeyID(signature: OSType(0x4654_524D), id: 1)  // 'FTRM'
        RegisterEventHotKey(UInt32(kVK_ANSI_T),
                            UInt32(optionKey | cmdKey),
                            hotKeyID,
                            GetApplicationEventTarget(),
                            0,
                            &hotKeyRef)
    }
}
