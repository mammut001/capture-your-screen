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
        try resolver.ensureFolderExists()
        let folderURL = resolver.screenshotFolderURL

        let now = Date()
        
        // Create a sub-folder for today's date
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

        // Write to disk on a background thread so the main actor is never blocked.
        try await Task.detached(priority: .userInitiated) {
            try pngData.write(to: fileURL, options: .atomic)
        }.value

        let record = ScreenshotRecord(
            id: filename,
            url: fileURL,
            date: now,
            thumbnail: makeThumbnail(from: image)
        )
        screenshots.insert(record, at: 0)
        return record
    }

    // MARK: - History

    /// Scan the screenshot folder and rebuild the history list.
    func refreshHistory() async {
        let folderURL = resolver.screenshotFolderURL
        let fm = FileManager.default

        guard let contents = try? fm.contentsOfDirectory(
            at: folderURL,
            includingPropertiesForKeys: [.creationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        // Parse records on a background thread
        let formatter = dateFormatter
        let records: [ScreenshotRecord] = await Task.detached(priority: .utility) {
            var foundURLs: [URL] = []
            if let enumerator = fm.enumerator(at: folderURL, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
                for case let url as URL in enumerator {
                    if url.pathExtension.lowercased() == "png" {
                        foundURLs.append(url)
                    }
                }
            }
            
            return foundURLs.compactMap { url in
                guard url.pathExtension.lowercased() == "png" else { return nil }
                let filename = url.lastPathComponent
                let datePart = filename
                    .replacingOccurrences(of: "Screenshot_", with: "")
                    .replacingOccurrences(of: ".png", with: "")
                guard let date = formatter.date(from: datePart) else { return nil }
                return ScreenshotRecord(id: filename, url: url, date: date, thumbnail: nil)
            }
            .sorted { $0.date > $1.date }
        }.value

        // Load thumbnails on a background thread (reading many files off main)
        var recordsWithThumbs = records
        await Task.detached(priority: .utility) {
            for i in recordsWithThumbs.indices {
                if let image = NSImage(contentsOf: recordsWithThumbs[i].url) {
                    recordsWithThumbs[i].thumbnail = ScreenshotStore.makeThumbnailStatic(from: image)
                }
            }
        }.value

        screenshots = recordsWithThumbs
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

    private func makeThumbnail(from image: NSImage) -> NSImage {
        Self.makeThumbnailStatic(from: image)
    }

    /// Static version so it can be called from a detached Task (no actor isolation needed).
    nonisolated static func makeThumbnailStatic(from image: NSImage) -> NSImage {
        let targetSize = NSSize(width: 60, height: 60)
        let thumb = NSImage(size: targetSize, flipped: false) { rect in
            image.draw(in: rect, from: .zero, operation: .copy, fraction: 1.0)
            return true
        }
        return thumb
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
