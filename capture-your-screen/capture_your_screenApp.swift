//
//  capture_your_screenApp.swift
//  capture-your-screen
//
//  Created by Yuhan Song on 2026-04-03.
//

import SwiftUI
import UserNotifications

@main
struct capture_your_screenApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        MenuBarExtra("Capture Your Screen", systemImage: "camera.viewfinder") {
            MenuBarView()
                .environmentObject(appDelegate.viewModel)
                .environmentObject(appDelegate.screenshotStore)
        }
        .menuBarExtraStyle(.menu)

        Window("Settings", id: "settings") {
            SettingsView()
                .environmentObject(appDelegate.viewModel)
        }
        .windowResizability(.contentSize)
    }
}

// MARK: - AppDelegate

final class AppDelegate: NSObject, NSApplicationDelegate {
    let hotkeyManager = HotkeyManager()
    let screenshotStore = ScreenshotStore()

    lazy var coordinator: CaptureCoordinator = CaptureCoordinator(screenshotStore: screenshotStore)

    lazy var viewModel: MenuBarViewModel = MenuBarViewModel(
        captureCoordinator: coordinator,
        screenshotStore: screenshotStore
    )

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Request notification permission
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }

        // Wire hotkey → capture coordinator
        hotkeyManager.onHotkeyPressed = { [weak self] in
            Task { @MainActor in
                self?.coordinator.startCapture()
            }
        }
        hotkeyManager.register()

        // Sync hotkey display to view model
        Task { @MainActor in
            viewModel.updateHotkeyDisplay(hotkeyManager.currentConfig.displayString)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotkeyManager.unregister()
    }
}
