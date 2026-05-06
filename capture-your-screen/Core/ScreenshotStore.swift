import Combine
import Foundation
import AppKit
import CoreGraphics

struct ScreenshotRecord: Identifiable, Hashable {
    let id: String
    let url: URL
    let date: Date
    var thumbnail: NSImage?

    var filename: String { url.lastPathComponent }

    nonisolated init(url: URL, date: Date, thumbnail: NSImage? = nil) {
        let standardizedURL = url.standardizedFileURL
        self.id = standardizedURL.path
        self.url = standardizedURL
        self.date = date
        self.thumbnail = thumbnail
    }

    func hash(into hasher: inout Hasher) { hasher.combine(url.standardizedFileURL.path) }
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.url.standardizedFileURL.path == rhs.url.standardizedFileURL.path
    }
}

@MainActor
final class ScreenshotStore: ObservableObject {
    @Published private(set) var screenshots: [ScreenshotRecord] = []

    var resolver = StorageResolver()
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

    /// Call this when the custom folder preference changes so the resolver re-reads UserDefaults.
    /// (StorageResolver reads UserDefaults on every property access, so this is mostly for symmetry.)
    func reloadResolver() {
        objectWillChange.send()
    }

    init() {
        folderWatcher.onChange = { [weak self] in
            Task { @MainActor [weak self] in
                self?.scheduleRefreshHistory()
            }
        }
    }

    // MARK: - Save

    /// Persist an NSImage to disk; returns the saved record.
    /// File I/O is performed on a background thread to avoid blocking the main actor.
    func save(_ image: NSImage) async throws -> ScreenshotRecord {
        try resolver.ensureFolderExists()
        let folderURL = resolver.screenshotFolderURL

        let now = Date()
        
        let folderFormatter = DateFormatter()
        folderFormatter.dateFormat = "yyyy-MM-dd"
        let dateFolderName = folderFormatter.string(from: now)
        let dateFolderURL = folderURL.appendingPathComponent(dateFolderName, isDirectory: true)
        
        try FileManager.default.createDirectory(at: dateFolderURL, withIntermediateDirectories: true)
        
        let filename = "Screenshot_\(dateFormatter.string(from: now)).png"
        let fileURL = dateFolderURL.appendingPathComponent(filename)

        guard let pngData = pngData(from: image) else {
            throw ScreenshotStoreError.imageEncodingFailed
        }

        try await Task.detached(priority: .userInitiated) {
            try pngData.write(to: fileURL, options: .atomic)
        }.value

        let thumbnail = makeThumbnail(from: image)
        let record = ScreenshotRecord(url: fileURL, date: now, thumbnail: thumbnail)
        thumbnailCache[thumbnailCacheKey(for: record.url)] = thumbnail
        screenshots.insert(record, at: 0)
        startWatchingScreenshotFolder()
        return record
    }

    private var thumbnailTasks: [String: Task<Void, Never>] = [:]
    private var thumbnailCache: [String: NSImage] = [:]

    // MARK: - Cache Key

    private func thumbnailCacheKey(for url: URL) -> String {
        url.standardizedFileURL.path
    }

    // MARK: - Lazy Thumbnail Loading

    /// Load a thumbnail on demand. Calls are deduplicated per id, and all exit paths
    /// remove the corresponding task so future appearances can retry after a failure.
    /// Thumbnails are cached by file path — closing and reopening the menu preserves
    /// already-loaded thumbnails without re-reading the disk.
    func loadThumbnail(for id: String) {
        guard let record = screenshots.first(where: { $0.id == id }) else {
            return
        }
        let key = thumbnailCacheKey(for: record.url)

        if let existingThumbnail = record.thumbnail {
            thumbnailCache[key] = existingThumbnail
            return
        }

        if let cachedThumbnail = thumbnailCache[key] {
            updateThumbnail(cachedThumbnail, forKey: key)
            return
        }

        guard thumbnailTasks[key] == nil else {
            return
        }

        let fileURL = record.url
        let task = Task(priority: .utility) { [weak self, fileURL, key] in
            let image = await Self.loadImageFromDisk(at: fileURL)

            guard !Task.isCancelled else {
                self?.clearThumbnailTask(forKey: key)
                return
            }

            guard let image else {
                self?.clearThumbnailTask(forKey: key)
                return
            }

            let thumbnail = Self.makeThumbnailStatic(from: image)

            guard !Task.isCancelled else {
                self?.clearThumbnailTask(forKey: key)
                return
            }

            self?.finishThumbnailLoad(cacheKey: key, thumbnail: thumbnail)
        }

        thumbnailTasks[key] = task
    }

    private func updateThumbnail(_ thumbnail: NSImage, forKey key: String) {
        guard let index = screenshots.firstIndex(where: { thumbnailCacheKey(for: $0.url) == key }) else {
            return
        }

        guard screenshots[index].thumbnail == nil || screenshots[index].thumbnail !== thumbnail else { return }

        var updated = screenshots
        updated[index].thumbnail = thumbnail
        screenshots = updated
    }

    private func finishThumbnailLoad(cacheKey key: String, thumbnail: NSImage) {
        clearThumbnailTask(forKey: key)
        thumbnailCache[key] = thumbnail
        updateThumbnail(thumbnail, forKey: key)
    }

    private func clearThumbnailTask(forKey key: String) {
        thumbnailTasks[key]?.cancel()
        thumbnailTasks.removeValue(forKey: key)
    }

    private func cancelAllThumbnailTasks() {
        for task in thumbnailTasks.values {
            task.cancel()
        }
        thumbnailTasks.removeAll()
    }

    // MARK: - History

    /// Rebuild screenshot history. Disk I/O runs in background; thumbnail rendering is
    /// dispatched to the main thread via `MainActor.run` because `lockFocus` requires it.
    /// Thumbnails are restored from the in-memory thumbnailCache so previously-loaded
    /// thumbnails survive a menu close/open cycle without re-reading the disk.
    func refreshHistory() async {
        for record in screenshots {
            guard let thumbnail = record.thumbnail else { continue }
            thumbnailCache[thumbnailCacheKey(for: record.url)] = thumbnail
        }

        lastRefreshAt = Date()

        cancelAllThumbnailTasks()

        let folderURL = resolver.screenshotFolderURL
        let fm = FileManager.default

        guard fm.fileExists(atPath: folderURL.path) else {
            screenshots = []
            thumbnailCache.removeAll()
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

        let restoredRecords = records.map { record in
            var updatedRecord = record
            let key = thumbnailCacheKey(for: record.url)
            updatedRecord.thumbnail = thumbnailCache[key]
            return updatedRecord
        }

        let activeKeys = Set(records.map { thumbnailCacheKey(for: $0.url) })
        thumbnailCache = thumbnailCache.filter { activeKeys.contains($0.key) }

        screenshots = restoredRecords
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
        let folderURL = resolver.screenshotFolderURL.standardizedFileURL
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
        guard let record = screenshots.first(where: { $0.id == id }),
              let image = NSImage(contentsOf: record.url) else {
            throw ScreenshotStoreError.fileNotFound
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([image])
    }

    func delete(id: String) throws {
        guard let record = screenshots.first(where: { $0.id == id }) else {
            throw ScreenshotStoreError.fileNotFound
        }
        // Defense-in-depth: ensure the target file is inside the designated screenshots folder
        let folderURL = resolver.screenshotFolderURL.standardized
        guard record.url.standardized.path.hasPrefix(folderURL.path + "/") else {
            throw ScreenshotStoreError.fileNotFound
        }
        let key = thumbnailCacheKey(for: record.url)
        clearThumbnailTask(forKey: key)
        thumbnailCache.removeValue(forKey: key)

        try FileManager.default.removeItem(at: record.url)
        screenshots.removeAll { thumbnailCacheKey(for: $0.url) == key }
    }

    // MARK: - Helpers

    private func pngData(from image: NSImage) -> Data? {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }
        let rep = NSBitmapImageRep(cgImage: cgImage)
        return rep.representation(using: .png, properties: [:])
    }

    nonisolated private static func loadImageFromDisk(at url: URL) async -> NSImage? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                guard FileManager.default.fileExists(atPath: url.path) else {
                    continuation.resume(returning: nil)
                    return
                }

                continuation.resume(returning: NSImage(contentsOf: url))
            }
        }
    }

    private func makeThumbnail(from image: NSImage) -> NSImage {
        Self.makeThumbnailStatic(from: image)
    }

    @MainActor
    private static func makeThumbnailStatic(from image: NSImage) -> NSImage {
        let targetSize = NSSize(width: 420, height: 240)
        let thumb = NSImage(size: targetSize)
        thumb.lockFocus()
        NSColor.clear.set()
        NSRect(origin: .zero, size: targetSize).fill()
        image.draw(
            in: aspectFitRect(for: image.size, in: NSRect(origin: .zero, size: targetSize)),
            from: .zero,
            operation: .copy,
            fraction: 1.0
        )
        thumb.unlockFocus()
        return thumb
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

enum ScreenshotStoreError: Error, LocalizedError {
    case imageEncodingFailed
    case fileNotFound

    var errorDescription: String? {
        switch self {
        case .imageEncodingFailed: return "Failed to encode the screenshot as PNG."
        case .fileNotFound: return "Screenshot file not found."
        }
    }
}
