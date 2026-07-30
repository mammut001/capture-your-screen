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

@MainActor
final class SecurityScopedAccess {
    private var activeURLs: [URL: Int] = [:]  // URL -> reference count

    func startAccessing(_ url: URL) -> Bool {
        if let count = activeURLs[url] {
            activeURLs[url] = count + 1
            return true
        }
        guard url.startAccessingSecurityScopedResource() else {
            return false
        }
        activeURLs[url] = 1
        return true
    }

    func stopAccessing(_ url: URL) {
        guard let count = activeURLs[url] else { return }
        if count <= 1 {
            url.stopAccessingSecurityScopedResource()
            activeURLs.removeValue(forKey: url)
        } else {
            activeURLs[url] = count - 1
        }
    }

    func stopAll() {
        for (url, _) in activeURLs {
            url.stopAccessingSecurityScopedResource()
        }
        activeURLs.removeAll()
    }

    var isAccessing: Bool { !activeURLs.isEmpty }

    deinit {
        // Inline cleanup — deinit is nonisolated and cannot call @MainActor methods.
        for (url, _) in activeURLs {
            url.stopAccessingSecurityScopedResource()
        }
        activeURLs.removeAll()
    }
}

// MARK: - Bookmark Storage Protocol (testable)

protocol BookmarkStorage {
    func loadBookmarkData(forKey key: String) -> Data?
    func saveBookmarkData(_ data: Data, forKey key: String)
    func removeBookmarkData(forKey key: String)
    func loadString(forKey key: String) -> String?
    func saveString(_ string: String, forKey key: String)
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

    func saveString(_ string: String, forKey key: String) {
        set(string, forKey: key)
    }
}

// MARK: - Storage Resolver

@MainActor
final class StorageResolver {
    static let bookmarkDefaultsKey = "screenshotFolderBookmark"
    static let folderPathKey = "screenshotFolderPath"
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
        securityAccess: SecurityScopedAccess? = nil,
        fileManager: FileManager = .default
    ) {
        self.defaults = defaults
        self.bookmarkProvider = bookmarkProvider
        self.securityAccess = securityAccess ?? SecurityScopedAccess()
        self.fileManager = fileManager
        loadBookmark()
    }

    // MARK: - Public API

    var hasValidFolder: Bool {
        if cachedIsStale {
            reloadBookmark()
        }
        return cachedResolvedURL != nil
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
        defaults.saveString(url.path, forKey: Self.folderPathKey)
        defaults.removeObject(forKey: Self.oldPathDefaultsKey)
        cachedResolvedURL = url
        cachedIsStale = false
        _ = securityAccess.startAccessing(url)
    }

    func clearBookmark() {
        defaults.removeBookmarkData(forKey: Self.bookmarkDefaultsKey)
        defaults.removeObject(forKey: Self.folderPathKey)
        cachedResolvedURL = nil
        cachedIsStale = false
        securityAccess.stopAll()
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
        defaults.loadBookmarkData(forKey: Self.migrationShownKey) != nil
    }

    func markMigrationShown() {
        defaults.saveBookmarkData(Data(), forKey: Self.migrationShownKey)
    }

    func clearOldPathData() {
        defaults.removeObject(forKey: Self.oldPathDefaultsKey)
    }

    // MARK: - Private

    private func loadBookmark() {
        if let data = defaults.loadBookmarkData(forKey: Self.bookmarkDefaultsKey) {
            do {
                let (url, isStale) = try bookmarkProvider.resolveBookmarkData(data)
                cachedResolvedURL = url
                cachedIsStale = isStale
                if !isStale {
                    _ = securityAccess.startAccessing(url)
                    defaults.saveString(url.path, forKey: Self.folderPathKey)
                } else {
                    if let newData = try? bookmarkProvider.createBookmarkData(from: url) {
                        defaults.saveBookmarkData(newData, forKey: Self.bookmarkDefaultsKey)
                        defaults.saveString(url.path, forKey: Self.folderPathKey)
                    }
                }
                return
            } catch {
                defaults.removeBookmarkData(forKey: Self.bookmarkDefaultsKey)
            }
        }

        // Fallback 1: Saved path from user settings
        if let savedPath = defaults.loadString(forKey: Self.folderPathKey), !savedPath.isEmpty {
            let expandedPath = (savedPath as NSString).expandingTildeInPath
            let url = URL(fileURLWithPath: expandedPath)
            if fileManager.fileExists(atPath: url.path) {
                cachedResolvedURL = url
                cachedIsStale = false
                _ = securityAccess.startAccessing(url)
                if let newData = try? bookmarkProvider.createBookmarkData(from: url) {
                    defaults.saveBookmarkData(newData, forKey: Self.bookmarkDefaultsKey)
                }
                return
            }
        }

        // Fallback 2: Old path key migration
        if let oldPath = defaults.loadString(forKey: Self.oldPathDefaultsKey), !oldPath.isEmpty {
            let expandedPath = (oldPath as NSString).expandingTildeInPath
            let url = URL(fileURLWithPath: expandedPath)
            if fileManager.fileExists(atPath: url.path) {
                cachedResolvedURL = url
                cachedIsStale = false
                _ = securityAccess.startAccessing(url)
                if let newData = try? bookmarkProvider.createBookmarkData(from: url) {
                    defaults.saveBookmarkData(newData, forKey: Self.bookmarkDefaultsKey)
                    defaults.saveString(url.path, forKey: Self.folderPathKey)
                }
                return
            }
        }

        cachedResolvedURL = nil
        cachedIsStale = false
    }

    private func reloadBookmark() {
        loadBookmark()
    }
}

// MARK: - Mock Objects for Testing

#if DEBUG
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

    func saveString(_ string: String, forKey key: String) {
        stringStore[key] = string
    }

    func removeObject(forKey key: String) {
        dataStore.removeValue(forKey: key)
        stringStore.removeValue(forKey: key)
    }
}
#endif
