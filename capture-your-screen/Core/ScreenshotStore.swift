import Combine
import Foundation
import AppKit
import CoreGraphics
import ImageIO

struct ScreenshotRecord: Identifiable, Hashable {
    let id: String
    let url: URL
    let date: Date

    var filename: String { url.lastPathComponent }

    nonisolated init(url: URL, date: Date) {
        let standardizedURL = url.standardizedFileURL
        self.id = standardizedURL.path
        self.url = standardizedURL
        self.date = date
    }

    func hash(into hasher: inout Hasher) { hasher.combine(url.standardizedFileURL.path) }
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.url.standardizedFileURL.path == rhs.url.standardizedFileURL.path
    }
}

@MainActor
final class ScreenshotStore: ObservableObject {
    /// Metadata-only list (ids/urls/dates). Thumbnail pixels live in `thumbnailsByID`.
    @Published private(set) var screenshots: [ScreenshotRecord] = []
    /// Lazy preview images keyed by record id (standardized path).
    @Published private(set) var thumbnailsByID: [String: NSImage] = [:]

    let resolver = StorageResolver()
    private let folderWatcher = FolderWatcher()
    private var scheduledRefreshTask: Task<Void, Never>?
    private let refreshInterval: TimeInterval = 1.5
    private var hasLoadedHistory = false
    private var lastRefreshAt: Date?

    private let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd_HH-mm-ss_SSS"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    /// Max concurrent disk→thumbnail jobs (visible cards still request lazily).
    private let maxConcurrentThumbnailLoads = 3
    private var activeThumbnailLoads = 0
    private var pendingThumbnailIDs: [String] = []

    init() {
        folderWatcher.onChange = { [weak self] in
            Task { @MainActor [weak self] in
                self?.scheduleRefreshHistory()
            }
        }
    }

    // MARK: - Save

    func save(_ image: NSImage) async throws -> ScreenshotRecord {
        let folderURL = try resolver.prepareFolder()

        let now = Date()

        let folderFormatter = DateFormatter()
        folderFormatter.dateFormat = "yyyy-MM-dd"
        let dateFolderName = folderFormatter.string(from: now)
        let dateFolderURL = folderURL.appendingPathComponent(dateFolderName, isDirectory: true)

        try FileManager.default.createDirectory(at: dateFolderURL, withIntermediateDirectories: true)

        let filename = "Screenshot_\(dateFormatter.string(from: now)).png"
        let fileURL = dateFolderURL.appendingPathComponent(filename)

        guard let pngData = pngData(from: image) else {
            throw StorageError.imageEncodingFailed
        }

        try await Task.detached(priority: .userInitiated) {
            try pngData.write(to: fileURL, options: .atomic)
        }.value

        let thumbnail = await Task.detached(priority: .utility) {
            Self.makeThumbnailStatic(from: image)
        }.value

        let record = ScreenshotRecord(url: fileURL, date: now)
        let key = thumbnailCacheKey(for: record.url)
        publishThumbnail(thumbnail, forKey: key)
        screenshots.insert(record, at: 0)
        startWatchingScreenshotFolder()
        return record
    }

    private var thumbnailTasks: [String: Task<Void, Never>] = [:]

    // MARK: - Cache Key

    private func thumbnailCacheKey(for url: URL) -> String {
        url.standardizedFileURL.path
    }

    func thumbnail(for id: String) -> NSImage? {
        thumbnailsByID[id]
    }

    // MARK: - Lazy Thumbnail Loading

    func loadThumbnail(for id: String) {
        guard let record = screenshots.first(where: { $0.id == id }) else {
            return
        }
        let key = thumbnailCacheKey(for: record.url)

        if thumbnailsByID[key] != nil {
            return
        }

        guard thumbnailTasks[key] == nil else {
            return
        }

        guard resolver.securityAccess.isAccessing
                || resolver.securityAccess.startAccessing(record.url.deletingLastPathComponent()) else {
            return
        }

        if activeThumbnailLoads >= maxConcurrentThumbnailLoads {
            if !pendingThumbnailIDs.contains(id) {
                pendingThumbnailIDs.append(id)
            }
            return
        }

        startThumbnailTask(for: record, key: key)
    }

    private func startThumbnailTask(for record: ScreenshotRecord, key: String) {
        activeThumbnailLoads += 1
        let fileURL = record.url
        let task = Task.detached(priority: .utility) { [weak self, fileURL, key] in
            let thumbnail = Self.loadThumbnailFromDisk(at: fileURL)

            await MainActor.run {
                guard let self else { return }
                guard !Task.isCancelled else {
                    self.finishThumbnailTaskSlot(forKey: key)
                    return
                }
                if let thumbnail {
                    self.finishThumbnailLoad(cacheKey: key, thumbnail: thumbnail)
                } else {
                    self.finishThumbnailTaskSlot(forKey: key)
                }
            }
        }

        thumbnailTasks[key] = task
    }

    /// Updates only the thumbnail map — never rewrites `screenshots`.
    private func publishThumbnail(_ thumbnail: NSImage, forKey key: String) {
        if thumbnailsByID[key] === thumbnail { return }
        thumbnailsByID = HistorySectionBuilder.applyingThumbnail(thumbnail, for: key, to: thumbnailsByID)
    }

    private func finishThumbnailLoad(cacheKey key: String, thumbnail: NSImage) {
        publishThumbnail(thumbnail, forKey: key)
        finishThumbnailTaskSlot(forKey: key)
    }

    private func finishThumbnailTaskSlot(forKey key: String) {
        thumbnailTasks[key] = nil
        activeThumbnailLoads = max(0, activeThumbnailLoads - 1)
        drainPendingThumbnailLoads()
    }

    private func clearThumbnailTask(forKey key: String) {
        guard thumbnailTasks[key] != nil else { return }
        thumbnailTasks[key]?.cancel()
        thumbnailTasks[key] = nil
        activeThumbnailLoads = max(0, activeThumbnailLoads - 1)
        pendingThumbnailIDs.removeAll { id in
            screenshots.first(where: { $0.id == id }).map { thumbnailCacheKey(for: $0.url) } == key
        }
    }

    private func cancelAllThumbnailTasks() {
        for task in thumbnailTasks.values {
            task.cancel()
        }
        thumbnailTasks.removeAll()
        pendingThumbnailIDs.removeAll()
        activeThumbnailLoads = 0
    }

    private func drainPendingThumbnailLoads() {
        while activeThumbnailLoads < maxConcurrentThumbnailLoads, !pendingThumbnailIDs.isEmpty {
            let nextID = pendingThumbnailIDs.removeFirst()
            guard let record = screenshots.first(where: { $0.id == nextID }) else { continue }
            let key = thumbnailCacheKey(for: record.url)
            if thumbnailsByID[key] != nil { continue }
            if thumbnailTasks[key] != nil { continue }
            startThumbnailTask(for: record, key: key)
        }
    }

    // MARK: - History

    func refreshHistory() async {
        lastRefreshAt = Date()

        cancelAllThumbnailTasks()

        guard resolver.hasValidFolder, let folderURL = resolver.screenshotFolderURL else {
            screenshots = []
            thumbnailsByID = [:]
            hasLoadedHistory = true
            folderWatcher.stop()
            resolver.securityAccess.stopAll()
            return
        }

        guard resolver.securityAccess.startAccessing(folderURL) else {
            screenshots = []
            thumbnailsByID = [:]
            hasLoadedHistory = true
            folderWatcher.stop()
            return
        }

        let fm = FileManager.default

        guard fm.fileExists(atPath: folderURL.path) else {
            screenshots = []
            thumbnailsByID = [:]
            hasLoadedHistory = true
            folderWatcher.stop()
            return
        }

        let formatter = dateFormatter
        let records: [ScreenshotRecord] = await Task.detached(priority: .utility) {
            var foundURLs: [URL] = []
            let enumerator = fm.enumerator(
                at: folderURL,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            )

            while let url = enumerator?.nextObject() as? URL {
                if url.pathExtension.lowercased() == "png" {
                    foundURLs.append(url)
                }
            }

            return foundURLs.compactMap { url in
                let filename = url.lastPathComponent
                let datePart = filename
                    .replacingOccurrences(of: "Screenshot_", with: "")
                    .replacingOccurrences(of: ".png", with: "")
                guard let date = formatter.date(from: datePart) else { return nil }
                return ScreenshotRecord(url: url, date: date)
            }
            .sorted { $0.date > $1.date }
        }.value

        let activeKeys = Set(records.map { thumbnailCacheKey(for: $0.url) })
        let pruned = thumbnailsByID.filter { activeKeys.contains($0.key) }
        if pruned.count != thumbnailsByID.count {
            thumbnailsByID = pruned
        }

        // Only republish list when membership/order changes — not when thumbnails change.
        if !HistorySectionBuilder.membershipEquals(screenshots, records) {
            screenshots = records
        }
        hasLoadedHistory = true
        startWatchingScreenshotFolder(forceRestart: true)
    }

    func refreshIfNeeded() async {
        guard hasLoadedHistory,
              let lastRefreshAt,
              Date().timeIntervalSince(lastRefreshAt) < refreshInterval else {
            await refreshHistory()
            return
        }
    }

    func refreshHistoryIfNeeded(maxAge: TimeInterval = 5) async {
        guard hasLoadedHistory,
              let lastRefreshAt,
              Date().timeIntervalSince(lastRefreshAt) < maxAge else {
            await refreshHistory()
            return
        }
    }

    func startWatchingScreenshotFolder(forceRestart: Bool = false) {
        guard let folderURL = resolver.screenshotFolderURL?.standardizedFileURL else { return }

        guard resolver.securityAccess.startAccessing(folderURL) else { return }

        if !forceRestart,
           folderWatcher.isWatching,
           folderWatcher.watchedFolderURL == folderURL {
            return
        }

        folderWatcher.start(watching: folderURL)
    }

    func restartWatchingScreenshotFolder() {
        scheduledRefreshTask?.cancel()
        scheduledRefreshTask = nil
        folderWatcher.stop()
        startWatchingScreenshotFolder(forceRestart: true)
        scheduleRefreshHistory(immediate: true)
    }

    func stopWatchingScreenshotFolder() {
        scheduledRefreshTask?.cancel()
        scheduledRefreshTask = nil
        folderWatcher.stop()
    }

    private func scheduleRefreshHistory(immediate: Bool = false) {
        scheduledRefreshTask?.cancel()

        let delayNanoseconds: UInt64 = immediate ? 0 : 300_000_000
        scheduledRefreshTask = Task { [weak self] in
            if delayNanoseconds > 0 {
                try? await Task.sleep(nanoseconds: delayNanoseconds)
            }
            guard !Task.isCancelled else { return }
            await self?.refreshHistory()
        }
    }

    // MARK: - Actions

    func copyToClipboard(id: String) throws {
        guard let record = screenshots.first(where: { $0.id == id }) else {
            throw StorageError.fileNotFound
        }
        guard resolver.isFileInScreenshotFolder(record.url) else {
            throw StorageError.fileNotInScreenshotDirectory
        }
        guard resolver.securityAccess.startAccessing(record.url.deletingLastPathComponent()) else {
            throw StorageError.securityScopedAccessDenied
        }
        guard let image = NSImage(contentsOf: record.url) else {
            throw StorageError.fileReadFailed(CocoaError(.fileReadUnknown))
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([image])
    }

    func delete(id: String) throws {
        guard let record = screenshots.first(where: { $0.id == id }) else {
            throw StorageError.fileNotFound
        }
        guard resolver.isFileInScreenshotFolder(record.url) else {
            throw StorageError.fileNotInScreenshotDirectory
        }
        guard resolver.securityAccess.startAccessing(record.url.deletingLastPathComponent()) else {
            throw StorageError.securityScopedAccessDenied
        }
        let key = thumbnailCacheKey(for: record.url)
        clearThumbnailTask(forKey: key)
        var nextThumbs = thumbnailsByID
        nextThumbs.removeValue(forKey: key)
        thumbnailsByID = nextThumbs

        try FileManager.default.removeItem(at: record.url)
        screenshots.removeAll { thumbnailCacheKey(for: $0.url) == key }
    }

    // MARK: - Test / internal hooks

    /// Installs a metadata-only list without touching thumbnails (unit tests).
    func replaceScreenshotsForTesting(_ records: [ScreenshotRecord]) {
        screenshots = records
    }

    /// Applies one thumbnail the same way production load completion does (unit tests).
    func applyThumbnailForTesting(_ image: NSImage, id: String) {
        finishThumbnailLoad(cacheKey: id, thumbnail: image)
    }

    var screenshotsPublishCountForTesting: Int { _screenshotsPublishCount }
    var thumbnailsPublishCountForTesting: Int { _thumbnailsPublishCount }

    private var _screenshotsPublishCount = 0
    private var _thumbnailsPublishCount = 0
    private var didInstallPublishCounters = false

    func installPublishCountersForTesting() {
        guard !didInstallPublishCounters else { return }
        didInstallPublishCounters = true
        $screenshots
            .sink { [weak self] _ in self?._screenshotsPublishCount += 1 }
            .store(in: &testingCancellables)
        $thumbnailsByID
            .sink { [weak self] _ in self?._thumbnailsPublishCount += 1 }
            .store(in: &testingCancellables)
        // Reset after initial subscription emissions.
        _screenshotsPublishCount = 0
        _thumbnailsPublishCount = 0
    }

    private var testingCancellables = Set<AnyCancellable>()

    // MARK: - Helpers

    private func pngData(from image: NSImage) -> Data? {
        ScreenshotEncoding.pngData(from: image)
    }

    /// ImageIO thumbnail — avoids decoding full-resolution PNG on the main actor.
    nonisolated static func loadThumbnailFromDisk(at url: URL, maxPixelSize: CGFloat = 420) -> NSImage? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: Int(max(1, maxPixelSize)),
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true
        ]

        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }

    nonisolated static func makeThumbnailStatic(from image: NSImage) -> NSImage {
        let targetWidth = 420
        let targetHeight = 240
        let targetSize = NSSize(width: targetWidth, height: targetHeight)
        let fit = aspectFitRect(for: image.size, in: NSRect(origin: .zero, size: targetSize))

        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return image
        }

        guard let cgContext = CGContext(
            data: nil,
            width: targetWidth,
            height: targetHeight,
            bitsPerComponent: 8,
            bytesPerRow: targetWidth * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return image
        }

        // Clear to transparent
        cgContext.clear(CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))

        // CoreGraphics origin is bottom-left; flip the fit rect vertically
        let flippedRect = CGRect(
            x: fit.origin.x,
            y: CGFloat(targetHeight) - fit.origin.y - fit.height,
            width: fit.width,
            height: fit.height
        )
        cgContext.draw(cgImage, in: flippedRect)

        guard let resultImage = cgContext.makeImage() else {
            return image
        }

        return NSImage(cgImage: resultImage, size: targetSize)
    }

    nonisolated private static func aspectFitRect(for sourceSize: NSSize, in bounds: NSRect) -> NSRect {
        guard sourceSize.width > 0, sourceSize.height > 0 else { return bounds }

        let widthRatio = bounds.width / sourceSize.width
        let heightRatio = bounds.height / sourceSize.height
        let scale = min(widthRatio, heightRatio)

        let drawSize = NSSize(width: sourceSize.width * scale, height: sourceSize.height * scale)
        let origin = NSPoint(
            x: bounds.midX - (drawSize.width / 2),
            y: bounds.midY - (drawSize.height / 2)
        )
        return NSRect(origin: origin, size: drawSize)
    }
}
