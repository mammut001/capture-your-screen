import Foundation
import ServiceManagement
import Combine
import os

private let logger = Logger(subsystem: "com.captureyourscreen.core", category: "LaunchAtLogin")

/// Manages the "Launch at Login" status using SMAppService (introduced in macOS 13.0).
@MainActor
final class LaunchAtLoginManager: ObservableObject {
    
    @Published var isEnabled: Bool = false {
        didSet {
            guard !isUpdating else { return }
            if isEnabled != (SMAppService.mainApp.status == .enabled) {
                toggleLaunchAtLogin()
            }
        }
    }

    private var isUpdating = false

    init() {
        // Correctly set initial state based on system status.
        isEnabled = (SMAppService.mainApp.status == .enabled)
    }

    private func toggleLaunchAtLogin() {
        isUpdating = true
        defer { isUpdating = false }
        do {
            if isEnabled {
                try SMAppService.mainApp.register()
                logger.info("Successfully registered main app for launch at login.")
            } else {
                try SMAppService.mainApp.unregister()
                logger.info("Successfully unregistered main app from launch at login.")
            }
        } catch {
            logger.error("Error changing launch at login status: \(error.localizedDescription, privacy: .public)")
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
