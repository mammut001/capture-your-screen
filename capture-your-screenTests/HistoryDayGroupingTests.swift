import XCTest
@testable import capture_your_screen

final class HistoryDayGroupingTests: XCTestCase {

    func testMultiDayGroupingKeepsAllItemsAndSeparateDays() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!

        let day1 = calendar.date(from: DateComponents(year: 2026, month: 6, day: 1, hour: 10))!
        let day2 = calendar.date(from: DateComponents(year: 2026, month: 6, day: 2, hour: 11))!
        let day3 = calendar.date(from: DateComponents(year: 2026, month: 6, day: 3, hour: 12))!

        var records: [ScreenshotRecord] = []
        // 7 on day1, 5 on day2, 12 on day3 (more than the old UI prefix(4))
        for i in 0..<7 {
            records.append(record(day: day1, index: i, calendar: calendar))
        }
        for i in 0..<5 {
            records.append(record(day: day2, index: i, calendar: calendar))
        }
        for i in 0..<12 {
            records.append(record(day: day3, index: i, calendar: calendar))
        }

        let sections = HistorySectionBuilder.sections(from: records, calendar: calendar)
        XCTAssertEqual(sections.count, 3, "expected one section per calendar day")

        let counts = sections.map(\.items.count).sorted()
        XCTAssertEqual(counts, [5, 7, 12])

        let total = sections.reduce(0) { $0 + $1.items.count }
        XCTAssertEqual(total, records.count, "grouping must retain every screenshot")

        // Newest day first
        XCTAssertEqual(
            calendar.startOfDay(for: sections[0].date),
            calendar.startOfDay(for: day3)
        )
        XCTAssertEqual(sections[0].items.count, 12)

        // Within a day, items stay sorted newest-first
        let day3Items = sections[0].items
        for i in 0..<(day3Items.count - 1) {
            XCTAssertGreaterThanOrEqual(day3Items[i].date, day3Items[i + 1].date)
        }
    }

    func testFlatRowsIncludeHeaderThenEveryItemNoTruncation() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!

        let dayA = calendar.date(from: DateComponents(year: 2026, month: 7, day: 10, hour: 9))!
        let dayB = calendar.date(from: DateComponents(year: 2026, month: 7, day: 11, hour: 9))!

        let records =
            (0..<6).map { record(day: dayA, index: $0, calendar: calendar) } +
            (0..<9).map { record(day: dayB, index: $0, calendar: calendar) }

        let sections = HistorySectionBuilder.sections(from: records, calendar: calendar)
        let rows = HistorySectionBuilder.flatRows(from: sections)

        let headers = rows.compactMap { row -> Date? in
            if case .dayHeader(let date, _, _, let count) = row {
                XCTAssertGreaterThan(count, 0)
                return calendar.startOfDay(for: date)
            }
            return nil
        }
        XCTAssertEqual(headers.count, 2)

        let items = rows.compactMap { row -> ScreenshotHistoryItem? in
            if case .item(let item) = row { return item }
            return nil
        }
        XCTAssertEqual(items.count, 15, "flat list must not drop items beyond a 4-card prefix")

        // Each header is immediately followed by that day's items (order: newest day first).
        XCTAssertEqual(rows.count, 2 + 15)
        if case .dayHeader(_, _, _, let count) = rows[0] {
            XCTAssertEqual(count, 9)
            for offset in 1...9 {
                guard case .item = rows[offset] else {
                    XCTFail("expected item row at \(offset)")
                    return
                }
            }
        } else {
            XCTFail("first row should be day header")
        }
    }

    func testViewModelHistoryRowsMirrorFullSections() {
        let store = ScreenshotStore()
        let hotkey = HotkeyManager()
        let coordinator = CaptureCoordinator(screenshotStore: store, hotkeyManager: hotkey)
        let viewModel = MenuBarViewModel(
            captureCoordinator: coordinator,
            screenshotStore: store,
            hotkeyManager: hotkey
        )

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let day = calendar.date(from: DateComponents(year: 2026, month: 5, day: 20, hour: 8))!
        let records = (0..<11).map { record(day: day, index: $0, calendar: calendar) }

        store.replaceScreenshotsForTesting(records)
        spinMain(for: 0.05)

        XCTAssertEqual(viewModel.historySections.count, 1)
        XCTAssertEqual(viewModel.historySections[0].items.count, 11)
        let itemRows = viewModel.historyRows.filter {
            if case .item = $0 { return true }
            return false
        }
        XCTAssertEqual(itemRows.count, 11)
        XCTAssertEqual(viewModel.historyRows.count, 12) // 1 header + 11 items
    }

    func testFilteredRowsRemoveEmptyDayHeadersAndUpdateMatchCount() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!

        let olderDay = calendar.date(from: DateComponents(year: 2026, month: 8, day: 1, hour: 9))!
        let newerDay = calendar.date(from: DateComponents(year: 2026, month: 8, day: 2, hour: 9))!
        let records = [
            ScreenshotRecord(
                url: URL(fileURLWithPath: "/tmp/shots/Screenshot_alpha.png"),
                date: olderDay
            ),
            ScreenshotRecord(
                url: URL(fileURLWithPath: "/tmp/shots/Screenshot_beta.png"),
                date: newerDay
            ),
            ScreenshotRecord(
                url: URL(fileURLWithPath: "/tmp/shots/Screenshot_beta-second.jpg"),
                date: calendar.date(byAdding: .minute, value: 1, to: newerDay)!
            )
        ]

        let sections = HistorySectionBuilder.sections(from: records, calendar: calendar)
        let rows = HistorySectionBuilder.filteredRows(from: sections, matching: "  BETA  ")

        XCTAssertEqual(rows.count, 3, "one matching header plus two matching screenshots")
        guard case .dayHeader(_, _, let subtitle, let count) = rows[0] else {
            XCTFail("first filtered row should be its day header")
            return
        }
        XCTAssertEqual(count, 2)
        XCTAssertTrue(subtitle.contains("2 shots"))
        XCTAssertTrue(rows.dropFirst().allSatisfy {
            if case .item(let item) = $0 { return item.filename.lowercased().contains("beta") }
            return false
        })
    }

    func testWhitespaceOnlySearchReturnsAllRows() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let day = calendar.date(from: DateComponents(year: 2026, month: 8, day: 3, hour: 9))!
        let sections = HistorySectionBuilder.sections(
            from: [record(day: day, index: 0, calendar: calendar)],
            calendar: calendar
        )

        XCTAssertEqual(
            HistorySectionBuilder.filteredRows(from: sections, matching: " \n\t "),
            HistorySectionBuilder.flatRows(from: sections)
        )
    }

    func testDateNavigationAcrossRecordedDays() {
        let store = ScreenshotStore()
        let hotkey = HotkeyManager()
        let coordinator = CaptureCoordinator(screenshotStore: store, hotkeyManager: hotkey)
        let viewModel = MenuBarViewModel(
            captureCoordinator: coordinator,
            screenshotStore: store,
            hotkeyManager: hotkey
        )

        let calendar = Calendar.current

        let day1 = calendar.date(from: DateComponents(year: 2026, month: 4, day: 10, hour: 10))!
        let day2 = calendar.date(from: DateComponents(year: 2026, month: 4, day: 15, hour: 11))!
        let day3 = calendar.date(from: DateComponents(year: 2026, month: 4, day: 20, hour: 12))!

        let records = [
            ScreenshotRecord(url: URL(fileURLWithPath: "/tmp/s1.png"), date: day1),
            ScreenshotRecord(url: URL(fileURLWithPath: "/tmp/s2.png"), date: day2),
            ScreenshotRecord(url: URL(fileURLWithPath: "/tmp/s3.png"), date: day3)
        ]
        store.replaceScreenshotsForTesting(records)
        spinMain(for: 0.05)

        XCTAssertEqual(viewModel.recordedDays.count, 3)

        // Filter to day2
        viewModel.applyDate(day2)
        XCTAssertTrue(viewModel.browsingByDate)
        XCTAssertEqual(viewModel.previousRecordedDate, calendar.startOfDay(for: day1))
        XCTAssertEqual(viewModel.nextRecordedDate, calendar.startOfDay(for: day3))

        // Navigate previous (to day1)
        viewModel.selectPreviousRecordedDate()
        XCTAssertEqual(viewModel.appliedDateFilter, calendar.startOfDay(for: day1))
        XCTAssertNil(viewModel.previousRecordedDate)
        XCTAssertEqual(viewModel.nextRecordedDate, calendar.startOfDay(for: day2))

        // Navigate next (back to day2)
        viewModel.selectNextRecordedDate()
        XCTAssertEqual(viewModel.appliedDateFilter, calendar.startOfDay(for: day2))

        // Navigate next (to day3)
        viewModel.selectNextRecordedDate()
        XCTAssertEqual(viewModel.appliedDateFilter, calendar.startOfDay(for: day3))
        XCTAssertNil(viewModel.nextRecordedDate)
        XCTAssertEqual(viewModel.previousRecordedDate, calendar.startOfDay(for: day2))

        // Clear filter
        viewModel.clearDateFilter()
        XCTAssertFalse(viewModel.browsingByDate)
        XCTAssertNil(viewModel.appliedDateFilter)
    }

    func testDateFilteredSearchMatchesOnlyWithinFilteredDay() {
        let store = ScreenshotStore()
        let hotkey = HotkeyManager()
        let coordinator = CaptureCoordinator(screenshotStore: store, hotkeyManager: hotkey)
        let viewModel = MenuBarViewModel(
            captureCoordinator: coordinator,
            screenshotStore: store,
            hotkeyManager: hotkey
        )

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!

        let dayA = calendar.date(from: DateComponents(year: 2026, month: 5, day: 1, hour: 10))!
        let dayB = calendar.date(from: DateComponents(year: 2026, month: 5, day: 2, hour: 10))!

        let records = [
            ScreenshotRecord(url: URL(fileURLWithPath: "/tmp/shots/report_alpha.png"), date: dayA),
            ScreenshotRecord(url: URL(fileURLWithPath: "/tmp/shots/report_beta.png"), date: dayB),
            ScreenshotRecord(url: URL(fileURLWithPath: "/tmp/shots/chart_beta.png"), date: dayB)
        ]
        store.replaceScreenshotsForTesting(records)
        spinMain(for: 0.05)

        // Filter to dayB
        viewModel.applyDate(dayB)
        XCTAssertEqual(viewModel.filteredHistoryItems.count, 2)

        // Search within dayB for "report"
        let searchReport = viewModel.filteredHistoryItems(matching: "report")
        XCTAssertEqual(searchReport.count, 1)
        XCTAssertEqual(searchReport.first?.filename, "report_beta.png")

        // Search within dayB for "alpha" (which exists on dayA, not dayB)
        let searchAlpha = viewModel.filteredHistoryItems(matching: "alpha")
        XCTAssertTrue(searchAlpha.isEmpty)
    }

    func testTodayAndYesterdayQuickActions() {
        let store = ScreenshotStore()
        let hotkey = HotkeyManager()
        let coordinator = CaptureCoordinator(screenshotStore: store, hotkeyManager: hotkey)
        let viewModel = MenuBarViewModel(
            captureCoordinator: coordinator,
            screenshotStore: store,
            hotkeyManager: hotkey
        )

        viewModel.applyToday()
        XCTAssertTrue(viewModel.browsingByDate)
        XCTAssertTrue(viewModel.isTodayFiltered)
        XCTAssertFalse(viewModel.isYesterdayFiltered)

        viewModel.applyYesterday()
        XCTAssertTrue(viewModel.browsingByDate)
        XCTAssertFalse(viewModel.isTodayFiltered)
        XCTAssertTrue(viewModel.isYesterdayFiltered)

        viewModel.clearDateFilter()
        XCTAssertFalse(viewModel.browsingByDate)
        XCTAssertFalse(viewModel.isTodayFiltered)
        XCTAssertFalse(viewModel.isYesterdayFiltered)
    }

    // MARK: - Helpers

    private func record(day: Date, index: Int, calendar: Calendar) -> ScreenshotRecord {
        let date = calendar.date(byAdding: .minute, value: index, to: day) ?? day
        let url = URL(
            fileURLWithPath: "/tmp/cys-day/Screenshot_\(Int(date.timeIntervalSince1970))_\(index).png"
        )
        return ScreenshotRecord(url: url, date: date)
    }

    private func spinMain(for seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
    }
}
