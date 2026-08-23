import ScreenCaptureKit
import CoreMedia
import CoreImage
import AppKit
import os

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
    nonisolated static let ciContext = CIContext()
    private nonisolated static let logger = Logger(
        subsystem: "com.captureyourscreen.capture",
        category: "ScreenCapture"
    )

    /// Capture the entire specified display (display-local origin at top-left).
    /// Used to freeze the screen *before* showing the selection overlay so
    /// transient UI (menu bar menus, popovers, tooltips) is preserved.
    static nonisolated func captureFullDisplay(displayID: CGDirectDisplayID? = nil) async throws -> NSImage {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let scDisplay = try resolveDisplay(displayID: displayID, in: content)
        let fullRect = CGRect(x: 0, y: 0, width: scDisplay.width, height: scDisplay.height)
        return try await captureRegion(fullRect, displayID: scDisplay.displayID, content: content, scDisplay: scDisplay)
    }

    /// Capture a region of the specified display.
    /// - Parameters:
    ///   - rect: Selection rectangle in the target display's local coordinates (points, top-left origin).
    ///   - displayID: The display to capture from. If nil, uses the primary display.
    /// Marked nonisolated to avoid deadlock when called from a main-actor context (local monitor / keyDown).
    static nonisolated func captureRegion(_ rect: CGRect, displayID: CGDirectDisplayID? = nil) async throws -> NSImage {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let scDisplay = try resolveDisplay(displayID: displayID, in: content)
        return try await captureRegion(rect, displayID: scDisplay.displayID, content: content, scDisplay: scDisplay)
    }

    // MARK: - Internals

    private static nonisolated func resolveDisplay(
        displayID: CGDirectDisplayID?,
        in content: SCShareableContent
    ) throws -> SCDisplay {
        let targetDisplayID = displayID ?? CGMainDisplayID()
        if let match = content.displays.first(where: { $0.displayID == targetDisplayID }) {
            return match
        }
        Self.logger.warning("Requested display \(targetDisplayID) not found, falling back to first available display")
        guard let fallback = content.displays.first else {
            throw ScreenCaptureError.noDisplayFound
        }
        return fallback
    }

    private static nonisolated func captureRegion(
        _ rect: CGRect,
        displayID: CGDirectDisplayID,
        content: SCShareableContent,
        scDisplay: SCDisplay
    ) async throws -> NSImage {
        _ = content
        _ = displayID

        // Prefer the live NSScreen backing scale; fall back to pixel/point ratio from SCDisplay.
        let scaleFactor: CGFloat = {
            if let screenScale = NSScreen.screens.first(where: {
                ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber") as NSDeviceDescriptionKey]
                    as? CGDirectDisplayID) == scDisplay.displayID
            })?.backingScaleFactor {
                return screenScale
            }
            // SCDisplay width/height are in points; frame size in pixels when available via CGDisplay.
            let pixelW = CGFloat(CGDisplayPixelsWide(scDisplay.displayID))
            let pointW = CGFloat(scDisplay.width)
            if pointW > 0, pixelW > 0 {
                return pixelW / pointW
            }
            return NSScreen.main?.backingScaleFactor ?? 1.0
        }()

        let filter = SCContentFilter(
            display: scDisplay,
            excludingApplications: [],
            exceptingWindows: []
        )

        let config = SCStreamConfiguration()
        let captureRect = rect.integral
        config.sourceRect = captureRect
        config.width = max(1, Int((captureRect.width * scaleFactor).rounded()))
        config.height = max(1, Int((captureRect.height * scaleFactor).rounded()))
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
        guard let cgImage = Self.ciContext.createCGImage(ciImage, from: ciImage.extent) else {
            throw ScreenCaptureError.captureFailed
        }

        return NSImage(cgImage: cgImage, size: captureRect.size)
    }
}
