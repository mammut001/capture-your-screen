import Foundation
import AppKit

struct ScreenshotHistoryItem: Identifiable, Equatable {
    let id: String
    let url: URL
    let date: Date
    let displayTime: String
    let fileSize: Int64?

    var filename: String { url.lastPathComponent }

    var formatLabel: String {
        switch url.pathExtension.lowercased() {
        case "jpg", "jpeg": "JPEG"
        default: "PNG"
        }
    }

    var formattedFileSize: String? {
        guard let fileSize else { return nil }
        let bytes = Double(fileSize)
        if bytes < 1024 { return "\(fileSize) B" }
        if bytes < 1024 * 1024 { return String(format: "%.1f KB", bytes / 1024) }
        return String(format: "%.1f MB", bytes / (1024 * 1024))
    }
}

struct ScreenshotDaySection: Identifiable, Equatable {
    let date: Date
    let items: [ScreenshotHistoryItem]

    var id: Date { date }

    var title: String {
        Self.titleFormatter.string(from: date)
    }

    var subtitle: String {
        let countLabel = items.count == 1 ? "1 shot" : "\(items.count) shots"
        if Calendar.current.isDateInToday(date) {
            return "Today · \(countLabel)"
        }
        if Calendar.current.isDateInYesterday(date) {
            return "Yesterday · \(countLabel)"
        }
        return countLabel
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
        let size: Int64? = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? nil
        return ScreenshotHistoryItem(
            id: id,
            url: url,
            date: date,
            displayTime: Self.historyTimeFormatter.string(from: date),
            fileSize: size
        )
    }
}
