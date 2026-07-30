//
//  NativeScreenshotSharingService.swift
//  capture-your-screen
//
//  Native macOS implementation of `ScreenshotSharing` backed by
//  NSSharingServicePicker. No network servers, uploads, or external
//  services are involved — only the system share sheet.
//

import AppKit

@MainActor
final class NativeScreenshotSharingService: NSObject, ScreenshotSharing {
    /// Strongly retained while the picker is on screen so AppKit callbacks
    /// always have a live delegate.
    private var activePicker: NSSharingServicePicker?
    private var continuation: CheckedContinuation<Void, Error>?

    var isAvailable: Bool { true }

    func share(image: NSImage, from sourceWindow: NSWindow?) async throws {
        guard continuation == nil else {
            throw ScreenshotSharingError.failed("A share operation is already in progress.")
        }
        guard let anchorView = sourceWindow?.contentView else {
            throw ScreenshotSharingError.unavailable
        }

        let picker = NSSharingServicePicker(items: [image])
        picker.delegate = self
        activePicker = picker

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            self.continuation = cont
            let bounds = anchorView.bounds
            // Anchor near the bottom edge, roughly where the Share button sits.
            let anchor = NSRect(x: bounds.midX - 1, y: bounds.minY + 4, width: 2, height: 2)
            picker.show(relativeTo: anchor, of: anchorView, preferredEdge: .minY)
        }
    }

    private func finishShare(didChooseService: Bool) {
        guard let cont = continuation else { return }
        continuation = nil
        activePicker = nil
        if didChooseService {
            cont.resume()
        } else {
            cont.resume(throwing: ScreenshotSharingError.cancelled)
        }
    }
}

extension NativeScreenshotSharingService: NSSharingServicePickerDelegate {
    nonisolated func sharingServicePicker(
        _ sharingServicePicker: NSSharingServicePicker,
        didChoose service: NSSharingService?
    ) {
        let didChoose = service != nil
        // AppKit delivers picker delegate callbacks on the main thread.
        MainActor.assumeIsolated {
            finishShare(didChooseService: didChoose)
        }
    }
}
