import SwiftUI
import AppKit

struct CopyToastView: View {
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "doc.on.doc.fill")
                .foregroundColor(.green)
            VStack(alignment: .leading, spacing: 1) {
                Text("Copied")
                    .font(.caption.bold())
                Text("Screenshot copied to clipboard")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            Spacer()
            Image(systemName: "checkmark.circle.fill")
                .foregroundColor(.green)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(NSColor.windowBackgroundColor))
                .shadow(radius: 6, y: 2)
        )
        .padding(.horizontal, 16)
    }
}
