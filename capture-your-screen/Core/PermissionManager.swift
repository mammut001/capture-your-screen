import Foundation
import AppKit
import CoreGraphics

struct PermissionManager {
    /// Check Screen Recording permission synchronously using CGPreflightScreenCaptureAccess.
    var screenRecordingStatus: PermissionStatus {
        CGPreflightScreenCaptureAccess() ? .granted : .denied
    }

    /// Request Screen Recording permission. Shows the system prompt if not yet determined.
    @discardableResult
    func requestScreenRecordingAccess() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    /// Open System Settings → Privacy & Security → Screen Recording.
    func openScreenRecordingSettings() {
        let urlString = "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
        if let url = URL(string: urlString) {
            NSWorkspace.shared.open(url)
        }
    }

    /// Show a blocking alert guiding the user to grant Screen Recording permission.
    @MainActor
    func showPermissionAlert() {
        let alert = NSAlert()
        alert.messageText = "Screen Recording Permission Required"
        alert.informativeText =
            "Capture Your Screen needs Screen Recording permission to capture your screen.\n\n" +
            "Please go to System Settings → Privacy & Security → Screen Recording and enable this app."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            openScreenRecordingSettings()
        }
    }
}

enum PermissionStatus {
    case granted
    case denied
    case notDetermined
}

