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

            return CaptureWindowCandidate(
                windowID: (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value ?? 0,
                ownerPID: pid,
                ownerName: info[kCGWindowOwnerName as String] as? String ?? "",
                layer: (info[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0,
                screenLocalBounds: local,
                frontToBackOrder: order
            )
        }
    }

    /// Find the frozen candidate a pointer should snap to. Direct containment
    /// follows z-order. When the pointer remains on a menu-bar icon, prefer the
    /// open, nearby popover instead of the tiny status-item window.
    static func selectionRect(
        at point: CGPoint,
        candidates: [CaptureWindowCandidate],
        screenSize: CGSize
    ) -> CGRect? {
        let direct = candidates.first { $0.screenLocalBounds.contains(point) }

        if point.y <= 44 {
            if let direct,
               !isMenuBarChrome(direct.screenLocalBounds, screenSize: screenSize) {
                return direct.screenLocalBounds
            }

            let preferredOwner = direct?.ownerPID
            let anchored = candidates.first { candidate in
                let rect = candidate.screenLocalBounds
                guard rect.width >= 100,
                      rect.height >= 60,
                      rect.width < screenSize.width * 0.9,
                      rect.minY <= 180,
                      horizontalDistance(from: point.x, to: rect) <= 48 else { return false }
                return preferredOwner == nil || candidate.ownerPID == preferredOwner
            }
            if let anchored { return anchored.screenLocalBounds }

            // Some system status items and their panels use different owner
            // processes. Fall back to the nearest frontmost anchored panel.
            if let nearby = candidates.first(where: { candidate in
                let rect = candidate.screenLocalBounds
                return rect.width >= 100 && rect.height >= 60 && rect.minY <= 180
                    && rect.width < screenSize.width * 0.9
                    && horizontalDistance(from: point.x, to: rect) <= 48
            }) {
                return nearby.screenLocalBounds
            }
        }

        return direct?.screenLocalBounds
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

    private static func isMenuBarChrome(_ rect: CGRect, screenSize: CGSize) -> Bool {
        rect.height <= 50 || (rect.width >= screenSize.width * 0.9 && rect.minY <= 44)
    }

    private static func horizontalDistance(from x: CGFloat, to rect: CGRect) -> CGFloat {
        if rect.minX...rect.maxX ~= x { return 0 }
        return min(abs(x - rect.minX), abs(x - rect.maxX))
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

    /// Apply a pointer move in screen-local top-left coordinates.
    /// Returns `true` when `selection` changed.
    @discardableResult
    mutating func pointerMoved(
        to point: CGPoint,
        candidates: [CaptureWindowCandidate],
        screenSize: CGSize
    ) -> Bool {
        guard !isSelectionFinalized, !isDragging else { return false }
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

    /// Unlock after the user presses X — resume hover from the last known point.
    mutating func unlock(
        candidates: [CaptureWindowCandidate],
        screenSize: CGSize
    ) {
        isSelectionFinalized = false
        isDragging = false
        if let lastHoverLocation {
            selection = CaptureWindowSelection.selectionRect(
                at: lastHoverLocation,
                candidates: candidates,
                screenSize: screenSize
            )
        }
    }
}
