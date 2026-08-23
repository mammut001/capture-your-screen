//
//  ScreenshotCropping.swift
//  capture-your-screen
//
//  Crops a full-display freeze-frame using screen-local (top-left) point
//  coordinates from the selection overlay. Scale is derived from the actual
//  CGImage pixel size vs logical screen size — never hard-coded 2x.
//

import AppKit
import CoreGraphics
import Foundation

enum ScreenshotCropping {

    /// Convert a screen-local point rect into a CGImage pixel rect (top-left origin).
    /// Returns `nil` when inputs are invalid or the result would be empty after clamping.
    static func pixelRect(
        forScreenLocalRect rect: CGRect,
        logicalScreenSize: CGSize,
        imagePixelSize: CGSize
    ) -> CGRect? {
        guard logicalScreenSize.width > 0, logicalScreenSize.height > 0,
              imagePixelSize.width > 0, imagePixelSize.height > 0 else {
            return nil
        }

        let scaleX = imagePixelSize.width / logicalScreenSize.width
        let scaleY = imagePixelSize.height / logicalScreenSize.height

        let integral = rect.integral
        var pixel = CGRect(
            x: floor(integral.origin.x * scaleX),
            y: floor(integral.origin.y * scaleY),
            width: floor(integral.width * scaleX),
            height: floor(integral.height * scaleY)
        )

        let bounds = CGRect(origin: .zero, size: imagePixelSize)
        pixel = pixel.intersection(bounds).integral
        guard pixel.width >= 1, pixel.height >= 1 else { return nil }
        return pixel
    }

    /// Crop `image` using a selection rect in the same top-left point space as
    /// `SelectionOverlayView` / ScreenCaptureKit `sourceRect`.
    static func crop(
        image: NSImage,
        toScreenLocalRect rect: CGRect,
        logicalScreenSize: CGSize
    ) -> NSImage? {
        guard let cgImage = pixelCGImage(of: image) else { return nil }

        let imagePixelSize = CGSize(width: cgImage.width, height: cgImage.height)
        guard let pixel = pixelRect(
            forScreenLocalRect: rect,
            logicalScreenSize: logicalScreenSize,
            imagePixelSize: imagePixelSize
        ) else {
            return nil
        }

        guard let cropped = cgImage.cropping(to: pixel) else { return nil }

        let scaleX = imagePixelSize.width / logicalScreenSize.width
        let scaleY = imagePixelSize.height / logicalScreenSize.height
        let pointSize = CGSize(
            width: CGFloat(cropped.width) / max(scaleX, .leastNonzeroMagnitude),
            height: CGFloat(cropped.height) / max(scaleY, .leastNonzeroMagnitude)
        )
        return NSImage(cgImage: cropped, size: pointSize)
    }

    private static func pixelCGImage(of image: NSImage) -> CGImage? {
        if let rep = image.representations
            .compactMap({ $0 as? NSBitmapImageRep })
            .max(by: { $0.pixelsWide * $0.pixelsHigh < $1.pixelsWide * $1.pixelsHigh }),
           let cg = rep.cgImage {
            return cg
        }
        var proposed = NSRect(origin: .zero, size: image.size)
        return image.cgImage(forProposedRect: &proposed, context: nil, hints: nil)
    }
}
