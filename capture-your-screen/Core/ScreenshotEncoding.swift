import AppKit
import Foundation

enum ScreenshotEncoding {
    /// Encode an NSImage as PNG data. Shared by the menu bar app and CLI helper.
    static func pngData(from image: NSImage) -> Data? {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }
        let rep = NSBitmapImageRep(cgImage: cgImage)
        return rep.representation(using: .png, properties: [:])
    }
}