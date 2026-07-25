import Foundation
import AppKit

// MARK: - Storage Errors

enum StorageError: LocalizedError {
    case folderNotSelected
    case bookmarkCreationFailed(Error)
    case bookmarkResolutionFailed(Error)
    case bookmarkIsInvalid
    case securityScopedAccessDenied
    case folderCreationFailed(Error)
    case fileWriteFailed(Error)
    case fileReadFailed(Error)
    case fileNotFound
    case imageEncodingFailed
    case fileNotInScreenshotDirectory

    var errorDescription: String? {
        switch self {
        case .folderNotSelected:
            return "No screenshot folder selected. Please choose a folder in Settings."
        case .bookmarkCreationFailed:
            return "Could not save folder access permission."
        case .bookmarkResolutionFailed:
            return "Could not restore folder access permission."
        case .bookmarkIsInvalid:
            return "Saved folder access permission is no longer valid. Please re-select the folder in Settings."
        case .securityScopedAccessDenied:
            return "Access to the screenshot folder was denied."
        case .folderCreationFailed:
            return "Could not create the screenshot folder."
        case .fileWriteFailed:
            return "Could not write the screenshot file."
        case .fileReadFailed:
            return "Could not read the screenshot file."
        case .fileNotFound:
            return "Screenshot file not found."
        case .imageEncodingFailed:
            return "Failed to encode the screenshot as PNG."
        case .fileNotInScreenshotDirectory:
            return "File is not inside the screenshots folder."
        }
    }

    var underlyingError: Error? {
        switch self {
        case .bookmarkCreationFailed(let e),
             .bookmarkResolutionFailed(let e),
             .folderCreationFailed(let e),
             .fileWriteFailed(let e),
             .fileReadFailed(let e):
            return e
        default:
            return nil
        }
    }
}

// MARK: - Bookmark Provider (testable via protocol)

protocol BookmarkProvider {
    func createBookmarkData(from url: URL) throws -> Data
    func resolveBookmarkData(_ data: Data) throws -> (url: URL, isStale: Bool)
}

struct RealBookmarkProvider: BookmarkProvider {
    func createBookmarkData(from url: URL) throws -> Data {
        try url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
    }

    func resolveBookmarkData(_ data: Data) throws -> (url: URL, isStale: Bool) {
        var isStale = false
        let url = try URL(
            resolvingBookmarkData: data,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )
        return (url, isStale)
    }
}

// MARK: - Security-Scoped Access Lifecycle

final class SecurityScopedAccess {
    private var securedURL: URL?
    private var isActive = false

    func startAccessing(_ url: URL) -> Bool {
        if isActive && securedURL == url {
            return true
        }
        stopAccessing()
        guard url.startAccessingSecurityScopedResource() else {
            return false
        }
        securedURL = url
        isActive = true
        return true
    }

    func stopAccessing() {
        guard isActive, let url = securedURL else { return }
        url.stopAccessingSecurityScopedResource()
        securedURL = nil
        isActive = false
    }

    var accessingURL: URL? { securedURL }
    var isAccessing: Bool { isActive }

    deinit {
        stopAccessing()
    }
}

// MARK: - Bookmark Storage Protocol (testable)

protocol BookmarkStorage {
    func loadBookmarkData(forKey key: String) -> Data?
    func saveBookmarkData(_ data: Data, forKey key: String)
    func removeBookmarkData(forKey key: String)
    func loadString(forKey key: String) -> String?
    func removeObject(forKey key: String)
}

extension UserDefaults: BookmarkStorage {
    func loadBookmarkData(forKey key: String) -> Data? {
        data(forKey: key)
    }

    func saveBookmarkData(_ data: Data, forKey key: String) {
        set(data, forKey: key)
    }

    func removeBookmarkData(forKey key: String) {
        removeObject(forKey: key)
    }

    func loadString(forKey key: String) -> String? {
        string(forKey: key)
    }
}

// MARK: - Storage Resolver

final class StorageResolver {
    static let bookmarkDefaultsKey = "screenshotFolderBookmark"
    static let oldPathDefaultsKey = "customScreenshotFolder"
    static let migrationShownKey = "screenshotFolderMigrationShown"

    static let defaultSuggestedPath = "~/Pictures/Screenshots"

    private let defaults: BookmarkStorage
    private let bookmarkProvider: BookmarkProvider
    let securityAccess: SecurityScopedAccess
    let fileManager: FileManager

    private var cachedResolvedURL: URL?
    private var cachedIsStale = false

    init(
        defaults: BookmarkStorage = UserDefaults.standard,
        bookmarkProvider: BookmarkProvider = RealBookmarkProvider(),
        securityAccess: SecurityScopedAccess = SecurityScopedAccess(),
        fileManager: FileManager = .default
    ) {
        self.defaults = defaults
        self.bookmarkProvider = bookmarkProvider
        self.securityAccess = securityAccess
        self.fileManager = fileManager
        loadBookmark()
    }

    // MARK: - Public API

    var hasValidFolder: Bool {
        if cachedIsStale {
            reloadBookmark()
        }
        return cachedResolvedURL != nil && !cachedIsStale
    }

    var screenshotFolderURL: URL? {
        if cachedIsStale {
            reloadBookmark()
        }
        return cachedResolvedURL
    }

    func saveBookmark(for url: URL) throws {
        let data = try bookmarkProvider.createBookmarkData(from: url)
        defaults.saveBookmarkData(data, forKey: Self.bookmarkDefaultsKey)
        defaults.removeObject(forKey: Self.oldPathDefaultsKey)
        cachedResolvedURL = url
        cachedIsStale = false
        _ = securityAccess.startAccessing(url)
    }

    func clearBookmark() {
        defaults.removeBookmarkData(forKey: Self.bookmarkDefaultsKey)
        cachedResolvedURL = nil
        cachedIsStale = false
        securityAccess.stopAccessing()
    }

    func prepareFolder() throws -> URL {
        guard let url = screenshotFolderURL else {
            throw StorageError.folderNotSelected
        }
        guard securityAccess.startAccessing(url) else {
            throw StorageError.securityScopedAccessDenied
        }
        do {
            try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        } catch {
            throw StorageError.folderCreationFailed(error)
        }
        return url
    }

    func accessFolder() throws -> URL {
        guard let url = screenshotFolderURL else {
            throw StorageError.folderNotSelected
        }
        guard securityAccess.startAccessing(url) else {
            throw StorageError.securityScopedAccessDenied
        }
        return url
    }

    func isFileInScreenshotFolder(_ fileURL: URL) -> Bool {
        guard let folderURL = cachedResolvedURL else { return false }
        let filePath = fileURL.standardizedFileURL.path
        let folderPath = folderURL.standardizedFileURL.path
        let normalizedFolderPath = folderPath.hasSuffix("/") ? folderPath : folderPath + "/"
        return filePath == folderPath || filePath.hasPrefix(normalizedFolderPath)
    }

    // MARK: - Migration

    var oldPathString: String? {
        defaults.loadString(forKey: Self.oldPathDefaultsKey)
    }

    var hasOldPathData: Bool {
        oldPathString != nil
    }

    var hasMigrationBeenShown: Bool {
        defaults.loadString(forKey: Self.migrationShownKey) != nil
    }

    func markMigrationShown() {
        defaults.saveBookmarkData(Data(), forKey: Self.migrationShownKey)
    }

    func clearOldPathData() {
        defaults.removeObject(forKey: Self.oldPathDefaultsKey)
    }

    // MARK: - Private

    private func loadBookmark() {
        guard let data = defaults.loadBookmarkData(forKey: Self.bookmarkDefaultsKey) else {
            cachedResolvedURL = nil
            cachedIsStale = false
            return
        }
        do {
            let (url, isStale) = try bookmarkProvider.resolveBookmarkData(data)
            cachedResolvedURL = url
            cachedIsStale = isStale
            if !isStale {
                _ = securityAccess.startAccessing(url)
            }
        } catch {
            cachedResolvedURL = nil
            cachedIsStale = false
            defaults.removeBookmarkData(forKey: Self.bookmarkDefaultsKey)
        }
    }

    private func reloadBookmark() {
        loadBookmark()
    }
}

// MARK: - Mock Objects for Testing

final class MockBookmarkProvider: BookmarkProvider {
    var onCreate: ((URL) throws -> Data)?
    var onResolve: ((Data) throws -> (url: URL, isStale: Bool))?

    func createBookmarkData(from url: URL) throws -> Data {
        try onCreate?(url) ?? Data()
    }

    func resolveBookmarkData(_ data: Data) throws -> (url: URL, isStale: Bool) {
        try onResolve?(data) ?? (URL(fileURLWithPath: "/tmp"), false)
    }
}

final class MockBookmarkStorage: BookmarkStorage {
    private var dataStore: [String: Data] = [:]
    private var stringStore: [String: String] = [:]

    func loadBookmarkData(forKey key: String) -> Data? {
        dataStore[key]
    }

    func saveBookmarkData(_ data: Data, forKey key: String) {
        dataStore[key] = data
    }

    func removeBookmarkData(forKey key: String) {
        dataStore.removeValue(forKey: key)
    }

    func loadString(forKey key: String) -> String? {
        stringStore[key]
    }

    func removeObject(forKey key: String) {
        dataStore.removeValue(forKey: key)
        stringStore.removeValue(forKey: key)
    }
}
