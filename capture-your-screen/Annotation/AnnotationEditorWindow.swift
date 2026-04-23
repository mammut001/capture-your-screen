//
//  AnnotationEditorWindow.swift
//  capture-your-screen
//

import AppKit

/// Modal-ish floating window that hosts the annotation editor.
final class AnnotationEditorWindow: NSWindow {
    convenience init(image: NSImage) {
        let visible = NSScreen.main?.visibleFrame.size ?? NSSize(width: 1200, height: 800)
        let maxW = visible.width * 0.85
        let maxH = visible.height * 0.85

        let imgW = max(image.size.width, 400)
        let imgH = max(image.size.height, 300)

        let scale = min(maxW / imgW, maxH / (imgH + 120), 1.0)
        let contentW = max(imgW * scale, 640)
        // Reserve ~52pt toolbar + ~48pt action bar on top of the canvas.
        let contentH = max(imgH * scale + 110, 420)

        let rect = NSRect(x: 0, y: 0, width: contentW, height: contentH)
        self.init(
            contentRect: rect,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        self.title = "Annotate Screenshot"
        self.isReleasedWhenClosed = false
        self.minSize = NSSize(width: 640, height: 420)
        self.center()
    }
}
