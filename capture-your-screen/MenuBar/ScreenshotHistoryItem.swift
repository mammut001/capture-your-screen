import Foundation
import AppKit

struct ScreenshotHistoryItem: Identifiable {
    let id: String
    let url: URL
    let date: Date
    let thumbnail: NSImage?
    let displayTime: String
}

enum HistoryGroup: String, CaseIterable, Hashable {
    case today = "Today"
    case yesterday = "Yesterday"
    case earlier = "Earlier"

    var icon: String {
        switch self {
        case .today: return "calendar.circle.fill"
        case .yesterday: return "calendar.circle"
        case .earlier: return "calendar"
        }
    }

    static func group(for date: Date) -> HistoryGroup {
        let cal = Calendar.current
        if cal.isDateInToday(date) { return .today }
        if cal.isDateInYesterday(date) { return .yesterday }
        return .earlier
    }
}

extension ScreenshotRecord {
    func toHistoryItem() -> ScreenshotHistoryItem {
        let formatter = DateFormatter()
        let group = HistoryGroup.group(for: date)
        if group == .earlier {
            formatter.dateFormat = "MMM d, HH:mm"
        } else {
            formatter.dateFormat = "HH:mm:ss"
        }
        return ScreenshotHistoryItem(
            id: id,
            url: url,
            date: date,
            thumbnail: thumbnail,
            displayTime: formatter.string(from: date)
        )
    }
}
