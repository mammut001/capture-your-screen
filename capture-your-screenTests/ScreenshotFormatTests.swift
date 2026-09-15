import XCTest
import AppKit
@testable import capture_your_screen

@MainActor
final class ScreenshotFormatTests: XCTestCase {
    func testJPEGPreferenceWritesJPEGAndPublishesMatchingRecord() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let resolver = try makeResolver(for: root)
        let store = ScreenshotStore(
            resolver: resolver,
            saveFormatProvider: { .jpeg }
        )
        defer { store.stopWatchingScreenshotFolder() }

        let record = try await store.save(makeSolidImage())
        let data = try Data(contentsOf: record.url)

        XCTAssertEqual(record.url.pathExtension, "jpg")
        XCTAssertEqual(Array(data.prefix(2)), [0xFF, 0xD8], "JPEG must start with its SOI marker")
        XCTAssertNotNil(NSImage(data: data))
        XCTAssertEqual(store.screenshots.map(\.id), [record.id])
        XCTAssertNotNil(store.thumbnail(for: record.id))
    }

    func testHistoryRefreshRecognizesPNGJPGAndJPEG() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let resolver = try makeResolver(for: root)
        let store = ScreenshotStore(resolver: resolver)
        defer { store.stopWatchingScreenshotFolder() }

        let dayFolder = root.appendingPathComponent("2026-08-04", isDirectory: true)
        try FileManager.default.createDirectory(at: dayFolder, withIntermediateDirectories: true)
        let names = [
            "Screenshot_2026-08-04_09-00-00_001.png",
            "Screenshot_2026-08-04_09-00-00_002.jpg",
            "Screenshot_2026-08-04_09-00-00_003.jpeg"
        ]
        for name in names {
            try Data([0x00]).write(to: dayFolder.appendingPathComponent(name))
        }
        try Data([0x00]).write(
            to: dayFolder.appendingPathComponent("Screenshot_2026-08-04_09-00-00_004.gif")
        )

        await store.refreshHistory()

        XCTAssertEqual(Set(store.screenshots.map { $0.url.pathExtension.lowercased() }), ["png", "jpg", "jpeg"])
        XCTAssertEqual(store.screenshots.count, 3)
    }

    func testSaveFormatPreferenceDefaultsSafely() {
        let suiteName = "ScreenshotFormatTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertEqual(SaveFormat.preferred(in: defaults), .png)
        defaults.set("jpeg", forKey: SaveFormat.preferenceKey)
        XCTAssertEqual(SaveFormat.preferred(in: defaults), .jpeg)
        defaults.set("unsupported", forKey: SaveFormat.preferenceKey)
        XCTAssertEqual(SaveFormat.preferred(in: defaults), .png)
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("cys-format-tests-\(UUID().uuidString)", isDirectory: true)
    }

    private func makeResolver(for root: URL) throws -> StorageResolver {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let storage = MockBookmarkStorage()
        let provider = MockBookmarkProvider()
        let bookmarkData = Data("format-test-bookmark".utf8)
        provider.onCreate = { _ in bookmarkData }
        provider.onResolve = { _ in (root, false) }

        let resolver = StorageResolver(
            defaults: storage,
            bookmarkProvider: provider,
            securityAccess: MockSecurityScopedAccess()
        )
        try resolver.saveBookmark(for: root)
        return resolver
    }

    private func makeSolidImage() -> NSImage {
        let image = NSImage(size: NSSize(width: 64, height: 40))
        image.lockFocus()
        NSColor.systemPurple.setFill()
        NSRect(x: 0, y: 0, width: 64, height: 40).fill()
        image.unlockFocus()
        return image
    }
}
