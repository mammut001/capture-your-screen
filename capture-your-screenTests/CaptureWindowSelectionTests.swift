import XCTest
import CoreGraphics
@testable import capture_your_screen

final class CaptureWindowSelectionTests: XCTestCase {
    private let screenFrame = CGRect(x: 0, y: 0, width: 1440, height: 900)

    /// Structural: overlay must wire the AppKit mouse monitor (not only SwiftUI hover).
    func testSelectionOverlaySourceUsesMouseMoveMonitor() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Tests/
            .deletingLastPathComponent() // repo
        let overlaySource = root
            .appendingPathComponent("capture-your-screen/Capture/SelectionOverlayView.swift")
        let source = try String(contentsOf: overlaySource, encoding: .utf8)
        XCTAssertTrue(
            source.contains("OverlayMouseMoveMonitor"),
            "SelectionOverlayView must install OverlayMouseMoveMonitor for click-free hover"
        )
        XCTAssertTrue(
            source.contains("OverlayHoverSession"),
            "SelectionOverlayView must drive OverlayHoverSession for pointer moves"
        )
        XCTAssertFalse(
            source.contains("onContinuousHover"),
            "onContinuousHover requires a priming click when inactive — must not be the hover path"
        )
        // Confirm / Quick Save must be reachable from hover preselect (no lock gate).
        XCTAssertFalse(
            source.contains("if isSelectionFinalized {\n                        actionButtons"),
            "Action buttons must show on hover preselect — do not gate on isSelectionFinalized"
        )
        XCTAssertTrue(
            source.contains("actionButtons(for: rect, canvasSize: geo.size)"),
            "SelectionOverlayView must present action buttons for a valid selection"
        )
        XCTAssertTrue(
            source.contains("protectedUIRects"),
            "Overlay must protect action-button chrome from window hit-testing"
        )
        XCTAssertTrue(
            source.contains("OverlayHoverTicker"),
            "SelectionOverlayView must poll the cursor — event monitors alone miss moves when the overlay eats events"
        )
        XCTAssertTrue(
            source.contains("hoverTicker"),
            "Hover ticker must be wired into the overlay view"
        )
        XCTAssertTrue(
            source.contains("CaptureWindowSelection.selectionRect("),
            "Hover and click-without-drag must call the shared selection rule"
        )
        XCTAssertTrue(
            source.contains("autoSelectionRect(at: end)"),
            "A click that does not drag must lock the shared auto-select rectangle"
        )
        XCTAssertTrue(
            source.contains("width: abs(current.x - start.x)"),
            "A drag past the click slop must store the dragged rectangle"
        )
        XCTAssertTrue(
            source.contains("height: abs(current.y - start.y)"),
            "A drag past the click slop must store the dragged rectangle"
        )
        XCTAssertFalse(
            source.contains("width * height"),
            "The overlay must not rank candidate windows by area"
        )
        XCTAssertTrue(
            source.contains("clickedChrome: chrome"),
            "X must unlock through the shared session and protect the dismissed button cluster"
        )
        XCTAssertTrue(
            source.contains("dismissChrome"),
            "Later hover ticks must keep the dismissed button cluster protected"
        )
    }

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

    func testCandidatesRejectDockFullscreenShieldSoHoverCanReachApps() {
        // Reproduces the live failure: Dock publishes a layer-20 window covering
        // the whole display, listed in front of every app — without filtering,
        // every hover point snaps to the full screen and never switches.
        let infos = [
            windowInfo(
                id: 10,
                pid: 448,
                bounds: screenFrame,
                layer: 20,
                ownerName: "Dock"
            ),
            windowInfo(
                id: 11,
                pid: 50,
                bounds: CGRect(x: 100, y: 80, width: 800, height: 600),
                layer: 0,
                ownerName: "Safari"
            ),
            windowInfo(
                id: 12,
                pid: 51,
                bounds: CGRect(x: 500, y: 100, width: 700, height: 500),
                layer: 0,
                ownerName: "Cursor"
            ),
        ]

        let result = CaptureWindowSelection.candidates(
            from: infos,
            screenFrameInGlobalTopLeftCoordinates: screenFrame,
            ownPID: 1
        )

        XCTAssertEqual(result.map(\.windowID), [11, 12])
        XCTAssertEqual(
            CaptureWindowSelection.selectionRect(
                at: CGPoint(x: 150, y: 120),
                candidates: result,
                screenSize: screenFrame.size
            ),
            CGRect(x: 100, y: 80, width: 800, height: 600)
        )
        XCTAssertEqual(
            CaptureWindowSelection.selectionRect(
                at: CGPoint(x: 1100, y: 200),
                candidates: result,
                screenSize: screenFrame.size
            ),
            CGRect(x: 500, y: 100, width: 700, height: 500)
        )
    }

    func testCandidatesKeepMaximizedNormalAppWindows() {
        let infos = [
            windowInfo(
                id: 1,
                pid: 50,
                bounds: CGRect(x: 0, y: 25, width: 1440, height: 875),
                layer: 0,
                ownerName: "Safari"
            )
        ]
        let result = CaptureWindowSelection.candidates(
            from: infos,
            screenFrameInGlobalTopLeftCoordinates: screenFrame,
            ownPID: 1
        )
        XCTAssertEqual(result.map(\.windowID), [1])
        assertSnap(
            at: CGPoint(x: 20, y: 80),
            candidates: result,
            equals: result[0].screenLocalBounds
        )
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

    // MARK: - OverlayHoverSession (no priming click)

    func testHoverSession_firstMoveWithoutClickSnapsToWindow() {
        let windowA = candidate(id: 1, pid: 10, layer: 0, rect: CGRect(x: 40, y: 60, width: 400, height: 300), order: 0)
        let windowB = candidate(id: 2, pid: 11, layer: 0, rect: CGRect(x: 500, y: 60, width: 400, height: 300), order: 1)
        var session = OverlayHoverSession()

        // First pointer move — no prior click / finalize.
        let changed = session.pointerMoved(
            to: CGPoint(x: 100, y: 100),
            candidates: [windowA, windowB],
            screenSize: screenFrame.size
        )

        XCTAssertTrue(changed)
        XCTAssertEqual(session.selection, windowA.screenLocalBounds)
        XCTAssertEqual(session.lastHoverLocation, CGPoint(x: 100, y: 100))
        XCTAssertFalse(session.isSelectionFinalized)
    }

    func testHoverSession_sequenceOfMovesUpdatesProposal() {
        let windowA = candidate(id: 1, pid: 10, layer: 0, rect: CGRect(x: 40, y: 60, width: 400, height: 300), order: 0)
        let windowB = candidate(id: 2, pid: 11, layer: 0, rect: CGRect(x: 500, y: 60, width: 400, height: 300), order: 1)
        var session = OverlayHoverSession()
        let candidates = [windowA, windowB]

        _ = session.pointerMoved(to: CGPoint(x: 100, y: 100), candidates: candidates, screenSize: screenFrame.size)
        XCTAssertEqual(session.selection, windowA.screenLocalBounds)

        _ = session.pointerMoved(to: CGPoint(x: 600, y: 120), candidates: candidates, screenSize: screenFrame.size)
        XCTAssertEqual(session.selection, windowB.screenLocalBounds)
    }

    func testHoverSession_finalizedIgnoresMovesUntilUnlock() {
        let windowA = candidate(id: 1, pid: 10, layer: 0, rect: CGRect(x: 40, y: 60, width: 400, height: 300), order: 0)
        let windowB = candidate(id: 2, pid: 11, layer: 0, rect: CGRect(x: 500, y: 60, width: 400, height: 300), order: 1)
        var session = OverlayHoverSession()
        let candidates = [windowA, windowB]

        _ = session.pointerMoved(to: CGPoint(x: 100, y: 100), candidates: candidates, screenSize: screenFrame.size)
        session.isSelectionFinalized = true

        let ignored = session.pointerMoved(
            to: CGPoint(x: 600, y: 120),
            candidates: candidates,
            screenSize: screenFrame.size
        )
        XCTAssertFalse(ignored)
        XCTAssertEqual(session.selection, windowA.screenLocalBounds)

        session.unlock(candidates: candidates, screenSize: screenFrame.size)
        XCTAssertFalse(session.isSelectionFinalized)
        // Unlock restores from lastHoverLocation (still over A).
        XCTAssertEqual(session.selection, windowA.screenLocalBounds)

        // Immediate re-hover after unlock (simulates post–Cmd+E / X without click).
        _ = session.pointerMoved(to: CGPoint(x: 600, y: 120), candidates: candidates, screenSize: screenFrame.size)
        XCTAssertEqual(session.selection, windowB.screenLocalBounds)
    }

    func testHoverSession_draggingSuppressesHoverUpdates() {
        let windowA = candidate(id: 1, pid: 10, layer: 0, rect: CGRect(x: 40, y: 60, width: 400, height: 300), order: 0)
        let windowB = candidate(id: 2, pid: 11, layer: 0, rect: CGRect(x: 500, y: 60, width: 400, height: 300), order: 1)
        var session = OverlayHoverSession(
            selection: windowA.screenLocalBounds,
            lastHoverLocation: CGPoint(x: 100, y: 100),
            isSelectionFinalized: false,
            isDragging: true
        )

        let ignored = session.pointerMoved(
            to: CGPoint(x: 600, y: 120),
            candidates: [windowA, windowB],
            screenSize: screenFrame.size
        )
        XCTAssertFalse(ignored)
        XCTAssertEqual(session.selection, windowA.screenLocalBounds)
    }

    func testHoverSession_pointerOverActionControlsKeepsSelection() {
        let windowA = candidate(id: 1, pid: 10, layer: 0, rect: CGRect(x: 40, y: 60, width: 400, height: 300), order: 0)
        let windowB = candidate(id: 2, pid: 11, layer: 0, rect: CGRect(x: 500, y: 60, width: 400, height: 300), order: 1)
        var session = OverlayHoverSession(
            selection: windowA.screenLocalBounds,
            lastHoverLocation: CGPoint(x: 100, y: 100),
            isSelectionFinalized: false,
            isDragging: false
        )
        let protected = [
            SelectionOverlayLayout.actionControlsFrame(
                selectionRect: windowA.screenLocalBounds,
                canvasSize: screenFrame.size
            )
        ]
        let overControls = CGPoint(x: protected[0].midX, y: protected[0].midY)

        let ignored = session.pointerMoved(
            to: overControls,
            candidates: [windowA, windowB],
            screenSize: screenFrame.size,
            protectedRects: protected
        )

        XCTAssertFalse(ignored)
        XCTAssertEqual(session.selection, windowA.screenLocalBounds)
        // lastHoverLocation stays on the window so unlock re-snaps correctly.
        XCTAssertEqual(session.lastHoverLocation, CGPoint(x: 100, y: 100))
    }

    func testHoverSession_afterLeavingActionControlsUpdatesAgain() {
        let windowA = candidate(id: 1, pid: 10, layer: 0, rect: CGRect(x: 40, y: 60, width: 400, height: 300), order: 0)
        let windowB = candidate(id: 2, pid: 11, layer: 0, rect: CGRect(x: 500, y: 60, width: 400, height: 300), order: 1)
        var session = OverlayHoverSession(
            selection: windowA.screenLocalBounds,
            lastHoverLocation: CGPoint(x: 100, y: 100)
        )
        let protected = [
            SelectionOverlayLayout.actionControlsFrame(
                selectionRect: windowA.screenLocalBounds,
                canvasSize: screenFrame.size
            )
        ]

        _ = session.pointerMoved(
            to: CGPoint(x: protected[0].midX, y: protected[0].midY),
            candidates: [windowA, windowB],
            screenSize: screenFrame.size,
            protectedRects: protected
        )
        XCTAssertEqual(session.selection, windowA.screenLocalBounds)

        let changed = session.pointerMoved(
            to: CGPoint(x: 600, y: 120),
            candidates: [windowA, windowB],
            screenSize: screenFrame.size,
            protectedRects: protected
        )
        XCTAssertTrue(changed)
        XCTAssertEqual(session.selection, windowB.screenLocalBounds)
    }

    func testActionControlsFrameSitsBelowSelectionWhenSpaceAllows() {
        let rect = CGRect(x: 200, y: 100, width: 400, height: 300)
        let frame = SelectionOverlayLayout.actionControlsFrame(
            selectionRect: rect,
            canvasSize: screenFrame.size
        )
        XCTAssertGreaterThan(frame.midY, rect.maxY)
        XCTAssertTrue(frame.intersects(
            CGRect(x: rect.midX - 120, y: rect.maxY, width: 240, height: 80)
        ))
    }

    func testActionControlsFrameFlipsAboveWhenNearBottom() {
        let rect = CGRect(x: 200, y: 780, width: 400, height: 100)
        let frame = SelectionOverlayLayout.actionControlsFrame(
            selectionRect: rect,
            canvasSize: screenFrame.size
        )
        XCTAssertLessThan(frame.midY, rect.minY)
    }

    func testOverlappingWindowsPickFrontmostByListOrder() {
        let back = candidate(id: 1, pid: 10, layer: 0, rect: CGRect(x: 50, y: 50, width: 600, height: 500), order: 1)
        let front = candidate(id: 2, pid: 20, layer: 0, rect: CGRect(x: 100, y: 100, width: 300, height: 250), order: 0)

        let selected = CaptureWindowSelection.selectionRect(
            at: CGPoint(x: 150, y: 150),
            candidates: [front, back],
            screenSize: screenFrame.size
        )
        XCTAssertEqual(selected, front.screenLocalBounds)
    }

    // MARK: - Frontmost window, not min or max area

    func testAutoSelectPrefersFrontSmallOverBackLarge() {
        let large = candidate(id: 1, pid: 10, layer: 0, rect: CGRect(x: 40, y: 80, width: 900, height: 700), order: 4)
        let small = candidate(id: 2, pid: 20, layer: 0, rect: CGRect(x: 200, y: 160, width: 120, height: 80), order: 0)
        // Large is listed first and has the greater area. Z-order still wins.
        let overlap = CGPoint(x: 220, y: 180)

        assertSnap(at: overlap, candidates: [large, small], equals: small.screenLocalBounds)
    }

    func testAutoSelectPrefersFrontLargeOverBackSmall() {
        let small = candidate(id: 1, pid: 10, layer: 0, rect: CGRect(x: 200, y: 160, width: 120, height: 80), order: 3)
        let large = candidate(id: 2, pid: 20, layer: 0, rect: CGRect(x: 40, y: 80, width: 900, height: 700), order: 0)
        // Small is listed first. The front window is the larger one.
        let overlap = CGPoint(x: 220, y: 180)

        assertSnap(at: overlap, candidates: [small, large], equals: large.screenLocalBounds)
    }

    func testAutoSelectPointOutsideFrontWindowUsesTheWindowBehindIt() {
        let large = candidate(id: 1, pid: 10, layer: 0, rect: CGRect(x: 40, y: 80, width: 900, height: 700), order: 4)
        let small = candidate(id: 2, pid: 20, layer: 0, rect: CGRect(x: 200, y: 160, width: 120, height: 80), order: 0)
        // Inside the back window only — the front window must not steal it.
        let onlyLarge = CGPoint(x: 60, y: 100)

        assertSnap(at: onlyLarge, candidates: [small, large], equals: large.screenLocalBounds)
    }

    func testAutoSelectEmptyPointYieldsNoRectangle() {
        let window = candidate(id: 1, pid: 10, layer: 0, rect: CGRect(x: 100, y: 80, width: 400, height: 300), order: 0)
        let nearbyPopover = candidate(id: 2, pid: 30, layer: 8, rect: CGRect(x: 80, y: 28, width: 260, height: 320), order: 1)
        let candidates = [window, nearbyPopover]

        assertSnap(at: CGPoint(x: 1200, y: 700), candidates: candidates, equals: nil)
        // Menu-bar band, horizontally over the popover, but not inside any window.
        assertSnap(at: CGPoint(x: 120, y: 8), candidates: candidates, equals: nil)

        var session = OverlayHoverSession()
        _ = session.pointerMoved(
            to: CGPoint(x: 200, y: 200),
            candidates: candidates,
            screenSize: screenFrame.size
        )
        XCTAssertEqual(session.selection, window.screenLocalBounds)

        let cleared = session.pointerMoved(
            to: CGPoint(x: 120, y: 8),
            candidates: candidates,
            screenSize: screenFrame.size
        )
        XCTAssertTrue(cleared)
        XCTAssertNil(session.selection)
    }

    func testAutoSelectExcludesNearFullscreenShield() {
        let infos = [
            windowInfo(id: 70, pid: 70, bounds: screenFrame, layer: 20, ownerName: "Stage Manager"),
            windowInfo(id: 71, pid: 448, bounds: screenFrame, layer: 20, ownerName: "Dock"),
            windowInfo(
                id: 72,
                pid: 80,
                bounds: CGRect(x: 120, y: 100, width: 500, height: 360),
                layer: 0,
                ownerName: "TextEdit"
            ),
        ]
        let result = CaptureWindowSelection.candidates(
            from: infos,
            screenFrameInGlobalTopLeftCoordinates: screenFrame,
            ownPID: 1
        )

        XCTAssertEqual(result.map(\.windowID), [72])
        assertSnap(
            at: CGPoint(x: 200, y: 180),
            candidates: result,
            equals: result[0].screenLocalBounds
        )
        // On the shield, outside the app window: nothing, not the full screen.
        assertSnap(at: CGPoint(x: 20, y: 700), candidates: result, equals: nil)
    }

    func testMenuBarStatusItemUsesSameOwnerPopoverNotAnotherOwnersPanel() {
        let icon = candidate(id: 1, pid: 30, layer: 25, rect: CGRect(x: 1240, y: 0, width: 28, height: 28), order: 0)
        // Smaller, listed first, and in front of the owner's popover.
        let otherPanel = candidate(id: 2, pid: 40, layer: 8, rect: CGRect(x: 1220, y: 22, width: 110, height: 80), order: 1)
        let ownPopover = candidate(id: 3, pid: 30, layer: 8, rect: CGRect(x: 980, y: 28, width: 360, height: 440), order: 2)
        let onIcon = CGPoint(x: 1250, y: 12)

        assertSnap(
            at: onIcon,
            candidates: [otherPanel, ownPopover, icon],
            equals: ownPopover.screenLocalBounds
        )
    }

    func testMenuBarStatusItemDoesNotUseAnotherOwnersPanel() {
        let icon = candidate(id: 1, pid: 30, layer: 25, rect: CGRect(x: 1240, y: 0, width: 28, height: 28), order: 0)
        let otherPanel = candidate(id: 2, pid: 40, layer: 8, rect: CGRect(x: 1100, y: 24, width: 280, height: 200), order: 1)

        assertSnap(
            at: CGPoint(x: 1250, y: 12),
            candidates: [otherPanel, icon],
            equals: icon.screenLocalBounds
        )
    }

    func testMenuBarBandOrdinaryWindowIsNotReplacedByNearbyPopover() {
        let window = candidate(id: 1, pid: 10, layer: 0, rect: CGRect(x: 40, y: 0, width: 500, height: 400), order: 1)
        let popover = candidate(id: 2, pid: 10, layer: 8, rect: CGRect(x: 200, y: 20, width: 300, height: 220), order: 0)
        // In the menu-bar band, inside the ordinary window, outside the popover.
        let point = CGPoint(x: 400, y: 8)

        assertSnap(at: point, candidates: [popover, window], equals: window.screenLocalBounds)
    }

    func testMaximizedFrontWindowBeatsSameOwnerPanelBehindIt() {
        let front = candidate(
            id: 1,
            pid: 10,
            layer: 0,
            rect: CGRect(x: 0, y: 25, width: 1440, height: 875),
            order: 0
        )
        let back = candidate(
            id: 2,
            pid: 10,
            layer: 0,
            rect: CGRect(x: 100, y: 20, width: 200, height: 150),
            order: 1
        )
        // Listed back-first. The point is inside both; the maximized window is in front.
        assertSnap(
            at: CGPoint(x: 150, y: 30),
            candidates: [back, front],
            equals: front.screenLocalBounds
        )
    }

    func testShortWideMenuBarIsNotExpandedToSameOwnerPopover() {
        let bar = candidate(
            id: 1,
            pid: 10,
            layer: 25,
            rect: CGRect(x: 0, y: 0, width: 1440, height: 24),
            order: 0
        )
        let popover = candidate(
            id: 2,
            pid: 10,
            layer: 8,
            rect: CGRect(x: 100, y: 20, width: 200, height: 150),
            order: 1
        )
        assertSnap(
            at: CGPoint(x: 150, y: 10),
            candidates: [popover, bar],
            equals: bar.screenLocalBounds
        )
    }

    func testBelowMenuBarStaysOnContainingWindowNotNearbyPopover() {
        let window = candidate(id: 1, pid: 10, layer: 0, rect: CGRect(x: 80, y: 50, width: 500, height: 400), order: 1)
        let popover = candidate(id: 2, pid: 10, layer: 8, rect: CGRect(x: 100, y: 28, width: 220, height: 60), order: 0)
        // y=90 is below the menu-bar band. The popover is nearby but does not contain the point.
        let point = CGPoint(x: 150, y: 90)

        assertSnap(at: point, candidates: [popover, window], equals: window.screenLocalBounds)
    }

    func testUnlockAfterDragKeepsLastHoverWhilePointerStaysOnDismissedChrome() {
        let hoverOnFront = CGPoint(x: 500, y: 500)
        let front = candidate(
            id: 1,
            pid: 10,
            layer: 0,
            rect: CGRect(x: 400, y: 420, width: 300, height: 220),
            order: 0
        )
        let dragRect = CGRect(x: 40, y: 40, width: 200, height: 120)
        let chrome = SelectionOverlayLayout.actionControlsFrame(
            selectionRect: dragRect,
            canvasSize: screenFrame.size
        )
        let onDismissedButtons = CGPoint(x: chrome.midX, y: chrome.midY)
        let underButtons = candidate(
            id: 2,
            pid: 20,
            layer: 0,
            rect: CGRect(x: 80, y: 150, width: 220, height: 120),
            order: 1
        )
        let candidates = [underButtons, front]
        XCTAssertTrue(front.screenLocalBounds.contains(hoverOnFront))
        XCTAssertFalse(front.screenLocalBounds.contains(onDismissedButtons))
        XCTAssertTrue(underButtons.screenLocalBounds.contains(onDismissedButtons))
        XCTAssertTrue(chrome.contains(onDismissedButtons))
        XCTAssertFalse(chrome.contains(CGPoint(x: underButtons.screenLocalBounds.maxX - 1, y: onDismissedButtons.y)))

        var session = OverlayHoverSession()
        XCTAssertTrue(session.pointerMoved(
            to: hoverOnFront,
            candidates: candidates,
            screenSize: screenFrame.size
        ))
        XCTAssertEqual(session.selection, front.screenLocalBounds)

        session.selection = dragRect
        session.isDragging = true
        XCTAssertFalse(session.pointerMoved(
            to: onDismissedButtons,
            candidates: candidates,
            screenSize: screenFrame.size
        ))
        XCTAssertEqual(session.selection, dragRect)
        XCTAssertEqual(session.lastHoverLocation, hoverOnFront)

        session.isDragging = false
        session.isSelectionFinalized = true
        XCTAssertFalse(session.pointerMoved(
            to: onDismissedButtons,
            candidates: candidates,
            screenSize: screenFrame.size
        ))
        XCTAssertEqual(session.selection, dragRect)

        session.unlock(
            candidates: candidates,
            screenSize: screenFrame.size,
            livePoint: onDismissedButtons,
            clickedChrome: [chrome]
        )
        XCTAssertFalse(session.isSelectionFinalized)
        XCTAssertFalse(session.isDragging)
        XCTAssertEqual(session.selection, front.screenLocalBounds)
        XCTAssertEqual(session.lastHoverLocation, hoverOnFront)

        // The hover ticker fires again while the pointer is still on X.
        XCTAssertFalse(session.pointerMoved(
            to: onDismissedButtons,
            candidates: candidates,
            screenSize: screenFrame.size
        ))
        XCTAssertEqual(session.selection, front.screenLocalBounds)
        XCTAssertEqual(session.lastHoverLocation, hoverOnFront)

        let leftTheButtons = CGPoint(x: underButtons.screenLocalBounds.maxX - 1, y: onDismissedButtons.y)
        XCTAssertTrue(session.pointerMoved(
            to: leftTheButtons,
            candidates: candidates,
            screenSize: screenFrame.size
        ))
        XCTAssertEqual(session.selection, underButtons.screenLocalBounds)
        XCTAssertTrue(session.dismissChrome.isEmpty)
    }

    func testHoverSwitchLockDragAndUnlockUseFrontmostRule() {
        let backLarge = candidate(id: 1, pid: 10, layer: 0, rect: CGRect(x: 40, y: 80, width: 700, height: 500), order: 2)
        let frontSmall = candidate(id: 2, pid: 20, layer: 0, rect: CGRect(x: 80, y: 120, width: 160, height: 100), order: 0)
        let other = candidate(id: 3, pid: 30, layer: 0, rect: CGRect(x: 860, y: 80, width: 400, height: 300), order: 1)
        let candidates = [backLarge, other, frontSmall]
        let onSmall = CGPoint(x: 100, y: 150)
        let onOther = CGPoint(x: 900, y: 140)
        let onlyOnLarge = CGPoint(x: 600, y: 400)

        var session = OverlayHoverSession()
        XCTAssertNil(session.selection)

        XCTAssertTrue(session.pointerMoved(to: onSmall, candidates: candidates, screenSize: screenFrame.size))
        XCTAssertEqual(session.selection, frontSmall.screenLocalBounds)
        XCTAssertFalse(session.isSelectionFinalized)

        XCTAssertTrue(session.pointerMoved(to: onOther, candidates: candidates, screenSize: screenFrame.size))
        XCTAssertEqual(session.selection, other.screenLocalBounds)

        session.isDragging = true
        XCTAssertFalse(session.pointerMoved(to: onSmall, candidates: candidates, screenSize: screenFrame.size))
        XCTAssertEqual(session.selection, other.screenLocalBounds)
        XCTAssertEqual(session.lastHoverLocation, onOther)

        session.isDragging = false
        session.isSelectionFinalized = true
        XCTAssertFalse(session.pointerMoved(to: onlyOnLarge, candidates: candidates, screenSize: screenFrame.size))
        XCTAssertEqual(session.selection, other.screenLocalBounds)
        XCTAssertEqual(session.lastHoverLocation, onOther)

        session.unlock(candidates: candidates, screenSize: screenFrame.size)
        XCTAssertFalse(session.isSelectionFinalized)
        XCTAssertFalse(session.isDragging)
        XCTAssertEqual(session.selection, other.screenLocalBounds)

        XCTAssertTrue(session.pointerMoved(to: onSmall, candidates: candidates, screenSize: screenFrame.size))
        XCTAssertEqual(session.selection, frontSmall.screenLocalBounds)
    }

    func testNegativeDisplayOriginLocalPointConversion() {
        // Secondary display to the left of the primary (negative Cocoa X).
        let screenFrameGlobal = CGRect(x: -1920, y: 0, width: 1920, height: 1080)
        let infos = [
            windowInfo(id: 1, pid: 10, bounds: CGRect(x: -1500, y: 100, width: 400, height: 300))
        ]
        let result = CaptureWindowSelection.candidates(
            from: infos,
            screenFrameInGlobalTopLeftCoordinates: screenFrameGlobal,
            ownPID: 1
        )
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].screenLocalBounds, CGRect(x: 420, y: 100, width: 400, height: 300))
    }

    private func assertSnap(
        at point: CGPoint,
        candidates: [CaptureWindowCandidate],
        equals expected: CGRect?,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(
            CaptureWindowSelection.selectionRect(
                at: point,
                candidates: candidates,
                screenSize: screenFrame.size
            ),
            expected,
            file: file,
            line: line
        )
        var session = OverlayHoverSession()
        _ = session.pointerMoved(
            to: point,
            candidates: candidates,
            screenSize: screenFrame.size
        )
        XCTAssertEqual(session.selection, expected, file: file, line: line)
        XCTAssertFalse(session.isSelectionFinalized, file: file, line: line)
        XCTAssertEqual(session.lastHoverLocation, point, file: file, line: line)
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
        onscreen: Bool = true,
        ownerName: String? = nil
    ) -> [String: Any] {
        [
            kCGWindowNumber as String: NSNumber(value: id),
            kCGWindowOwnerPID as String: NSNumber(value: pid),
            kCGWindowOwnerName as String: ownerName ?? "App \(pid)",
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
