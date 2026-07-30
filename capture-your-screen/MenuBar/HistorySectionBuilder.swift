import Foundation
import AppKit

/// One row in the default multi-day history scroll list.
/// Flattening headers + cards lets `LazyVStack` virtualize each card independently
/// instead of materializing an entire day at once.
enum HistoryListRow: Identifiable, Equatable {
    case dayHeader(date: Date, title: String, subtitle: String, count: Int)
    case item(ScreenshotHistoryItem)

    var id: String {
        switch self {
        case .dayHeader(let date, _, _, _):
            return "day-\(date.timeIntervalSinceReferenceDate)"
        case .item(let item):
            return "item-\(item.id)"
        }
    }
}

/// Pure helpers for history list structure. Thumbnail images are intentionally
/// not part of section identity — previews live in a separate map.
enum HistorySectionBuilder {
    /// Stable membership signature for the screenshot set (order-sensitive ids).
    static func membershipSignature(for records: [ScreenshotRecord]) -> [String] {
        records.map(\.id)
    }

    /// Whether two record lists represent the same set of files in the same order.
    static func membershipEquals(_ lhs: [ScreenshotRecord], _ rhs: [ScreenshotRecord]) -> Bool {
        membershipSignature(for: lhs) == membershipSignature(for: rhs)
    }

    /// Group records into day sections without embedding thumbnail images.
    /// Every item is retained in its calendar-day section (no truncation).
    static func sections(
        from records: [ScreenshotRecord],
        calendar: Calendar = .current
    ) -> [ScreenshotDaySection] {
        let items = records.map { $0.toHistoryItem() }
        let groupedByDay = Dictionary(grouping: items) { item in
            calendar.startOfDay(for: item.date)
        }

        return groupedByDay
            .map { date, dayItems in
                ScreenshotDaySection(
                    date: date,
                    items: dayItems.sorted { $0.date > $1.date }
                )
            }
            .sorted { $0.date > $1.date }
    }

    /// Flatten day sections into lazy-scroll rows: one header per day, then every item.
    static func flatRows(from sections: [ScreenshotDaySection]) -> [HistoryListRow] {
        var rows: [HistoryListRow] = []
        rows.reserveCapacity(sections.reduce(0) { $0 + 1 + $1.items.count })
        for section in sections {
            rows.append(
                .dayHeader(
                    date: section.date,
                    title: section.title,
                    subtitle: section.subtitle,
                    count: section.items.count
                )
            )
            for item in section.items {
                rows.append(.item(item))
            }
        }
        return rows
    }

    /// Apply one thumbnail into a map without touching list structure.
    static func applyingThumbnail(
        _ image: NSImage,
        for id: String,
        to map: [String: NSImage]
    ) -> [String: NSImage] {
        var next = map
        next[id] = image
        return next
    }
}
