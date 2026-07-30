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
