//
//  AnnotationModel.swift
//  capture-your-screen
//
//  Data model for annotation elements overlaid on a captured screenshot.
//  Coordinates are normalized to 0...1 in the base image space so that the
//  annotations stay correctly positioned regardless of how the editor window
//  is resized.
//

import Combine
import SwiftUI

/// Unique identifier for an annotation item.
typealias AnnotationID = UUID

/// All supported annotation types.
enum AnnotationType: String, CaseIterable, Codable, Identifiable {
    case arrow
    case text
    case rectangle
    case ellipse
    case stepNumber
    case pixelate
    case blur

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .arrow:      return "Arrow"
        case .text:       return "Text"
        case .rectangle:  return "Rectangle"
        case .ellipse:    return "Ellipse"
        case .stepNumber: return "Step"
        case .pixelate:   return "Pixelate"
        case .blur:       return "Blur"
        }
    }

    var symbolName: String {
        switch self {
        case .arrow:      return "arrow.up.right"
        case .text:       return "character.textbox"
        case .rectangle:  return "rectangle"
        case .ellipse:    return "circle"
        case .stepNumber: return "1.circle.fill"
        case .pixelate:   return "square.grid.3x3"
        case .blur:       return "drop.fill"
        }
    }

    var shortcutKey: Character {
        switch self {
        case .arrow:      return "a"
        case .text:       return "t"
        case .rectangle:  return "r"
        case .ellipse:    return "o"
        case .stepNumber: return "n"
        case .pixelate:   return "p"
        case .blur:       return "b"
        }
    }
}

/// A single annotation element. Coordinates are normalized (0...1) relative
/// to the base image.
struct AnnotationItem: Identifiable, Equatable {
    let id: AnnotationID
    var type: AnnotationType

    // Common
    var colorHex: String = "#FF3B30"   // default red
    var lineWidth: CGFloat = 3.0
    var opacity: Double = 1.0

    // Spatial (normalized)
    var startPoint: CGPoint = .zero
    var endPoint: CGPoint = .zero

    // Text-specific
    var textContent: String = ""
    var fontSize: CGFloat = 18.0

    // Step-specific
    var stepNumber: Int = 1

    // Pixelate-specific
    var pixelSize: CGFloat = 10.0

    // Blur-specific
    var blurRadius: CGFloat = 15.0

    init(id: AnnotationID = UUID(), type: AnnotationType) {
        self.id = id
        self.type = type
    }

    var color: Color {
        Color(hex: colorHex) ?? .red
    }

    /// Convenience: normalized rect used for rectangles.
    var normalizedRect: CGRect {
        let x = min(startPoint.x, endPoint.x)
        let y = min(startPoint.y, endPoint.y)
        let w = abs(endPoint.x - startPoint.x)
        let h = abs(endPoint.y - startPoint.y)
        return CGRect(x: x, y: y, width: w, height: h)
    }
}

/// Observable state of the annotation editor. Expected to be mutated from
/// the main thread (SwiftUI).
final class AnnotationCanvas: ObservableObject {
    @Published var items: [AnnotationItem] = []
    @Published var selectedItemID: AnnotationID? = nil
    @Published var activeTool: AnnotationType = .arrow
    @Published var activeColorHex: String = "#FF3B30"
    @Published var activeLineWidth: CGFloat = 3.0
    @Published var activeFontSize: CGFloat = 18.0
    @Published var activePixelSize: CGFloat = 10.0
    @Published var activeBlurRadius: CGFloat = 15.0

    // MARK: - Undo / Redo

    private var undoStack: [[AnnotationItem]] = []
    private var redoStack: [[AnnotationItem]] = []
    private let maxHistory = 50

    /// Take a snapshot of the current items. Call BEFORE mutating state.
    func snapshot() {
        undoStack.append(items)
        if undoStack.count > maxHistory {
            undoStack.removeFirst(undoStack.count - maxHistory)
        }
        redoStack.removeAll()
    }

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(items)
        items = previous
        selectedItemID = nil
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(items)
        items = next
        selectedItemID = nil
    }

    // MARK: - Mutations

    /// Next auto-incrementing step number (1-based).
    var nextStepNumber: Int {
        let maxStep = items
            .filter { $0.type == .stepNumber }
            .map(\.stepNumber)
            .max() ?? 0
        return maxStep + 1
    }

    func addItem(_ item: AnnotationItem) {
        snapshot()
        items.append(item)
        selectedItemID = item.id
    }

    func updateItem(_ id: AnnotationID, _ mutate: (inout AnnotationItem) -> Void) {
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
        mutate(&items[idx])
    }

    /// Commit a pending drag/resize. Pushes an undo snapshot of the state
    /// *before* the drag started.
    func commit(previousItems: [AnnotationItem]) {
        guard items != previousItems else { return }
        undoStack.append(previousItems)
        if undoStack.count > maxHistory {
            undoStack.removeFirst(undoStack.count - maxHistory)
        }
        redoStack.removeAll()
    }

    func deleteSelected() {
        guard let id = selectedItemID,
              items.contains(where: { $0.id == id }) else { return }
        snapshot()
        items.removeAll { $0.id == id }
        selectedItemID = nil
    }

    func item(with id: AnnotationID) -> AnnotationItem? {
        items.first(where: { $0.id == id })
    }

    func selectedItem() -> AnnotationItem? {
        guard let id = selectedItemID else { return nil }
        return item(with: id)
    }

    func clearSelection() {
        selectedItemID = nil
    }
}

// MARK: - Color hex helpers

extension Color {
    init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt64(s, radix: 16) else { return nil }
        let r = Double((v >> 16) & 0xFF) / 255.0
        let g = Double((v >>  8) & 0xFF) / 255.0
        let b = Double(v & 0xFF) / 255.0
        self = Color(red: r, green: g, blue: b)
    }
}

/// Canonical palette used by the toolbar color picker.
enum AnnotationPalette {
    static let colors: [String] = [
        "#FF3B30", // red
        "#FF9500", // orange
        "#FFCC00", // yellow
        "#34C759", // green
        "#007AFF", // blue
        "#AF52DE", // purple
        "#000000", // black
        "#FFFFFF", // white
    ]
}
