import AppKit

/// Borderless, transparent, full-screen NSWindow used for the capture overlay.
///
/// Transient UI (menu bar menus, popovers, tooltips) is preserved by capturing a
/// freeze-frame *before* this window appears (`CaptureCoordinator` +
/// `ScreenCapture.captureFullDisplay`). Avoiding `NSApp.activate` is still
/// helpful while the overlay is up, but freeze-frame is what keeps menus in the
/// final crop after the user clicks Confirm.
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
        self.level = .statusBar
        self.backgroundColor = .clear
        self.isOpaque = false
        self.hasShadow = false
        self.ignoresMouseEvents = false
        self.acceptsMouseMovedEvents = true
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        // Smooth fade-in animation
        self.alphaValue = 0
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            self.animator().alphaValue = 1.0
        }
    }

    override func close() {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            self.animator().alphaValue = 0.0
        } completionHandler: {
            super.close()
        }
    }

    /// Key status helps SwiftUI button behavior, but capture controls themselves
    /// are Carbon global hotkeys because the previously active app still owns
    /// keyboard focus. We must never activate here and dismiss transient UI.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
