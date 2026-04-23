//
//  AnnotationToolbar.swift
//  capture-your-screen
//

import SwiftUI

struct AnnotationToolbar: View {
    @ObservedObject var canvas: AnnotationCanvas

    var body: some View {
        HStack(spacing: 6) {
            // Tool buttons
            ForEach(AnnotationType.allCases) { tool in
                ToolButton(tool: tool, canvas: canvas)
            }

            Divider().frame(height: 22).padding(.horizontal, 4)

            // Color palette
            HStack(spacing: 4) {
                ForEach(AnnotationPalette.colors, id: \.self) { hex in
                    ColorSwatch(
                        hex: hex,
                        isSelected: canvas.activeColorHex.uppercased() == hex.uppercased()
                    ) {
                        canvas.activeColorHex = hex
                        if let id = canvas.selectedItemID {
                            canvas.snapshot()
                            canvas.updateItem(id) { $0.colorHex = hex }
                        }
                    }
                }
            }

            Divider().frame(height: 22).padding(.horizontal, 4)

            // Line width picker (hidden for text / step)
            if canvas.activeTool == .arrow || canvas.activeTool == .rectangle {
                LineWidthPicker(
                    width: Binding(
                        get: { canvas.activeLineWidth },
                        set: { newValue in
                            canvas.activeLineWidth = newValue
                            if let id = canvas.selectedItemID,
                               let item = canvas.item(with: id),
                               item.type == .arrow || item.type == .rectangle {
                                canvas.updateItem(id) { $0.lineWidth = newValue }
                            }
                        }
                    )
                )
            }

            Spacer(minLength: 8)

            // Undo / Redo / Delete
            Button(action: canvas.undo) {
                Image(systemName: "arrow.uturn.backward")
            }
            .buttonStyle(.borderless)
            .disabled(!canvas.canUndo)
            .help("Undo (⌘Z)")

            Button(action: canvas.redo) {
                Image(systemName: "arrow.uturn.forward")
            }
            .buttonStyle(.borderless)
            .disabled(!canvas.canRedo)
            .help("Redo (⇧⌘Z)")

            Button(action: canvas.deleteSelected) {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .disabled(canvas.selectedItemID == nil)
            .help("Delete selected (⌫)")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
    }
}

// MARK: - Subviews

private struct ToolButton: View {
    let tool: AnnotationType
    @ObservedObject var canvas: AnnotationCanvas

    var body: some View {
        let selected = canvas.activeTool == tool
        Button {
            canvas.activeTool = tool
            canvas.clearSelection()
        } label: {
            Image(systemName: tool.symbolName)
                .font(.system(size: 14, weight: .medium))
                .frame(width: 30, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(selected ? Color.accentColor.opacity(0.25) : Color.clear)
                )
                .foregroundStyle(selected ? Color.accentColor : Color.primary)
        }
        .buttonStyle(.borderless)
        .help("\(tool.displayName) (\(String(tool.shortcutKey).uppercased()))")
    }
}

private struct ColorSwatch: View {
    let hex: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Circle()
                .fill(Color(hex: hex) ?? .red)
                .frame(width: 18, height: 18)
                .overlay(
                    Circle()
                        .stroke(isSelected ? Color.white : Color.black.opacity(0.2),
                                lineWidth: isSelected ? 2 : 1)
                )
                .overlay(
                    Circle()
                        .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 2)
                        .padding(-3)
                )
        }
        .buttonStyle(.plain)
    }
}

private struct LineWidthPicker: View {
    @Binding var width: CGFloat
    private let options: [CGFloat] = [2, 3, 5, 8]

    var body: some View {
        HStack(spacing: 4) {
            ForEach(options, id: \.self) { w in
                Button {
                    width = w
                } label: {
                    Capsule()
                        .fill(Color.primary)
                        .frame(width: 20, height: max(2, w * 0.8))
                        .padding(.vertical, 10)
                        .padding(.horizontal, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 5)
                                .fill(width == w ? Color.accentColor.opacity(0.2) : Color.clear)
                        )
                }
                .buttonStyle(.borderless)
            }
        }
    }
}
