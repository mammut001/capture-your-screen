import XCTest
import AppKit
import Combine
@testable import capture_your_screen

@MainActor
final class HistoryRefreshRaceTests: XCTestCase {
    func testOlderScanCannotReplaceNewerScan() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let loader = PausedHistoryLoader()
        let store = ScreenshotStore(resolver: try makeResolver(for: root), historyLoader: loader.load)
        defer { store.stopWatchingScreenshotFolder() }

        let firstStarted = expectation(description: "First directory scan started")
        loader.onStart = { firstStarted.fulfill() }
        let first = Task { await store.refreshHistory() }
        await fulfillment(of: [firstStarted], timeout: 2)

        let secondStarted = expectation(description: "Second directory scan started")
        loader.onStart = { secondStarted.fulfill() }
        let second = Task { await store.refreshHistory() }
        await fulfillment(of: [secondStarted], timeout: 2)

        let newest = record(in: root, name: "new.png")
        loader.complete(1, with: [newest])
        await second.value
        loader.complete(0, with: [record(in: root, name: "old.png")])
        await first.value

        XCTAssertEqual(store.screenshots.map(\.id), [newest.id])
    }

    func testFolderSwitchRejectsPreviousFoldersScan() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let otherFolder = root.appendingPathComponent("other", isDirectory: true)
        try FileManager.default.createDirectory(at: otherFolder, withIntermediateDirectories: true)
        let resolver = try makeResolver(for: root)
        let loader = PausedHistoryLoader()
        let store = ScreenshotStore(resolver: resolver, historyLoader: loader.load)
        defer { store.stopWatchingScreenshotFolder() }

        let started = expectation(description: "Old folder scan started")
        loader.onStart = { started.fulfill() }
        let scan = Task { await store.refreshHistory() }
        await fulfillment(of: [started], timeout: 2)
        try resolver.saveBookmark(for: otherFolder)
        loader.complete(0, with: [record(in: root, name: "old.png")])
        await scan.value

        XCTAssertTrue(store.screenshots.isEmpty)
    }

    func testCancelledScanDoesNotPublishResults() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let loader = PausedHistoryLoader()
        let store = ScreenshotStore(resolver: try makeResolver(for: root), historyLoader: loader.load)
        defer { store.stopWatchingScreenshotFolder() }

        let started = expectation(description: "Directory scan started")
        loader.onStart = { started.fulfill() }
        let scan = Task { await store.refreshHistory() }
        await fulfillment(of: [started], timeout: 2)
        scan.cancel()
        loader.complete(0, with: [record(in: root, name: "cancelled.png")])
        await scan.value

        XCTAssertTrue(store.screenshots.isEmpty)
    }

    func testOlderScanCannotRemoveNewlySavedScreenshot() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let loader = PausedHistoryLoader()
        let store = ScreenshotStore(
            resolver: try makeResolver(for: root),
            saveFormatProvider: { .png },
            historyLoader: loader.load
        )
        defer { store.stopWatchingScreenshotFolder() }

        let started = expectation(description: "Scan of initially empty folder started")
        loader.onStart = { started.fulfill() }
        let scan = Task { await store.refreshHistory() }
        await fulfillment(of: [started], timeout: 2)

        let existing = record(in: root, name: "existing.png")
        let replacementStarted = expectation(description: "Fresh scan started after save invalidated initial scan")
        loader.onStart = { replacementStarted.fulfill() }
        let saved = try await store.save(makeImage())
        await fulfillment(of: [replacementStarted], timeout: 2)

        let completeHistoryPublished = expectation(description: "Saved and existing screenshots are both visible")
        let subscription = store.$screenshots.sink { records in
            if Set(records.map(\.id)) == Set([existing.id, saved.id]) {
                completeHistoryPublished.fulfill()
            }
        }
        defer { subscription.cancel() }

        loader.complete(1, with: [saved, existing])
        await fulfillment(of: [completeHistoryPublished], timeout: 2)
        loader.complete(0, with: [])
        await scan.value

        XCTAssertEqual(Set(store.screenshots.map(\.id)), Set([saved.id, existing.id]))
        XCTAssertNotNil(store.thumbnail(for: saved.id))
        XCTAssertTrue(FileManager.default.fileExists(atPath: saved.url.path))
    }

    func testFailedDeletePreservesRecordAndThumbnail() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ScreenshotStore(resolver: try makeResolver(for: root))
        let missing = record(in: root, name: "already-missing.png")
        let thumbnail = makeImage()
        store.replaceScreenshotsForTesting([missing])
        store.applyThumbnailForTesting(thumbnail, id: missing.id)

        XCTAssertThrowsError(try store.delete(id: missing.id))
        XCTAssertEqual(store.screenshots.map(\.id), [missing.id])
        XCTAssertTrue(store.thumbnail(for: missing.id) === thumbnail)
    }

    private func record(in folder: URL, name: String) -> ScreenshotRecord {
        ScreenshotRecord(url: folder.appendingPathComponent(name), date: Date())
    }

    private func temporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cys-history-race-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func makeResolver(for root: URL) throws -> StorageResolver {
        let provider = MockBookmarkProvider()
        provider.onCreate = { Data($0.path.utf8) }
        provider.onResolve = { (URL(fileURLWithPath: String(decoding: $0, as: UTF8.self)), false) }
        let resolver = StorageResolver(
            defaults: MockBookmarkStorage(),
            bookmarkProvider: provider,
            securityAccess: MockSecurityScopedAccess()
        )
        try resolver.saveBookmark(for: root)
        return resolver
    }

    private func makeImage() -> NSImage {
        let image = NSImage(size: NSSize(width: 16, height: 16))
        image.lockFocus()
        NSColor.systemBlue.setFill()
        NSRect(x: 0, y: 0, width: 16, height: 16).fill()
        image.unlockFocus()
        return image
    }
}

@MainActor
private final class PausedHistoryLoader {
    var onStart: (() -> Void)?
    private var requests: [CheckedContinuation<[ScreenshotRecord], Never>] = []

    func load(_ folder: URL) async -> [ScreenshotRecord] {
        await withCheckedContinuation { continuation in
            requests.append(continuation)
            onStart?()
        }
    }

    func complete(_ index: Int, with records: [ScreenshotRecord]) {
        requests[index].resume(returning: records)
    }
}
