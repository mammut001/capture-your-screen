//
//  AnnotationEditorView.swift
//  capture-your-screen
//

import SwiftUI
import AppKit

struct AnnotationEditorView: View {
    let baseImage: NSImage
    @StateObject private var canvas: AnnotationCanvas

    let onSave: (NSImage) -> Void       // Save composited image
    let onSaveOriginal: () -> Void      // Save the untouched base image (skip annotations)
    let onCancel: () -> Void

    init(
        baseImage: NSImage,
        canvas: AnnotationCanvas = AnnotationCanvas(),
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
            AnnotationToolbar(canvas: canvas)

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
                            Text("Press Space to Skip")
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
                .help("Save original without annotations (⌘↵ / Space)")

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
    }

    // MARK: - Actions

    private func save() {
        let items = canvas.items
        let image = baseImage
        // Do the composite on a background queue, keep the call site clean.
        DispatchQueue.global(qos: .userInitiated).async {
            let composed = AnnotationCompositor.composite(baseImage: image, annotations: items)
            DispatchQueue.main.async {
                onSave(composed)
            }
        }
    }

    private func saveOriginal() {
        onSaveOriginal()
    }

    private func cancel() {
        onCancel()
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
            window?.makeFirstResponder(self)
            installMonitor()
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

        private func removeMonitor() {
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
