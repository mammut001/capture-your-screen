//
//  AnnotationCompositor.swift
//  capture-your-screen
//
//  Composites a base NSImage with a list of AnnotationItem values into a
//  single final NSImage using AppKit drawing. The output is rendered at the
//  original pixel resolution of the base image so exported screenshots stay
//  crisp.
//

import AppKit

enum AnnotationCompositor {

    /// Render `annotations` on top of `baseImage` and return a new NSImage.
    /// Coordinates in annotations are normalized to 0...1.
    static func composite(
        baseImage: NSImage,
        annotations: [AnnotationItem]
    ) -> NSImage {
        guard let baseRep = pixelRepresentation(of: baseImage) else {
            // Fallback: nothing we can do, return original.
            return baseImage
        }

        let pixelWidth  = CGFloat(baseRep.width)
        let pixelHeight = CGFloat(baseRep.height)
        let size = NSSize(width: pixelWidth, height: pixelHeight)

        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(pixelWidth),
            pixelsHigh: Int(pixelHeight),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            return baseImage
        }
        rep.size = size

        guard let ctx = NSGraphicsContext(bitmapImageRep: rep) else {
            return baseImage
        }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx

        // AppKit uses a bottom-left origin by default. Flip to top-left so our
        // normalized coordinates (y-down) match expectations.
        let flip = NSAffineTransform()
        flip.translateX(by: 0, yBy: pixelHeight)
        flip.scaleX(by: 1, yBy: -1)
        flip.concat()

        // 1. Draw base image.
        NSImage(cgImage: baseRep, size: size).draw(
            in: NSRect(origin: .zero, size: size),
            from: .zero,
            operation: .copy,
            fraction: 1.0,
            respectFlipped: true,
            hints: [NSImageRep.HintKey.interpolation: NSNumber(value: NSImageInterpolation.high.rawValue)]
        )

        // 2. Draw each annotation scaled to pixel size.
        for item in annotations {
            drawItem(item, canvasSize: size)
        }

        NSGraphicsContext.restoreGraphicsState()

        let result = NSImage(size: size)
        result.addRepresentation(rep)
        return result
    }

    // MARK: - Drawing

    private static func drawItem(_ item: AnnotationItem, canvasSize: NSSize) {
        let color = NSColor(cgColor: nsColor(fromHex: item.colorHex).cgColor) ?? NSColor.red
        color.withAlphaComponent(item.opacity).setStroke()
        color.withAlphaComponent(item.opacity).setFill()

        // Scale line width proportionally to image size so strokes don't look
        // hairline on high-resolution screenshots. We take the ratio against a
        // 1000-pt reference width.
        let scale = canvasSize.width / 1000.0
        let lineWidth = max(1.0, item.lineWidth * max(scale, 1))

        switch item.type {
        case .arrow:
            drawArrow(
                from: denorm(item.startPoint, size: canvasSize),
                to:   denorm(item.endPoint, size: canvasSize),
                lineWidth: lineWidth,
                color: color.withAlphaComponent(item.opacity)
            )

        case .rectangle:
            let r = denormRect(item.normalizedRect, size: canvasSize)
            let path = NSBezierPath(rect: r)
            path.lineWidth = lineWidth
            color.withAlphaComponent(item.opacity).setStroke()
            path.stroke()

        case .text:
            drawText(
                item.textContent.isEmpty ? " " : item.textContent,
                at: denorm(item.startPoint, size: canvasSize),
                fontSize: item.fontSize * max(scale, 1),
                color: color.withAlphaComponent(item.opacity)
            )

        case .stepNumber:
            drawStepNumber(
                item.stepNumber,
                at: denorm(item.startPoint, size: canvasSize),
                fontSize: item.fontSize * max(scale, 1),
                color: color.withAlphaComponent(item.opacity)
            )
        }
    }

    private static func drawArrow(from start: NSPoint, to end: NSPoint, lineWidth: CGFloat, color: NSColor) {
        let dx = end.x - start.x
        let dy = end.y - start.y
        guard dx != 0 || dy != 0 else { return }
        let angle = atan2(dy, dx)
        let headLength = max(14, lineWidth * 4)
        let headAngle: CGFloat = .pi / 7

        // Shaft
        let shaftEnd = NSPoint(
            x: end.x - cos(angle) * headLength * 0.6,
            y: end.y - sin(angle) * headLength * 0.6
        )
        let shaft = NSBezierPath()
        shaft.move(to: start)
        shaft.line(to: shaftEnd)
        shaft.lineWidth = lineWidth
        shaft.lineCapStyle = .round
        color.setStroke()
        shaft.stroke()

        // Head (filled)
        let head = NSBezierPath()
        let left = NSPoint(
            x: end.x - headLength * cos(angle - headAngle),
            y: end.y - headLength * sin(angle - headAngle)
        )
        let right = NSPoint(
            x: end.x - headLength * cos(angle + headAngle),
            y: end.y - headLength * sin(angle + headAngle)
        )
        head.move(to: end)
        head.line(to: left)
        head.line(to: right)
        head.close()
        color.setFill()
        head.fill()
    }

    private static func drawText(_ content: String, at point: NSPoint, fontSize: CGFloat, color: NSColor) {
        let font = NSFont.systemFont(ofSize: fontSize, weight: .semibold)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color
        ]
        let attributed = NSAttributedString(string: content, attributes: attrs)
        let size = attributed.size()
        // Position matches the SwiftUI renderer: `point` is the CENTER of the text.
        let rect = NSRect(
            x: point.x - size.width / 2,
            y: point.y - size.height / 2,
            width: size.width,
            height: size.height
        )
        attributed.draw(in: rect)
    }

    private static func drawStepNumber(_ number: Int, at point: NSPoint, fontSize: CGFloat, color: NSColor) {
        let diameter = max(24, fontSize * 1.8)
        let rect = NSRect(
            x: point.x - diameter / 2,
            y: point.y - diameter / 2,
            width: diameter,
            height: diameter
        )
        let circle = NSBezierPath(ovalIn: rect)
        color.setFill()
        circle.fill()

        let font = NSFont.systemFont(ofSize: diameter * 0.55, weight: .bold)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.white
        ]
        let attributed = NSAttributedString(string: "\(number)", attributes: attrs)
        let size = attributed.size()
        let textRect = NSRect(
            x: rect.midX - size.width / 2,
            y: rect.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
        attributed.draw(in: textRect)
    }

    // MARK: - Coordinate helpers

    private static func denorm(_ p: CGPoint, size: NSSize) -> NSPoint {
        NSPoint(x: p.x * size.width, y: p.y * size.height)
    }

    private static func denormRect(_ r: CGRect, size: NSSize) -> NSRect {
        NSRect(
            x: r.origin.x * size.width,
            y: r.origin.y * size.height,
            width: r.width * size.width,
            height: r.height * size.height
        )
    }

    private static func nsColor(fromHex hex: String) -> NSColor {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt64(s, radix: 16) else { return .red }
        let r = CGFloat((v >> 16) & 0xFF) / 255.0
        let g = CGFloat((v >>  8) & 0xFF) / 255.0
        let b = CGFloat(v & 0xFF) / 255.0
        return NSColor(red: r, green: g, blue: b, alpha: 1.0)
    }

    /// Returns the pixel-accurate CGImage for the NSImage, preferring the
    /// largest bitmap representation.
    private static func pixelRepresentation(of image: NSImage) -> CGImage? {
        if let rep = image.representations
            .compactMap({ $0 as? NSBitmapImageRep })
            .max(by: { $0.pixelsWide * $0.pixelsHigh < $1.pixelsWide * $1.pixelsHigh }),
           let cg = rep.cgImage {
            return cg
        }
        var rect = NSRect(origin: .zero, size: image.size)
        return image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }
}
