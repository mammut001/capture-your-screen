import SwiftUI
import AppKit

struct MenuBarView: View {
    @EnvironmentObject var viewModel: MenuBarViewModel
    @EnvironmentObject var appDelegate: AppDelegate
    @EnvironmentObject var hotkeyManager: HotkeyManager
    @Environment(\.dismiss) private var dismiss: DismissAction
    @State private var showingDatePicker: Bool = false
    @State private var pendingDate: Date = Date()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            headerSection
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
            }
            .padding(.bottom, 12)
            .animation(.easeInOut(duration: 0.2), value: viewModel.errorMessage)
        }
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
                        Image(systemName: dateButtonSymbolName)
                        Text(dateButtonTitle)
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
                .help(viewModel.browsingByDate ? "Back to all screenshots" : "Browse by date")
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

            if viewModel.permissionStatus == .denied {
                permissionWarningBanner
                    .transition(.move(edge: .top).combined(with: .opacity))
            }


            if showingDatePicker {
                datePickerCard
                    .transition(
                        .asymmetric(
                            insertion: .move(edge: .top).combined(with: .opacity),
                            removal: .scale(scale: 0.96).combined(with: .opacity)
                        )
                    )
            }
        }
        .zIndex(1)
        .clipped()
    }

    @ViewBuilder
    private var historyContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            if viewModel.browsingByDate {
                selectedDateBanner
                historyScroll(items: viewModel.filteredHistoryItems)
            } else if !showingDatePicker && historyIsEmpty {
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
                ScrollView {
                    // Flat header + item rows: LazyVStack can recycle each card independently.
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(viewModel.historyRows) { row in
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
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    @ViewBuilder
    private var selectedDateBanner: some View {
        if let filterDate = viewModel.appliedDateFilter {
            HStack(spacing: 8) {
                Button(action: { viewModel.copyLatestScreenshot(on: filterDate) }) {
                    Image(systemName: "doc.on.doc.fill")
                        .foregroundColor(.accentColor)
                }
                .buttonStyle(.plain)
                .help("Copy latest screenshot for this date")

                Text(formattedDate(filterDate))
                    .font(.caption.bold())
                    .foregroundColor(.accentColor)

                Spacer()

                Button(action: {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        viewModel.clearDateFilter()
                        showingDatePicker = false
                    }
                }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help("Clear date filter")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(panelCardBackground)
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
                VStack(alignment: .leading, spacing: 6) {
                    Text("No screenshots on this day")
                        .font(.headline)
                    Text("Try another date or clear the filter to browse all captures.")
                        .font(.caption)
                        .foregroundColor(.secondary)
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
        HStack(spacing: 10) {
            Button(action: { viewModel.copyLatestScreenshot(on: date) }) {
                Image(systemName: "doc.on.doc.fill")
                    .foregroundColor(.accentColor)
            }
            .buttonStyle(.plain)
            .help("Copy latest screenshot for this date")

            Button(action: {
                withAnimation(.easeInOut(duration: 0.2)) {
                    viewModel.selectDate(date)
                    viewModel.applySelectedDateFilter()
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
            .help("Focus this day")

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
        VStack(alignment: .leading, spacing: 8) {
            Button(action: { viewModel.copyScreenshot(item) }) {
                historyPreview(item)
            }
            .buttonStyle(.plain)

            HStack(spacing: 10) {
                Text(item.displayTime)
                    .font(.subheadline.monospacedDigit().weight(.semibold))
                    .foregroundColor(.primary)

                Spacer()

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
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(NSColor.windowBackgroundColor))
                .shadow(color: Color.black.opacity(0.04), radius: 3, y: 1)
        )
        .contextMenu {
            Button("Copy") { viewModel.copyScreenshot(item) }
            Button("Show in Finder") { viewModel.showInFinder(item) }
            Divider()
            Button("Delete", role: .destructive) { viewModel.deleteScreenshot(item) }
        }
        // Stable estimated height helps LazyVStack scroll without jumping.
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

    private var headerSubtitle: String {
        if let filterDate = viewModel.appliedDateFilter {
            return "Browsing screenshots from \(formattedDate(filterDate))"
        }
        return "Recent captures, organized by day"
    }

    private var dateButtonSymbolName: String {
        if showingDatePicker {
            return "calendar.badge.minus"
        }
        if viewModel.browsingByDate {
            return "arrow.uturn.backward.circle"
        }
        return "calendar"
    }

    private var dateButtonTitle: String {
        if showingDatePicker {
            return "Hide Date"
        }
        if viewModel.browsingByDate {
            return "Back to All"
        }
        return "Pick Date"
    }

    private var datePickerCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Browse by date")
                        .font(.headline)
                    Text("Choose a day to focus on screenshots from that date.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()

                Button("All Dates") {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        viewModel.clearDateFilter()
                        showingDatePicker = false
                    }
                }
                .buttonStyle(.borderless)
                .foregroundColor(.accentColor)
            }

            VStack(spacing: 14) {
                CompactCalendarView(
                    visibleMonth: $viewModel.visibleMonth,
                    selectedDate: $viewModel.selectedDate,
                    datesWithScreenshots: viewModel.datesWithScreenshots
                )
                    .frame(maxWidth: .infinity)

                HStack(spacing: 10) {
                    Button("Today") {
                        viewModel.selectToday()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)

                    Button("Yesterday") {
                        viewModel.selectYesterday()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)

                    Spacer()

                    Button("Apply") {
                        withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                            viewModel.applySelectedDateFilter()
                            showingDatePicker = false
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(14)
        .background(panelCardBackground)
    }

    private var footerSection: some View {
        HStack(spacing: 8) {
            Button(action: { viewModel.openScreenshotFolder() }) {
                Label("Open Folder", systemImage: "folder")
            }
            .buttonStyle(.bordered)

            Button(action: {
                // Dismiss the MenuBar popup first — the system popup window always
                // sits on top, so Settings would be hidden behind it if we don't close it.
                dismiss()
                // Small delay lets the popup finish its close animation before
                // the Settings window appears, so there's no visual overlap.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    appDelegate.openSettingsWindow()
                }
            }) {
                Label("Settings", systemImage: "gearshape")
            }
            .buttonStyle(.bordered)

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
                    .stroke(Color.white.opacity(0.65), lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(0.05), radius: 12, y: 6)
    }

    private func toggleDatePicker() {
        if showingDatePicker {
            withAnimation(.easeInOut(duration: 0.2)) {
                showingDatePicker = false
            }
        } else if viewModel.browsingByDate {
            withAnimation(.easeInOut(duration: 0.2)) {
                viewModel.clearDateFilter()
                showingDatePicker = false
            }
        } else {
            if let filter = viewModel.appliedDateFilter {
                viewModel.selectedDate = filter
                viewModel.visibleMonth = Calendar.current.startOfMonth(for: filter)
            }
            withAnimation(.spring(response: 0.3, dampingFraction: 0.88)) {
                showingDatePicker = true
            }
        }
    }
}

private struct CompactCalendarView: View {
    @Binding var visibleMonth: Date
    @Binding var selectedDate: Date
    let datesWithScreenshots: [Date: Int]
    @GestureState private var dragTranslation: CGFloat = 0

    private let calendar = Calendar.current
    private let weekdays = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]

    init(visibleMonth: Binding<Date>, selectedDate: Binding<Date>, datesWithScreenshots: [Date: Int]) {
        _visibleMonth = visibleMonth
        _selectedDate = selectedDate
        self.datesWithScreenshots = datesWithScreenshots
    }

    var body: some View {
        VStack(spacing: 14) {
            HStack {
                monthTitleView
                Spacer()
                Button(action: showPreviousMonth) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 14, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundColor(.secondary)
                .contentShape(Rectangle())
                .frame(width: 32, height: 32)
                .zIndex(10)

                Button(action: showNextMonth) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 14, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundColor(canShowNextMonth ? .secondary : .secondary.opacity(0.35))
                .disabled(!canShowNextMonth)
                .contentShape(Rectangle())
                .frame(width: 32, height: 32)
                .zIndex(10)
            }

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 7), spacing: 10) {
                ForEach(weekdays, id: \.self) { day in
                    Text(day)
                        .font(.caption.weight(.semibold))
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity)
                }

                ForEach(monthCells) { cell in
                    ZStack {
                        Circle()
                            .fill(isSelected(cell.date) ? Color.accentColor : Color.clear)
                            .frame(width: 40, height: 40)

                        Text("\(calendar.component(.day, from: cell.date))")
                            .font(.system(size: 15, weight: isSelected(cell.date) ? .bold : .medium))
                            .foregroundColor(textColor(for: cell.date, isCurrentMonth: cell.isCurrentMonth))

                        if let count = screenshotCount(for: cell.date, isCurrentMonth: cell.isCurrentMonth) {
                            Text(count > 99 ? "99+" : "\(count)")
                                .font(.system(size: 8, weight: .bold, design: .rounded))
                                .foregroundColor(.white)
                                .padding(.horizontal, 3)
                                .padding(.vertical, 1)
                                .background(Capsule().fill(Color.green))
                                .offset(y: 14)
                        }
                    }
                    .frame(width: 42, height: 42)
                    .contentShape(Rectangle())
                    .onTapGesture { selectedDate = cell.date }
                    .opacity(cell.date > Date() ? 0.3 : 1)
                    .frame(maxWidth: .infinity)
                }
            }

            Text("Swipe left or right to change month")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.white.opacity(0.96))
        )
        .overlay {
            TrackpadSwipeCatcher { direction in
                withAnimation(.spring(response: 0.28, dampingFraction: 0.88)) {
                    switch direction {
                    case .previous:
                        showPreviousMonth()
                    case .next:
                        showNextMonth()
                    }
                }
            }
        }
        .contentShape(Rectangle())
        .offset(x: dragTranslation * 0.12)
        .highPriorityGesture(monthSwipeGesture, including: .gesture)
        .onChange(of: selectedDate) { _, newValue in
            visibleMonth = calendar.startOfMonth(for: newValue)
        }
    }

    private static let monthFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMMM yyyy"
        return f
    }()

    private var monthTitle: String {
        Self.monthFormatter.string(from: visibleMonth)
    }

    private var monthTitleView: some View {
        Text(monthTitle)
            .font(.system(size: 20, weight: .bold))
            .fixedSize(horizontal: true, vertical: false)
    }

    private var canShowNextMonth: Bool {
        let currentMonth = calendar.startOfMonth(for: Date())
        return visibleMonth < currentMonth
    }

    private var monthCells: [CalendarCell] {
        guard let monthInterval = calendar.dateInterval(of: .month, for: visibleMonth) else {
            return []
        }

        let firstDayOfMonth = monthInterval.start
        let firstWeekday = calendar.component(.weekday, from: firstDayOfMonth)
        let daysToSubtract = firstWeekday - 1
        guard let startDate = calendar.date(byAdding: .day, value: -daysToSubtract, to: firstDayOfMonth) else {
            return []
        }

        return (0..<42).compactMap { i in
            guard let date = calendar.date(byAdding: .day, value: i, to: startDate) else { return nil }
            let isCurrentMonth = calendar.isDate(date, equalTo: visibleMonth, toGranularity: .month)
            return CalendarCell(date: date, isCurrentMonth: isCurrentMonth)
        }
    }

    private func showPreviousMonth() {
        guard let newMonth = calendar.date(byAdding: .month, value: -1, to: visibleMonth) else { return }
        visibleMonth = calendar.startOfMonth(for: newMonth)
    }

    private func showNextMonth() {
        guard canShowNextMonth else { return }
        guard let newMonth = calendar.date(byAdding: .month, value: 1, to: visibleMonth) else { return }
        visibleMonth = calendar.startOfMonth(for: newMonth)
    }

    private var monthSwipeGesture: some Gesture {
        DragGesture(minimumDistance: 20)
            .updating($dragTranslation) { value, state, _ in
                state = value.translation.width
            }
            .onEnded { value in
                let horizontal = value.translation.width
                let vertical = value.translation.height
                guard abs(horizontal) > abs(vertical), abs(horizontal) > 40 else { return }

                withAnimation(.spring(response: 0.28, dampingFraction: 0.88)) {
                    if horizontal < 0 {
                        showNextMonth()
                    } else {
                        showPreviousMonth()
                    }
                }
            }
    }

    private func isSelected(_ date: Date) -> Bool {
        calendar.isDate(date, inSameDayAs: selectedDate)
    }

    private func textColor(for date: Date, isCurrentMonth: Bool) -> Color {
        if date > Date() {
            return .secondary.opacity(0.28)
        }
        if isSelected(date) {
            return .white
        }
        return isCurrentMonth ? .primary : .secondary.opacity(0.5)
    }

    private func screenshotCount(for date: Date, isCurrentMonth: Bool) -> Int? {
        guard isCurrentMonth, date <= Date() else { return nil }
        let count = datesWithScreenshots[calendar.startOfDay(for: date)] ?? 0
        return count > 0 ? count : nil
    }
}

private struct CalendarCell: Identifiable {
    let date: Date
    let isCurrentMonth: Bool

    var id: TimeInterval { date.timeIntervalSinceReferenceDate }
}

private enum CalendarSwipeDirection {
    case previous
    case next
}

private struct TrackpadSwipeCatcher: NSViewRepresentable {
    let onSwipe: (CalendarSwipeDirection) -> Void

    func makeNSView(context: Context) -> SwipeCaptureView {
        let view = SwipeCaptureView()
        view.onSwipe = onSwipe
        return view
    }

    func updateNSView(_ nsView: SwipeCaptureView, context: Context) {
        nsView.onSwipe = onSwipe
    }
}

private final class SwipeCaptureView: NSView {
    var onSwipe: ((CalendarSwipeDirection) -> Void)?
    private var accumulatedHorizontalDelta: CGFloat = 0
    private var didTriggerSwipeInCurrentGesture = false
    private let swipeActivationThreshold: CGFloat = 90

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // Forward mouse events so clicks/taps pass through to SwiftUI views below
    override func mouseDown(with event: NSEvent) { nextResponder?.mouseDown(with: event) }
    override func mouseUp(with event: NSEvent) { nextResponder?.mouseUp(with: event) }
    override func mouseDragged(with event: NSEvent) { nextResponder?.mouseDragged(with: event) }
    override func mouseMoved(with event: NSEvent) { nextResponder?.mouseMoved(with: event) }
    override func rightMouseDown(with event: NSEvent) { nextResponder?.rightMouseDown(with: event) }

    override func scrollWheel(with event: NSEvent) {
        let deltaX = event.scrollingDeltaX
        let deltaY = event.scrollingDeltaY

        if event.phase == .began {
            accumulatedHorizontalDelta = 0
            didTriggerSwipeInCurrentGesture = false
        }

        guard abs(deltaX) > abs(deltaY), abs(deltaX) > 0 else {
            super.scrollWheel(with: event)
            return
        }

        guard !didTriggerSwipeInCurrentGesture else {
            if event.phase == .ended || event.momentumPhase == .ended || event.phase == .cancelled {
                accumulatedHorizontalDelta = 0
                didTriggerSwipeInCurrentGesture = false
            }
            return
        }

        accumulatedHorizontalDelta += deltaX

        if accumulatedHorizontalDelta >= swipeActivationThreshold {
            accumulatedHorizontalDelta = 0
            didTriggerSwipeInCurrentGesture = true
            onSwipe?(.previous)
        } else if accumulatedHorizontalDelta <= -swipeActivationThreshold {
            accumulatedHorizontalDelta = 0
            didTriggerSwipeInCurrentGesture = true
            onSwipe?(.next)
        }

        if event.phase == .ended || event.momentumPhase == .ended || event.phase == .cancelled {
            accumulatedHorizontalDelta = 0
            didTriggerSwipeInCurrentGesture = false
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
