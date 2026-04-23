import SwiftUI

/// Animated rotating rainbow stroke border.
struct RainbowBorderView: View {
    var cornerRadius: CGFloat = 6
    @State private var phase: Double = 0

    private static let colors: [Color] = [
        .red, .orange, .yellow, .green, .blue, .purple, .red
    ]

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius)
            .strokeBorder(
                AngularGradient(
                    colors: Self.colors,
                    center: .center,
                    startAngle: .degrees(phase),
                    endAngle: .degrees(phase + 360)
                ),
                lineWidth: 2
            )
            .onAppear {
                withAnimation(.linear(duration: 3).repeatForever(autoreverses: false)) {
                    phase = 360
                }
            }
    }
}
