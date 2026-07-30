//
//  ScreenshotSharing.swift
//  capture-your-screen
//
//  Replaceable sharing abstraction. Today this is implemented by
//  `NativeScreenshotSharingService` (NSSharingServicePicker). A future
//  `LocalNetworkScreenshotSharingService` can replace or supplement it
//  without changing the post-capture UI or the coordinator routing.
//

import AppKit

enum ScreenshotSharingError: LocalizedError {
    /// No sharing mechanism can be presented right now.
    case unavailable
    /// The user dismissed the share flow without choosing a destination.
    case cancelled
    /// The share flow failed after being started.
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .unavailable:
            return "Sharing is not available right now."
        case .cancelled:
            return "Sharing was cancelled."
        case .failed(let reason):
            return "Sharing failed: \(reason)"
        }
    }
}

/// Owns the sharing operation for a captured screenshot.
@MainActor
protocol ScreenshotSharing: AnyObject {
    /// Whether the service can currently present a share flow.
    var isAvailable: Bool { get }

    /// Initiates sharing of the image, anchored to `sourceWindow` when one
    /// is available. Returns once the share flow has been successfully
    /// started (for the native picker: the user chose a sharing service).
    /// Throws `ScreenshotSharingError.cancelled` when the user backs out.
    func share(image: NSImage, from sourceWindow: NSWindow?) async throws
}
