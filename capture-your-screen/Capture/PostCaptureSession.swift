//
//  PostCaptureSession.swift
//  capture-your-screen
//
//  In-memory model for a screenshot that has been captured but not yet
//  copied, annotated, shared, or discarded. Exactly one session may be
//  active at a time; its UUID is used to reject stale async callbacks.
//

import AppKit

/// The currently captured screenshot awaiting a user decision.
struct PostCaptureSession: Identifiable {
    let id: UUID
    let originalImage: NSImage
    let createdAt: Date
    let sourceDisplayID: CGDirectDisplayID?
    let selectionRect: CGRect?

    init(
        originalImage: NSImage,
        sourceDisplayID: CGDirectDisplayID? = nil,
        selectionRect: CGRect? = nil
    ) {
        self.id = UUID()
        self.originalImage = originalImage
        self.createdAt = Date()
        self.sourceDisplayID = sourceDisplayID
        self.selectionRect = selectionRect
    }

    /// Best-effort pixel dimensions (Retina-aware) for display in the UI.
    var pixelSize: CGSize {
        if let rep = originalImage.representations.first, rep.pixelsWide > 0, rep.pixelsHigh > 0 {
            return CGSize(width: rep.pixelsWide, height: rep.pixelsHigh)
        }
        return originalImage.size
    }
}

// MARK: - Action routing types

/// Actions the post-capture panel can emit. The panel renders UI only;
/// the coordinator owns state and routing.
struct PostCaptureActionHandlers {
    let onCopy: () -> Void
    let onAnnotate: () -> Void
    let onShare: () -> Void
    let onCancel: () -> Void
}

/// Inline status displayed inside the post-capture panel.
enum PostCapturePanelStatus: Equatable {
    case ready
    case processing(String)
    case success(String)
    case failure(String)
}

/// Abstraction over the post-capture panel window so the coordinator can
/// be tested without creating AppKit windows.
@MainActor
protocol PostCapturePanelPresenting: AnyObject {
    var isPresenting: Bool { get }
    var presentedWindow: NSWindow? { get }
    func present(session: PostCaptureSession, handlers: PostCaptureActionHandlers)
    func showStatus(_ status: PostCapturePanelStatus)
    func dismiss()
}

/// Callbacks emitted by the annotation editor.
struct AnnotationEditorHandlers {
    let onSave: (NSImage) -> Void
    let onSkip: () -> Void
    let onCancel: () -> Void
}

/// Abstraction over the annotation editor window for the same reason.
@MainActor
protocol AnnotationEditorPresenting: AnyObject {
    func present(image: NSImage, handlers: AnnotationEditorHandlers)
    func dismiss()
}

// MARK: - Shared helpers

extension NSScreen {
    /// The CGDirectDisplayID backing this screen, when available.
    var directDisplayID: CGDirectDisplayID? {
        deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }
}
