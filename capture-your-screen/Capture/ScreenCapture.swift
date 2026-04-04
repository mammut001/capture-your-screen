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
    /// Capture a region of the main display (rect in screen coordinates, bottom-left origin, logical points).
    /// Marked nonisolated to avoid deadlock when called from a main-actor context (local monitor / keyDown).
    static nonisolated func captureRegion(_ rect: CGRect) async throws -> NSImage {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)

        // Find the display matching the main screen
        let mainDisplayID = CGMainDisplayID()
        guard let scDisplay = content.displays.first(where: { $0.displayID == mainDisplayID })
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
        config.sourceRect = rect
        config.width = max(1, Int(rect.width * scaleFactor))
        config.height = max(1, Int(rect.height * scaleFactor))
        config.capturesAudio = false
        config.pixelFormat = kCVPixelFormatType_32BGRA

        let sampleBuffer = try await SCScreenshotManager.captureSampleBuffer(
            contentFilter: filter,
            configuration: config
        )

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            throw ScreenCaptureError.captureFailed
        }

        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let ciContext = CIContext()
        guard let cgImage = ciContext.createCGImage(ciImage, from: ciImage.extent) else {
            throw ScreenCaptureError.captureFailed
        }

        return NSImage(cgImage: cgImage, size: rect.size)
    }
}

