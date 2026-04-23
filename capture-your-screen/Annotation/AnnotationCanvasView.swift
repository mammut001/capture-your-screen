//
//  AnnotationCanvasView.swift
//  capture-your-screen
//
//  Base image + annotation overlay + gesture handling. This is where all
//  creation / selection / movement / resizing logic lives.
//

import SwiftUI
import AppKit

struct AnnotationCanvasView: View {
    let baseImage: NSImage
    @ObservedObject var canvas: AnnotationCanvas

    /// Focused text item being edited (inline text input).
    @State private var editingTextID: AnnotationID? = nil

    // Drag state
    @State private var dragMode: DragMode = .idle
    @State private var dragStartItems: [AnnotationItem] = []

    private enum DragMode {
        case idle
        case creating(id: AnnotationID)
        case moving(id: AnnotationID, grabNormOffset: CGPoint) // offset between grab point and item's startPoint
        case resizingHandle(id: AnnotationID, handle: AnnotationHandle)
    }

    var body: some View {
        GeometryReader { geo in
            let displayRect = computedDisplayRect(in: geo.size)

            ZStack(alignment: .topLeading) {
                // 1) Base image.
                Image(nsImage: baseImage)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: geo.size.width, height: geo.size.height)

                // 2) Annotations.
                AnnotationOverlayView(canvas: canvas, displayRect: displayRect)
                    .allowsHitTesting(false)

                // 3) Inline text editor (when a text item is being edited).
                if let id = editingTextID, let item = canvas.item(with: id) {
                    inlineTextEditor(for: item, in: displayRect)
                }

                // 4) Selection handles (drawn on top of everything).
                if let id = canvas.selectedItemID,
                   let item = canvas.item(with: id) {
                    SelectionHandlesView(
                        item: item,
                        displayRect: displayRect,
                        onHandleDrag: { handle, location, isFinal in
                            handleHandleDrag(item: item, handle: handle, location: location, displayRect: displayRect, isFinal: isFinal)
                        }
                    )
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .contentShape(Rectangle())
            .gesture(canvasGesture(displayRect: displayRect))
            .background(Color.black.opacity(0.02))
        }
    }

    // MARK: - Display rect calculation

    /// Compute the rect occupied by the aspect-fit image inside `container`.
    private func computedDisplayRect(in container: CGSize) -> CGRect {
        let imgW = max(baseImage.size.width, 1)
        let imgH = max(baseImage.size.height, 1)
        let scale = min(container.width / imgW, container.height / imgH)
        let w = imgW * scale
        let h = imgH * scale
        let x = (container.width - w) / 2
        let y = (container.height - h) / 2
        return CGRect(x: x, y: y, width: w, height: h)
    }

    // MARK: - Gesture

    private func canvasGesture(displayRect: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { g in
                onDragChanged(location: g.location, start: g.startLocation, displayRect: displayRect)
            }
            .onEnded { g in
                onDragEnded(location: g.location, start: g.startLocation, displayRect: displayRect,
                            isTap: (abs(g.translation.width) + abs(g.translation.height) < 3))
            }
    }

    private func onDragChanged(location: CGPoint, start: CGPoint, displayRect: CGRect) {
        guard displayRect.contains(start) else { return }
        let startNorm = normalize(start, in: displayRect)
        let curNorm   = normalize(location, in: displayRect)

        switch dragMode {
        case .idle:
            // Decide what to do based on active tool & whether the start
            // location hit an existing item.
            if let hit = hitTest(start, displayRect: displayRect) {
                // Start a move on existing item; select it first.
                canvas.selectedItemID = hit.id
                dragStartItems = canvas.items
                let offset = CGPoint(
                    x: startNorm.x - hit.startPoint.x,
                    y: startNorm.y - hit.startPoint.y
                )
                dragMode = .moving(id: hit.id, grabNormOffset: offset)
            } else {
                // Start creating a new item of the active tool.
                createNewItem(at: startNorm, curNorm: curNorm)
            }

        case .creating(let id):
            canvas.updateItem(id) { item in
                // Text / step: use startPoint only, ignore endPoint drag.
                if item.type == .text || item.type == .stepNumber {
                    item.startPoint = curNorm
                } else {
                    item.endPoint = curNorm
                }
            }

        case .moving(let id, let offset):
            canvas.updateItem(id) { item in
                let newStart = CGPoint(
                    x: clamp01(curNorm.x - offset.x),
                    y: clamp01(curNorm.y - offset.y)
                )
                let delta = CGPoint(x: newStart.x - item.startPoint.x, y: newStart.y - item.startPoint.y)
                item.startPoint = newStart
                item.endPoint = CGPoint(
                    x: clamp01(item.endPoint.x + delta.x),
                    y: clamp01(item.endPoint.y + delta.y)
                )
            }

        case .resizingHandle:
            break // handled by SelectionHandlesView callback
        }
    }

    private func onDragEnded(location: CGPoint, start: CGPoint, displayRect: CGRect, isTap: Bool) {
        defer {
            dragMode = .idle
            dragStartItems = []
        }

        switch dragMode {
        case .creating(let id):
            // For arrow / rectangle: if size is essentially zero, discard.
            if let item = canvas.item(with: id) {
                let dx = abs(item.endPoint.x - item.startPoint.x)
                let dy = abs(item.endPoint.y - item.startPoint.y)
                if (item.type == .arrow || item.type == .rectangle) && dx < 0.005 && dy < 0.005 {
                    canvas.items.removeAll { $0.id == id }
                    canvas.selectedItemID = nil
                    return
                }
                // For text: enter inline editing mode.
                if item.type == .text {
                    editingTextID = id
                }
            }

        case .moving:
            if !dragStartItems.isEmpty {
                canvas.commit(previousItems: dragStartItems)
            }

        case .idle:
            // Pure tap on empty area: deselect.
            if isTap && displayRect.contains(start) {
                if hitTest(start, displayRect: displayRect) == nil {
                    canvas.clearSelection()
                    editingTextID = nil
                }
            }

        case .resizingHandle:
            break
        }
    }

    private func handleHandleDrag(item: AnnotationItem, handle: AnnotationHandle, location: CGPoint, displayRect: CGRect, isFinal: Bool) {
        if dragStartItems.isEmpty {
            dragStartItems = canvas.items
            dragMode = .resizingHandle(id: item.id, handle: handle)
        }
        let norm = normalize(location, in: displayRect)
        canvas.updateItem(item.id) { it in
            switch handle {
            case .start:
                it.startPoint = CGPoint(x: clamp01(norm.x), y: clamp01(norm.y))
            case .end:
                it.endPoint = CGPoint(x: clamp01(norm.x), y: clamp01(norm.y))
            case .body:
                break
            }
        }
        if isFinal {
            if !dragStartItems.isEmpty {
                canvas.commit(previousItems: dragStartItems)
            }
            dragStartItems = []
            dragMode = .idle
        }
    }

    // MARK: - Create

    private func createNewItem(at start: CGPoint, curNorm: CGPoint) {
        var item = AnnotationItem(type: canvas.activeTool)
        item.colorHex = canvas.activeColorHex
        item.lineWidth = canvas.activeLineWidth
        item.fontSize = canvas.activeFontSize
        item.startPoint = start
        item.endPoint = curNorm
        switch canvas.activeTool {
        case .stepNumber:
            item.stepNumber = canvas.nextStepNumber
            item.endPoint = start
        case .text:
            item.textContent = ""
            item.endPoint = start
        default:
            break
        }
        canvas.addItem(item)
        dragMode = .creating(id: item.id)
    }

    // MARK: - Hit testing

    /// Returns the top-most item that contains `location` (display-space point).
    private func hitTest(_ location: CGPoint, displayRect: CGRect) -> AnnotationItem? {
        guard displayRect.contains(location) else { return nil }
        let norm = normalize(location, in: displayRect)
        for item in canvas.items.reversed() {
            if contains(item: item, normPoint: norm, displayRect: displayRect) {
                return item
            }
        }
        return nil
    }

    private func contains(item: AnnotationItem, normPoint p: CGPoint, displayRect: CGRect) -> Bool {
        switch item.type {
        case .arrow:
            // Distance from point to the arrow line segment, in display points.
            let s = denormalize(item.startPoint, in: displayRect)
            let e = denormalize(item.endPoint, in: displayRect)
            let loc = denormalize(p, in: displayRect)
            let d = distance(point: loc, segmentStart: s, segmentEnd: e)
            return d <= max(10, item.lineWidth + 6)

        case .rectangle:
            let r = item.normalizedRect
            // hit if within the stroke band (6pt) around the border
            let strokeBandNorm = (item.lineWidth + 8) / max(displayRect.width, displayRect.height)
            let outer = r.insetBy(dx: -strokeBandNorm, dy: -strokeBandNorm)
            let inner = r.insetBy(dx: strokeBandNorm, dy: strokeBandNorm)
            return outer.contains(p) && !inner.contains(p)

        case .text:
            let center = denormalize(item.startPoint, in: displayRect)
            // Approximate bounding box based on text size.
            let estimatedWidth  = CGFloat(max(item.textContent.count, 3)) * item.fontSize * 0.6 + 24
            let estimatedHeight = item.fontSize + 12
            let rect = CGRect(
                x: center.x - estimatedWidth / 2,
                y: center.y - estimatedHeight / 2,
                width: estimatedWidth,
                height: estimatedHeight
            )
            let loc = denormalize(p, in: displayRect)
            return rect.contains(loc)

        case .stepNumber:
            let center = denormalize(item.startPoint, in: displayRect)
            let loc = denormalize(p, in: displayRect)
            let diameter = max(24, item.fontSize * 1.8)
            let dx = loc.x - center.x
            let dy = loc.y - center.y
            return (dx * dx + dy * dy) <= (diameter / 2) * (diameter / 2)
        }
    }

    // MARK: - Inline text editor

    @ViewBuilder
    private func inlineTextEditor(for item: AnnotationItem, in displayRect: CGRect) -> some View {
        let p = denormalize(item.startPoint, in: displayRect)
        InlineTextField(
            text: Binding(
                get: { canvas.item(with: item.id)?.textContent ?? "" },
                set: { newValue in
                    canvas.updateItem(item.id) { $0.textContent = newValue }
                }
            ),
            fontSize: item.fontSize,
            color: item.color,
            onCommit: {
                // If text is empty, remove the placeholder item.
                if let current = canvas.item(with: item.id),
                   current.textContent.trimmingCharacters(in: .whitespaces).isEmpty {
                    canvas.items.removeAll { $0.id == item.id }
                    canvas.selectedItemID = nil
                }
                editingTextID = nil
            }
        )
        .position(x: p.x, y: p.y)
    }

    // MARK: - Coordinate helpers

    private func normalize(_ p: CGPoint, in rect: CGRect) -> CGPoint {
        CGPoint(
            x: (p.x - rect.origin.x) / max(rect.width, 1),
            y: (p.y - rect.origin.y) / max(rect.height, 1)
        )
    }

    private func denormalize(_ p: CGPoint, in rect: CGRect) -> CGPoint {
        CGPoint(
            x: rect.origin.x + p.x * rect.width,
            y: rect.origin.y + p.y * rect.height
        )
    }

    private func clamp01(_ v: CGFloat) -> CGFloat {
        min(max(v, 0), 1)
    }

    private func distance(point p: CGPoint, segmentStart a: CGPoint, segmentEnd b: CGPoint) -> CGFloat {
        let dx = b.x - a.x
        let dy = b.y - a.y
        let lenSq = dx * dx + dy * dy
        guard lenSq > 0.0001 else {
            return hypot(p.x - a.x, p.y - a.y)
        }
        var t = ((p.x - a.x) * dx + (p.y - a.y) * dy) / lenSq
        t = min(max(t, 0), 1)
        let proj = CGPoint(x: a.x + t * dx, y: a.y + t * dy)
        return hypot(p.x - proj.x, p.y - proj.y)
    }
}

// MARK: - Inline Text Field

private struct InlineTextField: View {
    @Binding var text: String
    let fontSize: CGFloat
    let color: Color
    let onCommit: () -> Void

    @FocusState private var isFocused: Bool

    var body: some View {
        TextField("Text", text: $text, onCommit: onCommit)
            .textFieldStyle(.plain)
            .font(.system(size: fontSize, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.black.opacity(0.15))
            )
            .fixedSize()
            .focused($isFocused)
            .onAppear { isFocused = true }
            .onChange(of: isFocused) { _, focused in
                if !focused { onCommit() }
            }
    }
}
