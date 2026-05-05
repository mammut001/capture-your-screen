import Combine
import Foundation
import AppKit
import SwiftUI

@MainActor
final class MenuBarViewModel: ObservableObject {
    @Published var historySections: [ScreenshotDaySection] = []
    @Published var currentHotkeyDisplay: String = HotkeyConfiguration.default.displayString
    @Published var isCapturing: Bool = false
    @Published var errorMessage: String?
    @Published var selectedItem: ScreenshotHistoryItem?
    @Published var showCopyToast: Bool = false
    @Published var browsingByDate: Bool = false
    @Published var selectedDate: Date = Date()
    @Published var screenshotsForSelectedDate: [ScreenshotHistoryItem] = []

    private let captureCoordinator: CaptureCoordinator
    private let screenshotStore: ScreenshotStore
    private let hotkeyManager: HotkeyManager
    private var cancellables = Set<AnyCancellable>()

    init(captureCoordinator: CaptureCoordinator, screenshotStore: ScreenshotStore, hotkeyManager: HotkeyManager) {
        self.captureCoordinator = captureCoordinator
        self.screenshotStore = screenshotStore
        self.hotkeyManager = hotkeyManager
        self.currentHotkeyDisplay = hotkeyManager.currentConfig.displayString

        // Keep currentHotkeyDisplay in sync whenever the hotkey is changed
        hotkeyManager.$currentConfig
            .receive(on: RunLoop.main)
            .sink { [weak self] config in
                self?.currentHotkeyDisplay = config.displayString
            }
            .store(in: &cancellables)

        // Automatically rebuild history groups whenever the store changes
        screenshotStore.$screenshots
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.rebuildSections()
            }
            .store(in: &cancellables)

        // Track captureCoordinator state so isCapturing stays accurate
        captureCoordinator.$state
            .receive(on: RunLoop.main)
            .sink { [weak self] state in
                self?.isCapturing = (state == .capturing)
            }
            .store(in: &cancellables)

        captureCoordinator.$lastError
            .receive(on: RunLoop.main)
            .sink { [weak self] error in
                guard let error else { return }
                self?.showError(error.localizedDescription)
            }
            .store(in: &cancellables)

        // Initial build
        rebuildSections()
    }

    // MARK: - Thumbnail Loading

    /// Trigger lazy thumbnail loading for a history item.
    /// Called by the UI when a card enters the visible area.
    func loadThumbnailIfNeeded(for item: ScreenshotHistoryItem) {
        screenshotStore.loadThumbnail(for: item.id)
    }

    // MARK: - Actions

    func startCapture() {
        captureCoordinator.startCapture()
    }

    var permissionStatus: PermissionStatus {
        captureCoordinator.permissionStatus
    }

    func openPermissionSettings() {
        captureCoordinator.permissionManager.openScreenRecordingSettings()
    }

    func openScreenshotFolder() {
        let rootURL = screenshotStore.resolver.screenshotFolderURL
        
        let folderFormatter = DateFormatter()
        folderFormatter.dateFormat = "yyyy-MM-dd"
        let dateFolderName = folderFormatter.string(from: Date())
        let todayFolderURL = rootURL.appendingPathComponent(dateFolderName, isDirectory: true)
        
        // Open today's folder if it exists, otherwise fallback to root folder
        let targetURL = FileManager.default.fileExists(atPath: todayFolderURL.path) ? todayFolderURL : rootURL
        
        try? FileManager.default.createDirectory(at: targetURL, withIntermediateDirectories: true)

        // Select the first file in the folder so Finder opens and highlights it;
        // fall back to selecting the folder itself when it is empty.
        let fileToSelect: URL
        if let firstFile = FileManager.default.enumerator(
            at: targetURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )?.nextObject() as? URL {
            fileToSelect = firstFile
        } else {
            fileToSelect = targetURL
        }
        NSWorkspace.shared.activateFileViewerSelecting([fileToSelect])
    }

    /// Direct copy — used by context menu (no confirm step needed).
    func copyScreenshot(_ item: ScreenshotHistoryItem) {
        Task {
            await copyScreenshotAsync(at: item.url)
        }
    }

    func copyLatestScreenshot(on date: Date) {
        guard let item = historySections.first(where: { Calendar.current.isDate($0.date, inSameDayAs: date) })?.items.first else {
            showError("Could not copy — file not found.")
            return
        }
        Task {
            await copyScreenshotAsync(at: item.url)
        }
    }

    /// Stage a row for copy (first tap); deselects if already selected.
    func selectItem(_ item: ScreenshotHistoryItem) {
        withAnimation(.easeInOut(duration: 0.2)) {
            if selectedItem?.id == item.id {
                selectedItem = nil
            } else {
                selectedItem = item
            }
        }
    }

    /// Execute copy after the user confirms (second tap on the green button).
    func confirmCopy(_ item: ScreenshotHistoryItem) {
        copyScreenshot(item)
        selectedItem = nil
    }

    private func showError(_ message: String) {
        errorMessage = message
        // Auto-clear after 3 s so the banner doesn't linger.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            if self?.errorMessage == message { self?.errorMessage = nil }
        }
    }

    func showInFinder(_ item: ScreenshotHistoryItem) {
        guard FileManager.default.fileExists(atPath: item.url.path) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([item.url])
    }

    func deleteScreenshot(_ item: ScreenshotHistoryItem) {
        try? screenshotStore.delete(id: item.id)
        rebuildSections()
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
            Task {
                await refresh()
            }
        }
    }

    /// Reset save location back to the default (~/Pictures/Screenshots).
    func resetToDefaultFolder() {
        screenshotStore.resolver.customFolderURL = nil
        screenshotStore.reloadResolver()
        Task {
            await refresh()
        }
    }

    func refresh() async {
        await screenshotStore.refreshHistory()
        rebuildSections()
    }

    // MARK: - Internal

    func rebuildSections() {
        let items = screenshotStore.screenshots.map { $0.toHistoryItem() }
        let groupedByDay = Dictionary(grouping: items) { item in
            Calendar.current.startOfDay(for: item.date)
        }

        historySections = groupedByDay
            .map { date, dayItems in
                ScreenshotDaySection(
                    date: date,
                    items: dayItems.sorted { $0.date > $1.date }
                )
            }
            .sorted { $0.date > $1.date }

        if browsingByDate { rebuildDateGroup() }
    }

    func toggleDateBrowsing() {
        if browsingByDate {
            browsingByDate = false
        } else {
            selectedDate = Date()
            browsingByDate = true
            rebuildDateGroup()
        }
    }

    func setSelectedDate(_ date: Date) {
        selectedDate = date
        browsingByDate = true
        rebuildDateGroup()
    }

    func rebuildDateGroup() {
        let cal = Calendar.current
        let all = screenshotStore.screenshots.map { $0.toHistoryItem() }
        screenshotsForSelectedDate = all.filter { cal.isDate($0.date, inSameDayAs: selectedDate) }
    }

    func clearDateFilter() {
        browsingByDate = false
    }

    func updateHotkeyDisplay(_ display: String) {
        currentHotkeyDisplay = display
    }

    private func copyScreenshotAsync(at url: URL) async {
        guard let data = await Self.loadImageDataFromDisk(at: url) else {
            showError("Could not copy — file not found or unreadable.")
            return
        }

        writeImageDataToPasteboard(data)
        showCopySuccess()
    }

    nonisolated private static func loadImageDataFromDisk(at url: URL) async -> Data? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                guard FileManager.default.fileExists(atPath: url.path) else {
                    continuation.resume(returning: nil)
                    return
                }

                continuation.resume(returning: try? Data(contentsOf: url))
            }
        }
    }

    private func writeImageDataToPasteboard(_ data: Data) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setData(data, forType: .png)
        pasteboard.writeObjects([item])
    }

    private func showCopySuccess() {
        withAnimation(.easeInOut(duration: 0.3)) {
            showCopyToast = true
        }
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            withAnimation(.easeInOut(duration: 0.3)) {
                showCopyToast = false
            }
        }
    }
}
