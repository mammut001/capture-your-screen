//
//  AnnotationRenderer.swift
//  capture-your-screen
//
//  SwiftUI rendering for annotation items. This is a pure (read-only) view
//  that draws all items onto the canvas. Interaction lives in
//  AnnotationCanvasView.
//

import SwiftUI

/// Draws all annotation items inside a rectangle that matches the displayed
/// image's frame (`displayRect`, in the parent's local coordinate space).
struct AnnotationOverlayView: View {
    @ObservedObject var canvas: AnnotationCanvas
    /// The rect inside the parent view where the image is actually drawn.
    let displayRect: CGRect

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(canvas.items) { item in
                renderItem(item)
                    .opacity(item.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private func renderItem(_ item: AnnotationItem) -> some View {
        switch item.type {
        case .arrow:
            ArrowShape(start: denorm(item.startPoint), end: denorm(item.endPoint))
                .fill(item.color)
                .overlay(
                    ArrowShape(start: denorm(item.startPoint), end: denorm(item.endPoint))
                        .stroke(item.color, style: StrokeStyle(lineWidth: item.lineWidth, lineCap: .round, lineJoin: .round))
                )

        case .rectangle:
            let r = denormRect(item.normalizedRect)
            Rectangle()
                .stroke(item.color, lineWidth: item.lineWidth)
                .frame(width: max(r.width, 1), height: max(r.height, 1))
                .position(x: r.midX, y: r.midY)

        case .text:
            let p = denorm(item.startPoint)
            Text(item.textContent.isEmpty ? "Text" : item.textContent)
                .font(.system(size: item.fontSize, weight: .semibold))
                .foregroundStyle(item.color)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.black.opacity(item.textContent.isEmpty ? 0.15 : 0.0))
                )
                .position(x: p.x, y: p.y)

        case .stepNumber:
            let p = denorm(item.startPoint)
            let d = max(24, item.fontSize * 1.8)
            StepNumberBadge(number: item.stepNumber, color: item.color, diameter: d)
                .position(x: p.x, y: p.y)
        }
    }

    // MARK: - Coordinate helpers

    private func denorm(_ p: CGPoint) -> CGPoint {
        CGPoint(
            x: displayRect.origin.x + p.x * displayRect.width,
            y: displayRect.origin.y + p.y * displayRect.height
        )
    }

    private func denormRect(_ r: CGRect) -> CGRect {
        CGRect(
            x: displayRect.origin.x + r.origin.x * displayRect.width,
            y: displayRect.origin.y + r.origin.y * displayRect.height,
            width: r.width * displayRect.width,
            height: r.height * displayRect.height
        )
    }
}
