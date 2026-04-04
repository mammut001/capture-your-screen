import Carbon.HIToolbox
import Combine
import Foundation
import AppKit

struct HotkeyConfiguration: Codable, Equatable {
    var keyCode: UInt32
    var modifiers: UInt32   // Carbon modifier flags (cmdKey | shiftKey etc.)
    var displayString: String

    static let `default` = HotkeyConfiguration(
        keyCode: UInt32(kVK_ANSI_A),
        modifiers: UInt32(cmdKey | shiftKey),
        displayString: "⌘⇧A"
    )
}

// Top-level C-compatible callback — must not capture Swift context
private func carbonHotkeyCallback(
    _ callRef: EventHandlerCallRef?,
    _ event: EventRef?,
    _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let userData else { return OSStatus(eventNotHandledErr) }
    let manager = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
    DispatchQueue.main.async { manager.handleHotkeyPressed() }
    return noErr
}

final class HotkeyManager: ObservableObject {
    @Published private(set) var currentConfig: HotkeyConfiguration

    var onHotkeyPressed: (() -> Void)?

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private static let defaultsKey = "hotkeyConfiguration"

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
           let config = try? JSONDecoder().decode(HotkeyConfiguration.self, from: data) {
            currentConfig = config
        } else {
            currentConfig = .default
        }
    }

    func register() {
        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(
            GetApplicationEventTarget(),
            carbonHotkeyCallback,
            1,
            &spec,
            selfPtr,
            &handlerRef
        )
        registerHotKey()
    }

    private func registerHotKey() {
        var hotKeyID = EventHotKeyID(signature: 0x43415050 /* "CAPP" */, id: 1)
        RegisterEventHotKey(
            currentConfig.keyCode,
            currentConfig.modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            OptionBits(0),
            &hotKeyRef
        )
    }

    func unregister() {
        if let ref = hotKeyRef {
            UnregisterEventHotKey(ref)
            hotKeyRef = nil
        }
    }

    func updateConfig(_ config: HotkeyConfiguration) {
        unregister()
        currentConfig = config
        if let data = try? JSONEncoder().encode(config) {
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        }
        registerHotKey()
    }

    func handleHotkeyPressed() {
        onHotkeyPressed?()
    }

    deinit {
        unregister()
        if let ref = handlerRef {
            RemoveEventHandler(ref)
        }
    }
}
