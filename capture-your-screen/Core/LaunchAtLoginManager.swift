import Foundation
import ServiceManagement
import Combine

/// Manages the "Launch at Login" status using SMAppService (introduced in macOS 13.0).
@MainActor
final class LaunchAtLoginManager: ObservableObject {
    
    @Published var isEnabled: Bool = false {
        didSet {
            // Only toggle if the state has actually changed and we're not just initializing.
            if isEnabled != (SMAppService.mainApp.status == .enabled) {
                toggleLaunchAtLogin()
            }
        }
    }

    init() {
        // Correctly set initial state based on system status.
        isEnabled = (SMAppService.mainApp.status == .enabled)
    }

    private func toggleLaunchAtLogin() {
        do {
            if isEnabled {
                try SMAppService.mainApp.register()
                print("LaunchAtLoginManager: Successfully registered main app.")
            } else {
                try SMAppService.mainApp.unregister()
                print("LaunchAtLoginManager: Successfully unregistered main app.")
            }
        } catch {
            print("LaunchAtLoginManager: Error changing launch at login status: \(error.localizedDescription)")
            // Rollback UI state if system call failed.
            isEnabled = (SMAppService.mainApp.status == .enabled)
        }
    }

    /// Refresh status from system, in case user changed it in System Settings.
    func refreshStatus() {
        let currentStatus = (SMAppService.mainApp.status == .enabled)
        if isEnabled != currentStatus {
            isEnabled = currentStatus
        }
    }
}
