import XCTest
import SwiftUI
import AppKit
@testable import capture_your_screen

/// Regression guard: an earlier build overlaid an NSView swipe catcher on the
/// calendar that swallowed every click, so dates could not be selected.
/// These drive real mouse events through an offscreen window.
@MainActor
final class CalendarInteractionTests: XCTestCase {
    private func spin(_ s: TimeInterval) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }

    func testClickingDayCellsSelectsDates() throws {
        var selected: [Date] = []
        let today = Calendar.current.startOfDay(for: Date())
        let host = NSHostingView(rootView: CalendarProbeHost(onSelect: { selected.append($0) }, today: today))
        let window = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 320, height: 420),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        window.orderFrontRegardless()
        spin(0.3)

        func click(_ p: NSPoint) {
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                let e = NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                           windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
                window.sendEvent(e)
                spin(0.02)
            }
            spin(0.05)
        }
        // Sweep a vertical line through the middle column of the grid.
        var y: CGFloat = 20
        while y < 400 { click(NSPoint(x: 160, y: y)); y += 12 }
        
        XCTAssertGreaterThan(Set(selected).count, 2, "Clicking day cells should select dates")
        window.orderOut(nil)
    }
}

private struct CalendarProbeHost: View {
    let onSelect: (Date) -> Void
    let today: Date
    @State var month = Calendar.current.startOfMonth(for: Date())
    @State var selected = Date()
    var body: some View {
        CompactCalendarView(visibleMonth: $month, selectedDate: $selected, datesWithScreenshots: [today: 3],
                            firstWeekdayPreference: 1, onSelectDate: onSelect, onClearFilter: {}, onClose: {})
            .frame(width: 320)
    }
}

@MainActor
final class MenuBarCalendarInteractionTests: XCTestCase {
    private func spin(_ s: TimeInterval) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }

    func testClickingDayInPanelCalendarAppliesFilter() throws {
        let app = AppDelegate()
        let root = MenuBarView(showingDatePicker: true)
            .environmentObject(app.viewModel)
            .environmentObject(app.screenshotStore)
            .environmentObject(app.hotkeyManager)
            .environmentObject(app.launchAtLoginManager)
            .environmentObject(app)
        let host = NSHostingView(rootView: root)
        let window = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 560, height: 700),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        window.orderFrontRegardless()
        spin(0.5)

        func click(_ p: NSPoint) {
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                let e = NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                           windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
                window.sendEvent(e)
                spin(0.02)
            }
            spin(0.1)
        }
        // Card is centred horizontally and sits 48pt below the top (700pt window, AppKit y is bottom-up).
        var hit: Date?
        var y: CGFloat = 700 - 48 - 60
        while y > 700 - 48 - 330 {
            click(NSPoint(x: 280, y: y))
            if let f = app.viewModel.appliedDateFilter { hit = f; break }
            y -= 10
        }
        
        XCTAssertNotNil(hit, "Clicking a day in the panel calendar should apply a date filter")
        window.orderOut(nil)
    }
}
