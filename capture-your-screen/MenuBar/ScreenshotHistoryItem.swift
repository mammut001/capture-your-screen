import Foundation
import AppKit

struct ScreenshotHistoryItem: Identifiable, Equatable {
    let id: String
    let url: URL
    let date: Date
    let displayTime: String
}

struct ScreenshotDaySection: Identifiable, Equatable {
    let date: Date
    let items: [ScreenshotHistoryItem]

    var id: Date { date }

    var title: String {
        Self.titleFormatter.string(from: date)
    }

    var subtitle: String {
        if Calendar.current.isDateInToday(date) {
            return "Today"
        }
        if Calendar.current.isDateInYesterday(date) {
            return "Yesterday"
        }
        return "\(items.count) shots"
    }

    private static let titleFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE, MMM d"
        return formatter
    }()
}

extension ScreenshotRecord {
    private static let historyTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    func toHistoryItem() -> ScreenshotHistoryItem {
        ScreenshotHistoryItem(
            id: id,
            url: url,
            date: date,
            displayTime: Self.historyTimeFormatter.string(from: date)
        )
    }
}
