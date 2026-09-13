import SwiftUI
import AppKit
import CoreGraphics

/// Full-screen SwiftUI overlay for area selection.
/// Shows a **frozen** full-display screenshot underneath a dark veil so the
/// selection cutout reveals the captured frame (including menus / popovers)
/// instead of the live desktop.
struct SelectionOverlayView: View {
    /// Full-display freeze-frame captured before this overlay appeared.
    let frozenImage: NSImage
    /// Window/popover bounds sampled before the overlay could dismiss it.
    let initialSelection: CGRect?
    /// Immutable pre-overlay candidates used for both hover and click snapping.
    let windowCandidates: [CaptureWindowCandidate]
    let onConfirm: (CGRect) -> Void
    let onQuickSave: (CGRect) -> Void
    let onCancel: () -> Void
    let onSelectionChanged: (CGRect?) -> Void
    let screen: NSScreen
    let hotkeyConfig: HotkeyConfiguration

    @State private var selection: CGRect? = nil
    @State private var dragStart: CGPoint? = nil
    @State private var selectionBeforePress: CGRect? = nil
    @State private var isManualDragging: Bool = false
    @State private var lastHoverLocation: CGPoint? = nil
    @State private var isSelectionFinalized: Bool = false
    @State private var showKeyVisualizer: Bool = false

    private let minSelectionSize: CGFloat = 10
    private let clickSelectionThreshold: CGFloat = 6

    var body: some View {
        GeometryReader { geo in
            ZStack {
                // Freeze-frame fills the overlay so cutouts show the captured UI.
                Image(nsImage: frozenImage)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: geo.size.width, height: geo.size.height)
                    .allowsHitTesting(false)

                // Dark veil with a clear cutout punched out over the selection
                darkVeil(in: geo.size)
                    .allowsHitTesting(false)

                // Keep selection gestures below controls so Quick Save / confirm
                // clicks can never be stolen by the zero-distance drag gesture.
                interactionCanvas(size: geo.size)

                // Selection border and action buttons
                if let rect = selection, rect.width >= minSelectionSize, rect.height >= minSelectionSize {
                    selectionBorder(rect: rect)
                        .allowsHitTesting(false)

                    if isSelectionFinalized {
                        actionButtons(for: rect, canvasSize: geo.size)
                    }
                }

                // Instruction label — fixed at top, never moves
                instructionLabel
                    .padding(.top, 24)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .allowsHitTesting(false)

                // Key visualizer — overlaid independently so it doesn't shift the label
                if showKeyVisualizer {
                    KeyVisualizerView(config: hotkeyConfig, isActive: false)
                        .transition(.scale(scale: 0.85).combined(with: .opacity))
                        .padding(.top, 72)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                        .allowsHitTesting(false)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onChange(of: selection) { _, newSelection in
                onSelectionChanged(newSelection)
            }
            .onAppear {
                NSCursor.crosshair.push()
                if let initialSelection {
                    selection = initialSelection
                    // Initial geometry is a hover proposal; click locks it.
                    isSelectionFinalized = false
                    onSelectionChanged(initialSelection)
                } else {
                    initializeDefaultSelectionAtMouseLocation()
                    onSelectionChanged(selection)
                }
                // Briefly flash the active hotkey as visual confirmation
                withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) { showKeyVisualizer = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    withAnimation(.easeInOut(duration: 0.2)) { showKeyVisualizer = false }
                }
            }
            .onDisappear {
                NSCursor.pop()
            }
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
            ForEach(Array(handlePositions(for: rect).enumerated()), id: \.offset) { _, point in
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
                .position(
                    x: min(max(rect.midX, 42), max(42, screen.frame.width - 42)),
                    y: rect.maxY + 24 <= screen.frame.height ? rect.maxY + 16 : max(10, rect.minY - 16)
                )
        }
    }

    private var instructionLabel: some View {
        Text("Move to target, click to lock, or drag — Esc cancel, ⌘↩ quick save, ↵ annotate")
            .font(.system(size: 13, weight: .medium))
            .foregroundColor(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Color.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
    }

    // MARK: - Drag gesture

    private func interactionCanvas(size: CGSize) -> some View {
        Color.clear
            .contentShape(Rectangle())
            .frame(width: size.width, height: size.height)
            // NSTrackingArea (.activeAlways) + global mouse-moved: works without a
            // priming click and without NSApp.activate (menus stay open).
            .background(
                OverlayMouseMoveMonitor(
                    isEnabled: !isSelectionFinalized && dragStart == nil,
                    screen: screen,
                    onMove: { location in
                        applyPointerMove(to: location, canvasSize: size)
                    }
                )
            )
            .gesture(dragGesture)
    }

    /// Shared path for tracking-area / global monitor moves (no priming click).
    private func applyPointerMove(to location: CGPoint, canvasSize: CGSize) {
        var session = OverlayHoverSession(
            selection: selection,
            lastHoverLocation: lastHoverLocation,
            isSelectionFinalized: isSelectionFinalized,
            isDragging: dragStart != nil
        )
        guard session.pointerMoved(
            to: location,
            candidates: windowCandidates,
            screenSize: canvasSize
        ) else {
            lastHoverLocation = session.lastHoverLocation
            return
        }
        lastHoverLocation = session.lastHoverLocation
        selection = session.selection
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { value in
                let start = dragStart ?? value.startLocation
                if dragStart == nil {
                    dragStart = value.startLocation
                    selectionBeforePress = selection
                    isManualDragging = false
                    isSelectionFinalized = false
                }

                let current = value.location

                guard distanceBetween(start, current) > clickSelectionThreshold else {
                    // Preserve the hover proposal during normal click jitter.
                    selection = selectionBeforePress
                    return
                }

                isManualDragging = true

                selection = CGRect(
                    x: min(start.x, current.x),
                    y: min(start.y, current.y),
                    width: abs(current.x - start.x),
                    height: abs(current.y - start.y)
                )
            }
            .onEnded { value in
                let start = dragStart ?? value.startLocation
                let end = value.location
                dragStart = nil

                guard isManualDragging,
                      distanceBetween(start, end) > clickSelectionThreshold else {
                    if let autoSelection = autoSelectionRect(at: end) {
                        selection = autoSelection
                        isSelectionFinalized = true
                    } else {
                        selection = nil
                        isSelectionFinalized = false
                    }
                    selectionBeforePress = nil
                    isManualDragging = false
                    return
                }

                if let rect = selection,
                   rect.width >= minSelectionSize,
                   rect.height >= minSelectionSize {
                    isSelectionFinalized = true
                } else {
                    selection = nil
                    isSelectionFinalized = false
                }
                selectionBeforePress = nil
                isManualDragging = false
            }
    }

    // MARK: - Action buttons

    private func actionButtons(for rect: CGRect, canvasSize: CGSize) -> some View {
        HStack(spacing: 12) {
            // X button — cancel selection and let user re-select via hover immediately
            Button(action: {
                var session = OverlayHoverSession(
                    selection: selection,
                    lastHoverLocation: lastHoverLocation,
                    isSelectionFinalized: true,
                    isDragging: false
                )
                session.unlock(candidates: windowCandidates, screenSize: canvasSize)
                isSelectionFinalized = session.isSelectionFinalized
                lastHoverLocation = session.lastHoverLocation
                selection = session.selection
                // Re-snap under the live cursor so the next move is not required
                // to "wake" tracking after unlock.
                let live = CaptureWindowSelection.screenLocalPoint(
                    fromCocoaGlobal: NSEvent.mouseLocation,
                    on: screen
                )
                applyPointerMove(to: live, canvasSize: canvasSize)
            }) {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(.white)
                    .frame(width: 32, height: 32)
                    .background(Color.black.opacity(0.7), in: Circle())
            }
            .buttonStyle(.plain)

            // Quick Save button — save immediately, bypass annotation editor
            Button(action: {
                if let rect = selection {
                    DispatchQueue.main.async { onQuickSave(rect) }
                }
            }) {
                HStack(spacing: 5) {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 11, weight: .bold))
                    Text("Quick Save")
                        .font(.system(size: 11, weight: .bold))
                }
                .foregroundColor(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.accentColor, in: Capsule())
            }
            .buttonStyle(.plain)

            // Checkmark button — confirm and capture (with annotation)
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
        .position(
            x: min(max(rect.midX, 100), max(100, canvasSize.width - 100)),
            y: rect.maxY + 50 <= canvasSize.height ? rect.maxY + 30 : max(24, rect.minY - 30)
        )
    }

    // MARK: - Helpers

    private func distanceBetween(_ lhs: CGPoint, _ rhs: CGPoint) -> CGFloat {
        hypot(rhs.x - lhs.x, rhs.y - lhs.y)
    }

    private func initializeDefaultSelectionAtMouseLocation() {
        let local = CaptureWindowSelection.screenLocalPoint(fromCocoaGlobal: NSEvent.mouseLocation, on: screen)
        lastHoverLocation = local
        selection = autoSelectionRect(at: local)
        isSelectionFinalized = false
    }

    private func autoSelectionRect(at localPoint: CGPoint) -> CGRect? {
        CaptureWindowSelection.selectionRect(
            at: localPoint,
            candidates: windowCandidates,
            screenSize: screen.frame.size
        )
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
