import SwiftUI
import AppKit

struct MenuBarView: View {
    @EnvironmentObject var viewModel: MenuBarViewModel
    @EnvironmentObject var screenshotStore: ScreenshotStore
    @Environment(\.dismiss) private var dismiss: DismissAction
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // ── Header ──────────────────────────────────────────────
            HStack {
                Label("Capture Your Screen", systemImage: "camera.viewfinder")
                    .font(.headline)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            Divider()

            // ── Take Screenshot ──────────────────────────────────────
            Button(action: {
                dismiss()
                viewModel.startCapture()
            }) {
                HStack {
                    Label("Take Screenshot", systemImage: "plus.viewfinder")
                    Spacer()
                    Text(viewModel.currentHotkeyDisplay)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)

            Divider()
                .padding(.vertical, 4)

            // ── History ──────────────────────────────────────────────
            if historyIsEmpty {
                Text("No screenshots yet")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
            } else {
                ForEach(HistoryGroup.allCases, id: \.self) { group in
                    if let items = viewModel.historyGroups[group], !items.isEmpty {
                        groupSection(group: group, items: items)
                    }
                }
            }

            Divider()
                .padding(.vertical, 4)

            // ── Footer actions ───────────────────────────────────────
            Group {
                Button(action: { viewModel.openScreenshotFolder() }) {
                    Label("Open Screenshot Folder", systemImage: "folder")
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 12)
                .padding(.vertical, 5)

                Button(action: {
                    NSApp.activate(ignoringOtherApps: true)
                    openWindow(id: "settings")
                }) {
                    Label("Settings", systemImage: "gearshape")
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 12)
                .padding(.vertical, 5)

                Divider()
                    .padding(.vertical, 4)

                Button(action: { NSApplication.shared.terminate(nil) }) {
                    Label("Quit", systemImage: "power")
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
            }
        }
        .padding(.bottom, 8)
        .frame(width: 280)
        .task { await viewModel.refresh() }
        .onChange(of: screenshotStore.screenshots) { _ in
            viewModel.rebuildGroups()
        }
        }

    // MARK: - History group section

    private func groupSection(group: HistoryGroup, items: [ScreenshotHistoryItem]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // Group header
            HStack {
                Label(group.rawValue, systemImage: group.icon)
                    .font(.subheadline.bold())
                    .foregroundColor(.secondary)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.top, 4)
            .padding(.bottom, 2)

            // Items (up to 5 per group for compact display)
            ForEach(items.prefix(5)) { item in
                historyRow(item: item)
            }
            if items.count > 5 {
                Text("+ \(items.count - 5) more…")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 4)
            }
        }
    }

    private func historyRow(item: ScreenshotHistoryItem) -> some View {
        HStack(spacing: 8) {
            // Thumbnail
            Group {
                if let thumb = item.thumbnail {
                    Image(nsImage: thumb)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    Color.secondary.opacity(0.2)
                }
            }
            .frame(width: 40, height: 28)
            .clipShape(RoundedRectangle(cornerRadius: 3))
            .overlay(RoundedRectangle(cornerRadius: 3).stroke(Color.secondary.opacity(0.3), lineWidth: 0.5))

            // Time
            Text(item.displayTime)
                .font(.caption)
                .foregroundColor(.primary)

            Spacer()

            // Copy button
            Button(action: { viewModel.copyScreenshot(item) }) {
                Image(systemName: "doc.on.doc")
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .help("Copy to clipboard")

            // Show in Finder button
            Button(action: { viewModel.showInFinder(item) }) {
                Image(systemName: "folder")
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .help("Show in Finder")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .contextMenu {
            Button("Copy") { viewModel.copyScreenshot(item) }
            Button("Show in Finder") { viewModel.showInFinder(item) }
            Divider()
            Button("Delete", role: .destructive) { viewModel.deleteScreenshot(item) }
        }
    }

    private var historyIsEmpty: Bool {
        HistoryGroup.allCases.allSatisfy { (viewModel.historyGroups[$0] ?? []).isEmpty }
    }
}

// MARK: - Settings View

struct SettingsView: View {
    @EnvironmentObject var viewModel: MenuBarViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Settings")
                .font(.title2.bold())

            GroupBox(label: Label("Hotkey", systemImage: "keyboard")) {
                HStack {
                    Text("Capture shortcut:")
                    Spacer()
                    Text(viewModel.currentHotkeyDisplay)
                        .font(.system(.body, design: .monospaced))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.secondary.opacity(0.15), in: RoundedRectangle(cornerRadius: 4))
                }
                .padding(.vertical, 4)
                Text("Hotkey customization coming soon.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            GroupBox(label: Label("Save Location", systemImage: "folder")) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(viewModel.screenshotFolderDisplay)
                            .font(.system(.caption, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: 200, alignment: .leading)
                        Spacer()
                        Button("Browse…") {
                            viewModel.chooseScreenshotFolder()
                        }
                    }
                    HStack(spacing: 4) {
                        Text("Default: ~/Pictures/Screenshots")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        Spacer()
                        Button("Reset") {
                            viewModel.resetToDefaultFolder()
                        }
                        .font(.caption2)
                        .buttonStyle(.plain)
                        .foregroundColor(.accentColor)
                    }
                    Text("Tip: You can point this to iCloud Drive or any other folder.")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                .padding(.vertical, 4)
            }

            Spacer()

            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 360, height: 240)
    }
}
