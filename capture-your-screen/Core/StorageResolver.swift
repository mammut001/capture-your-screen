import Foundation
import AppKit

/// Simple storage resolver.
/// Default save location: ~/Pictures/Screenshots
/// Users can override this with any folder they choose, including iCloud Drive.
struct StorageResolver {

    private static let defaultsKey = "customScreenshotFolder"

    /// User-selected folder URL (persisted in UserDefaults). If nil, the default is used.
    var customFolderURL: URL? {
        get {
            guard let path = UserDefaults.standard.string(forKey: Self.defaultsKey) else { return nil }
            return URL(fileURLWithPath: path)
        }
        set {
            if let url = newValue {
                UserDefaults.standard.set(url.path, forKey: Self.defaultsKey)
            } else {
                UserDefaults.standard.removeObject(forKey: Self.defaultsKey)
            }
        }
    }

    /// ~/Pictures/Screenshots
    static var defaultFolderURL: URL {
        let pictures = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask)[0]
        return pictures.appendingPathComponent("Screenshots", isDirectory: true)
    }

    /// The folder that will actually be used: custom > default
    var screenshotFolderURL: URL {
        customFolderURL ?? Self.defaultFolderURL
    }

    /// Ensure the target folder exists, creating it (and its parents) if needed.
    func ensureFolderExists() throws {
        try FileManager.default.createDirectory(
            at: screenshotFolderURL,
            withIntermediateDirectories: true
        )
    }
}
