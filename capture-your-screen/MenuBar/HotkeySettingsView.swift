import SwiftUI
import Carbon.HIToolbox

// MARK: - Hotkey Settings

/// Full-page hotkey customisation panel, presented as a sheet from SettingsView.
struct HotkeySettingsView: View {
    @EnvironmentObject var hotkeyManager: HotkeyManager
    @Environment(\.dismiss) private var dismiss

    @State private var isRecording: Bool = false
    @State private var recordedKeyCode: UInt32?
    @State private var recordedModifiers: UInt32 = 0
    /// Local mirror of recordingPreviewConfig — updated by HotkeyRecorderView's
    /// onChange so that rapid keypresses don't re-render the entire settings sheet.
    @State private var livePreviewConfig: HotkeyConfiguration?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // ── Title
            Text("Screenshot Shortcut")
                .font(.headline)

            // ── Current shortcut display
            VStack(alignment: .leading, spacing: 8) {
                Text("Current shortcut:")
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                ZStack {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.secondary.opacity(0.06))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .strokeBorder(Color.secondary.opacity(0.1), lineWidth: 1)
                        )

                    HStack {
                        Text(hotkeyManager.currentConfig.displayString)
                            .font(.system(size: 18, weight: .bold, design: .monospaced))
                            .foregroundColor(.primary)

                        Spacer()

                        Button(isRecording ? "Cancel" : "Change…") {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                if isRecording {
                                    cancelRecording()
                                } else {
                                    startRecording()
                                }
                            }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                    .padding(.horizontal, 14)
                }
                .frame(height: 48)

                // ── Recording zone — Stable height, visibility controlled via opacity
                ZStack {
                    VStack(spacing: 12) {
                        Divider()
                            .padding(.vertical, 4)

                        RecordingIndicatorView()
                            .id("rec-indicator")

                        HotkeyRecorderView(
                            previewConfig: $livePreviewConfig,
                            onKeyRecorded: { keyCode, modifiers in
                                recordedKeyCode = keyCode
                                recordedModifiers = modifiers
                            }
                        )
                        .frame(height: 100)

                        Text("Press a key combo, then click Apply")
                            .font(.caption)
                            .foregroundColor(.secondary)

                        HStack(spacing: 10) {
                            Button("Apply") { applyRecording() }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.large)
                                .frame(maxWidth: .infinity)
                                .disabled(recordedKeyCode == nil)

                            Button("Cancel") {
                                withAnimation { cancelRecording() }
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.large)
                            .frame(maxWidth: .infinity)
                        }
                    }
                    .opacity(isRecording ? 1 : 0)
                    .allowsHitTesting(isRecording)
                }
                .frame(height: isRecording ? nil : 0, alignment: .top)
                .clipped()
            }
        }
        .padding(24)
        .frame(width: 400)
        .fixedSize(horizontal: false, vertical: true)
        // Sync livePreviewConfig from the manager.
        .onChange(of: hotkeyManager.recordingPreviewConfig) { _, newValue in
            livePreviewConfig = newValue
        }
    }

    // MARK: - Recording control

    private func startRecording() {
        recordedKeyCode = nil
        recordedModifiers = 0
        isRecording = true
        hotkeyManager.startRecording()
    }

    private func cancelRecording() {
        isRecording = false
        recordedKeyCode = nil
        recordedModifiers = 0
        hotkeyManager.cancelRecording()
    }

    private func applyRecording() {
        guard let keyCode = recordedKeyCode else { return }
        let displayString = KeyCodeMapper.makeDisplayString(keyCode: keyCode, modifiers: recordedModifiers)
        let newConfig = HotkeyConfiguration(
            keyCode: keyCode,
            modifiers: recordedModifiers,
            displayString: displayString
        )
        hotkeyManager.updateConfig(newConfig)
        cancelRecording()
        dismiss()
    }
}

// MARK: - Hotkey Recorder View

/// The interactive tile area that live-previews the combo being pressed.
/// Takes previewConfig as an explicit Binding so SwiftUI only re-renders this
/// view (not the entire settings sheet) when a key is pressed.
struct HotkeyRecorderView: View {
    let previewConfig: Binding<HotkeyConfiguration?>
    let onKeyRecorded: (UInt32, UInt32) -> Void

    @State private var animatingKey: String?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.black.opacity(0.5))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(Color.green.opacity(0.4), lineWidth: 1)
                )

            // Placeholder — always centered, fades out when keys are pressed
            Text("Type the shortcut…")
                .font(.caption)
                .foregroundColor(.secondary)
                .opacity(previewConfig.wrappedValue == nil ? 1 : 0)
                .animation(.easeInOut(duration: 0.15), value: previewConfig.wrappedValue == nil)

            // Key badges — centered independently, never shifts the placeholder
            HStack(spacing: 8) {
                ForEach(currentModifierKeys, id: \.self) { key in
                    KeyBadge(symbol: key, isHighlighted: true, isAnimating: animatingKey == key)
                }
                if let mainKey = currentMainKey {
                    KeyBadge(symbol: mainKey, isHighlighted: true, isAnimating: animatingKey == mainKey)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onChange(of: previewConfig.wrappedValue?.displayString) { _, _ in
            guard let config = previewConfig.wrappedValue else { return }
            updateDisplay(from: config)
        }
    }

    // MARK: - Computed

    private var currentModifierKeys: [String] {
        let mods = previewConfig.wrappedValue?.modifiers ?? 0
        var result: [String] = []
        if mods & UInt32(cmdKey)     != 0 { result.append("⌘") }
        if mods & UInt32(shiftKey)   != 0 { result.append("⇧") }
        if mods & UInt32(optionKey)  != 0 { result.append("⌥") }
        if mods & UInt32(controlKey) != 0 { result.append("⌃") }
        return result
    }

    private var currentMainKey: String? {
        guard let config = previewConfig.wrappedValue else { return nil }
        let stripped = config.displayString
            .replacingOccurrences(of: "⌘", with: "")
            .replacingOccurrences(of: "⇧", with: "")
            .replacingOccurrences(of: "⌥", with: "")
            .replacingOccurrences(of: "⌃", with: "")
            .trimmingCharacters(in: .whitespaces)
        return stripped.isEmpty ? nil : stripped
    }

    private func updateDisplay(from config: HotkeyConfiguration) {
        // Animate the most recently added key
        let allKeys = currentModifierKeys + [currentMainKey].compactMap { $0 }
        if let last = allKeys.last {
            withAnimation(.spring(response: 0.25, dampingFraction: 0.6)) {
                animatingKey = last
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                animatingKey = nil
            }
        }
        onKeyRecorded(config.keyCode, config.modifiers)
    }
}
