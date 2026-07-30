//
//  ScreenshotPersisting.swift
//  capture-your-screen
//
//  Thin persistence facade so the capture workflow can be unit tested
//  without writing PNG files to disk. `ScreenshotStore` remains the
//  single production source of truth for saving and history.
//

import AppKit

@MainActor
protocol ScreenshotPersisting: AnyObject {
    /// Persists the image to the configured screenshot folder and
    /// inserts it into screenshot history. Returns the created record.
    func persistScreenshot(_ image: NSImage) async throws -> ScreenshotRecord
}

extension ScreenshotStore: ScreenshotPersisting {
    func persistScreenshot(_ image: NSImage) async throws -> ScreenshotRecord {
        try await save(image)
    }
}
