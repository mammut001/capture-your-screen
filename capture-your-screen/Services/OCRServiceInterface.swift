import Foundation
import AppKit

/// 预留 — OCR Service Protocol
/// v1 does not implement this. The interface is reserved for future OCR
/// integration (e.g. Apple Vision framework) without architectural changes.
protocol OCRServiceProtocol: Sendable {
    /// Extract text from the given image.
    /// - Parameter image: The source image (screenshot).
    /// - Returns: Extracted text string, or empty string if no text found.
    /// - Throws: `OCRError` if processing fails.
    func extractText(from image: NSImage) async throws -> String
}

enum OCRError: Error, LocalizedError {
    case imageTooSmall
    case noTextFound
    case processingFailed(String)
    case serviceUnavailable

    var errorDescription: String? {
        switch self {
        case .imageTooSmall:
            return "Image is too small for text recognition."
        case .noTextFound:
            return "No text found in the image."
        case .processingFailed(let detail):
            return "OCR processing failed: \(detail)"
        case .serviceUnavailable:
            return "OCR service is unavailable."
        }
    }
}

// 预留: Future implementation using Apple Vision
// final class VisionOCRService: OCRServiceProtocol {
//     func extractText(from image: NSImage) async throws -> String {
//         // Uses VNRecognizeTextRequest internally
//     }
// }
