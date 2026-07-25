import Foundation
import AppKit
import CoreGraphics

/// Tracks Screen Recording permission state. Must be a class (not struct) because
/// it is stored as a `let` in CaptureCoordinator and needs shared mutability.
final class PermissionManager {
    private static let hasRequestedAccessKey = "PermissionManager.hasRequestedScreenRecordingAccess"

    /// Tracks whether we have already prompted / requested Screen Recording access.
    /// `CGPreflightScreenCaptureAccess()` returns false for both "never asked" and "denied",
    /// so we need this flag to distinguish the two states across launches.
    private var hasRequestedAccess: Bool {
        get { UserDefaults.standard.bool(forKey: Self.hasRequestedAccessKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.hasRequestedAccessKey) }
    }

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

    /// Re-evaluate TCC state. Call after returning from System Settings or when the app becomes active.
    @discardableResult
    func refresh() -> PermissionStatus {
        screenRecordingStatus
    }

    /// Request Screen Recording permission. Shows the system prompt if not yet determined.
    /// Returns true if permission is now granted.
    ///
    /// Note: On macOS, enabling Screen Recording in System Settings often does not take
    /// effect for the *currently running* process. A full quit + relaunch may still be required
    /// even when the toggle is already ON.
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
            "1. Open System Settings → Privacy & Security → Screen Recording\n" +
            "2. Enable “capture-your-screen” (or “Capture Your Screen”)\n" +
            "3. Fully quit this app from the menu bar, then open it again\n\n" +
            "macOS only applies Screen Recording permission after a restart of the app."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            openScreenRecordingSettings()
        }
    }
}

enum PermissionStatus: Equatable {
    case granted
    case denied
    case notDetermined
}
