import Foundation
import AppKit

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
