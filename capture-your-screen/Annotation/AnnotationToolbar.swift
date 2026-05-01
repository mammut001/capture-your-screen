//
//  AnnotationToolbar.swift
//  capture-your-screen
//

import SwiftUI

struct AnnotationToolbar: View {
    @ObservedObject var canvas: AnnotationCanvas

    /// Base image for OCR extraction.
    var baseImage: NSImage? = nil

    @State private var isProcessingOCR = false
    @State private var showOCRPopover = false
    @State private var ocrResult: String? = nil
    @State private var ocrError: String? = nil
    @State private var showCopiedToast = false

    private let ocrService = VisionOCRService()

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

            // Line width picker (hidden for text / step / blur / pixelate)
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

            // Pixelate size picker
            if canvas.activeTool == .pixelate {
                PixelateSizePicker(
                    pixelSize: Binding(
                        get: { canvas.activePixelSize },
                        set: { newValue in
                            canvas.activePixelSize = newValue
                            if let id = canvas.selectedItemID,
                               let item = canvas.item(with: id),
                               item.type == .pixelate {
                                canvas.updateItem(id) { $0.pixelSize = newValue }
                            }
                        }
                    )
                )
            }

            // Blur radius picker
            if canvas.activeTool == .blur {
                BlurRadiusPicker(
                    blurRadius: Binding(
                        get: { canvas.activeBlurRadius },
                        set: { newValue in
                            canvas.activeBlurRadius = newValue
                            if let id = canvas.selectedItemID,
                               let item = canvas.item(with: id),
                               item.type == .blur {
                                canvas.updateItem(id) { $0.blurRadius = newValue }
                            }
                        }
                    )
                )
            }

            Spacer(minLength: 8)

            // OCR button
            if baseImage != nil {
                Button(action: performOCR) {
                    HStack(spacing: 4) {
                        if isProcessingOCR {
                            ProgressView()
                                .controlSize(.small)
                                .scaleEffect(0.7)
                        } else {
                            Image(systemName: "text.viewfinder")
                                .font(.system(size: 13, weight: .medium))
                        }
                        Text("OCR")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color.accentColor.opacity(showOCRPopover ? 0.2 : 0.0))
                    )
                }
                .buttonStyle(.borderless)
                .disabled(isProcessingOCR)
                .help("Extract text from screenshot (OCR)")
                .popover(isPresented: $showOCRPopover, arrowEdge: .bottom) {
                    ocrPopoverContent
                }
            }

            Divider().frame(height: 22).padding(.horizontal, 4)

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

    // MARK: - OCR

    private func performOCR() {
        guard let image = baseImage else { return }
        isProcessingOCR = true
        ocrResult = nil
        ocrError = nil

        Task {
            do {
                let text = try await ocrService.extractText(from: image)
                await MainActor.run {
                    ocrResult = text
                    ocrError = nil
                    isProcessingOCR = false
                    showOCRPopover = true
                }
            } catch {
                await MainActor.run {
                    ocrResult = nil
                    ocrError = error.localizedDescription
                    isProcessingOCR = false
                    showOCRPopover = true
                }
            }
        }
    }

    @ViewBuilder
    private var ocrPopoverContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "text.viewfinder")
                    .foregroundStyle(.secondary)
                Text("Extracted Text")
                    .font(.headline)
                Spacer()
            }

            if let text = ocrResult {
                ScrollView {
                    Text(text)
                        .font(.system(size: 13, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(Color(nsColor: .textBackgroundColor))
                        )
                }
                .frame(maxHeight: 250)

                HStack {
                    Text("\(text.components(separatedBy: .newlines).count) lines · \(text.count) characters")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Spacer()

                    if showCopiedToast {
                        Label("Copied!", systemImage: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.green)
                            .transition(.scale.combined(with: .opacity))
                    }

                    Button(action: {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(text, forType: .string)
                        withAnimation(.spring(response: 0.3)) {
                            showCopiedToast = true
                        }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                            withAnimation { showCopiedToast = false }
                        }
                    }) {
                        Label("Copy All", systemImage: "doc.on.doc")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
            } else if let error = ocrError {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                    Text(error)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.orange.opacity(0.1))
                )
            }
        }
        .padding(16)
        .frame(width: 380)
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

private struct PixelateSizePicker: View {
    @Binding var pixelSize: CGFloat
    private let options: [CGFloat] = [5, 10, 15, 20, 30]

    var body: some View {
        HStack(spacing: 4) {
            ForEach(options, id: \.self) { size in
                Button {
                    pixelSize = size
                } label: {
                    Image(systemName: "square.grid.3x3")
                        .font(.system(size: 12))
                        .frame(width: 28, height: 28)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(pixelSize == size ? Color.accentColor.opacity(0.2) : Color.clear)
                        )
                }
                .buttonStyle(.borderless)
                .help("\(Int(size))px")
            }
        }
    }
}

private struct BlurRadiusPicker: View {
    @Binding var blurRadius: CGFloat
    private let options: [CGFloat] = [5, 10, 15, 25, 40]

    var body: some View {
        HStack(spacing: 4) {
            ForEach(options, id: \.self) { radius in
                Button {
                    blurRadius = radius
                } label: {
                    Image(systemName: "drop.fill")
                        .font(.system(size: 12))
                        .frame(width: 28, height: 28)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(blurRadius == radius ? Color.accentColor.opacity(0.2) : Color.clear)
                        )
                }
                .buttonStyle(.borderless)
                .help("\(Int(radius))px")
            }
        }
    }
}
