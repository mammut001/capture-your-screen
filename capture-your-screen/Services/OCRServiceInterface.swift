import Foundation
import AppKit
import Vision

/// OCR Service Protocol — extract text from screenshots.
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

// MARK: - Vision Framework Implementation

/// Fully offline OCR using Apple's Vision framework.
/// Supports Chinese (Simplified + Traditional), English, Japanese, Korean.
final class VisionOCRService: OCRServiceProtocol, @unchecked Sendable {

    func extractText(from image: NSImage) async throws -> String {
        guard let cgImage = image.cgImage(
            forProposedRect: nil, context: nil, hints: nil
        ) else {
            throw OCRError.imageTooSmall
        }

        // Minimum image size sanity check
        guard cgImage.width >= 10, cgImage.height >= 10 else {
            throw OCRError.imageTooSmall
        }

        return try await withCheckedThrowingContinuation { continuation in
            let request = VNRecognizeTextRequest { request, error in
                if let error {
                    continuation.resume(
                        throwing: OCRError.processingFailed(error.localizedDescription)
                    )
                    return
                }

                guard let observations = request.results as? [VNRecognizedTextObservation],
                      !observations.isEmpty else {
                    continuation.resume(throwing: OCRError.noTextFound)
                    return
                }

                // Sort observations by vertical position (top → bottom),
                // then by horizontal position (left → right) within the same line.
                let sorted = observations.sorted { a, b in
                    // Vision uses bottom-left origin; higher Y = closer to top of image.
                    let ay = a.boundingBox.midY
                    let by = b.boundingBox.midY
                    // If roughly on the same line (within 2% of image height), sort left→right.
                    if abs(ay - by) < 0.02 {
                        return a.boundingBox.minX < b.boundingBox.minX
                    }
                    // Otherwise top→bottom (higher Y first).
                    return ay > by
                }

                let text = sorted
                    .compactMap { $0.topCandidates(1).first?.string }
                    .joined(separator: "\n")

                if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    continuation.resume(throwing: OCRError.noTextFound)
                } else {
                    continuation.resume(returning: text)
                }
            }

            // Configuration
            request.recognitionLevel = .accurate
            request.recognitionLanguages = [
                "zh-Hans",  // Simplified Chinese
                "zh-Hant",  // Traditional Chinese
                "en-US",    // English
                "ja",       // Japanese
                "ko",       // Korean
            ]
            request.usesLanguageCorrection = true

            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            do {
                try handler.perform([request])
            } catch {
                continuation.resume(
                    throwing: OCRError.processingFailed(error.localizedDescription)
                )
            }
        }
    }
}
