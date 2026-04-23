import AppKit
import SwiftUI

/// Borderless, transparent, full-screen NSWindow used for the capture overlay.
final class OverlayWindow: NSWindow {
    init(screen: NSScreen) {
        super.init(
            contentRect: screen.frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        self.isReleasedWhenClosed = false
        self.setFrame(screen.frame, display: false)
        // Use statusBar level – high enough to appear above all app windows but
        // low enough that the system can still recover (Cmd+Tab, Dock, etc.)
        // if the process crashes without closing the window.
        // screenSaverWindow level was causing the screen to appear "frozen"
        // on EXC_BAD_ACCESS crashes because the transparent overlay stayed on top.
        self.level = .statusBar
        self.backgroundColor = .clear
        self.isOpaque = false
        self.hasShadow = false
        self.ignoresMouseEvents = false
        self.acceptsMouseMovedEvents = true
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// NSHostingView subclass that accepts first responder so the window's
/// first-responder chain reaches this view (required for key events).
final class KeyboardAcceptingHostingView<Content: View>: NSHostingView<Content> {
    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
    }
}
