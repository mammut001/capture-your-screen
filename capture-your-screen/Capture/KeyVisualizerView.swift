import SwiftUI
import Carbon.HIToolbox

// MARK: - Key Visualizer

/// Shows the keys in a HotkeyConfiguration as animated badge tiles.
/// Used in both the capture overlay (brief hotkey confirmed animation)
/// and in the hotkey recorder (live display of what the user is pressing).
struct KeyVisualizerView: View {
    let config: HotkeyConfiguration
    /// When true, badges are tinted green (active/recording state).
    let isActive: Bool

    @State private var animatingKey: String?

    var body: some View {
        VStack(spacing: 16) {
            HStack(spacing: 8) {
                ForEach(modifierKeys, id: \.self) { key in
                    KeyBadge(symbol: key, isHighlighted: isActive, isAnimating: animatingKey == key)
                }
                if !keyPart.isEmpty {
                    KeyBadge(symbol: keyPart, isHighlighted: isActive, isAnimating: animatingKey == keyPart)
                }
            }

            if isActive {
                Text("Press your shortcut…")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color.black.opacity(0.6))
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .strokeBorder(Color.white.opacity(0.15), lineWidth: 1)
                )
        )
        .onChange(of: config.displayString) { _, _ in
            triggerAnimation()
        }
    }

    // MARK: - Computed

    private var modifierKeys: [String] {
        var result: [String] = []
        let mods = config.modifiers
        if mods & UInt32(cmdKey)     != 0 { result.append("⌘") }
        if mods & UInt32(shiftKey)   != 0 { result.append("⇧") }
        if mods & UInt32(optionKey)  != 0 { result.append("⌥") }
        if mods & UInt32(controlKey) != 0 { result.append("⌃") }
        return result
    }

    /// The non-modifier portion of the display string (e.g. "A" from "⌘⇧A").
    private var keyPart: String {
        config.displayString
            .replacingOccurrences(of: "⌘", with: "")
            .replacingOccurrences(of: "⇧", with: "")
            .replacingOccurrences(of: "⌥", with: "")
            .replacingOccurrences(of: "⌃", with: "")
            .trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Animation

    private func triggerAnimation() {
        let allKeys = modifierKeys + (keyPart.isEmpty ? [] : [keyPart])
        guard let last = allKeys.last else { return }
        withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) {
            animatingKey = last
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            animatingKey = nil
        }
    }
}

// MARK: - Key Badge

/// A single rounded-rectangle key tile.
struct KeyBadge: View {
    let symbol: String
    let isHighlighted: Bool
    let isAnimating: Bool

    var body: some View {
        Text(symbol)
            .font(.system(size: symbol == "Space" ? 12 : 18, weight: .semibold, design: .rounded))
            .foregroundColor(isHighlighted ? .green : .white)
            .frame(width: symbol == "Space" ? 80 : 44, height: 44)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isHighlighted ? Color.green.opacity(0.2) : Color.white.opacity(0.1))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(
                        isHighlighted ? Color.green.opacity(0.5) : Color.white.opacity(0.2),
                        lineWidth: isAnimating ? 2 : 1
                    )
            )
            .shadow(color: isHighlighted ? Color.green.opacity(0.3) : .clear, radius: 8)
            .scaleEffect(isAnimating ? 1.3 : 1.0)
            .animation(.spring(response: 0.3, dampingFraction: 0.6), value: isAnimating)
    }
}

// MARK: - Recording Indicator

/// A pulsing red REC badge shown while recording a new hotkey.
struct RecordingIndicatorView: View {
    @State private var opacity: Double = 1.0

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(Color.red)
                .frame(width: 8, height: 8)
                .opacity(opacity)

            Text("REC")
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundColor(.red)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Capsule().fill(Color.red.opacity(0.15)))
        .onAppear {
            withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                opacity = 0.3
            }
        }
    }
}
