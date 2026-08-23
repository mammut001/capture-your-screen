//
//  ScreenshotCroppingTests.swift
//  capture-your-screenTests
//
//  Pure crop / scale conversion tests for freeze-frame region extraction.
//

import XCTest
import AppKit
@testable import capture_your_screen

final class ScreenshotCroppingTests: XCTestCase {

    // MARK: - Pixel rect (1x / 2x / non-integer)

    func testPixelRect_1xScale() {
        let pixel = ScreenshotCropping.pixelRect(
            forScreenLocalRect: CGRect(x: 10, y: 20, width: 30, height: 40),
            logicalScreenSize: CGSize(width: 100, height: 100),
            imagePixelSize: CGSize(width: 100, height: 100)
        )
        XCTAssertEqual(pixel, CGRect(x: 10, y: 20, width: 30, height: 40))
    }

    func testPixelRect_2xScale() {
        let pixel = ScreenshotCropping.pixelRect(
            forScreenLocalRect: CGRect(x: 10, y: 20, width: 30, height: 40),
            logicalScreenSize: CGSize(width: 100, height: 80),
            imagePixelSize: CGSize(width: 200, height: 160)
        )
        XCTAssertEqual(pixel, CGRect(x: 20, y: 40, width: 60, height: 80))
    }

    func testPixelRect_nonIntegerScale() {
        // 1440 / 1280 = 1.125
        let pixel = ScreenshotCropping.pixelRect(
            forScreenLocalRect: CGRect(x: 16, y: 8, width: 64, height: 32),
            logicalScreenSize: CGSize(width: 1280, height: 800),
            imagePixelSize: CGSize(width: 1440, height: 900)
        )
        XCTAssertEqual(pixel?.origin.x, floor(16 * 1.125))
        XCTAssertEqual(pixel?.origin.y, floor(8 * 1.125))
        XCTAssertEqual(pixel?.width, floor(64 * 1.125))
        XCTAssertEqual(pixel?.height, floor(32 * 1.125))
    }

    func testPixelRect_clampsToImageBounds() {
        let pixel = ScreenshotCropping.pixelRect(
            forScreenLocalRect: CGRect(x: 90, y: 90, width: 50, height: 50),
            logicalScreenSize: CGSize(width: 100, height: 100),
            imagePixelSize: CGSize(width: 100, height: 100)
        )
        XCTAssertEqual(pixel, CGRect(x: 90, y: 90, width: 10, height: 10))
    }

    func testPixelRect_rejectsEmptyAfterClamp() {
        let pixel = ScreenshotCropping.pixelRect(
            forScreenLocalRect: CGRect(x: 100, y: 100, width: 10, height: 10),
            logicalScreenSize: CGSize(width: 100, height: 100),
            imagePixelSize: CGSize(width: 100, height: 100)
        )
        XCTAssertNil(pixel)
    }

    func testPixelRect_rejectsInvalidLogicalSize() {
        XCTAssertNil(
            ScreenshotCropping.pixelRect(
                forScreenLocalRect: CGRect(x: 0, y: 0, width: 10, height: 10),
                logicalScreenSize: .zero,
                imagePixelSize: CGSize(width: 100, height: 100)
            )
        )
    }

    // MARK: - Actual crop

    func testCrop_2xProducesExpectedPixelSize() throws {
        let logical = CGSize(width: 100, height: 50)
        let image = try makeSolidImage(pixelWidth: 200, pixelHeight: 100, pointSize: logical)
        let cropped = ScreenshotCropping.crop(
            image: image,
            toScreenLocalRect: CGRect(x: 10, y: 5, width: 20, height: 10),
            logicalScreenSize: logical
        )
        XCTAssertNotNil(cropped)
        guard let cg = cropped?.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return XCTFail("Missing CGImage")
        }
        XCTAssertEqual(cg.width, 40)
        XCTAssertEqual(cg.height, 20)
    }

    func testCrop_topLeftOrigin_doesNotFlipY() throws {
        // Top-left 10×10 logical rect on a 2x 40×40 image → pixels (0,0,20,20).
        // If Y were flipped we'd get the bottom strip instead.
        let logical = CGSize(width: 20, height: 20)
        let image = try makeGradientImage(pixelWidth: 40, pixelHeight: 40, pointSize: logical)
        let cropped = ScreenshotCropping.crop(
            image: image,
            toScreenLocalRect: CGRect(x: 0, y: 0, width: 10, height: 10),
            logicalScreenSize: logical
        )
        XCTAssertNotNil(cropped)
        guard let cg = cropped?.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return XCTFail("Missing CGImage")
        }
        XCTAssertEqual(cg.width, 20)
        XCTAssertEqual(cg.height, 20)

        // Sample a pixel near the top-left of the crop; gradient paints red at top.
        let color = try samplePixel(cg, x: 1, y: 1)
        XCTAssertGreaterThan(color.red, 0.8, "Top-left crop should sample the top of the image (red)")
        XCTAssertLessThan(color.blue, 0.2)
    }

    // MARK: - Helpers

    private func makeSolidImage(pixelWidth: Int, pixelHeight: Int, pointSize: CGSize) throws -> NSImage {
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixelWidth,
            pixelsHigh: pixelHeight,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            throw NSError(domain: "test", code: 1)
        }
        rep.size = pointSize
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.red.setFill()
        NSRect(origin: .zero, size: pointSize).fill()
        NSGraphicsContext.restoreGraphicsState()

        let image = NSImage(size: pointSize)
        image.addRepresentation(rep)
        return image
    }

    /// Vertical gradient: red at top (y=0 in CG), blue at bottom.
    private func makeGradientImage(pixelWidth: Int, pixelHeight: Int, pointSize: CGSize) throws -> NSImage {
        guard let ctx = CGContext(
            data: nil,
            width: pixelWidth,
            height: pixelHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw NSError(domain: "test", code: 2)
        }
        // CGContext origin is bottom-left; fill top rows (high y) with red by drawing
        // a gradient from blue (bottom) to red (top) in CG space, which matches
        // CGImage row 0 = top after makeImage.
        let colors = [
            CGColor(red: 0, green: 0, blue: 1, alpha: 1),
            CGColor(red: 1, green: 0, blue: 0, alpha: 1)
        ] as CFArray
        guard let gradient = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: colors,
            locations: [0, 1]
        ) else {
            throw NSError(domain: "test", code: 3)
        }
        ctx.drawLinearGradient(
            gradient,
            start: CGPoint(x: 0, y: 0),
            end: CGPoint(x: 0, y: pixelHeight),
            options: []
        )
        guard let cgImage = ctx.makeImage() else {
            throw NSError(domain: "test", code: 4)
        }
        return NSImage(cgImage: cgImage, size: pointSize)
    }

    private struct RGBA {
        let red: CGFloat
        let green: CGFloat
        let blue: CGFloat
        let alpha: CGFloat
    }

    private func samplePixel(_ image: CGImage, x: Int, y: Int) throws -> RGBA {
        guard let data = image.dataProvider?.data,
              let ptr = CFDataGetBytePtr(data) else {
            throw NSError(domain: "test", code: 5)
        }
        let bytesPerPixel = max(1, image.bitsPerPixel / 8)
        let offset = y * image.bytesPerRow + x * bytesPerPixel
        let r = CGFloat(ptr[offset]) / 255
        let g = CGFloat(ptr[offset + 1]) / 255
        let b = CGFloat(ptr[offset + 2]) / 255
        let a = bytesPerPixel > 3 ? CGFloat(ptr[offset + 3]) / 255 : 1
        return RGBA(red: r, green: g, blue: b, alpha: a)
    }
}
