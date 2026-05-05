//
//  capture_your_screenApp.swift
//  capture-your-screen
//
//  Created by Yuhan Song on 2026-04-03.
//

import SwiftUI
import Combine
import UserNotifications

@main
struct capture_your_screenApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        MenuBarExtra("Capture Your Screen", systemImage: "camera.viewfinder") {
            MenuBarView()
                .environmentObject(appDelegate.viewModel)
                .environmentObject(appDelegate.screenshotStore)
                .environmentObject(appDelegate.hotkeyManager)
                .environmentObject(appDelegate.launchAtLoginManager)
                .environmentObject(appDelegate)
        }
        .menuBarExtraStyle(.window)

        Window("Settings", id: "settings") {
            SettingsView()
                .environmentObject(appDelegate.viewModel)
                .environmentObject(appDelegate.hotkeyManager)
                .environmentObject(appDelegate.launchAtLoginManager)
        }
        .windowResizability(.contentSize)
    }
}

// MARK: - AppDelegate

final class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    let hotkeyManager = HotkeyManager()
    let screenshotStore = ScreenshotStore()
    let launchAtLoginManager = LaunchAtLoginManager()
    @Published var showSettingsSheet: Bool = false

    lazy var coordinator: CaptureCoordinator = CaptureCoordinator(
        screenshotStore: screenshotStore,
        hotkeyManager: hotkeyManager
    )

    lazy var viewModel: MenuBarViewModel = MenuBarViewModel(
        captureCoordinator: coordinator,
        screenshotStore: screenshotStore,
        hotkeyManager: hotkeyManager
    )

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Request notification permission
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }

        // Refresh launch status (in case user changed it in System Settings while app was closed)
        launchAtLoginManager.refreshStatus()

        Task { @MainActor [weak self] in
            self?.screenshotStore.startWatchingScreenshotFolder()
        }

        // Wire hotkey → capture coordinator
        hotkeyManager.onHotkeyPressed = { [weak self] in
            Task { @MainActor in
                self?.coordinator.startCapture()
            }
        }
        hotkeyManager.register()
    }

    func applicationWillTerminate(_ notification: Notification) {
        Task { @MainActor [weak self] in
            self?.screenshotStore.stopWatchingScreenshotFolder()
        }
        hotkeyManager.unregister()
    }
}
