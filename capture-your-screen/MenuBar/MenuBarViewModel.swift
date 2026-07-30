import Combine
import Foundation
import AppKit
import SwiftUI

@MainActor
final class MenuBarViewModel: ObservableObject {
    @Published var historySections: [ScreenshotDaySection] = []
    /// Flattened header + item rows for the multi-day lazy history list.
    @Published private(set) var historyRows: [HistoryListRow] = []
    @Published var currentHotkeyDisplay: String = HotkeyConfiguration.default.displayString
    @Published var isCapturing: Bool = false
    @Published var errorMessage: String?
    @Published var showCopyToast: Bool = false

    @Published var visibleMonth: Date = Date()
    @Published var selectedDate: Date = Date()
    @Published var appliedDateFilter: Date? = nil

    @Published private(set) var permissionStatus: PermissionStatus = .notDetermined
    /// Mirrors store preview map so cards re-render without rebuilding day sections.
    @Published private(set) var thumbnailsByID: [String: NSImage] = [:]

    private let captureCoordinator: CaptureCoordinator
    private let screenshotStore: ScreenshotStore
    private let hotkeyManager: HotkeyManager
    private var cancellables = Set<AnyCancellable>()
    private let calendar = Calendar.current
    private var lastMembershipSignature: [String] = []
    /// Counts full section rebuilds (tests / diagnostics).
    private(set) var sectionRebuildCount = 0
    private var copyToastTask: Task<Void, Never>?

    init(captureCoordinator: CaptureCoordinator, screenshotStore: ScreenshotStore, hotkeyManager: HotkeyManager) {
        self.captureCoordinator = captureCoordinator
        self.screenshotStore = screenshotStore
        self.hotkeyManager = hotkeyManager
        self.currentHotkeyDisplay = hotkeyManager.currentConfig.displayString
        self.permissionStatus = captureCoordinator.permissionStatus
        let today = Calendar.current.startOfDay(for: Date())
        self.selectedDate = today
        self.visibleMonth = Calendar.current.startOfMonth(for: today)

        hotkeyManager.$currentConfig
            .receive(on: RunLoop.main)
            .sink { [weak self] config in
                self?.currentHotkeyDisplay = config.displayString
            }
            .store(in: &cancellables)

        // Rebuild day sections only when the set of files changes — not per thumbnail.
        screenshotStore.$screenshots
            .receive(on: RunLoop.main)
            .sink { [weak self] records in
                self?.applyScreenshotMembership(records)
            }
            .store(in: &cancellables)

        screenshotStore.$thumbnailsByID
            .receive(on: RunLoop.main)
            .sink { [weak self] thumbs in
                self?.thumbnailsByID = thumbs
            }
            .store(in: &cancellables)

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

        captureCoordinator.$permissionStatus
            .receive(on: RunLoop.main)
            .sink { [weak self] status in
                self?.permissionStatus = status
            }
            .store(in: &cancellables)

        applyScreenshotMembership(screenshotStore.screenshots)
        thumbnailsByID = screenshotStore.thumbnailsByID
        checkMigration()
    }

    // MARK: - Thumbnail Loading

    func thumbnail(for item: ScreenshotHistoryItem) -> NSImage? {
        thumbnailsByID[item.id] ?? screenshotStore.thumbnail(for: item.id)
    }

    func loadThumbnailIfNeeded(for item: ScreenshotHistoryItem) {
        guard thumbnail(for: item) == nil else { return }
        screenshotStore.loadThumbnail(for: item.id)
    }

    // MARK: - Actions

    func startCapture() {
        checkStorageReady()
        refreshPermissionStatus()
        captureCoordinator.startCapture()
    }

    @discardableResult
    func refreshPermissionStatus() -> PermissionStatus {
        let status = captureCoordinator.refreshPermissionStatus()
        permissionStatus = status
        return status
    }

    func openPermissionSettings() {
        captureCoordinator.permissionManager.openScreenRecordingSettings()
    }

    func openScreenshotFolder() {
        guard let folderURL = screenshotStore.resolver.screenshotFolderURL else {
            showError("No folder selected. Please choose a folder in Settings.")
            return
        }

        guard screenshotStore.resolver.securityAccess.startAccessing(folderURL) else {
            showError("Cannot access the screenshot folder. Please re-select it in Settings.")
            return
        }

        let folderFormatter = DateFormatter()
        folderFormatter.dateFormat = "yyyy-MM-dd"
        let dateFolderName = folderFormatter.string(from: Date())
        let todayFolderURL = folderURL.appendingPathComponent(dateFolderName, isDirectory: true)
        let targetURL = FileManager.default.fileExists(atPath: todayFolderURL.path) ? todayFolderURL : folderURL

        if !FileManager.default.fileExists(atPath: targetURL.path) {
            do {
                try FileManager.default.createDirectory(at: targetURL, withIntermediateDirectories: true)
            } catch {
                showError("Could not create folder: \(error.localizedDescription)")
                return
            }
        }

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

    private func showError(_ message: String) {
        errorMessage = message
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            if self?.errorMessage == message { self?.errorMessage = nil }
        }
    }

    func showInFinder(_ item: ScreenshotHistoryItem) {
        guard screenshotStore.resolver.isFileInScreenshotFolder(item.url) else {
            showError("File is not in the screenshots folder.")
            return
        }
        guard FileManager.default.fileExists(atPath: item.url.path) else {
            showError("File not found.")
            return
        }
        guard screenshotStore.resolver.securityAccess.startAccessing(item.url.deletingLastPathComponent()) else {
            showError("Cannot access file location.")
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([item.url])
    }

    func deleteScreenshot(_ item: ScreenshotHistoryItem) {
        do {
            try screenshotStore.delete(id: item.id)
            // Membership publisher will rebuild sections once.
        } catch {
            showError(error.localizedDescription)
        }
    }

    var screenshotFolderDisplay: String {
        guard screenshotStore.resolver.hasValidFolder,
              let url = screenshotStore.resolver.screenshotFolderURL else {
            return "No folder selected"
        }
        return url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }

    func chooseScreenshotFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.message = "Choose a folder to save screenshots.\nYou can point this to iCloud Drive or any other location."

        if let oldPath = screenshotStore.resolver.oldPathString {
            panel.directoryURL = URL(fileURLWithPath: oldPath)
        } else if let currentURL = screenshotStore.resolver.screenshotFolderURL {
            panel.directoryURL = currentURL
        } else {
            let pictures = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first
            panel.directoryURL = pictures
        }

        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            try screenshotStore.resolver.saveBookmark(for: url)
            clearDateFilter()
            screenshotStore.restartWatchingScreenshotFolder()
            objectWillChange.send()
        } catch {
            showError(error.localizedDescription)
        }
    }

    func resetToDefaultFolder() {
        screenshotStore.resolver.clearBookmark()
        chooseScreenshotFolder()
    }

    func refresh() async {
        await screenshotStore.refreshIfNeeded()
        applyScreenshotMembership(screenshotStore.screenshots)
    }

    func refreshIfNeeded() async {
        await screenshotStore.refreshIfNeeded()
        applyScreenshotMembership(screenshotStore.screenshots)
    }

    func forceRefresh() async {
        await screenshotStore.refreshHistory()
        applyScreenshotMembership(screenshotStore.screenshots)
    }

    // MARK: - Calendar / Date Filter

    func moveVisibleMonth(by delta: Int) {
        guard let newMonth = Calendar.current.date(byAdding: .month, value: delta, to: visibleMonth) else { return }
        visibleMonth = Calendar.current.startOfMonth(for: newMonth)
    }

    func selectDate(_ date: Date) {
        selectedDate = calendar.startOfDay(for: date)
        visibleMonth = calendar.startOfMonth(for: selectedDate)
    }

    func applySelectedDateFilter() {
        appliedDateFilter = calendar.startOfDay(for: selectedDate)
    }

    func clearDateFilter() {
        appliedDateFilter = nil
        let today = calendar.startOfDay(for: Date())
        selectedDate = today
        visibleMonth = calendar.startOfMonth(for: today)
    }

    func selectToday() {
        let today = calendar.startOfDay(for: Date())
        selectedDate = today
        visibleMonth = calendar.startOfMonth(for: today)
    }

    func selectYesterday() {
        guard let yesterday = calendar.date(byAdding: .day, value: -1, to: Date()) else { return }
        selectedDate = calendar.startOfDay(for: yesterday)
        visibleMonth = calendar.startOfMonth(for: selectedDate)
    }

    var browsingByDate: Bool {
        appliedDateFilter != nil
    }

    var filteredHistoryItems: [ScreenshotHistoryItem] {
        guard let filterDate = appliedDateFilter else {
            return screenshotStore.screenshots.map { $0.toHistoryItem() }
        }
        return screenshotStore.screenshots
            .filter { calendar.isDate($0.date, inSameDayAs: filterDate) }
            .map { $0.toHistoryItem() }
    }

    var datesWithScreenshots: [Date: Int] {
        var counts: [Date: Int] = [:]
        for record in screenshotStore.screenshots {
            let day = calendar.startOfDay(for: record.date)
            counts[day, default: 0] += 1
        }
        return counts
    }

    // MARK: - Internal

    /// Rebuilds day sections only when membership (ids/order) changes.
    func applyScreenshotMembership(_ records: [ScreenshotRecord]) {
        let signature = HistorySectionBuilder.membershipSignature(for: records)
        guard signature != lastMembershipSignature else { return }
        lastMembershipSignature = signature
        rebuildSections(from: records)
    }

    func rebuildSections() {
        rebuildSections(from: screenshotStore.screenshots)
        lastMembershipSignature = HistorySectionBuilder.membershipSignature(for: screenshotStore.screenshots)
    }

    private func rebuildSections(from records: [ScreenshotRecord]) {
        sectionRebuildCount += 1
        let sections = HistorySectionBuilder.sections(from: records, calendar: calendar)
        historySections = sections
        historyRows = HistorySectionBuilder.flatRows(from: sections)
    }

    func updateHotkeyDisplay(_ display: String) {
        currentHotkeyDisplay = display
    }

    // MARK: - Migration

    private func checkMigration() {
        guard screenshotStore.resolver.hasOldPathData && !screenshotStore.resolver.hasMigrationBeenShown else { return }
        screenshotStore.resolver.markMigrationShown()

        guard let oldPath = screenshotStore.resolver.oldPathString else { return }
        let oldURL = URL(fileURLWithPath: oldPath)
        let exists = FileManager.default.fileExists(atPath: oldPath)

        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self else { return }

            let alert = NSAlert()
            alert.messageText = "Screenshot Folder Access Updated"
            if exists {
                alert.informativeText = "Your previous screenshot folder was \"\(oldPath)\".\n\nTo keep saving screenshots to this location, please confirm it in the folder selection dialog."
            } else {
                alert.informativeText = "Your previous screenshot folder \"\(oldPath)\" was not found.\n\nPlease choose a new folder to save screenshots."
            }
            alert.alertStyle = .informational
            alert.addButton(withTitle: "Select Folder")
            alert.addButton(withTitle: "Cancel")
            NSApp.activate(ignoringOtherApps: true)

            if alert.runModal() == .alertFirstButtonReturn {
                let panel = NSOpenPanel()
                panel.canChooseFiles = false
                panel.canChooseDirectories = true
                panel.allowsMultipleSelection = false
                panel.canCreateDirectories = true
                panel.prompt = "Choose"
                panel.message = "Choose a folder to save screenshots."
                if exists {
                    panel.directoryURL = oldURL
                } else {
                    let pictures = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first
                    panel.directoryURL = pictures
                }

                if panel.runModal() == .OK, let url = panel.url {
                    do {
                        try self.screenshotStore.resolver.saveBookmark(for: url)
                        self.screenshotStore.resolver.clearOldPathData()
                        self.screenshotStore.restartWatchingScreenshotFolder()
                        self.objectWillChange.send()
                    } catch {
                        self.showError(error.localizedDescription)
                    }
                }
            } else {
                self.screenshotStore.resolver.clearOldPathData()
            }
        }
    }

    private func checkStorageReady() {
        if !screenshotStore.resolver.hasValidFolder {
            showError("Please select a screenshot folder in Settings before capturing.")
        }
    }

    private func copyScreenshotAsync(at url: URL) async {
        guard screenshotStore.resolver.securityAccess.startAccessing(url.deletingLastPathComponent()) else {
            showError("Could not copy — file access denied.")
            return
        }

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
        copyToastTask?.cancel()
        withAnimation(.easeInOut(duration: 0.3)) {
            showCopyToast = true
        }
        copyToastTask = Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.3)) {
                showCopyToast = false
            }
        }
    }
}

extension Calendar {
    func startOfMonth(for date: Date) -> Date {
        let components = dateComponents([.year, .month], from: date)
        return self.date(from: components) ?? date
    }
}
