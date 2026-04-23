//
//  ArrowShape.swift
//  capture-your-screen
//
//  A SwiftUI Shape that draws a straight line with a filled triangular
//  arrowhead at `end`.
//

import SwiftUI

struct ArrowShape: Shape {
    var start: CGPoint
    var end: CGPoint
    var headLength: CGFloat = 14
    var headAngle: CGFloat = .pi / 7 // ~25°

    func path(in rect: CGRect) -> Path {
        var p = Path()
        guard start != end else { return p }

        let dx = end.x - start.x
        let dy = end.y - start.y
        let angle = atan2(dy, dx)

        // Shorten the shaft slightly so the tip sits cleanly inside the arrowhead.
        let shaftEnd = CGPoint(
            x: end.x - cos(angle) * headLength * 0.6,
            y: end.y - sin(angle) * headLength * 0.6
        )

        p.move(to: start)
        p.addLine(to: shaftEnd)

        // Arrowhead: filled triangle at `end`.
        let left = CGPoint(
            x: end.x - headLength * cos(angle - headAngle),
            y: end.y - headLength * sin(angle - headAngle)
        )
        let right = CGPoint(
            x: end.x - headLength * cos(angle + headAngle),
            y: end.y - headLength * sin(angle + headAngle)
        )
        p.move(to: end)
        p.addLine(to: left)
        p.addLine(to: right)
        p.closeSubpath()

        return p
    }

    var animatableData: AnimatablePair<CGPoint.AnimatableData, CGPoint.AnimatableData> {
        get { AnimatablePair(start.animatableData, end.animatableData) }
        set {
            start.animatableData = newValue.first
            end.animatableData = newValue.second
        }
    }
}
