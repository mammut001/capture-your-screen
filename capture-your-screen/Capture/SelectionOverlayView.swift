import SwiftUI
import AppKit

/// Full-screen SwiftUI overlay for area selection.
/// Renders a dark, semi-transparent veil over the screen with a clear cutout
/// for the actively selected rectangle.
struct SelectionOverlayView: View {
    let onConfirm: (CGRect) -> Void
    let onCancel: () -> Void

    @State private var selection: CGRect? = nil
    @State private var dragStart: CGPoint? = nil
    @State private var isSelectionFinalized: Bool = false
    @FocusState private var isFocused: Bool
    @State private var eventMonitor: Any?

    private let minSelectionSize: CGFloat = 10

    var body: some View {
        GeometryReader { geo in
            ZStack {
                // Dark veil with a clear cutout punched out over the selection
                darkVeil(in: geo.size)
                    .allowsHitTesting(false)

                // Selection border and action buttons
                if let rect = selection, rect.width >= minSelectionSize, rect.height >= minSelectionSize {
                    selectionBorder(rect: rect)

                    if isSelectionFinalized {
                        actionButtons(for: rect)
                    }
                }

                // Instruction label at top center
                VStack {
                    instructionLabel
                        .padding(.top, 60)
                    Spacer()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(dragGesture)
            .onAppear {
                isFocused = true
                NSCursor.crosshair.push()
                eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                    if event.keyCode == 53 { // Escape
                        // Defer to next run loop to avoid re-entrancy while inside event callback
                        DispatchQueue.main.async { onCancel() }
                        return nil
                    } else if event.keyCode == 36 || event.keyCode == 76 { // Return / Enter
                        // Confirm capture if a valid selection exists, otherwise cancel
                        DispatchQueue.main.async {
                            if let rect = self.selection,
                               rect.width >= self.minSelectionSize,
                               rect.height >= self.minSelectionSize {
                                onConfirm(rect)
                            } else {
                                onCancel()
                            }
                        }
                        return nil
                    }
                    return event
                }
            }
            .onDisappear {
                NSCursor.pop()
                if let monitor = eventMonitor {
                    NSEvent.removeMonitor(monitor)
                }
            }
            .focusable()
            .focused($isFocused)
        }
        .ignoresSafeArea()
    }

    // MARK: - Sub-views

    private func darkVeil(in size: CGSize) -> some View {
        ZStack {
            Color.black.opacity(0.4)
            if let rect = selection, rect.width > 0, rect.height > 0 {
                Rectangle()
                    .fill(Color.black)
                    .frame(width: rect.width, height: rect.height)
                    .position(x: rect.midX, y: rect.midY)
                    .blendMode(.destinationOut)
            }
        }
        .drawingGroup()   // Required for destinationOut blend mode to composite correctly
        .frame(width: size.width, height: size.height)
    }

    private func selectionBorder(rect: CGRect) -> some View {
        ZStack {
            // 1pt white border
            Rectangle()
                .strokeBorder(Color.white, lineWidth: 1)
                .frame(width: rect.width, height: rect.height)
                .position(x: rect.midX, y: rect.midY)

            // Corner + midpoint handles
            ForEach(handlePositions(for: rect), id: \.self) { point in
                Rectangle()
                    .fill(Color.white)
                    .frame(width: 8, height: 8)
                    .shadow(radius: 1)
                    .position(point)
            }

            // Dimensions label inside/below selection
            Text("\(Int(rect.width)) × \(Int(rect.height))")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(Color.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 4))
                .position(x: rect.midX, y: rect.maxY + 16)
        }
    }

    private var instructionLabel: some View {
        Text("Drag to select — Esc to cancel, ↵ to capture")
            .font(.system(size: 13, weight: .medium))
            .foregroundColor(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Color.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
    }

    // MARK: - Drag gesture

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { value in
                let start = value.startLocation
                let current = value.location
                selection = CGRect(
                    x: min(start.x, current.x),
                    y: min(start.y, current.y),
                    width: abs(current.x - start.x),
                    height: abs(current.y - start.y)
                )
            }
            .onEnded { _ in
                isSelectionFinalized = true
            }
    }

    // MARK: - Action buttons

    private func actionButtons(for rect: CGRect) -> some View {
        HStack(spacing: 12) {
            // X button — cancel selection and let user re-select
            Button(action: {
                isSelectionFinalized = false
                selection = nil
            }) {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(.white)
                    .frame(width: 32, height: 32)
                    .background(Color.black.opacity(0.7), in: Circle())
            }
            .buttonStyle(.plain)

            // Checkmark button — confirm and capture
            Button(action: {
                if let rect = selection {
                    let captureRect = rect
                    // Defer to next run loop to avoid SwiftUI button handler re-entrancy
                    DispatchQueue.main.async { onConfirm(captureRect) }
                }
            }) {
                Image(systemName: "checkmark")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(.black)
                    .frame(width: 32, height: 32)
                    .background(Color.green, in: Circle())
            }
            .buttonStyle(.plain)
        }
        .position(x: rect.midX, y: rect.maxY + 30)
    }

    // MARK: - Helpers

    private func confirmIfPossible() {
        guard let rect = selection,
              rect.width >= minSelectionSize,
              rect.height >= minSelectionSize else { return }
        onConfirm(rect)
    }

    /// Returns all 8 handle positions (4 corners + 4 edge midpoints) for a given rect.
    private func handlePositions(for rect: CGRect) -> [CGPoint] {
        [
            CGPoint(x: rect.minX, y: rect.minY),
            CGPoint(x: rect.midX, y: rect.minY),
            CGPoint(x: rect.maxX, y: rect.minY),
            CGPoint(x: rect.maxX, y: rect.midY),
            CGPoint(x: rect.maxX, y: rect.maxY),
            CGPoint(x: rect.midX, y: rect.maxY),
            CGPoint(x: rect.minX, y: rect.maxY),
            CGPoint(x: rect.minX, y: rect.midY),
        ]
    }
}
