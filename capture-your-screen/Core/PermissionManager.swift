import Foundation
import AppKit
import CoreGraphics

/// Tracks Screen Recording permission state. Must be a class (not struct) because
/// it is stored as a `let` in CaptureCoordinator and needs shared mutability.
final class PermissionManager {
    /// Tracks whether CGRequestScreenCaptureAccess() has ever been called.
    /// CGPreflightScreenCaptureAccess() returns false for both "never asked" and "denied",
    /// so we need this flag to distinguish the two states.
    private var hasRequestedAccess: Bool = false

    /// Check Screen Recording permission synchronously.
    /// - `.granted`: CGPreflight returns true
    /// - `.notDetermined`: CGPreflight returns false AND we haven't requested yet
    /// - `.denied`: CGPreflight returns false AND we have already requested
    var screenRecordingStatus: PermissionStatus {
        if CGPreflightScreenCaptureAccess() {
            return .granted
        }
        return hasRequestedAccess ? .denied : .notDetermined
    }

    /// Request Screen Recording permission. Shows the system prompt if not yet determined.
    /// Returns true if permission is now granted.
    @discardableResult
    func requestScreenRecordingAccess() -> Bool {
        hasRequestedAccess = true
        return CGRequestScreenCaptureAccess()
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

