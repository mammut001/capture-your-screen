import XCTest
@testable import capture_your_screen

final class StorageResolverTests: XCTestCase {

    // MARK: - Path Containment

    func testPathContainment_rejectsSiblingDirectory() {
        let resolver = makeResolver()
        let folderURL = URL(fileURLWithPath: "/Users/test/Screenshots")
        let siblingFile = URL(fileURLWithPath: "/Users/test/Screenshots2/file.png")
        try? resolver.saveBookmark(for: folderURL)

        XCTAssertFalse(resolver.isFileInScreenshotFolder(siblingFile))
    }

    func testPathContainment_acceptsChildFile() {
        let resolver = makeResolver()
        let folderURL = URL(fileURLWithPath: "/Users/test/Screenshots")
        let childFile = URL(fileURLWithPath: "/Users/test/Screenshots/2024-01-01/file.png")
        try? resolver.saveBookmark(for: folderURL)

        XCTAssertTrue(resolver.isFileInScreenshotFolder(childFile))
    }

    func testPathContainment_acceptsRootFile() {
        let resolver = makeResolver()
        let folderURL = URL(fileURLWithPath: "/Users/test/Screenshots")
        let rootFile = URL(fileURLWithPath: "/Users/test/Screenshots/file.png")
        try? resolver.saveBookmark(for: folderURL)

        XCTAssertTrue(resolver.isFileInScreenshotFolder(rootFile))
    }

    func testPathContainment_rejectsUnrelatedPath() {
        let resolver = makeResolver()
        let folderURL = URL(fileURLWithPath: "/Users/test/Screenshots")
        let unrelated = URL(fileURLWithPath: "/tmp/other.png")
        try? resolver.saveBookmark(for: folderURL)

        XCTAssertFalse(resolver.isFileInScreenshotFolder(unrelated))
    }

    // MARK: - Bookmark Storage

    func testNoBookmark_returnsFolderNotSelected() {
        let resolver = makeResolverWithoutBookmark()

        XCTAssertNil(resolver.screenshotFolderURL)
        XCTAssertFalse(resolver.hasValidFolder)

        XCTAssertThrowsError(try resolver.prepareFolder()) { error in
            guard let storageError = error as? StorageError else {
                XCTFail("Expected StorageError, got \(error)")
                return
            }
            if case .folderNotSelected = storageError { } else {
                XCTFail("Expected folderNotSelected, got \(storageError)")
            }
        }
    }

    func testSaveAndResolveBookmark() {
        let mockStorage = MockBookmarkStorage()
        let mockProvider = MockBookmarkProvider()
        let testURL = URL(fileURLWithPath: "/tmp/test-screenshots")
        let bookmarkData = "test-bookmark-data".data(using: .utf8)!

        mockProvider.onCreate = { _ in bookmarkData }
        mockProvider.onResolve = { _ in (testURL, false) }

        let resolver = StorageResolver(defaults: mockStorage, bookmarkProvider: mockProvider)
        try? resolver.saveBookmark(for: testURL)

        XCTAssertTrue(resolver.hasValidFolder)
        XCTAssertEqual(resolver.screenshotFolderURL, testURL)
    }

    func testCorruptedBookmarkData_doesNotCrash() {
        let mockStorage = MockBookmarkStorage()
        let mockProvider = MockBookmarkProvider()
        let corruptedData = "not-a-valid-bookmark".data(using: .utf8)!

        mockProvider.onResolve = { _ in
            throw NSError(domain: "bookmark", code: -1, userInfo: nil)
        }

        mockStorage.saveBookmarkData(corruptedData, forKey: StorageResolver.bookmarkDefaultsKey)

        let resolver = StorageResolver(defaults: mockStorage, bookmarkProvider: mockProvider)

        XCTAssertNil(resolver.screenshotFolderURL)
        XCTAssertFalse(resolver.hasValidFolder)
        XCTAssertNil(mockStorage.loadBookmarkData(forKey: StorageResolver.bookmarkDefaultsKey))
    }

    // MARK: - Folder Switching

    func testSwitchingFolder_changesResolvedURL() {
        let mockStorage = MockBookmarkStorage()
        let mockProvider = MockBookmarkProvider()
        let bookmarkData = "bookmark".data(using: .utf8)!
        let oldURL = URL(fileURLWithPath: "/tmp/old")
        let newURL = URL(fileURLWithPath: "/tmp/new")

        mockProvider.onCreate = { _ in bookmarkData }
        var resolveCallCount = 0
        mockProvider.onResolve = { data in
            resolveCallCount += 1
            if resolveCallCount == 1 {
                return (oldURL, false)
            }
            return (newURL, false)
        }

        let resolver = StorageResolver(defaults: mockStorage, bookmarkProvider: mockProvider)

        try? resolver.saveBookmark(for: oldURL)
        XCTAssertEqual(resolver.screenshotFolderURL, oldURL)

        try? resolver.saveBookmark(for: newURL)
        XCTAssertEqual(resolver.screenshotFolderURL, newURL)
    }

    // MARK: - Old Path Migration

    func testOldPathMigration_doesNotAutoGrantAccess() {
        let mockStorage = MockBookmarkStorage()
        let mockProvider = MockBookmarkProvider()

        mockProvider.onResolve = { _ in
            throw NSError(domain: "bookmark", code: -1, userInfo: nil)
        }

        let resolver = StorageResolver(defaults: mockStorage, bookmarkProvider: mockProvider)

        XCTAssertFalse(resolver.hasValidFolder)
        // After migration shown, there should be no auto-access
        resolver.markMigrationShown()
        XCTAssertFalse(resolver.hasValidFolder)
    }

    // MARK: - ScreenshotStore

    func testScreenshotStore_withoutFolder_returnsError() {
        let mockStorage = MockBookmarkStorage()
        let mockProvider = MockBookmarkProvider()
        let resolver = StorageResolver(defaults: mockStorage, bookmarkProvider: mockProvider)

        XCTAssertThrowsError(try resolver.prepareFolder()) { error in
            guard let storageError = error as? StorageError else {
                XCTFail("Expected StorageError, got \(error)")
                return
            }
            if case .folderNotSelected = storageError { } else {
                XCTFail("Expected folderNotSelected, got \(storageError)")
            }
        }
    }

    // MARK: - Stale Bookmark

    func testStaleBookmark_reResolvesOnAccess() {
        let mockStorage = MockBookmarkStorage()
        let mockProvider = MockBookmarkProvider()
        let bookmarkData = "test-bookmark".data(using: .utf8)!
        let staleURL = URL(fileURLWithPath: "/tmp/stale")
        let freshURL = URL(fileURLWithPath: "/tmp/fresh")

        var resolveCount = 0
        mockProvider.onCreate = { _ in bookmarkData }
        mockProvider.onResolve = { _ in
            resolveCount += 1
            if resolveCount == 1 {
                return (staleURL, true)
            }
            return (freshURL, false)
        }

        mockStorage.saveBookmarkData(bookmarkData, forKey: StorageResolver.bookmarkDefaultsKey)

        let resolver = StorageResolver(defaults: mockStorage, bookmarkProvider: mockProvider)

        XCTAssertTrue(resolver.hasValidFolder)
        XCTAssertEqual(resolver.screenshotFolderURL, freshURL)
    }

    // MARK: - Helpers

    private func makeResolver() -> StorageResolver {
        let mockStorage = MockBookmarkStorage()
        let mockProvider = MockBookmarkProvider()
        let bookmarkData = "dummy".data(using: .utf8)!
        mockProvider.onCreate = { _ in bookmarkData }
        mockProvider.onResolve = { _ in (URL(fileURLWithPath: "/tmp"), false) }
        return StorageResolver(defaults: mockStorage, bookmarkProvider: mockProvider)
    }

    private func makeResolverWithoutBookmark() -> StorageResolver {
        let mockStorage = MockBookmarkStorage()
        let mockProvider = MockBookmarkProvider()
        return StorageResolver(defaults: mockStorage, bookmarkProvider: mockProvider)
    }
}
