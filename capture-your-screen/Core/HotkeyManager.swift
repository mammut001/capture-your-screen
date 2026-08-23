import Carbon.HIToolbox
import Combine
import Foundation
import AppKit
import os

private let logger = Logger(subsystem: "com.captureyourscreen.core", category: "HotkeyManager")

enum CaptureKeyCommand {
    case cancel
    case confirm
    case quickSave
}

private let primaryHotKeySignature: OSType = 0x43415050 // "CAPP"
private let captureHotKeySignature: OSType = 0x4341504B // "CAPK"

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

// Top-level C-compatible callback — must not capture Swift context.
// Uses a static weak reference so it never dereferences a deallocated object.
private func carbonHotkeyCallback(
    _ callRef: EventHandlerCallRef?,
    _ event: EventRef?,
    _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let manager = HotkeyManager.callbackTarget, let event else {
        return OSStatus(eventNotHandledErr)
    }

    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(
        event,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &hotKeyID
    )
    guard status == noErr,
          hotKeyID.signature == primaryHotKeySignature || hotKeyID.signature == captureHotKeySignature else {
        return OSStatus(eventNotHandledErr)
    }

    DispatchQueue.main.async { manager.handleRegisteredHotKey(hotKeyID) }
    return noErr
}

final class HotkeyManager: ObservableObject {
    /// Weak reference used by the C callback — never dangling.
    fileprivate static weak var callbackTarget: HotkeyManager?

    @Published private(set) var currentConfig: HotkeyConfiguration
    /// Whether the manager is currently in hotkey-recording mode.
    @Published var isRecording: Bool = false
    /// Live preview of the combo being held during recording; nil when not recording.
    @Published var recordingPreviewConfig: HotkeyConfiguration?

    var onHotkeyPressed: (() -> Void)?

    private var hotKeyRef: EventHotKeyRef?
    private var captureHotKeyRefs: [EventHotKeyRef] = []
    private var captureKeyHandler: ((CaptureKeyCommand) -> Void)?
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

    /// Install the Carbon event handler and register the current hotkey combo.
    func register() {
        ensureRegistered()
    }

    /// Idempotent registration — safe to call whenever the app wakes up.
    func ensureRegistered() {
        Self.callbackTarget = self

        if handlerRef == nil {
            var spec = EventTypeSpec(
                eventClass: OSType(kEventClassKeyboard),
                eventKind: UInt32(kEventHotKeyPressed)
            )
            let status = InstallEventHandler(
                GetApplicationEventTarget(),
                carbonHotkeyCallback,
                1,
                &spec,
                nil,   // no raw pointer — callback uses the static weak reference
                &handlerRef
            )
            if status != noErr {
                logger.error("InstallEventHandler failed with status \(status)")
            }
        }

        if hotKeyRef == nil {
            registerHotKey()
        }
    }

    private func registerHotKey() {
        if let ref = hotKeyRef {
            UnregisterEventHotKey(ref)
            hotKeyRef = nil
        }
        
        let hotKeyID = EventHotKeyID(signature: primaryHotKeySignature, id: 1)
        let status = RegisterEventHotKey(
            currentConfig.keyCode,
            currentConfig.modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            OptionBits(0),
            &hotKeyRef
        )
        if status != noErr {
            logger.error("RegisterEventHotKey failed with status \(status)")
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

    /// Consume capture controls globally while the non-activating overlay is
    /// visible. Local NSEvent monitors cannot see keys owned by another app.
    func beginCaptureKeyInterception(handler: @escaping (CaptureKeyCommand) -> Void) {
        endCaptureKeyInterception()
        captureKeyHandler = handler
        registerCaptureHotKey(keyCode: UInt32(kVK_Escape), modifiers: 0, id: 2)
        registerCaptureHotKey(keyCode: UInt32(kVK_Return), modifiers: 0, id: 3)
        registerCaptureHotKey(keyCode: UInt32(kVK_ANSI_KeypadEnter), modifiers: 0, id: 4)
        registerCaptureHotKey(keyCode: UInt32(kVK_Return), modifiers: UInt32(cmdKey), id: 5)
        registerCaptureHotKey(keyCode: UInt32(kVK_ANSI_KeypadEnter), modifiers: UInt32(cmdKey), id: 6)
    }

    func endCaptureKeyInterception() {
        for ref in captureHotKeyRefs {
            UnregisterEventHotKey(ref)
        }
        captureHotKeyRefs.removeAll()
        captureKeyHandler = nil
    }

#if DEBUG
    var captureKeyRegistrationCountForTesting: Int { captureHotKeyRefs.count }
#endif

    private func registerCaptureHotKey(keyCode: UInt32, modifiers: UInt32, id: UInt32) {
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: captureHotKeySignature, id: id)
        let status = RegisterEventHotKey(
            keyCode,
            modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            OptionBits(0),
            &ref
        )
        if status == noErr, let ref {
            captureHotKeyRefs.append(ref)
        } else {
            logger.error("Register capture hotkey \(id) failed with status \(status)")
        }
    }

    fileprivate func handleRegisteredHotKey(_ hotKeyID: EventHotKeyID) {
        if hotKeyID.signature == primaryHotKeySignature, hotKeyID.id == 1 {
            handleHotkeyPressed()
            return
        }

        guard hotKeyID.signature == captureHotKeySignature else { return }
        switch hotKeyID.id {
        case 2: captureKeyHandler?(.cancel)
        case 3, 4: captureKeyHandler?(.confirm)
        case 5, 6: captureKeyHandler?(.quickSave)
        default: break
        }
    }

    // MARK: - Recording

    /// Begin recording: intercept all local keyDown events.
    func startRecording() {
        if let existing = localMonitor {
            NSEvent.removeMonitor(existing)
            localMonitor = nil
        }
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
        if Self.callbackTarget === self {
            Self.callbackTarget = nil
        }
        unregister()
        endCaptureKeyInterception()
        if let ref = handlerRef {
            RemoveEventHandler(ref)
        }
    }
}
