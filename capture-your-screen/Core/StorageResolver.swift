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
            return "Cannot access the screenshot folder. Please re-select it in Settings."
        case .folderCreationFailed:
            return "Could not create the screenshot folder."
        case .fileWriteFailed:
            return "Could not write the screenshot file."
        case .fileReadFailed:
            return "Could not read the screenshot file."
        case .fileNotFound:
            return "Screenshot file not found."
        case .imageEncodingFailed:
            return "Failed to encode the screenshot image."
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

/// Abstraction over security-scoped resource access (testable).
@MainActor
protocol SecurityScopedAccessing: AnyObject {
    @discardableResult
    func startAccessing(_ url: URL) -> Bool
    func stopAccessing(_ url: URL)
    func stopAll()
    var isAccessing: Bool { get }
    func isAccessing(_ url: URL) -> Bool
}

/// Tracks `startAccessingSecurityScopedResource` only for bookmark **root**
/// URLs. Child paths (date folders / files) must never call startAccessing
/// themselves — once the root is open, the sandbox allows reading children.
@MainActor
final class SecurityScopedAccess: SecurityScopedAccessing {
    private struct Entry {
        let url: URL
        var count: Int
    }

    /// Keyed by standardized path so equivalent URLs share one refcount.
    private var active: [String: Entry] = [:]

    private func key(for url: URL) -> String {
        url.standardizedFileURL.path
    }

    @discardableResult
    func startAccessing(_ url: URL) -> Bool {
        let k = key(for: url)
        if var entry = active[k] {
            entry.count += 1
            active[k] = entry
            return true
        }
        let standardized = url.standardizedFileURL
        guard standardized.startAccessingSecurityScopedResource() else {
            return false
        }
        active[k] = Entry(url: standardized, count: 1)
        return true
    }

    func stopAccessing(_ url: URL) {
        let k = key(for: url)
        guard var entry = active[k] else { return }
        if entry.count <= 1 {
            entry.url.stopAccessingSecurityScopedResource()
            active.removeValue(forKey: k)
        } else {
            entry.count -= 1
            active[k] = entry
        }
    }

    func stopAll() {
        for (_, entry) in active {
            entry.url.stopAccessingSecurityScopedResource()
        }
        active.removeAll()
    }

    var isAccessing: Bool { !active.isEmpty }

    func isAccessing(_ url: URL) -> Bool {
        active[key(for: url)] != nil
    }

    deinit {
        // Inline cleanup — deinit is nonisolated and cannot call @MainActor methods.
        for (_, entry) in active {
            entry.url.stopAccessingSecurityScopedResource()
        }
        active.removeAll()
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
    let securityAccess: SecurityScopedAccessing
    let fileManager: FileManager

    private var cachedResolvedURL: URL?
    private var cachedIsStale = false

    init(
        defaults: BookmarkStorage = UserDefaults.standard,
        bookmarkProvider: BookmarkProvider? = nil,
        securityAccess: SecurityScopedAccessing? = nil,
        fileManager: FileManager = .default
    ) {
        self.defaults = defaults
        self.bookmarkProvider = bookmarkProvider ?? RealBookmarkProvider()
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

    /// Bookmarked root folder only. Never a date subfolder or file path.
    var screenshotFolderURL: URL? {
        if cachedIsStale {
            reloadBookmark()
        }
        return cachedResolvedURL
    }

    /// Last known path string for UI/migration only — not a security-scoped grant.
    var displayPathHint: String? {
        if let url = screenshotFolderURL {
            return url.path
        }
        return defaults.loadString(forKey: Self.folderPathKey)
            ?? defaults.loadString(forKey: Self.oldPathDefaultsKey)
    }

    /// Persist a security-scoped bookmark from an `NSOpenPanel` (or equivalent) URL.
    func saveBookmark(for url: URL) throws {
        // Panel URLs are already security-scoped; hold access while creating the bookmark.
        let heldPanel = securityAccess.startAccessing(url)

        let data: Data
        do {
            data = try bookmarkProvider.createBookmarkData(from: url)
        } catch {
            if heldPanel { securityAccess.stopAccessing(url) }
            throw StorageError.bookmarkCreationFailed(error)
        }

        // Resolve immediately so we store/use the same scoped URL the system returns.
        let resolved: URL
        let isStale: Bool
        do {
            (resolved, isStale) = try bookmarkProvider.resolveBookmarkData(data)
        } catch {
            if heldPanel { securityAccess.stopAccessing(url) }
            throw StorageError.bookmarkResolutionFailed(error)
        }

        if heldPanel {
            securityAccess.stopAccessing(url)
        }
        securityAccess.stopAll()

        defaults.saveBookmarkData(data, forKey: Self.bookmarkDefaultsKey)
        defaults.saveString(resolved.path, forKey: Self.folderPathKey)
        defaults.removeObject(forKey: Self.oldPathDefaultsKey)

        cachedResolvedURL = resolved.standardizedFileURL
        cachedIsStale = isStale

        guard securityAccess.startAccessing(resolved) else {
            cachedResolvedURL = nil
            cachedIsStale = false
            throw StorageError.securityScopedAccessDenied
        }
    }

    func clearBookmark() {
        defaults.removeBookmarkData(forKey: Self.bookmarkDefaultsKey)
        defaults.removeObject(forKey: Self.folderPathKey)
        cachedResolvedURL = nil
        cachedIsStale = false
        securityAccess.stopAll()
    }

    /// Opens security-scoped access on the **bookmark root** only.
    /// Call this before any read/write under the screenshot folder tree.
    /// Do **not** call `startAccessing` on child date folders or files.
    @discardableResult
    func accessFolder() throws -> URL {
        if cachedIsStale {
            reloadBookmark()
        }
        guard let url = cachedResolvedURL else {
            throw StorageError.folderNotSelected
        }
        if securityAccess.startAccessing(url) {
            return url
        }

        // One recovery pass: re-resolve bookmark data (handles stale scope).
        reloadBookmark()
        guard let retried = cachedResolvedURL else {
            throw StorageError.bookmarkIsInvalid
        }
        guard securityAccess.startAccessing(retried) else {
            throw StorageError.securityScopedAccessDenied
        }
        return retried
    }

    /// Non-throwing convenience for UI paths that only need a Bool.
    @discardableResult
    func ensureFolderAccess() -> Bool {
        (try? accessFolder()) != nil
    }

    func prepareFolder() throws -> URL {
        let url = try accessFolder()
        do {
            try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        } catch {
            throw StorageError.folderCreationFailed(error)
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
        // Drop previous security scopes before rebinding.
        securityAccess.stopAll()

        if let data = defaults.loadBookmarkData(forKey: Self.bookmarkDefaultsKey) {
            do {
                let (url, isStale) = try bookmarkProvider.resolveBookmarkData(data)
                let standardized = url.standardizedFileURL

                if isStale {
                    // Need live access to refresh a stale bookmark, then re-resolve.
                    if securityAccess.startAccessing(standardized),
                       let newData = try? bookmarkProvider.createBookmarkData(from: standardized) {
                        defaults.saveBookmarkData(newData, forKey: Self.bookmarkDefaultsKey)
                        if let (fresh, stillStale) = try? bookmarkProvider.resolveBookmarkData(newData),
                           !stillStale {
                            securityAccess.stopAll()
                            let freshStd = fresh.standardizedFileURL
                            if securityAccess.startAccessing(freshStd) {
                                defaults.saveString(freshStd.path, forKey: Self.folderPathKey)
                                cachedResolvedURL = freshStd
                                cachedIsStale = false
                                return
                            }
                        }
                        // Fall back to the URL we could still open.
                        defaults.saveString(standardized.path, forKey: Self.folderPathKey)
                        cachedResolvedURL = standardized
                        cachedIsStale = false
                        return
                    }
                    // Stale and unusable — force re-select rather than pretend we have access.
                    cachedResolvedURL = nil
                    cachedIsStale = false
                    defaults.saveString(standardized.path, forKey: Self.folderPathKey)
                    return
                }

                // Fresh bookmark: require successful root scope open.
                guard securityAccess.startAccessing(standardized) else {
                    // Keep path for UI hint, but do not mark folder valid without scope.
                    defaults.saveString(standardized.path, forKey: Self.folderPathKey)
                    cachedResolvedURL = nil
                    cachedIsStale = false
                    return
                }

                cachedResolvedURL = standardized
                cachedIsStale = false
                defaults.saveString(standardized.path, forKey: Self.folderPathKey)
                return
            } catch {
                defaults.removeBookmarkData(forKey: Self.bookmarkDefaultsKey)
            }
        }

        // Path-only keys are NOT a sandbox grant. Never set cachedResolvedURL from
        // a plain path — that caused "has folder" UI while every access failed.
        // Keep strings for migration / display hints only.
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

/// Always succeeds — unit tests run without real sandbox scopes.
@MainActor
final class MockSecurityScopedAccess: SecurityScopedAccessing {
    private var paths: [String: Int] = [:]

    @discardableResult
    func startAccessing(_ url: URL) -> Bool {
        let key = url.standardizedFileURL.path
        paths[key, default: 0] += 1
        return true
    }

    func stopAccessing(_ url: URL) {
        let key = url.standardizedFileURL.path
        guard let count = paths[key] else { return }
        if count <= 1 {
            paths.removeValue(forKey: key)
        } else {
            paths[key] = count - 1
        }
    }

    func stopAll() {
        paths.removeAll()
    }

    var isAccessing: Bool { !paths.isEmpty }

    func isAccessing(_ url: URL) -> Bool {
        paths[url.standardizedFileURL.path] != nil
    }
}
#endif
