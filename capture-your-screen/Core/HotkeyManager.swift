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
    /// Whether the manager is currently in hotkey-recording mode.
    @Published var isRecording: Bool = false
    /// Live preview of the combo being held during recording; nil when not recording.
    @Published var recordingPreviewConfig: HotkeyConfiguration?

    var onHotkeyPressed: (() -> Void)?

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private var localMonitor: Any?
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
        guard handlerRef == nil else { return } // Already registered
        
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
        if let ref = hotKeyRef {
            UnregisterEventHotKey(ref)
            hotKeyRef = nil
        }
        
        var hotKeyID = EventHotKeyID(signature: 0x43415050 /* "CAPP" */, id: 1)
        let status = RegisterEventHotKey(
            currentConfig.keyCode,
            currentConfig.modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            OptionBits(0),
            &hotKeyRef
        )
        if status != noErr {
            print("HotkeyManager: RegisterEventHotKey failed with status \(status)")
        }
    }

    func unregister() {
        if let ref = hotKeyRef {
            UnregisterEventHotKey(ref)
            hotKeyRef = nil
        }
        // We keep the handlerRef alive so we can continue listening for new keys
    }

    func updateConfig(_ config: HotkeyConfiguration) {
        currentConfig = config
        if let data = try? JSONEncoder().encode(config) {
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        }
        registerHotKey()
    }

    func handleHotkeyPressed() {
        guard !isRecording else { return }
        onHotkeyPressed?()
    }

    // MARK: - Recording

    /// Begin recording: intercept all local keyDown events.
    func startRecording() {
        isRecording = true
        recordingPreviewConfig = nil
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleRecordingKeyDown(event)
            return nil // consume the event
        }
    }

    /// Cancel recording without applying any change.
    func cancelRecording() {
        isRecording = false
        recordingPreviewConfig = nil
        stopLocalMonitor()
    }

    /// Apply the given combo as the new hotkey and stop recording.
    func finishRecording(with keyCode: UInt32, modifiers: UInt32) {
        let displayString = KeyCodeMapper.makeDisplayString(keyCode: keyCode, modifiers: modifiers)
        let config = HotkeyConfiguration(
            keyCode: keyCode,
            modifiers: modifiers,
            displayString: displayString
        )
        updateConfig(config)
        isRecording = false
        recordingPreviewConfig = nil
        stopLocalMonitor()
    }

    private func stopLocalMonitor() {
        if let monitor = localMonitor {
            NSEvent.removeMonitor(monitor)
            localMonitor = nil
        }
    }

    /// Handle a keyDown during recording mode.
    private func handleRecordingKeyDown(_ event: NSEvent) {
        let keyCode = UInt32(event.keyCode)
        let modifiers = KeyCodeMapper.carbonModifiers(from: event)

        switch keyCode {
        case UInt32(kVK_Escape):
            cancelRecording()

        case UInt32(kVK_Return), UInt32(kVK_ANSI_KeypadEnter):
            // Enter with no modifier = confirm the current preview
            if modifiers == 0 {
                if let preview = recordingPreviewConfig {
                    finishRecording(with: preview.keyCode, modifiers: preview.modifiers)
                } else {
                    cancelRecording()
                }
            }

        default:
            // Update live preview for any non-Escape key
            let preview = HotkeyConfiguration(
                keyCode: keyCode,
                modifiers: modifiers,
                displayString: KeyCodeMapper.makeDisplayString(keyCode: keyCode, modifiers: modifiers)
            )
            recordingPreviewConfig = preview
        }
    }

    deinit {
        unregister()
        if let ref = handlerRef {
            RemoveEventHandler(ref)
        }
    }
}
