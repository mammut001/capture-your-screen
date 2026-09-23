import AppKit
import CoreGraphics

/// Immutable window geometry captured before the overlay can dismiss menus.
struct CaptureWindowCandidate: Equatable {
    let windowID: CGWindowID
    let ownerPID: pid_t
    let ownerName: String
    let layer: Int
    let screenLocalBounds: CGRect
    let frontToBackOrder: Int
}

enum CaptureWindowSelection {
    private static let minimumSize: CGFloat = 10

    /// System processes that publish shield / wallpaper windows which sit above
    /// real app windows in CGWindowList order and would otherwise steal every
    /// hover hit (especially Dock's full-screen layer-20 window).
    private static let excludedOwnerNames: Set<String> = [
        "Dock",
        "Window Server",
        "Wallpaper",
        "Backstop",
    ]

    /// Snapshot every useful window on the target screen. The returned order is
    /// the CGWindowList front-to-back order and must remain stable while frozen.
    static func snapshot(on screen: NSScreen, ownPID: pid_t = ProcessInfo.processInfo.processIdentifier) -> [CaptureWindowCandidate] {
        guard let infoList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else { return [] }

        return candidates(
            from: infoList,
            screenFrameInGlobalTopLeftCoordinates: globalTopLeftFrame(for: screen),
            ownPID: ownPID
        )
    }

    static func candidates(
        from infoList: [[String: Any]],
        screenFrameInGlobalTopLeftCoordinates screenFrame: CGRect,
        ownPID: pid_t
    ) -> [CaptureWindowCandidate] {
        infoList.enumerated().compactMap { order, info in
            let pid = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value ?? 0
            guard pid != 0, pid != ownPID else { return nil }

            let ownerName = info[kCGWindowOwnerName as String] as? String ?? ""
            guard !excludedOwnerNames.contains(ownerName) else { return nil }

            let alpha = (info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1
            guard alpha > 0.05 else { return nil }

            let isOnscreen = (info[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue ?? true
            guard isOnscreen else { return nil }

            guard let dictionary = info[kCGWindowBounds as String] as? [String: Any],
                  let globalBounds = CGRect(dictionaryRepresentation: dictionary as CFDictionary),
                  globalBounds.width >= minimumSize,
                  globalBounds.height >= minimumSize else { return nil }

            let clipped = globalBounds.intersection(screenFrame)
            guard !clipped.isNull,
                  clipped.width >= minimumSize,
                  clipped.height >= minimumSize else { return nil }

            let local = CGRect(
                x: clipped.minX - screenFrame.minX,
                y: clipped.minY - screenFrame.minY,
                width: clipped.width,
                height: clipped.height
            ).integral

            let layer = (info[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0
            // Drop remaining near-fullscreen shields (e.g. some Stage Manager /
            // mission-control backdrops) that are not normal app windows.
            if isNearFullscreenShield(local, screenSize: screenFrame.size, layer: layer) {
                return nil
            }

            return CaptureWindowCandidate(
                windowID: (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value ?? 0,
                ownerPID: pid,
                ownerName: ownerName,
                layer: layer,
                screenLocalBounds: local,
                frontToBackOrder: order
            )
        }
    }

    /// True for non-standard-layer windows that cover essentially the whole
    /// screen — these steal hover from every real window underneath.
    private static func isNearFullscreenShield(
        _ rect: CGRect,
        screenSize: CGSize,
        layer: Int
    ) -> Bool {
        guard layer != 0 else { return false }
        let coversWidth = rect.width >= screenSize.width * 0.95
        let coversHeight = rect.height >= screenSize.height * 0.95
        return coversWidth && coversHeight
    }

    /// Rectangle for a pointer: the frontmost window that contains the point.
    /// Area is not a tie-break — a smaller window in front beats a larger one
    /// behind it, and a larger window in front beats a smaller one behind it.
    /// Empty space returns nil. The only expansion past strict containment is a
    /// menu-bar status item, which selects that same owner's nearby open popover.
    static func selectionRect(
        at point: CGPoint,
        candidates: [CaptureWindowCandidate],
        screenSize: CGSize
    ) -> CGRect? {
        let hit = frontmostCandidate(among: candidates, containing: point)

        if point.y <= 44,
           let hit,
           isMenuBarStatusItem(hit.screenLocalBounds),
           let popover = sameOwnerMenuBarPopover(
               near: point,
               ownerPID: hit.ownerPID,
               candidates: candidates,
               screenSize: screenSize
           ) {
            return popover.screenLocalBounds
        }

        return hit?.screenLocalBounds
    }

    /// Lowest `frontToBackOrder` wins. Callers may pass the list in any order.
    private static func frontmostCandidate(
        among candidates: [CaptureWindowCandidate],
        containing point: CGPoint
    ) -> CaptureWindowCandidate? {
        candidates
            .filter { $0.screenLocalBounds.contains(point) }
            .min { $0.frontToBackOrder < $1.frontToBackOrder }
    }

    /// Nearby open panel belonging to the status item under the pointer.
    /// A different owner's panel is never a substitute.
    private static func sameOwnerMenuBarPopover(
        near point: CGPoint,
        ownerPID: pid_t,
        candidates: [CaptureWindowCandidate],
        screenSize: CGSize
    ) -> CaptureWindowCandidate? {
        candidates
            .filter { candidate in
                guard candidate.ownerPID == ownerPID else { return false }
                let rect = candidate.screenLocalBounds
                return rect.width >= 100
                    && rect.height >= 60
                    && rect.width < screenSize.width * 0.9
                    && rect.minY <= 180
                    && horizontalDistance(from: point.x, to: rect) <= 48
            }
            .min { $0.frontToBackOrder < $1.frontToBackOrder }
    }

    static func screenLocalPoint(fromCocoaGlobal point: CGPoint, on screen: NSScreen) -> CGPoint {
        CGPoint(x: point.x - screen.frame.minX, y: screen.frame.maxY - point.y)
    }

    static func globalTopLeftFrame(for screen: NSScreen) -> CGRect {
        let mainDisplayScreen = NSScreen.screens.first { $0.directDisplayID == CGMainDisplayID() }
        let primaryMaxY = mainDisplayScreen?.frame.maxY ?? NSScreen.screens.first?.frame.maxY ?? screen.frame.maxY
        return CGRect(
            x: screen.frame.minX,
            y: primaryMaxY - screen.frame.maxY,
            width: screen.frame.width,
            height: screen.frame.height
        )
    }

    /// Menu-bar status icons are small. A short full-width bar, or a maximized
    /// window whose top sits at `minY <= 44`, is a normal hit — do not expand
    /// it into a same-owner panel behind it.
    private static func isMenuBarStatusItem(_ rect: CGRect) -> Bool {
        rect.minY <= 44 && rect.width <= 80 && rect.height <= 44
    }

    private static func horizontalDistance(from x: CGFloat, to rect: CGRect) -> CGFloat {
        if rect.minX...rect.maxX ~= x { return 0 }
        return min(abs(x - rect.minX), abs(x - rect.maxX))
    }
}

/// Layout helpers shared by the overlay and hit-testing (keep UI chrome out of
/// window auto-select).
enum SelectionOverlayLayout {
    /// Approximate frame of the X / Quick Save / Confirm control cluster.
    /// Coordinates match `SelectionOverlayView.actionButtons` positioning.
    static func actionControlsFrame(
        selectionRect rect: CGRect,
        canvasSize: CGSize
    ) -> CGRect {
        let barWidth: CGFloat = 220
        let barHeight: CGFloat = 40
        let centerX = min(max(rect.midX, 100), max(100, canvasSize.width - 100))
        let centerY = rect.maxY + 50 <= canvasSize.height
            ? rect.maxY + 30
            : max(24, rect.minY - 30)
        // Slightly padded so cursor can approach the buttons without snapping
        // the highlight to whatever window sits underneath the chrome.
        return CGRect(
            x: centerX - barWidth / 2,
            y: centerY - barHeight / 2,
            width: barWidth,
            height: barHeight
        ).insetBy(dx: -10, dy: -10)
    }
}

/// Mutable hover/lock state for the selection overlay.
/// Pointer moves update the proposal **without** requiring a priming click;
/// lock / drag gates suppress hover until unlock.
struct OverlayHoverSession: Equatable {
    var selection: CGRect?
    var lastHoverLocation: CGPoint?
    var isSelectionFinalized: Bool = false
    var isDragging: Bool = false
    /// Action cluster of a rect just dismissed with X. Moves inside it keep the
    /// last-hover selection until the pointer leaves, including the hover ticker
    /// that follows the click.
    var dismissChrome: [CGRect] = []

    /// Apply a pointer move in screen-local top-left coordinates.
    /// Returns `true` when `selection` changed.
    ///
    /// Points inside `protectedRects` or `dismissChrome` keep the current
    /// selection and do not overwrite `lastHoverLocation`.
    @discardableResult
    mutating func pointerMoved(
        to point: CGPoint,
        candidates: [CaptureWindowCandidate],
        screenSize: CGSize,
        protectedRects: [CGRect] = []
    ) -> Bool {
        guard !isSelectionFinalized, !isDragging else { return false }
        let onDismissedChrome = dismissChrome.contains { $0.contains(point) }
        if !dismissChrome.isEmpty, !onDismissedChrome {
            dismissChrome = []
        }
        if onDismissedChrome || protectedRects.contains(where: { $0.contains(point) }) {
            return false
        }
        lastHoverLocation = point
        let next = CaptureWindowSelection.selectionRect(
            at: point,
            candidates: candidates,
            screenSize: screenSize
        )
        guard next != selection else { return false }
        selection = next
        return true
    }

    /// Unlock after the user presses X. The selection becomes the frontmost
    /// window at `lastHoverLocation`. A live pointer still inside `clickedChrome`
    /// (the buttons of the rect being dismissed) does not replace that result.
    mutating func unlock(
        candidates: [CaptureWindowCandidate],
        screenSize: CGSize,
        livePoint: CGPoint? = nil,
        clickedChrome: [CGRect] = []
    ) {
        isSelectionFinalized = false
        isDragging = false
        dismissChrome = clickedChrome
        if let lastHoverLocation {
            selection = CaptureWindowSelection.selectionRect(
                at: lastHoverLocation,
                candidates: candidates,
                screenSize: screenSize
            )
        }
        if let livePoint {
            pointerMoved(
                to: livePoint,
                candidates: candidates,
                screenSize: screenSize
            )
        }
    }
}
