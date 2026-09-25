//
//  AnnotationCompositorTests.swift
//  capture-your-screenTests
//
//  Verifies that AnnotationCompositor does not invert/flip images
//  and places annotations at the expected visual locations.
//

import XCTest
import AppKit
@testable import capture_your_screen

final class AnnotationCompositorTests: XCTestCase {

    /// Helper to create a 200x200 test image whose visual top half is Red
    /// and visual bottom half is Blue.
    private func makeTestImage(width: Int = 200, height: Int = 200) -> NSImage {
        let cs = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: cs,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!

        // In CoreGraphics context, y=0 is bottom, y=height is top.
        // Bottom half: Blue
        ctx.setFillColor(NSColor.blue.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height / 2))
        // Top half: Red
        ctx.setFillColor(NSColor.red.cgColor)
        ctx.fill(CGRect(x: 0, y: height / 2, width: width, height: height / 2))

        let cgImage = ctx.makeImage()!
        return NSImage(cgImage: cgImage, size: NSSize(width: width, height: height))
    }

    func testComposite_emptyAnnotationsReturnsOriginalImage() {
        let base = makeTestImage()
        let result = AnnotationCompositor.composite(baseImage: base, annotations: [])
        XCTAssertTrue(result === base)
    }

    func testComposite_doesNotFlipImageVertically() {
        let base = makeTestImage(width: 200, height: 200)

        // Add a dummy annotation so composite() enters the rendering path
        var item = AnnotationItem(type: .rectangle)
        item.startPoint = CGPoint(x: 0.4, y: 0.4)
        item.endPoint = CGPoint(x: 0.6, y: 0.6)
        item.colorHex = "#00FF00"
        item.lineWidth = 2

        let composited = AnnotationCompositor.composite(baseImage: base, annotations: [item])

        // Verify that the output image maintains top-is-red and bottom-is-blue
        guard let tiffData = composited.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiffData) else {
            XCTFail("Failed to get NSBitmapImageRep from composited image")
            return
        }

        // Check pixel at visual top (x: 10, y: 10 in top-down coordinates)
        let topColor = rep.colorAt(x: 10, y: 10)
        XCTAssertNotNil(topColor)
        XCTAssertGreaterThan(topColor?.redComponent ?? 0, 0.8, "Top of image should be red")
        XCTAssertLessThan(topColor?.blueComponent ?? 1, 0.2, "Top of image should not be blue")

        // Check pixel at visual bottom (x: 10, y: 190 in top-down coordinates)
        let bottomColor = rep.colorAt(x: 10, y: 190)
        XCTAssertNotNil(bottomColor)
        XCTAssertGreaterThan(bottomColor?.blueComponent ?? 0, 0.8, "Bottom of image should be blue")
        XCTAssertLessThan(bottomColor?.redComponent ?? 1, 0.2, "Bottom of image should not be red")
    }

    func testComposite_placesAnnotationsAtExpectedVisualPositions() {
        let base = makeTestImage(width: 200, height: 200)

        // Place a green rectangle at the visual top: y=0.05..0.25 (row 10..50)
        var topBox = AnnotationItem(type: .rectangle)
        topBox.startPoint = CGPoint(x: 0.2, y: 0.05)
        topBox.endPoint = CGPoint(x: 0.8, y: 0.25)
        topBox.colorHex = "#00FF00"
        topBox.lineWidth = 10

        // Place a magenta rectangle at the visual bottom: y=0.75..0.95 (row 150..190)
        var bottomBox = AnnotationItem(type: .rectangle)
        bottomBox.startPoint = CGPoint(x: 0.2, y: 0.75)
        bottomBox.endPoint = CGPoint(x: 0.8, y: 0.95)
        bottomBox.colorHex = "#FF00FF"
        bottomBox.lineWidth = 10

        let composited = AnnotationCompositor.composite(baseImage: base, annotations: [topBox, bottomBox])

        guard let tiffData = composited.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiffData) else {
            XCTFail("Failed to get NSBitmapImageRep from composited image")
            return
        }

        // Inside the topBox (e.g. x: 100, y: 10): should have green
        let topBoxColor = rep.colorAt(x: 100, y: 10)
        XCTAssertGreaterThan(topBoxColor?.greenComponent ?? 0, 0.7, "Top box stroke should be green")

        // Inside the bottomBox (e.g. x: 100, y: 190): should have magenta (red + blue)
        let bottomBoxColor = rep.colorAt(x: 100, y: 190)
        XCTAssertGreaterThan(bottomBoxColor?.redComponent ?? 0, 0.7, "Bottom box stroke should have red")
        XCTAssertGreaterThan(bottomBoxColor?.blueComponent ?? 0, 0.7, "Bottom box stroke should have blue")
    }
}
