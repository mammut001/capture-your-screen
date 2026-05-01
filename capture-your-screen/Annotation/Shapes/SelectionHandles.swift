//
//  SelectionHandles.swift
//  capture-your-screen
//
//  Draws draggable handles at meaningful positions of the selected item.
//

import SwiftUI

enum AnnotationHandle: Hashable {
    case start       // arrow start / rect top-left / text anchor / step center
    case end         // arrow end / rect bottom-right
    case body        // whole-item move (no visual, gesture lives on item)
}

struct SelectionHandlesView: View {
    let item: AnnotationItem
    let displayRect: CGRect         // the rect where the image is actually drawn (in local coords)
    /// Called when a handle is dragged. Delta is in display-space points.
    let onHandleDrag: (AnnotationHandle, CGPoint, Bool) -> Void // (handle, newLocationInDisplay, isFinalCommit)

    var body: some View {
        ZStack(alignment: .topLeading) {
            switch item.type {
            case .arrow:
                handle(at: denorm(item.startPoint), kind: .start)
                handle(at: denorm(item.endPoint),   kind: .end)
            case .rectangle:
                let r = item.normalizedRect
                handle(at: denorm(CGPoint(x: r.minX, y: r.minY)), kind: .start)
                handle(at: denorm(CGPoint(x: r.maxX, y: r.maxY)), kind: .end)
            case .ellipse:
                let r = item.normalizedRect
                handle(at: denorm(CGPoint(x: r.minX, y: r.minY)), kind: .start)
                handle(at: denorm(CGPoint(x: r.maxX, y: r.maxY)), kind: .end)
            case .text, .stepNumber:
                // single anchor handle shown at startPoint
                handle(at: denorm(item.startPoint), kind: .start)
            case .pixelate, .blur:
                // These are rect-like; show diagonal handles like rectangle.
                let r = item.normalizedRect
                handle(at: denorm(CGPoint(x: r.minX, y: r.minY)), kind: .start)
                handle(at: denorm(CGPoint(x: r.maxX, y: r.maxY)), kind: .end)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func denorm(_ p: CGPoint) -> CGPoint {
        CGPoint(
            x: displayRect.origin.x + p.x * displayRect.width,
            y: displayRect.origin.y + p.y * displayRect.height
        )
    }

    private func handle(at point: CGPoint, kind: AnnotationHandle) -> some View {
        let size: CGFloat = 10
        return Circle()
            .fill(Color.white)
            .overlay(Circle().stroke(Color.accentColor, lineWidth: 1.5))
            .frame(width: size, height: size)
            .shadow(color: .black.opacity(0.3), radius: 1, x: 0, y: 1)
            .position(x: point.x, y: point.y)
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .local)
                    .onChanged { g in
                        onHandleDrag(kind, g.location, false)
                    }
                    .onEnded { g in
                        onHandleDrag(kind, g.location, true)
                    }
            )
    }
}
