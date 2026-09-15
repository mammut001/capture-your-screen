import AppKit
import Foundation

enum SaveFormat: String, CaseIterable, Identifiable, Sendable {
    case png
    case jpeg

    static let preferenceKey = "saveFormatPreference"
    nonisolated static let supportedFileExtensions: Set<String> = ["png", "jpg", "jpeg"]

    var id: String { rawValue }

    var fileExtension: String {
        switch self {
        case .png: "png"
        case .jpeg: "jpg"
        }
    }

    var bitmapFileType: NSBitmapImageRep.FileType {
        switch self {
        case .png: .png
        case .jpeg: .jpeg
        }
    }

    var encodingProperties: [NSBitmapImageRep.PropertyKey: Any] {
        switch self {
        case .png: [:]
        case .jpeg: [.compressionFactor: 0.9]
        }
    }

    static func preferred(in defaults: UserDefaults = .standard) -> SaveFormat {
        guard let rawValue = defaults.string(forKey: preferenceKey) else { return .png }
        return SaveFormat(rawValue: rawValue) ?? .png
    }
}

enum ScreenshotEncoding {
    /// Encode an NSImage using the selected app format.
    static func data(from image: NSImage, format: SaveFormat) -> Data? {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }
        let rep = NSBitmapImageRep(cgImage: cgImage)
        return rep.representation(
            using: format.bitmapFileType,
            properties: format.encodingProperties
        )
    }

    /// Stable PNG entry point shared by the app and the read-only CLI helper.
    static func pngData(from image: NSImage) -> Data? {
        data(from: image, format: .png)
    }
}
