//
//  StepNumberBadge.swift
//  capture-your-screen
//

import SwiftUI

struct StepNumberBadge: View {
    let number: Int
    let color: Color
    let diameter: CGFloat

    init(number: Int, color: Color, diameter: CGFloat = 30) {
        self.number = number
        self.color = color
        self.diameter = diameter
    }

    var body: some View {
        ZStack {
            Circle()
                .fill(color)
                .frame(width: diameter, height: diameter)
                .shadow(color: .black.opacity(0.25), radius: 2, x: 0, y: 1)
            Text("\(number)")
                .font(.system(size: diameter * 0.55, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .monospacedDigit()
        }
    }
}
