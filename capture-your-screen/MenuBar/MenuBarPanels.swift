import SwiftUI
import AppKit

struct MenuBarView: View {
    @EnvironmentObject var viewModel: MenuBarViewModel
    @EnvironmentObject var appDelegate: AppDelegate
    @EnvironmentObject var hotkeyManager: HotkeyManager
    @Environment(\.dismiss) private var dismiss: DismissAction
    @State private var showingDatePicker: Bool = false
    @State private var searchText: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            headerSection
            filterAndSearchSection
            historyContent
            footerSection
        }
        .padding(.horizontal, 14)
        .padding(.top, 14)
        .padding(.bottom, 10)
        .frame(width: 560, height: 700)
        .background(
            LinearGradient(
                colors: [
                    Color(NSColor.windowBackgroundColor),
                    Color.accentColor.opacity(0.05)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        )
        .task { await viewModel.refreshIfNeeded() }
        .onAppear {
            hotkeyManager.ensureRegistered()
            viewModel.refreshPermissionStatus()
        }
        .overlay {
            if showingDatePicker {
                calendarOverlay
            }
        }
        .overlay(alignment: .bottom) {
            VStack(spacing: 6) {
                if viewModel.showCopyToast {
                    CopyToastView()
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                if let msg = viewModel.errorMessage {
                    Text(msg)
                        .font(.caption)
                        .foregroundColor(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(Capsule().fill(Color.red.opacity(0.85)))
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
                if viewModel.isBatchMode && !viewModel.selectedForBatch.isEmpty {
                    batchDeleteBar
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .padding(.bottom, 12)
            .animation(.easeInOut(duration: 0.2), value: viewModel.errorMessage)
        }
    }

    private var calendarOverlay: some View {
        ZStack(alignment: .top) {
            Color.black.opacity(0.16)
                .ignoresSafeArea()
                .transition(.opacity)
                .onTapGesture {
                    withAnimation(.spring(response: 0.24, dampingFraction: 0.85)) {
                        showingDatePicker = false
                    }
                }

            VStack {
                calendarFloatingCard
                    .padding(.top, 48)
                    .transition(
                        .asymmetric(
                            insertion: .scale(scale: 0.94, anchor: .topTrailing).combined(with: .opacity),
                            removal: .scale(scale: 0.96, anchor: .topTrailing).combined(with: .opacity)
                        )
                    )
                Spacer()
            }
            .padding(.horizontal, 16)
        }
        .zIndex(100)
    }

    private var batchDeleteBar: some View {
        HStack(spacing: 12) {
            Text("\(viewModel.selectedForBatch.count) selected")
                .font(.caption.bold())
            Spacer()
            Button("Cancel") {
                viewModel.toggleBatchMode()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            Button("Delete Selected") {
                viewModel.batchDelete()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .tint(.red)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(NSColor.windowBackgroundColor))
                .shadow(color: Color.black.opacity(0.08), radius: 8, y: 4)
        )
        .padding(.horizontal, 12)
    }

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Label("Capture Your Screen", systemImage: "camera.viewfinder")
                        .font(.headline)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(headerSubtitle)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer()

                Button(action: toggleDatePicker) {
                    HStack(spacing: 6) {
                        Image(systemName: "calendar")
                        Text(dateHeaderButtonTitle)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 9, weight: .bold))
                            .rotationEffect(.degrees(showingDatePicker ? 180 : 0))
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundColor(viewModel.browsingByDate || showingDatePicker ? .accentColor : .primary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(
                        Capsule()
                            .fill((viewModel.browsingByDate || showingDatePicker) ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.10))
                    )
                }
                .buttonStyle(.plain)
                .help("Browse by date")
            }

            Button(action: {
                dismiss()
                viewModel.startCapture()
            }) {
                HStack(spacing: 12) {
                    Image(systemName: "plus.viewfinder")
                        .font(.title3.weight(.semibold))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Take Screenshot")
                            .font(.headline)
                        Text("Start a new capture immediately")
                            .font(.caption)
                            .foregroundColor(.secondary.opacity(0.95))
                    }
                    Spacer()
                    Text(viewModel.currentHotkeyDisplay)
                        .font(.system(.caption, design: .monospaced).weight(.semibold))
                        .foregroundColor(.white.opacity(0.92))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color.white.opacity(0.16), in: Capsule())
                }
                .foregroundColor(.white)
                .padding(16)
                .frame(maxWidth: .infinity)
                .background(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color.accentColor,
                                    Color.accentColor.opacity(0.72)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                )
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.space, modifiers: [])

            if viewModel.permissionStatus == .denied {
                permissionWarningBanner
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .zIndex(1)
    }

    private var filterAndSearchSection: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                TextField(viewModel.browsingByDate ? "Search this date's screenshots…" : "Search screenshots…", text: $searchText)
                    .textFieldStyle(.plain)
                if !searchText.isEmpty {
                    Button(action: { searchText = "" }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(NSColor.controlBackgroundColor).opacity(0.85))
            )

            quickFilterChipsRow

            if viewModel.browsingByDate {
                selectedDateBanner
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
    }

    private var quickFilterChipsRow: some View {
        HStack(spacing: 6) {
            filterChip(
                title: "All",
                count: nil,
                isSelected: !viewModel.browsingByDate,
                systemImage: "square.grid.2x2"
            ) {
                withAnimation(.easeInOut(duration: 0.2)) {
                    viewModel.clearDateFilter()
                    showingDatePicker = false
                }
            }

            let todayCount = viewModel.todayScreenshotCount
            filterChip(
                title: "Today",
                count: todayCount > 0 ? todayCount : nil,
                isSelected: viewModel.isTodayFiltered,
                systemImage: "sun.max"
            ) {
                withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
                    viewModel.applyToday()
                    showingDatePicker = false
                }
            }

            let yesterdayCount = viewModel.yesterdayScreenshotCount
            if yesterdayCount > 0 || viewModel.isYesterdayFiltered {
                filterChip(
                    title: "Yesterday",
                    count: yesterdayCount > 0 ? yesterdayCount : nil,
                    isSelected: viewModel.isYesterdayFiltered,
                    systemImage: "clock.arrow.circlepath"
                ) {
                    withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
                        viewModel.applyYesterday()
                        showingDatePicker = false
                    }
                }
            }

            Spacer()

            Button(action: toggleDatePicker) {
                HStack(spacing: 4) {
                    Image(systemName: "calendar")
                        .font(.system(size: 11, weight: .semibold))
                    if viewModel.browsingByDate && !viewModel.isTodayFiltered && !viewModel.isYesterdayFiltered,
                       let filterDate = viewModel.appliedDateFilter {
                        Text(formattedDate(filterDate))
                            .font(.caption.weight(.semibold))
                    } else {
                        Text("Pick Date")
                            .font(.caption.weight(.medium))
                    }
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .bold))
                        .rotationEffect(.degrees(showingDatePicker ? 180 : 0))
                }
                .foregroundColor(
                    showingDatePicker || (viewModel.browsingByDate && !viewModel.isTodayFiltered && !viewModel.isYesterdayFiltered)
                        ? .accentColor
                        : .secondary
                )
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(
                    Capsule()
                        .fill(
                            showingDatePicker || (viewModel.browsingByDate && !viewModel.isTodayFiltered && !viewModel.isYesterdayFiltered)
                                ? Color.accentColor.opacity(0.12)
                                : Color(NSColor.controlBackgroundColor).opacity(0.85)
                        )
                )
            }
            .buttonStyle(.plain)
            .help("Open calendar to choose a specific date")
        }
    }

    private func filterChip(
        title: String,
        count: Int?,
        isSelected: Bool,
        systemImage: String? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 10, weight: .semibold))
                }
                Text(title)
                    .font(.caption.weight(isSelected ? .semibold : .medium))
                if let count {
                    Text("\(count)")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(
                            Capsule()
                                .fill(isSelected ? Color.accentColor : Color.secondary.opacity(0.2))
                        )
                        .foregroundColor(isSelected ? .white : .secondary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .foregroundColor(isSelected ? .accentColor : .primary)
            .background(
                Capsule()
                    .fill(isSelected ? Color.accentColor.opacity(0.12) : Color(NSColor.controlBackgroundColor).opacity(0.85))
            )
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var selectedDateBanner: some View {
        if let filterDate = viewModel.appliedDateFilter {
            HStack(spacing: 8) {
                Button(action: {
                    withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
                        viewModel.selectPreviousRecordedDate()
                    }
                }) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 11, weight: .bold))
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                .disabled(viewModel.previousRecordedDate == nil)
                .opacity(viewModel.previousRecordedDate == nil ? 0.3 : 1)
                .help(viewModel.previousRecordedDate.map { "Previous date with captures: \(formattedDate($0))" } ?? "No earlier captures")

                HStack(spacing: 6) {
                    Text(dateBannerTitle(for: filterDate))
                        .font(.caption.bold())
                        .foregroundColor(.primary)

                    let count = viewModel.filteredHistoryItems.count
                    Text("· \(count) shot\(count == 1 ? "" : "s")")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }

                Button(action: {
                    withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
                        viewModel.selectNextRecordedDate()
                    }
                }) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .bold))
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                .disabled(viewModel.nextRecordedDate == nil)
                .opacity(viewModel.nextRecordedDate == nil ? 0.3 : 1)
                .help(viewModel.nextRecordedDate.map { "Next date with captures: \(formattedDate($0))" } ?? "No later captures")

                Spacer()

                Button(action: { viewModel.copyLatestScreenshot(on: filterDate) }) {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 11))
                        .foregroundColor(.accentColor)
                }
                .buttonStyle(.plain)
                .help("Copy latest screenshot for this date")

                Button(action: {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        viewModel.clearDateFilter()
                        showingDatePicker = false
                    }
                }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help("Clear date filter (show all)")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(Color(NSColor.controlBackgroundColor).opacity(0.95))
                    .overlay(
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .stroke(Color.accentColor.opacity(0.2), lineWidth: 1)
                    )
            )
        }
    }

    @ViewBuilder
    private var historyContent: some View {
        if viewModel.browsingByDate {
            let items = viewModel.filteredHistoryItems(matching: searchText)
            historyScroll(items: items)
        } else if historyIsEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("No screenshots yet")
                    .font(.headline)
                Text("Start with a new capture and your recent shots will appear here.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 220, alignment: .center)
            .padding(20)
            .background(panelCardBackground)
        } else {
            let matchingRows = viewModel.historyRows(matching: searchText)
            if matchingRows.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(.title2)
                        .foregroundColor(.secondary)
                    Text("No matching screenshots")
                        .font(.headline)
                    Text("Try a filename, format, or capture time.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 220, alignment: .center)
                .padding(20)
                .background(panelCardBackground)
            } else {
                ScrollView {
                    // Flat header + item rows: LazyVStack can recycle each card independently.
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(matchingRows) { row in
                            switch row {
                            case .dayHeader(let date, let title, let subtitle, let count):
                                dayHeaderRow(
                                    date: date,
                                    title: title,
                                    subtitle: subtitle,
                                    count: count
                                )
                            case .item(let item):
                                historyCard(item: item)
                            }
                        }
                    }
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var permissionWarningBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.shield.fill")
                .font(.system(size: 14))
                .foregroundColor(.orange)

            Text("Enable Screen Recording for this app, then fully quit and reopen it.")
                .font(.caption)
                .foregroundColor(.primary)

            Spacer()

            Button(action: { viewModel.openPermissionSettings() }) {
                Text("Fix Permission")
                    .font(.caption.bold())
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.orange.opacity(0.10))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.orange.opacity(0.30), lineWidth: 1)
                )
        )
    }

    private func historyScroll(items: [ScreenshotHistoryItem]) -> some View {
        Group {
            if items.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: searchText.isEmpty ? "calendar.badge.exclamationmark" : "magnifyingglass")
                        .font(.title2)
                        .foregroundColor(.secondary)
                    Text(searchText.isEmpty ? "No screenshots on this day" : "No matching screenshots")
                        .font(.headline)
                    Text(searchText.isEmpty ? "Try another date or clear the filter to browse all captures." : "Try adjusting your search query.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    if !searchText.isEmpty {
                        Button("Clear Search") {
                            searchText = ""
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .padding(.top, 4)
                    } else {
                        Button("Show All Captures") {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                viewModel.clearDateFilter()
                            }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .padding(.top, 4)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 220, alignment: .center)
                .padding(20)
                .background(panelCardBackground)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(items) { item in
                            historyCard(item: item)
                        }
                    }
                    .padding(4)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    /// Sticky-feeling day separator: title, relative label, count, quick actions.
    private func dayHeaderRow(
        date: Date,
        title: String,
        subtitle: String,
        count: Int
    ) -> some View {
        HStack(spacing: 12) {
            Button(action: { viewModel.copyLatestScreenshot(on: date) }) {
                Image(systemName: "doc.on.doc.fill")
                    .foregroundColor(.accentColor)
            }
            .buttonStyle(.plain)
            .help("Copy latest screenshot for this date")

            Button(action: {
                withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
                    viewModel.applyDate(date)
                }
            }) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.subheadline.bold())
                        .foregroundColor(.primary)
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
            .buttonStyle(.plain)
            .help("Filter to this day")

            Spacer()

            Text("\(count)")
                .font(.caption.bold().monospacedDigit())
                .foregroundColor(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.secondary.opacity(0.12), in: Capsule())
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(NSColor.controlBackgroundColor).opacity(0.96))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(Color.accentColor.opacity(0.18), lineWidth: 1)
                )
        )
        .padding(.top, 6)
    }

    private func historyCard(item: ScreenshotHistoryItem) -> some View {
        let isSelected = viewModel.isBatchMode && viewModel.selectedForBatch.contains(item.id)
        let isPinned = viewModel.isPinned(item.id)

        return VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .topTrailing) {
                Button(action: {
                    if viewModel.isBatchMode {
                        viewModel.toggleSelection(item.id)
                    } else {
                        viewModel.copyScreenshot(item)
                    }
                }) {
                    historyPreview(item)
                }
                .buttonStyle(.plain)

                if isPinned {
                    Image(systemName: "pin.fill")
                        .font(.caption2)
                        .foregroundColor(.accentColor)
                        .padding(6)
                        .background(Circle().fill(Color.white.opacity(0.9)))
                        .padding(8)
                }

                if viewModel.isBatchMode {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .foregroundColor(isSelected ? .accentColor : .white.opacity(0.8))
                        .shadow(radius: 1)
                        .padding(8)
                }
            }

            HStack(spacing: 10) {
                Text(item.displayTime)
                    .font(.subheadline.monospacedDigit().weight(.semibold))
                    .foregroundColor(.primary)

                if let sizeText = item.formattedFileSize {
                    Text(sizeText)
                        .font(.caption2.monospacedDigit())
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.10), in: Capsule())
                }

                Text(item.formatLabel)
                    .font(.caption2.monospaced().weight(.semibold))
                    .foregroundColor(.secondary)

                Spacer()

                if !viewModel.isBatchMode {
                    Button(action: { viewModel.copyScreenshot(item) }) {
                        Label("Copy", systemImage: "doc.on.doc")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)

                    Button(action: { viewModel.showInFinder(item) }) {
                        Label("Finder", systemImage: "folder")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(NSColor.windowBackgroundColor))
                .shadow(color: Color.black.opacity(0.04), radius: 3, y: 1)
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 2)
                )
        )
        .contextMenu {
            if !viewModel.isBatchMode {
                Button("Copy") { viewModel.copyScreenshot(item) }
                Button("Show in Finder") { viewModel.showInFinder(item) }
                Button(isPinned ? "Unpin" : "Pin") { viewModel.togglePin(item.id) }
                Divider()
                Button("Select for Batch Delete") { viewModel.toggleBatchMode(); viewModel.toggleSelection(item.id) }
                Button("Delete", role: .destructive) { viewModel.deleteScreenshot(item) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear {
            viewModel.loadThumbnailIfNeeded(for: item)
        }
    }

    private func historyPreview(_ item: ScreenshotHistoryItem) -> some View {
        ZStack(alignment: .bottomLeading) {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))

            Group {
                if let thumb = viewModel.thumbnail(for: item) {
                    Image(nsImage: thumb)
                        .resizable()
                        .interpolation(.low)
                        .scaledToFit()
                        .padding(8)
                } else {
                    VStack(spacing: 6) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Loading")
                            .font(.caption2.weight(.semibold))
                            .foregroundColor(.secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            HStack {
                Text(item.displayTime)
                    .font(.caption2.bold())
                    .foregroundColor(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.black.opacity(0.65), in: Capsule())
                Spacer()
            }
            .padding(8)
        }
        // Fixed height keeps lazy list metrics stable while scrolling.
        .frame(maxWidth: .infinity)
        .frame(height: 180)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.black.opacity(0.06), lineWidth: 1)
        )
    }

    private var historyIsEmpty: Bool {
        viewModel.historySections.isEmpty
    }

    private static let mediumDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        return f
    }()

    private func formattedDate(_ date: Date) -> String {
        Self.mediumDateFormatter.string(from: date)
    }

    private func dateBannerTitle(for date: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date) {
            return "Today (\(formattedDate(date)))"
        }
        if cal.isDateInYesterday(date) {
            return "Yesterday (\(formattedDate(date)))"
        }
        return formattedDate(date)
    }

    private var dateHeaderButtonTitle: String {
        if let filterDate = viewModel.appliedDateFilter {
            let cal = Calendar.current
            if cal.isDateInToday(filterDate) {
                return "Today"
            }
            if cal.isDateInYesterday(filterDate) {
                return "Yesterday"
            }
            return formattedDate(filterDate)
        }
        return "Calendar"
    }

    private var headerSubtitle: String {
        if let filterDate = viewModel.appliedDateFilter {
            return "Browsing screenshots from \(dateBannerTitle(for: filterDate))"
        }
        return "Recent captures, organized by day"
    }

    private var calendarFloatingCard: some View {
        CompactCalendarView(
            visibleMonth: $viewModel.visibleMonth,
            selectedDate: $viewModel.selectedDate,
            datesWithScreenshots: viewModel.datesWithScreenshots,
            firstWeekdayPreference: viewModel.firstWeekdayPreference,
            onSelectDate: { date in
                withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
                    viewModel.applyDate(date)
                    showingDatePicker = false
                }
            },
            onClearFilter: {
                withAnimation(.easeInOut(duration: 0.2)) {
                    viewModel.clearDateFilter()
                    showingDatePicker = false
                }
            },
            onClose: {
                withAnimation(.spring(response: 0.24, dampingFraction: 0.85)) {
                    showingDatePicker = false
                }
            }
        )
        .frame(width: 320)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(NSColor.windowBackgroundColor))
                .shadow(color: Color.black.opacity(0.22), radius: 24, y: 12)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color(NSColor.separatorColor).opacity(0.5), lineWidth: 1)
        )
    }

    private var footerSection: some View {
        HStack(spacing: 8) {
            Button(action: { viewModel.openScreenshotFolder() }) {
                Label("Open Folder", systemImage: "folder")
            }
            .buttonStyle(.bordered)

            Button(action: {
                dismiss()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    appDelegate.openSettingsWindow()
                }
            }) {
                Label("Settings", systemImage: "gearshape")
            }
            .buttonStyle(.bordered)

            Button(action: { viewModel.toggleBatchMode() }) {
                Label(viewModel.isBatchMode ? "Done" : "Batch", systemImage: viewModel.isBatchMode ? "checkmark" : "checkmark.circle")
            }
            .buttonStyle(.bordered)
            .tint(viewModel.isBatchMode ? .accentColor : nil)

            Spacer()

            Button(action: { NSApplication.shared.terminate(nil) }) {
                Label("Quit", systemImage: "power")
            }
            .buttonStyle(.plain)
            .foregroundColor(.secondary)
        }
        .padding(.horizontal, 4)
        .padding(.top, 6)
    }

    private var panelCardBackground: some View {
        RoundedRectangle(cornerRadius: 22, style: .continuous)
            .fill(Color(NSColor.controlBackgroundColor).opacity(0.9))
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(Color(NSColor.separatorColor).opacity(0.4), lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(0.05), radius: 12, y: 6)
    }

    private func toggleDatePicker() {
        if showingDatePicker {
            withAnimation(.spring(response: 0.24, dampingFraction: 0.85)) {
                showingDatePicker = false
            }
        } else {
            if let filter = viewModel.appliedDateFilter {
                viewModel.selectedDate = filter
                viewModel.visibleMonth = Calendar.current.startOfMonth(for: filter)
            } else {
                viewModel.visibleMonth = Calendar.current.startOfMonth(for: Date())
            }
            withAnimation(.spring(response: 0.26, dampingFraction: 0.84)) {
                showingDatePicker = true
            }
        }
    }
}

// MARK: - Compact Calendar View

private struct CalendarDayCell: Identifiable, Equatable {
    let date: Date
    let isCurrentMonth: Bool
    let isToday: Bool
    let isSelected: Bool
    let isFuture: Bool
    let screenshotCount: Int

    var id: TimeInterval { date.timeIntervalSinceReferenceDate }
}

private struct CompactCalendarView: View {
    @Binding var visibleMonth: Date
    @Binding var selectedDate: Date
    let datesWithScreenshots: [Date: Int]
    let firstWeekdayPreference: Int
    let onSelectDate: (Date) -> Void
    let onClearFilter: () -> Void
    let onClose: () -> Void

    @State private var hoveredDate: Date? = nil

    private var calendar: Calendar {
        var cal = Calendar.current
        cal.firstWeekday = firstWeekdayPreference
        return cal
    }

    private var weekdaySymbols: [String] {
        var symbols = calendar.shortStandaloneWeekdaySymbols
        let firstIndex = (calendar.firstWeekday - 1 + symbols.count) % symbols.count
        if firstIndex > 0 {
            symbols = Array(symbols[firstIndex...] + symbols[..<firstIndex])
        }
        return symbols
    }

    private static let monthFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMMM yyyy"
        return f
    }()

    private var monthTitle: String {
        Self.monthFormatter.string(from: visibleMonth)
    }

    private var isViewingCurrentMonth: Bool {
        calendar.isDate(visibleMonth, equalTo: Date(), toGranularity: .month)
    }

    private var canShowNextMonth: Bool {
        let currentMonth = calendar.startOfMonth(for: Date())
        return visibleMonth < currentMonth
    }

    private var monthCells: [CalendarDayCell] {
        guard let monthInterval = calendar.dateInterval(of: .month, for: visibleMonth) else {
            return []
        }

        let firstDayOfMonth = monthInterval.start
        let weekdayOfFirstDay = calendar.component(.weekday, from: firstDayOfMonth)
        let daysToSubtract = (weekdayOfFirstDay - calendar.firstWeekday + 7) % 7

        guard let gridStartDate = calendar.date(byAdding: .day, value: -daysToSubtract, to: firstDayOfMonth) else {
            return []
        }

        let daysInMonth = calendar.range(of: .day, in: .month, for: visibleMonth)?.count ?? 30
        let totalCellsNeeded = daysToSubtract + daysInMonth
        let numberOfWeeks = (totalCellsNeeded + 6) / 7
        let totalCells = numberOfWeeks * 7

        let today = calendar.startOfDay(for: Date())
        let startOfSelected = calendar.startOfDay(for: selectedDate)

        var cells: [CalendarDayCell] = []
        cells.reserveCapacity(totalCells)

        for i in 0..<totalCells {
            guard let cellDate = calendar.date(byAdding: .day, value: i, to: gridStartDate) else { continue }
            let normalizedDate = calendar.startOfDay(for: cellDate)
            let isCurrentMonth = calendar.isDate(normalizedDate, equalTo: visibleMonth, toGranularity: .month)
            let isToday = calendar.isDate(normalizedDate, inSameDayAs: today)
            let isSelected = calendar.isDate(normalizedDate, inSameDayAs: startOfSelected)
            let isFuture = normalizedDate > today
            let count = datesWithScreenshots[normalizedDate] ?? 0

            cells.append(
                CalendarDayCell(
                    date: normalizedDate,
                    isCurrentMonth: isCurrentMonth,
                    isToday: isToday,
                    isSelected: isSelected,
                    isFuture: isFuture,
                    screenshotCount: count
                )
            )
        }
        return cells
    }

    var body: some View {
        VStack(spacing: 12) {
            // Month Header
            HStack {
                Text(monthTitle)
                    .font(.headline.bold())
                    .foregroundColor(.primary)

                Spacer()

                if !isViewingCurrentMonth {
                    Button(action: jumpToCurrentMonth) {
                        Text("Today's Month")
                            .font(.caption2.weight(.semibold))
                            .foregroundColor(.accentColor)
                    }
                    .buttonStyle(.plain)
                    .padding(.trailing, 4)
                }

                Button(action: showPreviousMonth) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 11, weight: .bold))
                        .frame(width: 26, height: 26)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundColor(.secondary)
                .background(Circle().fill(Color.secondary.opacity(0.1)))

                Button(action: showNextMonth) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .bold))
                        .frame(width: 26, height: 26)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundColor(canShowNextMonth ? .secondary : .secondary.opacity(0.25))
                .disabled(!canShowNextMonth)
                .background(Circle().fill(Color.secondary.opacity(canShowNextMonth ? 0.1 : 0.03)))
            }

            // Weekdays + Day Cells
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 7), spacing: 6) {
                ForEach(weekdaySymbols, id: \.self) { day in
                    Text(day)
                        .font(.caption2.weight(.semibold))
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity)
                }

                ForEach(monthCells) { cell in
                    dayCellView(cell: cell)
                }
            }
            .gesture(
                DragGesture(minimumDistance: 30)
                    .onEnded { value in
                        if value.translation.width < -40 {
                            showNextMonth()
                        } else if value.translation.width > 40 {
                            showPreviousMonth()
                        }
                    }
            )

            Divider()
                .padding(.vertical, 2)

            // Footer shortcuts
            HStack {
                Button("Show All") {
                    onClearFilter()
                }
                .buttonStyle(.borderless)
                .font(.caption.weight(.medium))
                .foregroundColor(.accentColor)

                Spacer()

                Button("Today") {
                    let today = calendar.startOfDay(for: Date())
                    selectedDate = today
                    onSelectDate(today)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button("Close") {
                    onClose()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
        .padding(14)
        .onExitCommand {
            onClose()
        }
    }

    private func dayCellView(cell: CalendarDayCell) -> some View {
        Button(action: {
            guard !cell.isFuture else { return }
            selectedDate = cell.date
            onSelectDate(cell.date)
        }) {
            ZStack {
                if cell.isSelected {
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: 32, height: 32)
                } else if cell.isToday {
                    Circle()
                        .stroke(Color.accentColor, lineWidth: 1.5)
                        .frame(width: 32, height: 32)
                } else if cell.screenshotCount > 0 {
                    Circle()
                        .fill(Color.accentColor.opacity(0.10))
                        .frame(width: 32, height: 32)
                }

                if hoveredDate == cell.date && !cell.isSelected && !cell.isFuture {
                    Circle()
                        .fill(Color.primary.opacity(0.06))
                        .frame(width: 32, height: 32)
                }

                Text("\(calendar.component(.day, from: cell.date))")
                    .font(.system(size: 13, weight: cell.isSelected ? .bold : (cell.screenshotCount > 0 ? .semibold : .regular)))
                    .foregroundColor(cellTextColor(cell))

                if cell.screenshotCount > 0 {
                    Circle()
                        .fill(cell.isSelected ? Color.white : Color.accentColor)
                        .frame(width: 4, height: 4)
                        .offset(y: 10)
                }
            }
            .frame(width: 36, height: 36)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(cell.isFuture)
        .onHover { hovering in
            hoveredDate = hovering ? cell.date : nil
        }
        .help(cellTooltip(cell))
    }

    private func cellTextColor(_ cell: CalendarDayCell) -> Color {
        if cell.isFuture {
            return .secondary.opacity(0.25)
        }
        if cell.isSelected {
            return .white
        }
        if !cell.isCurrentMonth {
            return .secondary.opacity(0.4)
        }
        if cell.screenshotCount > 0 {
            return .primary
        }
        return .secondary
    }

    private static let shortDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        return f
    }()

    private func cellTooltip(_ cell: CalendarDayCell) -> String {
        let dateStr = Self.shortDateFormatter.string(from: cell.date)
        if cell.screenshotCount > 0 {
            return "\(dateStr): \(cell.screenshotCount) screenshot\(cell.screenshotCount == 1 ? "" : "s")"
        }
        return dateStr
    }

    private func showPreviousMonth() {
        guard let newMonth = calendar.date(byAdding: .month, value: -1, to: visibleMonth) else { return }
        withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
            visibleMonth = calendar.startOfMonth(for: newMonth)
        }
    }

    private func showNextMonth() {
        guard canShowNextMonth else { return }
        guard let newMonth = calendar.date(byAdding: .month, value: 1, to: visibleMonth) else { return }
        withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
            visibleMonth = calendar.startOfMonth(for: newMonth)
        }
    }

    private func jumpToCurrentMonth() {
        withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
            visibleMonth = calendar.startOfMonth(for: Date())
        }
    }
}

// MARK: - Settings View

struct SettingsView: View {
    @EnvironmentObject var viewModel: MenuBarViewModel
    @EnvironmentObject var hotkeyManager: HotkeyManager
    @EnvironmentObject var launchAtLoginManager: LaunchAtLoginManager
    @Environment(\.dismiss) private var dismiss
    @State private var showHotkeySettings: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            GroupBox(label: Label("General", systemImage: "slider.horizontal.3")) {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("Launch at Login", isOn: $launchAtLoginManager.isEnabled)
                        .toggleStyle(.switch)
                        .controlSize(.small)
                    Text("Automatically start the app when you sign in.")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                .padding(.vertical, 4)
                .padding(.horizontal, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            GroupBox(label: Label("Screenshot Shortcut", systemImage: "keyboard")) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Current Shortcut")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Text(viewModel.currentHotkeyDisplay)
                                .font(.system(.title3, design: .monospaced).bold())
                                .foregroundColor(.primary)
                        }
                        Spacer()
                        Button("Customize…") {
                            showHotkeySettings = true
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.regular)
                    }
                    .padding(.vertical, 6)
                }
                .padding(.horizontal, 4)
                .sheet(isPresented: $showHotkeySettings) {
                    HotkeySettingsView()
                        .environmentObject(hotkeyManager)
                }
            }

            GroupBox(label: Label("Save Location", systemImage: "folder")) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Current Path")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Text(viewModel.screenshotFolderDisplay)
                                .font(.system(.caption, design: .monospaced))
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .frame(maxWidth: 240, alignment: .leading)
                        }
                        Spacer()
                        Button("Browse…") {
                            viewModel.chooseScreenshotFolder()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.regular)
                    }
                    .padding(.vertical, 4)

                    HStack(spacing: 4) {
                        Text("Suggested: ~/Pictures/Screenshots")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        Spacer()
                        Button("Choose Default Folder\u{2026}") {
                            viewModel.resetToDefaultFolder()
                        }
                        .font(.caption2)
                        .buttonStyle(.plain)
                        .foregroundColor(.accentColor)
                    }
                }
                .padding(.horizontal, 4)
            }

            GroupBox(label: Label("Calendar", systemImage: "calendar")) {
                VStack(alignment: .leading, spacing: 10) {
                    Picker("First Weekday", selection: $viewModel.firstWeekdayPreference) {
                        Text("Sunday").tag(1)
                        Text("Monday").tag(2)
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 240)
                    Text("Changes take effect immediately in the date picker.")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                .padding(.vertical, 4)
                .padding(.horizontal, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            GroupBox(label: Label("Image Format", systemImage: "photo")) {
                VStack(alignment: .leading, spacing: 10) {
                    Picker("Save Format", selection: $viewModel.saveFormatPreference) {
                        Text("PNG").tag(SaveFormat.png)
                        Text("JPEG").tag(SaveFormat.jpeg)
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 200)
                    Text("PNG preserves quality; JPEG produces smaller files.")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                .padding(.vertical, 4)
                .padding(.horizontal, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            GroupBox(label: Label("Export", systemImage: "square.and.arrow.up")) {
                VStack(alignment: .leading, spacing: 10) {
                    Button("Export History to JSON…") {
                        viewModel.exportHistoryToJSON()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                    Text("Exports screenshot paths and metadata to a JSON file.")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                .padding(.vertical, 4)
                .padding(.horizontal, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Spacer()

            HStack {
                Text("Tip: You can point save location to iCloud Drive or any other folder.")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .italic()
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 520, height: 420)
    }
}
