import Combine
import Foundation
import AppKit
import SwiftUI
import UserNotifications

/// State machine that drives the full capture flow:
/// idle → capturing (overlay shown) → confirmed/cancelled → idle
@MainActor
final class CaptureCoordinator: ObservableObject {
    enum CaptureState {
        case idle
        case capturing
        case annotating
        case confirmed
        case cancelled
    }

    @Published private(set) var state: CaptureState = .idle
    @Published var lastError: Error?
    /// Exposed so MenuBarViewModel can observe permission state.
    var permissionStatus: PermissionStatus { permissionManager.screenRecordingStatus }

    private var overlayWindow: OverlayWindow?
    private var annotationWindow: AnnotationEditorWindow?
    private let screenshotStore: ScreenshotStore
    private let hotkeyManager: HotkeyManager
    let permissionManager = PermissionManager()

    init(screenshotStore: ScreenshotStore, hotkeyManager: HotkeyManager) {
        self.screenshotStore = screenshotStore
        self.hotkeyManager = hotkeyManager
    }

    // MARK: - Public API

    func startCapture() {
        guard case .idle = state else { return }
        lastError = nil

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

        guard let screen = activeCaptureScreen() else { return }

        state = .capturing

        let window = OverlayWindow(screen: screen)
        let overlayView = SelectionOverlayView(
            onConfirm: { [weak self] rect in
                self?.finishCapture(selectionRect: rect, screen: screen)
            },
            onQuickSave: { [weak self] rect in
                self?.quickSaveCapture(selectionRect: rect, screen: screen)
            },
            onCancel: { [weak self] in
                self?.cancelCapture()
            },
            screen: screen,
            hotkeyConfig: hotkeyManager.currentConfig
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

        // SelectionOverlayView emits coordinates in the overlay's local space.
        // Once the display is fixed, ScreenCaptureKit expects the rect within that display.
        let captureRect = selectionRect.integral

        performCapture(rect: captureRect, screen: screen)
    }

    private func performCapture(rect: CGRect, screen: NSScreen) {
        print("CaptureCoordinator: Starting capture for rect: \(rect) on screen: \(screen.frame)")
        Task {
            do {
                let image = try await ScreenCapture.captureRegion(rect, displayID: screen.displayID)
                print("CaptureCoordinator: Image captured successfully.")
                lastError = nil
                openAnnotationEditor(with: image)
            } catch {
                print("CaptureCoordinator: ERROR during capture: \(error.localizedDescription)")
                lastError = error
                showNotification(title: "Capture Failed", body: error.localizedDescription)
                state = .idle
            }
        }
    }

    /// Bypass the annotation editor and save directly to disk.
    private func quickSaveCapture(selectionRect: CGRect, screen: NSScreen) {
        guard case .capturing = state else { return }
        state = .confirmed
        overlayWindow?.close()
        overlayWindow = nil

        Task {
            do {
                let image = try await ScreenCapture.captureRegion(selectionRect.integral, displayID: screen.displayID)
                lastError = nil

                // Write to clipboard
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.writeObjects([image])

                // Save to disk
                let record = try await screenshotStore.save(image)
                print("CaptureCoordinator: Quick-saved as \(record.url.path)")
                showNotification(title: "Screenshot Captured", body: "Saved to \(record.url.lastPathComponent)")
            } catch {
                print("CaptureCoordinator: ERROR during quick save: \(error.localizedDescription)")
                lastError = error
                showNotification(title: "Save Failed", body: error.localizedDescription)
            }
            state = .idle
        }
    }

    // MARK: - Annotation flow

    private func openAnnotationEditor(with image: NSImage) {
        state = .annotating

        let window = AnnotationEditorWindow(image: image)
        let view = AnnotationEditorView(
            baseImage: image,
            onSave: { [weak self] annotated in
                self?.finalize(image: annotated)
            },
            onSaveOriginal: { [weak self] in
                self?.finalize(image: image)
            },
            onCancel: { [weak self] in
                self?.cancelAnnotation()
            }
        )

        let hosting = NSHostingView(rootView: view)
        hosting.frame = window.contentRect(forFrameRect: window.frame)
        hosting.autoresizingMask = [.width, .height]
        window.contentView = hosting
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        self.annotationWindow = window
    }

    private func finalize(image: NSImage) {
        annotationWindow?.close()
        annotationWindow = nil

        Task {
            do {
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.writeObjects([image])

                let record = try await screenshotStore.save(image)
                print("CaptureCoordinator: Saved as \(record.url.path)")
                showNotification(title: "Screenshot Captured", body: "Saved to \(record.url.lastPathComponent)")
            } catch {
                print("CaptureCoordinator: ERROR during save: \(error.localizedDescription)")
                lastError = error
                showNotification(title: "Save Failed", body: error.localizedDescription)
            }
            state = .idle
        }
    }

    private func cancelAnnotation() {
        annotationWindow?.close()
        annotationWindow = nil
        state = .idle
    }

    private func activeCaptureScreen() -> NSScreen? {
        let pointerLocation = NSEvent.mouseLocation
        return NSScreen.screens.first(where: { NSMouseInRect(pointerLocation, $0.frame, false) })
            ?? NSScreen.main
            ?? NSScreen.screens.first
    }

    private func showNotification(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                print("CaptureCoordinator: notification delivery failed: \(error.localizedDescription)")
            }
        }
    }
}

private extension NSScreen {
    var displayID: CGDirectDisplayID? {
        deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }
}
