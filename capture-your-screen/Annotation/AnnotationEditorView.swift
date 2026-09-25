//
//  AnnotationEditorView.swift
//  capture-your-screen
//

import SwiftUI
import AppKit

struct AnnotationEditorView: View {
    let baseImage: NSImage
    @StateObject private var canvas: AnnotationCanvas
    @State private var isSaving: Bool = false

    let onSave: (NSImage) -> Void       // Save composited image
    let onSaveOriginal: () -> Void      // Save the untouched base image (skip annotations)
    let onCancel: () -> Void

    /// Convenience init that creates a fresh AnnotationCanvas on the main actor.
    @MainActor
    init(
        baseImage: NSImage,
        onSave: @escaping (NSImage) -> Void,
        onSaveOriginal: @escaping () -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.init(
            baseImage: baseImage,
            canvas: AnnotationCanvas(),
            onSave: onSave,
            onSaveOriginal: onSaveOriginal,
            onCancel: onCancel
        )
    }

    init(
        baseImage: NSImage,
        canvas: AnnotationCanvas,
        onSave: @escaping (NSImage) -> Void,
        onSaveOriginal: @escaping () -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.baseImage = baseImage
        self._canvas = StateObject(wrappedValue: canvas)
        self.onSave = onSave
        self.onSaveOriginal = onSaveOriginal
        self.onCancel = onCancel
    }

    var body: some View {
        VStack(spacing: 0) {
            AnnotationToolbar(canvas: canvas, baseImage: baseImage)

            Divider()

            AnnotationCanvasView(baseImage: baseImage, canvas: canvas)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            actionBar
        }
        .background(KeyboardShortcutHandler(canvas: canvas,
                                            onCancel: cancel,
                                            onSave: save,
                                            onSaveOriginal: saveOriginal))
        .overlay {
            if isSaving {
                SavingToastView()
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.15), value: isSaving)
    }

    private var actionBar: some View {
        HStack {
            Button(role: .cancel) {
                cancel()
            } label: {
                Label("Cancel", systemImage: "xmark")
            }
            .keyboardShortcut(.cancelAction)

            Spacer()

            HStack(spacing: 12) {
                Button {
                    saveOriginal()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.right")
                            .font(.system(size: 14, weight: .semibold))
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Skip Annotation")
                                .font(.system(size: 14, weight: .semibold))
                            Text("Save original to disk")
                                .font(.system(size: 11, weight: .semibold, design: .rounded))
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 16)
                    .frame(height: 42)
                    .background(
                        Capsule()
                            .fill(Color(NSColor.controlBackgroundColor))
                    )
                    .overlay(
                        RainbowBorderView(cornerRadius: 21)
                    )
                }
                .keyboardShortcut(.return, modifiers: [.command])
                .buttonStyle(.plain)
                .frame(width: 240, height: 42)
                .help("Save the original screenshot to disk without annotations (⌘↵ / Space)")

                Button {
                    save()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark")
                            .font(.system(size: 14, weight: .bold))
                        Text("Save")
                            .font(.system(size: 15, weight: .semibold))
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                        .frame(height: 42)
                        .background(
                            Capsule()
                                .fill(Color.accentColor)
                        )
                }
                .keyboardShortcut("s", modifiers: [.command])
                .buttonStyle(.plain)
                .frame(width: 240, height: 42)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .overlay(alignment: .bottom) {
            ShortcutHintBar()
                .padding(.bottom, -28)
        }
    }

    // MARK: - Actions

    private func save() {
        isSaving = true
        let items = canvas.items
        let image = baseImage
        let composed = AnnotationCompositor.composite(baseImage: image, annotations: items)
        onSave(composed)
    }

    private func saveOriginal() {
        isSaving = true
        Task { @MainActor in
            self.onSaveOriginal()
        }
    }

    private func cancel() {
        onCancel()
    }
}

// MARK: - Shortcut hint bar

private struct ShortcutHintBar: View {
    var body: some View {
        HStack(spacing: 14) {
            ShortcutHintItem(keys: "⌘Z", action: "Undo")
            ShortcutHintItem(keys: "⇧⌘Z", action: "Redo")
            ShortcutHintItem(keys: "⌫", action: "Delete")
            ShortcutHintItem(keys: "Space", action: "Skip")
            ShortcutHintItem(keys: "⌘S", action: "Save")
            ShortcutHintItem(keys: "Esc", action: "Cancel")
        }
        .font(.system(size: 10, weight: .medium))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(NSColor.controlBackgroundColor).opacity(0.85))
        )
    }
}

private struct ShortcutHintItem: View {
    let keys: String
    let action: String
    var body: some View {
        HStack(spacing: 3) {
            Text(keys)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(.primary)
            Text(action)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - In-editor save progress toast

private struct SavingToastView: View {
    var body: some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
            VStack(alignment: .leading, spacing: 1) {
                Text("Saving...")
                    .font(.caption.bold())
                Text("Writing screenshot to disk")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(NSColor.windowBackgroundColor))
                .shadow(radius: 6, y: 2)
        )
        .padding(.horizontal, 16)
    }
}

// MARK: - Keyboard shortcut handler (local-only, hidden)

private struct KeyboardShortcutHandler: NSViewRepresentable {
    @ObservedObject var canvas: AnnotationCanvas
    let onCancel: () -> Void
    let onSave: () -> Void
    let onSaveOriginal: () -> Void

    func makeNSView(context: Context) -> KeyCaptureView {
        let v = KeyCaptureView()
        v.canvas = canvas
        v.onCancel = onCancel
        v.onSave = onSave
        v.onSaveOriginal = onSaveOriginal
        return v
    }

    func updateNSView(_ nsView: KeyCaptureView, context: Context) {
        nsView.canvas = canvas
        nsView.onCancel = onCancel
        nsView.onSave = onSave
        nsView.onSaveOriginal = onSaveOriginal
    }

    static func dismantleNSView(_ nsView: KeyCaptureView, coordinator: ()) {
        nsView.removeMonitor()
    }

    final class KeyCaptureView: NSView {
        weak var canvas: AnnotationCanvas?
        var onCancel: (() -> Void)?
        var onSave: (() -> Void)?
        var onSaveOriginal: (() -> Void)?

        private var monitor: Any?
        private var isActionTriggered = false

        override var acceptsFirstResponder: Bool { true }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window != nil {
                window?.makeFirstResponder(self)
                installMonitor()
            } else {
                removeMonitor()
            }
        }

        override func removeFromSuperview() {
            removeMonitor()
            super.removeFromSuperview()
        }

        deinit {
            removeMonitor()
        }

        private func installMonitor() {
            removeMonitor()
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, event.window === self.window else { return event }
                if self.handleKeyEvent(event) {
                    return nil
                }
                return event
            }
        }

        fileprivate func removeMonitor() {
            if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
        }

        /// Returns true if the key was consumed.
        private func handleKeyEvent(_ event: NSEvent) -> Bool {
            guard let canvas = canvas else { return false }

            // Once a terminal action is triggered (cancel/save/skip), ignore
            // subsequent key-down events to avoid re-entrancy while the window
            // is closing.
            if isActionTriggered {
                return true
            }

            // Do not intercept while the user is editing text (first responder
            // will be a TextField / text-editing view). We detect that by
            // checking whether the current first responder is a text view.
            if let responder = window?.firstResponder,
               responder is NSTextView || String(describing: type(of: responder)).contains("TextField") {
                return false
            }

            let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let characters = event.charactersIgnoringModifiers?.lowercased() ?? ""

            // Escape → cancel
            if event.keyCode == 53 {
                triggerTerminalAction(onCancel)
                return true
            }

            // Delete / Backspace → delete selected
            if event.keyCode == 51 || event.keyCode == 117 {
                canvas.deleteSelected()
                return true
            }

            // Command-based shortcuts are already wired via keyboardShortcut()
            // on the buttons; avoid double-handling them here.
            if mods.contains(.command) {
                // Undo / Redo
                if characters == "z" {
                    if mods.contains(.shift) {
                        canvas.redo()
                    } else {
                        canvas.undo()
                    }
                    return true
                }
                return false
            }

            // Tool switching shortcuts — only when no modifier pressed.
            if mods.isEmpty {
                // Space → skip annotation and save original image.
                if event.keyCode == 49 {
                    // Ignore key repeat to prevent duplicate skip actions.
                    if event.isARepeat { return true }
                    triggerTerminalAction(onSaveOriginal)
                    return true
                }

                if let tool = AnnotationType.allCases.first(where: { String($0.shortcutKey) == characters }) {
                    canvas.activeTool = tool
                    canvas.clearSelection()
                    return true
                }
            }

            return false
        }

        private func triggerTerminalAction(_ action: (() -> Void)?) {
            guard !isActionTriggered else { return }
            isActionTriggered = true

            // Defer to next run loop tick to avoid executing close/save flows
            // while still inside the NSEvent local monitor callback.
            DispatchQueue.main.async {
                action?()
            }
        }
    }
}
