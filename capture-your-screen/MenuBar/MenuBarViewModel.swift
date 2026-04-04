import Combine
import Foundation
import AppKit
import SwiftUI

@MainActor
final class MenuBarViewModel: ObservableObject {
    @Published var historyGroups: [HistoryGroup: [ScreenshotHistoryItem]] = [:]
    @Published var currentHotkeyDisplay: String = HotkeyConfiguration.default.displayString
    @Published var isCapturing: Bool = false
    @Published var errorMessage: String?

    private let captureCoordinator: CaptureCoordinator
    private let screenshotStore: ScreenshotStore

    init(captureCoordinator: CaptureCoordinator, screenshotStore: ScreenshotStore) {
        self.captureCoordinator = captureCoordinator
        self.screenshotStore = screenshotStore
    }

    // MARK: - Actions

    func startCapture() {
        captureCoordinator.startCapture()
    }

    func openScreenshotFolder() {
        // If the user hasn't explicitly chosen a folder, ask them to pick one first.
        if screenshotStore.resolver.customFolderURL == nil {
            NSApp.activate(ignoringOtherApps: true)
            chooseScreenshotFolder()
            // If they cancel out of the dialog, stop here
            if screenshotStore.resolver.customFolderURL == nil { return }
        }

        let rootURL = screenshotStore.resolver.screenshotFolderURL
        
        let folderFormatter = DateFormatter()
        folderFormatter.dateFormat = "yyyy-MM-dd"
        let dateFolderName = folderFormatter.string(from: Date())
        let todayFolderURL = rootURL.appendingPathComponent(dateFolderName, isDirectory: true)
        
        // Open today's folder if it exists, otherwise fallback to root folder
        let targetURL = FileManager.default.fileExists(atPath: todayFolderURL.path) ? todayFolderURL : rootURL
        
        try? FileManager.default.createDirectory(at: targetURL, withIntermediateDirectories: true)
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: targetURL.path)
        
        // Force Finder to come to the front
        if let finder = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first {
            finder.activate(options: .activateIgnoringOtherApps)
        }
    }

    func copyScreenshot(_ item: ScreenshotHistoryItem) {
        try? screenshotStore.copyToClipboard(id: item.id)
    }

    func showInFinder(_ item: ScreenshotHistoryItem) {
        NSWorkspace.shared.activateFileViewerSelecting([item.url])
    }

    func deleteScreenshot(_ item: ScreenshotHistoryItem) {
        try? screenshotStore.delete(id: item.id)
        rebuildGroups()
    }

    /// Human-readable display of the current save folder path.
    var screenshotFolderDisplay: String {
        let url = screenshotStore.resolver.screenshotFolderURL
        return url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }

    /// Open an NSOpenPanel so the user can pick any folder (including iCloud Drive).
    func chooseScreenshotFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.message = "Choose a folder to save screenshots.\nYou can point this to iCloud Drive or any other location."
        // Pre-select the current folder so the panel opens there
        panel.directoryURL = screenshotStore.resolver.screenshotFolderURL
        if panel.runModal() == .OK, let url = panel.url {
            screenshotStore.resolver.customFolderURL = url
            screenshotStore.reloadResolver()
            objectWillChange.send()
        }
    }

    /// Reset save location back to the default (~/Pictures/Screenshots).
    func resetToDefaultFolder() {
        screenshotStore.resolver.customFolderURL = nil
        screenshotStore.reloadResolver()
        objectWillChange.send()
    }

    func refresh() async {
        await screenshotStore.refreshHistory()
        rebuildGroups()
    }

    // MARK: - Internal

    func rebuildGroups() {
        let items = screenshotStore.screenshots.map { $0.toHistoryItem() }
        var groups: [HistoryGroup: [ScreenshotHistoryItem]] = [:]
        for item in items {
            let group = HistoryGroup.group(for: item.date)
            groups[group, default: []].append(item)
        }
        historyGroups = groups
    }

    func updateHotkeyDisplay(_ display: String) {
        currentHotkeyDisplay = display
    }
}
