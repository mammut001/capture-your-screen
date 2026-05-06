//
//  capture_your_screenApp.swift
//  capture-your-screen
//
//  Created by Yuhan Song on 2026-04-03.
//

import SwiftUI
import Combine
import UserNotifications
import ServiceManagement

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
    }
}

// MARK: - AppDelegate

final class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    let hotkeyManager = HotkeyManager()
    let screenshotStore = ScreenshotStore()
    let launchAtLoginManager = LaunchAtLoginManager()
    @Published var showSettingsSheet: Bool = false

    private static let launchAtLoginAskedKey = "hasAskedLaunchAtLogin"

    /// Manually managed Settings window — gives us full control over window level.
    private var settingsWindowController: SettingsWindowController?

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
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }

        launchAtLoginManager.refreshStatus()

        Task { @MainActor [weak self] in
            self?.screenshotStore.startWatchingScreenshotFolder()
        }

        hotkeyManager.onHotkeyPressed = { [weak self] in
            Task { @MainActor in
                self?.coordinator.startCapture()
            }
        }
        hotkeyManager.register()

        askLaunchAtLoginIfNeeded()
    }

    func applicationWillTerminate(_ notification: Notification) {
        Task { @MainActor [weak self] in
            self?.screenshotStore.stopWatchingScreenshotFolder()
        }
        hotkeyManager.unregister()
    }

    // MARK: - Settings Window

    /// Open (or focus) the Settings window.
    /// The window is created as a plain NSWindow so we can set its level to
    /// .floating — guaranteeing it appears above the annotation editor and any
    /// other normal-level windows regardless of capture state.
    @MainActor
    func openSettingsWindow() {
        if let controller = settingsWindowController, let window = controller.window, window.isVisible {
            // Already open — just bring to front.
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let controller = SettingsWindowController(
            viewModel: viewModel,
            hotkeyManager: hotkeyManager,
            launchAtLoginManager: launchAtLoginManager
        )
        settingsWindowController = controller
        controller.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - First-launch prompt

    private func askLaunchAtLoginIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: Self.launchAtLoginAskedKey) else { return }
        UserDefaults.standard.set(true, forKey: Self.launchAtLoginAskedKey)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            guard let self else { return }
            let alert = NSAlert()
            alert.messageText = "Launch Capture Your Screen at Login?"
            alert.informativeText = "Would you like Capture Your Screen to start automatically every time you log in to your Mac?"
            alert.alertStyle = .informational
            alert.addButton(withTitle: "Yes, Launch at Login")
            alert.addButton(withTitle: "Not Now")
            NSApp.activate(ignoringOtherApps: true)
            if alert.runModal() == .alertFirstButtonReturn {
                self.launchAtLoginManager.isEnabled = true
            }
        }
    }
}

// MARK: - Settings Window Controller

/// Wraps the SwiftUI SettingsView in a manually created NSWindow so we can set
/// an explicit window level that keeps it above the annotation editor.
final class SettingsWindowController: NSWindowController {

    init(viewModel: MenuBarViewModel,
         hotkeyManager: HotkeyManager,
         launchAtLoginManager: LaunchAtLoginManager) {

        let settingsView = SettingsView()
            .environmentObject(viewModel)
            .environmentObject(hotkeyManager)
            .environmentObject(launchAtLoginManager)

        let hostingView = NSHostingView(rootView: settingsView)
        // Size the window to fit the SwiftUI content.
        hostingView.autoresizingMask = [.width, .height]
        let fittingSize = hostingView.fittingSize
        let contentRect = NSRect(origin: .zero, size: fittingSize)

        let window = NSWindow(
            contentRect: contentRect,
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Settings"
        window.contentView = hostingView
        window.isReleasedWhenClosed = false
        // .floating puts it above all normal windows (including the annotation
        // editor) but below the full-screen overlay (.statusBar level).
        window.level = .floating
        window.center()

        super.init(window: window)
    }

    required init?(coder: NSCoder) { fatalError("not implemented") }
}
