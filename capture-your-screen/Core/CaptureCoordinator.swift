import Combine
import Foundation
import AppKit
import SwiftUI

/// State machine that drives the full capture flow:
/// idle → capturing (overlay shown) → confirmed/cancelled → idle
@MainActor
final class CaptureCoordinator: ObservableObject {
    enum CaptureState {
        case idle
        case capturing
        case confirmed
        case cancelled
    }

    @Published private(set) var state: CaptureState = .idle
    @Published var lastError: Error?

    private var overlayWindow: OverlayWindow?
    private let screenshotStore: ScreenshotStore
    private let permissionManager = PermissionManager()

    init(screenshotStore: ScreenshotStore) {
        self.screenshotStore = screenshotStore
    }

    // MARK: - Public API

    func startCapture() {
        guard case .idle = state else { return }

        // If not yet granted, trigger the system permission dialog first.
        // This makes the app appear in System Settings → Screen Recording.
        if permissionManager.screenRecordingStatus != .granted {
            _ = permissionManager.requestScreenRecordingAccess()
            // Re-check: if still not granted (user denied), show guidance alert
            if permissionManager.screenRecordingStatus != .granted {
                permissionManager.showPermissionAlert()
                return
            }
        }

        guard let screen = NSScreen.main else { return }

        state = .capturing

        let window = OverlayWindow(screen: screen)
        let overlayView = SelectionOverlayView(
            onConfirm: { [weak self] rect in
                self?.finishCapture(selectionRect: rect, screen: screen)
            },
            onCancel: { [weak self] in
                self?.cancelCapture()
            }
        )
        let hostingView = KeyboardAcceptingHostingView(rootView: overlayView)
        hostingView.frame = window.contentRect(forFrameRect: window.frame)
        window.contentView = hostingView
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(hostingView)
        NSApp.activate(ignoringOtherApps: true)

        self.overlayWindow = window
    }

    func cancelCapture() {
        // Guard against re-entrant calls (e.g. Esc pressed twice, or
        // event monitor firing after state already changed → EXC_BAD_ACCESS)
        guard case .capturing = state else { return }
        state = .idle
        overlayWindow?.close()
        overlayWindow = nil
    }

    // MARK: - Private

    private func finishCapture(selectionRect: CGRect, screen: NSScreen) {
        // Guard against re-entrant calls (e.g. Enter pressed while already capturing)
        guard case .capturing = state else { return }
        state = .confirmed
        // Hide the overlay first so it doesn't appear in the screenshot
        overlayWindow?.close()
        overlayWindow = nil

        // Convert view coords (top-left origin) → screen coords (bottom-left origin)
        let screenHeight = screen.frame.height
        let captureRect = CGRect(
            x: screen.frame.minX + selectionRect.minX,
            y: screen.frame.minY + (screenHeight - selectionRect.maxY),
            width: selectionRect.width,
            height: selectionRect.height
        )

        // performCapture uses Task {}, so it runs off the main thread automatically.
        performCapture(rect: captureRect)
    }

    private func performCapture(rect: CGRect) {
        Task {
            do {
                let image = try await ScreenCapture.captureRegion(rect)

                // Copy to clipboard
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.writeObjects([image])

                // Save to disk
                _ = try await screenshotStore.save(image)
                showNotification()
            } catch {
                lastError = error
            }
            state = .idle
        }
    }

    private func showNotification() {
        let content = UNMutableNotificationContent()
        content.title = "Screenshot Captured"
        content.body = "Saved and copied to clipboard."
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }
}

// Import UserNotifications for the notification helper above
import UserNotifications
