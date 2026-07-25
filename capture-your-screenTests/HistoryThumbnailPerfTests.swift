import XCTest
import AppKit
@testable import capture_your_screen

@MainActor
final class HistoryThumbnailPerfTests: XCTestCase {

    // MARK: - Pure helpers

    func testMembershipSignatureIgnoresThumbnailMaps() {
        let base = (0..<20).map { index in
            ScreenshotRecord(
                url: URL(fileURLWithPath: "/tmp/shots/Screenshot_2026-01-01_12-00-\(String(format: "%02d", index))_000.png"),
                date: Date(timeIntervalSince1970: 1_700_000_000 + Double(index))
            )
        }
        let sigA = HistorySectionBuilder.membershipSignature(for: base)
        let sigB = HistorySectionBuilder.membershipSignature(for: base)
        XCTAssertEqual(sigA, sigB)
        XCTAssertEqual(sigA.count, 20)

        var reordered = base
        reordered.swapAt(0, 1)
        XCTAssertNotEqual(
            HistorySectionBuilder.membershipSignature(for: base),
            HistorySectionBuilder.membershipSignature(for: reordered)
        )
    }

    func testSectionsStableWhenOnlyThumbnailsWouldChange() {
        let records = makeRecords(count: 40)
        let sectionsA = HistorySectionBuilder.sections(from: records)
        let sectionsB = HistorySectionBuilder.sections(from: records)

        XCTAssertEqual(sectionsA, sectionsB)
        let totalItems = sectionsA.reduce(0) { $0 + $1.items.count }
        XCTAssertEqual(totalItems, 40)
        // History items no longer carry thumbnail payloads.
        XCTAssertTrue(sectionsA.flatMap(\.items).allSatisfy { _ in true })
    }

    func testApplyingThumbnailDoesNotRequireListRewrite() {
        let image = makeSolidImage(size: NSSize(width: 8, height: 8))
        var map: [String: NSImage] = [:]
        for i in 0..<50 {
            map = HistorySectionBuilder.applyingThumbnail(image, for: "id-\(i)", to: map)
        }
        XCTAssertEqual(map.count, 50)
        XCTAssertTrue(map.keys.contains("id-0"))
        XCTAssertTrue(map.keys.contains("id-49"))
    }

    // MARK: - Store: thumbnails vs list publications

    func testManyThumbnailUpdatesDoNotRepublishScreenshotsArray() {
        let store = ScreenshotStore()
        store.installPublishCountersForTesting()

        let records = makeRecords(count: 60)
        store.replaceScreenshotsForTesting(records)

        // One membership publish from replace.
        let listPublishesAfterReplace = store.screenshotsPublishCountForTesting
        XCTAssertGreaterThanOrEqual(listPublishesAfterReplace, 1)

        let listBaseline = store.screenshotsPublishCountForTesting
        let thumbBaseline = store.thumbnailsPublishCountForTesting
        let listIdentityBefore = store.screenshots.map(\.id)

        let image = makeSolidImage(size: NSSize(width: 16, height: 10))
        for record in records {
            store.applyThumbnailForTesting(image, id: record.id)
        }

        let listPublishesDuringThumbs = store.screenshotsPublishCountForTesting - listBaseline
        let thumbPublishes = store.thumbnailsPublishCountForTesting - thumbBaseline

        XCTAssertEqual(
            listPublishesDuringThumbs,
            0,
            "Thumbnail completion must not re-assign screenshots (got \(listPublishesDuringThumbs) publishes)"
        )
        XCTAssertEqual(
            thumbPublishes,
            records.count,
            "Each thumbnail should publish once on the thumbnail map"
        )
        XCTAssertEqual(store.screenshots.map(\.id), listIdentityBefore)
        XCTAssertEqual(store.thumbnailsByID.count, records.count)
    }

    func testViewModelDoesNotRebuildSectionsOnThumbnailOnlyUpdates() {
        let store = ScreenshotStore()
        let hotkey = HotkeyManager()
        // CaptureCoordinator needs store + hotkey; use real types.
        let coordinator = CaptureCoordinator(screenshotStore: store, hotkeyManager: hotkey)
        let viewModel = MenuBarViewModel(
            captureCoordinator: coordinator,
            screenshotStore: store,
            hotkeyManager: hotkey
        )

        let records = makeRecords(count: 55)
        store.replaceScreenshotsForTesting(records)

        // Allow Combine delivery on main run loop.
        spinMain(for: 0.05)
        let rebuildsAfterMembership = viewModel.sectionRebuildCount
        XCTAssertGreaterThanOrEqual(rebuildsAfterMembership, 1)

        let sectionsBefore = viewModel.historySections
        let rebuildBaseline = viewModel.sectionRebuildCount

        let image = makeSolidImage(size: NSSize(width: 12, height: 12))
        for record in records {
            store.applyThumbnailForTesting(image, id: record.id)
        }
        spinMain(for: 0.05)

        let rebuildsDuringThumbs = viewModel.sectionRebuildCount - rebuildBaseline
        XCTAssertEqual(
            rebuildsDuringThumbs,
            0,
            "Thumbnail-only updates must not call full section rebuild (got \(rebuildsDuringThumbs))"
        )
        XCTAssertEqual(viewModel.historySections, sectionsBefore)
        XCTAssertEqual(viewModel.thumbnailsByID.count, records.count)

        // Cards still resolve previews via the narrow map.
        if let first = viewModel.historySections.first?.items.first {
            XCTAssertNotNil(viewModel.thumbnail(for: first))
        }
    }

    func testImageIOThumbnailLoadsWithoutFullMainActorDecode() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cys-thumb-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let fileURL = dir.appendingPathComponent("Screenshot_2026-03-15_10-11-12_123.png")
        let source = makeSolidImage(size: NSSize(width: 800, height: 600))
        let png = try XCTUnwrap(pngData(from: source))
        try png.write(to: fileURL)

        let thumb = ScreenshotStore.loadThumbnailFromDisk(at: fileURL, maxPixelSize: 120)
        let image = try XCTUnwrap(thumb)
        // Pixel bounds come from ImageIO; NSImage.size is in points (1x here).
        let longest = max(image.size.width, image.size.height)
        XCTAssertLessThanOrEqual(longest, 120 + 1, "expected ImageIO max-pixel thumbnail, got \(longest)")
        XCTAssertGreaterThan(longest, 0)
    }

    // MARK: - Helpers

    private func makeRecords(count: Int) -> [ScreenshotRecord] {
        (0..<count).map { index in
            let seconds = String(format: "%02d", index % 60)
            let url = URL(fileURLWithPath: "/tmp/cys-history/Screenshot_2026-06-01_12-00-\(seconds)_\(String(format: "%03d", index)).png")
            return ScreenshotRecord(
                url: url,
                date: Date(timeIntervalSince1970: 1_720_000_000 + Double(index))
            )
        }
    }

    private func makeSolidImage(size: NSSize) -> NSImage {
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.systemBlue.setFill()
        NSRect(origin: .zero, size: size).fill()
        image.unlockFocus()
        return image
    }

    private func pngData(from image: NSImage) -> Data? {
        ScreenshotEncoding.pngData(from: image)
    }

    private func spinMain(for seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
    }
}
