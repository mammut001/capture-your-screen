import XCTest
import CoreGraphics
@testable import capture_your_screen

final class CaptureWindowSelectionTests: XCTestCase {
    private let screenFrame = CGRect(x: 0, y: 0, width: 1440, height: 900)

    func testCandidatesFilterOwnTransparentAndOffscreenWindows() {
        let infos = [
            windowInfo(id: 1, pid: 99, bounds: CGRect(x: 10, y: 10, width: 300, height: 200)),
            windowInfo(id: 2, pid: 20, bounds: CGRect(x: 10, y: 10, width: 300, height: 200), alpha: 0),
            windowInfo(id: 3, pid: 21, bounds: CGRect(x: 10, y: 10, width: 300, height: 200), onscreen: false),
            windowInfo(id: 4, pid: 22, bounds: CGRect(x: 1600, y: 10, width: 300, height: 200)),
            windowInfo(id: 5, pid: 23, bounds: CGRect(x: 1400, y: 20, width: 100, height: 100))
        ]

        let result = CaptureWindowSelection.candidates(
            from: infos,
            screenFrameInGlobalTopLeftCoordinates: screenFrame,
            ownPID: 99
        )

        XCTAssertEqual(result.map(\.windowID), [5])
        XCTAssertEqual(result[0].screenLocalBounds, CGRect(x: 1400, y: 20, width: 40, height: 100))
    }

    func testSelectionUsesFrontmostContainingCandidateRegardlessOfLayer() {
        let back = candidate(id: 1, pid: 10, layer: 0, rect: CGRect(x: 50, y: 80, width: 500, height: 400), order: 1)
        let popover = candidate(id: 2, pid: 20, layer: 8, rect: CGRect(x: 100, y: 100, width: 220, height: 180), order: 0)

        let selected = CaptureWindowSelection.selectionRect(
            at: CGPoint(x: 150, y: 150),
            candidates: [popover, back],
            screenSize: screenFrame.size
        )

        XCTAssertEqual(selected, popover.screenLocalBounds)
    }

    func testPointerOnMenuBarIconSelectsSameOwnerPopover() {
        let icon = candidate(id: 1, pid: 30, layer: 25, rect: CGRect(x: 1240, y: 0, width: 28, height: 28), order: 0)
        let popover = candidate(id: 2, pid: 30, layer: 8, rect: CGRect(x: 1050, y: 28, width: 300, height: 420), order: 1)
        let unrelated = candidate(id: 3, pid: 40, layer: 8, rect: CGRect(x: 1160, y: 28, width: 240, height: 200), order: 2)

        let selected = CaptureWindowSelection.selectionRect(
            at: CGPoint(x: 1254, y: 14),
            candidates: [icon, popover, unrelated],
            screenSize: screenFrame.size
        )

        XCTAssertEqual(selected, popover.screenLocalBounds)
    }

    func testRegularWindowSelectionDoesNotUseMenuBarHeuristic() {
        let window = candidate(id: 1, pid: 10, layer: 0, rect: CGRect(x: 50, y: 80, width: 500, height: 400), order: 0)
        let popover = candidate(id: 2, pid: 20, layer: 8, rect: CGRect(x: 900, y: 28, width: 240, height: 200), order: 1)

        let selected = CaptureWindowSelection.selectionRect(
            at: CGPoint(x: 100, y: 120),
            candidates: [window, popover],
            screenSize: screenFrame.size
        )

        XCTAssertEqual(selected, window.screenLocalBounds)
    }

    private func candidate(id: CGWindowID, pid: pid_t, layer: Int, rect: CGRect, order: Int) -> CaptureWindowCandidate {
        CaptureWindowCandidate(
            windowID: id,
            ownerPID: pid,
            ownerName: "App \(pid)",
            layer: layer,
            screenLocalBounds: rect,
            frontToBackOrder: order
        )
    }

    private func windowInfo(
        id: CGWindowID,
        pid: pid_t,
        bounds: CGRect,
        layer: Int = 0,
        alpha: Double = 1,
        onscreen: Bool = true
    ) -> [String: Any] {
        [
            kCGWindowNumber as String: NSNumber(value: id),
            kCGWindowOwnerPID as String: NSNumber(value: pid),
            kCGWindowOwnerName as String: "App \(pid)",
            kCGWindowLayer as String: NSNumber(value: layer),
            kCGWindowAlpha as String: NSNumber(value: alpha),
            kCGWindowIsOnscreen as String: NSNumber(value: onscreen),
            kCGWindowBounds as String: [
                "X": NSNumber(value: Double(bounds.minX)),
                "Y": NSNumber(value: Double(bounds.minY)),
                "Width": NSNumber(value: Double(bounds.width)),
                "Height": NSNumber(value: Double(bounds.height))
            ]
        ]
    }
}
