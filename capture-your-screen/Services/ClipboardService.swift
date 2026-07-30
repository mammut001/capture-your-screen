//
//  ClipboardService.swift
//  capture-your-screen
//
//  Small injectable abstraction over the system pasteboard so the
//  post-capture workflow can be tested without touching NSPasteboard.
//

import AppKit

enum ClipboardError: LocalizedError {
    case writeFailed

    var errorDescription: String? {
        switch self {
        case .writeFailed:
            return "Could not copy the screenshot to the clipboard."
        }
    }
}

/// Owns pasteboard interaction for captured screenshots.
@MainActor
protocol ClipboardWriting: AnyObject {
    func writeImage(_ image: NSImage) throws
}

/// Production implementation backed by `NSPasteboard.general`.
@MainActor
final class SystemClipboardService: ClipboardWriting {
    init() {}

    func writeImage(_ image: NSImage) throws {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard pasteboard.writeObjects([image]) else {
            throw ClipboardError.writeFailed
        }
    }
}
