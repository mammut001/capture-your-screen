import ScreenCaptureKit
import CoreMedia
import CoreImage
import AppKit

enum ScreenCaptureError: Error, LocalizedError {
    case noMainScreen
    case captureFailed
    case noDisplayFound

    var errorDescription: String? {
        switch self {
        case .noMainScreen: return "No main screen available."
        case .captureFailed: return "Screen capture failed. Please ensure Screen Recording permission is granted."
        case .noDisplayFound: return "Could not find a suitable display to capture."
        }
    }
}

struct ScreenCapture {
    /// Capture a region of the specified display.
    /// - Parameters:
    ///   - rect: Selection rectangle in the target display's local coordinates (points).
    ///   - displayID: The display to capture from. If nil, uses the primary display.
    /// Marked nonisolated to avoid deadlock when called from a main-actor context (local monitor / keyDown).
    static nonisolated func captureRegion(_ rect: CGRect, displayID: CGDirectDisplayID? = nil) async throws -> NSImage {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)

        // Use the provided displayID, or fall back to the primary display
        let targetDisplayID = displayID ?? CGMainDisplayID()

        // Find the SCDisplay matching the target display
        guard let scDisplay = content.displays.first(where: { $0.displayID == targetDisplayID })
                ?? content.displays.first else {
            throw ScreenCaptureError.noDisplayFound
        }

        // Resolve HiDPI scale factor for output pixel dimensions
        let scaleFactor: CGFloat = NSScreen.screens.first(where: {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber") as NSDeviceDescriptionKey]
                as? CGDirectDisplayID) == scDisplay.displayID
        })?.backingScaleFactor ?? 2.0

        let filter = SCContentFilter(
            display: scDisplay,
            excludingApplications: [],
            exceptingWindows: []
        )

        let config = SCStreamConfiguration()
        let captureRect = rect.integral
        config.sourceRect = captureRect
        config.width = max(1, Int(captureRect.width * scaleFactor))
        config.height = max(1, Int(captureRect.height * scaleFactor))
        config.capturesAudio = false
        config.pixelFormat = kCVPixelFormatType_32BGRA

        let sampleBuffer = try await SCScreenshotManager.captureSampleBuffer(
            contentFilter: filter,
            configuration: config
        )

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            throw ScreenCaptureError.captureFailed
        }

        // ScreenCaptureKit already gives us a correctly oriented pixel buffer.
        // Applying an extra orientation transform here inverts the final image.
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let ciContext = CIContext()
        guard let cgImage = ciContext.createCGImage(ciImage, from: ciImage.extent) else {
            throw ScreenCaptureError.captureFailed
        }

        return NSImage(cgImage: cgImage, size: captureRect.size)
    }
}

