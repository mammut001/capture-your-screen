//
//  PostCaptureActionView.swift
//  capture-your-screen
//
//  SwiftUI content for the post-capture action panel. Renders the
//  preview and emits Copy / Annotate / Share / Cancel actions — it never
//  touches the pasteboard, disk, or sharing APIs directly.
//

import SwiftUI
import AppKit
import Combine

// MARK: - Strings

/// All user-facing strings for the post-capture workflow, grouped for
/// future localization.
enum PostCaptureStrings {
    static let windowTitle = "Screenshot Captured"
    static let panelTitle = "Screenshot captured"

    static let copyTitle = "Copy"
    static let copySubtitle = "Copy to Clipboard"
    static let annotateTitle = "Annotate"
    static let annotateSubtitle = "Mark up before saving"
    static let shareTitle = "Share"
    static let shareSubtitle = "Send or share this screenshot"
    static let cancelTitle = "Cancel"
    static let cancelHelp = "Discard this screenshot (esc)"

    static let readyHint = "⌘C Copy · ⌘E Annotate · ⇧⌘S Share · esc Cancel"
    static let savingStatus = "Saving…"
    static let preparingShareStatus = "Preparing to share…"
    static let copiedAndSaved = "Copied and saved"
    static let sharedAndSaved = "Shared and saved to history"

    static let copyFailed = "Couldn't copy to the clipboard. The screenshot is still here — try again or cancel."
    static let copiedButSaveFailed = "Copied to the clipboard, but saving to disk failed."
    static let saveFailed = "Couldn't save the screenshot. It is still here — try again or cancel."
    static let shareFailed = "Sharing didn't complete. The screenshot is still here."
    static let sharingUnavailable = "Sharing isn't available right now. The screenshot is still here."

    static let savedNotificationTitle = "Screenshot Captured"
    static func savedNotificationBody(filename: String) -> String { "Saved to \(filename)" }
    static let captureFailedNotificationTitle = "Capture Failed"
    static let saveFailedNotificationTitle = "Save Failed"
}

// MARK: - Panel model

/// Observable status shared between the coordinator (writer) and the
/// panel view (reader).
@MainActor
final class PostCapturePanelModel: ObservableObject {
    @Published var status: PostCapturePanelStatus = .ready

    /// True while an action is running or has just succeeded — buttons are
    /// disabled so fast repeated clicks cannot trigger duplicate actions.
    var isBusy: Bool {
        switch status {
        case .processing, .success: return true
        case .ready, .failure: return false
        }
    }
}

// MARK: - View

struct PostCaptureActionView: View {
    let image: NSImage
    let pixelSize: CGSize
    @ObservedObject var model: PostCapturePanelModel
    let handlers: PostCaptureActionHandlers

    private var dimensionsText: String {
        "\(Int(pixelSize.width)) × \(Int(pixelSize.height)) px"
    }

    var body: some View {
        VStack(spacing: 14) {
            header
            preview
            actionRow
            statusArea
            cancelButton
        }
        .padding(.horizontal, 18)
        .padding(.top, 30) // clears the transparent title bar / close button
        .padding(.bottom, 12)
        .frame(width: 460)
        .background(hiddenShortcutButtons)
    }

    // MARK: Sections

    private var header: some View {
        VStack(spacing: 2) {
            Text(PostCaptureStrings.panelTitle)
                .font(.headline)
            Text(dimensionsText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Screenshot dimensions \(dimensionsText)")
        }
    }

    private var preview: some View {
        Image(nsImage: image)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(maxWidth: 424, maxHeight: 230)
            .frame(minWidth: 60, minHeight: 40)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.18), radius: 6, y: 2)
            .accessibilityLabel("Screenshot preview, \(dimensionsText)")
    }

    private var actionRow: some View {
        HStack(spacing: 10) {
            actionButton(
                title: PostCaptureStrings.copyTitle,
                subtitle: PostCaptureStrings.copySubtitle,
                systemImage: "doc.on.doc",
                isProminent: true,
                action: handlers.onCopy
            )
            .keyboardShortcut(.defaultAction)
            .accessibilityLabel(PostCaptureStrings.copyTitle)
            .help("\(PostCaptureStrings.copySubtitle) and save to history (⌘C or ↩)")

            actionButton(
                title: PostCaptureStrings.annotateTitle,
                subtitle: PostCaptureStrings.annotateSubtitle,
                systemImage: "pencil.and.outline",
                isProminent: false,
                action: handlers.onAnnotate
            )
            .accessibilityLabel(PostCaptureStrings.annotateTitle)
            .help("\(PostCaptureStrings.annotateSubtitle) (⌘E)")

            actionButton(
                title: PostCaptureStrings.shareTitle,
                subtitle: PostCaptureStrings.shareSubtitle,
                systemImage: "square.and.arrow.up",
                isProminent: false,
                action: handlers.onShare
            )
            .accessibilityLabel(PostCaptureStrings.shareTitle)
            .help("\(PostCaptureStrings.shareSubtitle) (⇧⌘S)")
        }
    }

    @ViewBuilder
    private var statusArea: some View {
        Group {
            switch model.status {
            case .ready:
                Text(PostCaptureStrings.readyHint)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            case .processing(let message):
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            case .success(let message):
                Label(message, systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
            case .failure(let message):
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(minHeight: 18)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .combine)
    }

    private var cancelButton: some View {
        Button(role: .cancel, action: handlers.onCancel) {
            Text(PostCaptureStrings.cancelTitle)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .keyboardShortcut(.cancelAction)
        .disabled(model.isBusy)
        .accessibilityLabel(PostCaptureStrings.cancelTitle)
        .help(PostCaptureStrings.cancelHelp)
    }

    // MARK: Helpers

    @ViewBuilder
    private func actionButton(
        title: String,
        subtitle: String,
        systemImage: String,
        isProminent: Bool,
        action: @escaping () -> Void
    ) -> some View {
        let label = VStack(spacing: 5) {
            Image(systemName: systemImage)
                .font(.system(size: 17, weight: .medium))
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)

        if isProminent {
            Button(action: action) { label }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(model.isBusy)
        } else {
            Button(action: action) { label }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .disabled(model.isBusy)
        }
    }

    /// Invisible buttons that provide ⌘C / ⌘E / ⇧⌘S without installing
    /// any global event monitors.
    private var hiddenShortcutButtons: some View {
        Group {
            Button(action: handlers.onCopy) { EmptyView() }
                .keyboardShortcut("c", modifiers: .command)
            Button(action: handlers.onAnnotate) { EmptyView() }
                .keyboardShortcut("e", modifiers: .command)
            Button(action: handlers.onShare) { EmptyView() }
                .keyboardShortcut("s", modifiers: [.command, .shift])
        }
        .disabled(model.isBusy)
        .frame(width: 0, height: 0)
        .opacity(0)
        .accessibilityHidden(true)
    }
}
