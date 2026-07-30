//
//  PostCaptureActionWindow.swift
//  capture-your-screen
//
//  Lightweight floating panel that hosts PostCaptureActionView, plus the
//  production `PostCapturePanelPresenting` implementation that owns the
//  window lifecycle.
//

import AppKit
import SwiftUI

/// Floating utility panel shown after a successful normal capture.
final class PostCaptureActionWindow: NSPanel {
    init(contentViewController: NSViewController) {
        super.init(
            contentRect: .zero,
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        self.contentViewController = contentViewController
        title = PostCaptureStrings.windowTitle
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isMovableByWindowBackground = true
        isReleasedWhenClosed = false
        isFloatingPanel = true
        becomesKeyOnlyIfNeeded = false
        hidesOnDeactivate = false
        level = .floating
        collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        animationBehavior = .utilityWindow
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

// MARK: - Presenter

/// Owns the post-capture panel window. Guarantees at most one panel at a
/// time and reports the native close button as a Cancel action.
@MainActor
final class PostCaptureActionPanelController: NSObject, PostCapturePanelPresenting, NSWindowDelegate {
    private var window: PostCaptureActionWindow?
    private var model: PostCapturePanelModel?
    private var systemCloseHandler: (() -> Void)?

    var isPresenting: Bool { window != nil }
    var presentedWindow: NSWindow? { window }

    func present(session: PostCaptureSession, handlers: PostCaptureActionHandlers) {
        // Never allow two panels for one capture.
        dismiss()

        let model = PostCapturePanelModel()
        let view = PostCaptureActionView(
            image: session.originalImage,
            pixelSize: session.pixelSize,
            model: model,
            handlers: handlers
        )
        let hosting = NSHostingController(rootView: view)
        let panel = PostCaptureActionWindow(contentViewController: hosting)
        panel.delegate = self

        self.model = model
        self.window = panel
        self.systemCloseHandler = handlers.onCancel

        position(panel, onDisplay: session.sourceDisplayID)
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func showStatus(_ status: PostCapturePanelStatus) {
        model?.status = status
    }

    func dismiss() {
        guard let panel = window else { return }
        // Clear references first so windowWillClose (triggered by close())
        // is recognized as programmatic and does not fire the cancel handler.
        window = nil
        model = nil
        systemCloseHandler = nil
        panel.delegate = nil
        panel.close()
    }

    // MARK: NSWindowDelegate

    /// The user clicked the native close button (or pressed ⌘W):
    /// treat it exactly like Cancel.
    func windowWillClose(_ notification: Notification) {
        guard window != nil else { return }
        let handler = systemCloseHandler
        window = nil
        model = nil
        systemCloseHandler = nil
        handler?()
    }

    // MARK: Placement

    /// Centers the panel (slightly above center) on the display where the
    /// screenshot was captured.
    private func position(_ panel: NSWindow, onDisplay displayID: CGDirectDisplayID?) {
        panel.layoutIfNeeded()
        let screen = NSScreen.screens.first(where: { $0.directDisplayID == displayID })
            ?? NSScreen.main
            ?? NSScreen.screens.first
        guard let screen else { return }

        let visible = screen.visibleFrame
        let size = panel.frame.size
        let origin = NSPoint(
            x: visible.midX - size.width / 2,
            y: visible.midY - size.height / 2 + visible.height * 0.06
        )
        panel.setFrameOrigin(origin)
    }
}
