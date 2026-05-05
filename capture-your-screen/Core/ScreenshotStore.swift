import Combine
import Foundation
import AppKit
import CoreGraphics

struct ScreenshotRecord: Identifiable, Hashable {
    let id: String          // filename (unique key)
    let url: URL            // full file URL
    let date: Date          // capture timestamp parsed from filename
    var thumbnail: NSImage? // lazy-loaded thumbnail; nil until loaded

    func hash(into hasher: inout Hasher) { hasher.combine(id) }
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
}

@MainActor
final class ScreenshotStore: ObservableObject {
    @Published private(set) var screenshots: [ScreenshotRecord] = []

    var resolver = StorageResolver()

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

    // MARK: - Save

    /// Persist an NSImage to disk; returns the saved record.
    /// File I/O is performed on a background thread to avoid blocking the main actor.
    func save(_ image: NSImage) async throws -> ScreenshotRecord {
        print("ScreenshotStore: Attempting to save image to resolver path...")
        try resolver.ensureFolderExists()
        let folderURL = resolver.screenshotFolderURL

        let now = Date()
        
        let folderFormatter = DateFormatter()
        folderFormatter.dateFormat = "yyyy-MM-dd"
        let dateFolderName = folderFormatter.string(from: now)
        let dateFolderURL = folderURL.appendingPathComponent(dateFolderName, isDirectory: true)
        
        print("ScreenshotStore: Targeted folder: \(dateFolderURL.path)")
        try FileManager.default.createDirectory(at: dateFolderURL, withIntermediateDirectories: true)
        
        let filename = "Screenshot_\(dateFormatter.string(from: now)).png"
        let fileURL = dateFolderURL.appendingPathComponent(filename)

        guard let pngData = pngData(from: image) else {
            print("ScreenshotStore: FAILED to encode image to PNG data.")
            throw ScreenshotStoreError.imageEncodingFailed
        }

        print("ScreenshotStore: Writing data to disk (\(pngData.count) bytes)...")
        try await Task.detached(priority: .userInitiated) {
            try pngData.write(to: fileURL, options: .atomic)
        }.value

        print("ScreenshotStore: Successfully wrote \(filename)")

        let record = ScreenshotRecord(
            id: filename,
            url: fileURL,
            date: now,
            thumbnail: makeThumbnail(from: image)
        )
        screenshots.insert(record, at: 0)
        return record
    }

    private var thumbnailTasks: [String: Task<Void, Never>] = [:]

    // MARK: - Lazy Thumbnail Loading

    /// Load a thumbnail on demand. Calls are deduplicated per id, and all exit paths
    /// remove the corresponding task so future appearances can retry after a failure.
    func loadThumbnail(for id: String) {
        guard let record = screenshots.first(where: { $0.id == id }) else {
            print("ScreenshotStore: no record found for thumbnail id \(id)")
            return
        }
        guard record.thumbnail == nil else {
            return
        }
        guard thumbnailTasks[id] == nil else {
            return
        }

        let fileURL = record.url
        let task = Task(priority: .utility) { [weak self, fileURL] in
            let image = await Self.loadImageFromDisk(at: fileURL)

            guard !Task.isCancelled else {
                await self?.finishThumbnailLoad(for: id)
                return
            }

            guard let image else {
                print("ScreenshotStore: failed to load thumbnail source at \(fileURL.path)")
                await self?.finishThumbnailLoad(for: id)
                return
            }

            let thumbnail = await Self.makeThumbnailStatic(from: image)

            guard !Task.isCancelled else {
                await self?.finishThumbnailLoad(for: id)
                return
            }

            await self?.finishThumbnailLoad(for: id, thumbnail: thumbnail)
        }

        thumbnailTasks[id] = task
    }

    private func finishThumbnailLoad(for id: String, thumbnail: NSImage? = nil) {
        thumbnailTasks.removeValue(forKey: id)

        guard let thumbnail else { return }

        guard let index = screenshots.firstIndex(where: { $0.id == id }) else {
            print("ScreenshotStore: record \(id) disappeared before thumbnail update")
            return
        }
        guard screenshots[index].thumbnail == nil else { return }

        var updated = screenshots
        updated[index].thumbnail = thumbnail
        screenshots = updated
    }

    private func cancelThumbnailTask(for id: String) {
        thumbnailTasks[id]?.cancel()
        thumbnailTasks.removeValue(forKey: id)
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
    /// Thumbnails are NOT pre-loaded — call `loadThumbnail(for:)` on demand instead.
    func refreshHistory() async {
        cancelAllThumbnailTasks()

        let folderURL = resolver.screenshotFolderURL
        let fm = FileManager.default

        // If the folder doesn't exist yet, just clear the list and bail.
        guard fm.fileExists(atPath: folderURL.path) else {
            screenshots = []
            return
        }

        // Parse records on a background thread — no thumbnail loading here
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
                return ScreenshotRecord(id: filename, url: url, date: date, thumbnail: nil)
            }
            .sorted { $0.date > $1.date }
        }.value

        screenshots = records
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
        cancelThumbnailTask(for: id)

        try FileManager.default.removeItem(at: record.url)
        screenshots.removeAll { $0.id == id }
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
