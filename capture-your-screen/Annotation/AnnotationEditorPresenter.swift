//
//  AnnotationEditorPresenter.swift
//  capture-your-screen
//
//  Production `AnnotationEditorPresenting` implementation. Wraps the
//  existing AnnotationEditorWindow / AnnotationEditorView and reports the
//  native close button as a Cancel action so the coordinator can return
//  the user to the post-capture panel.
//

import AppKit
import SwiftUI

@MainActor
final class AnnotationEditorPresenter: NSObject, AnnotationEditorPresenting, NSWindowDelegate {
    private var window: AnnotationEditorWindow?
    private var systemCloseHandler: (() -> Void)?

    func present(image: NSImage, handlers: AnnotationEditorHandlers) {
        // Never allow two editors at once.
        dismiss()

        let window = AnnotationEditorWindow(image: image)
        let view = AnnotationEditorView(
            baseImage: image,
            onSave: handlers.onSave,
            onSaveOriginal: handlers.onSkip,
            onCancel: handlers.onCancel
        )

        let hosting = NSHostingView(rootView: view)
        hosting.frame = window.contentRect(forFrameRect: window.frame)
        hosting.autoresizingMask = [.width, .height]
        window.contentView = hosting
        window.delegate = self

        self.window = window
        self.systemCloseHandler = handlers.onCancel

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func dismiss() {
        guard let window = self.window else { return }
        // Clear references first so windowWillClose from close() is treated
        // as programmatic and does not invoke the cancel handler.
        self.window = nil
        self.systemCloseHandler = nil
        window.delegate = nil
        window.close()
    }

    // MARK: NSWindowDelegate

    /// Native close button acts as Cancel (returns to the action panel).
    func windowWillClose(_ notification: Notification) {
        guard window != nil else { return }
        let handler = systemCloseHandler
        window = nil
        systemCloseHandler = nil
        handler?()
    }
}
