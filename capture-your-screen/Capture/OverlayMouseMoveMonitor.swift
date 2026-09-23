//
//  OverlayMouseMoveMonitor.swift
//  capture-your-screen
//
//  Pointer tracking for the capture overlay.
//
//  We intentionally do NOT rely on NSApp.activate while the overlay is up
//  (historically to keep live menus; now freeze-frame covers that, but other
//  apps may still be "active"). In that state:
//    • local NSEvent monitors often see nothing
//    • global monitors miss events delivered to *our* overlay window
//    • SwiftUI/NSTrackingArea mouseMoved is unreliable under NSHostingView
//
//  So the source of truth is a short display-link-style poll of
//  `NSEvent.mouseLocation` — same approach many macOS region-capture tools use.
//  Event monitors remain as a low-latency supplement when they do fire.
//

import AppKit
import SwiftUI

/// Full-view mouse-move sensor in screen-local **top-left** coordinates.
struct OverlayMouseMoveMonitor: NSViewRepresentable {
    /// When false, tracking stays installed but moves are ignored
    /// (finalized / dragging). Keeping the view alive avoids re-install lag
    /// after unlock.
    var isEnabled: Bool
    var screen: NSScreen
    var onMove: (CGPoint) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onMove: onMove, screen: screen, isEnabled: isEnabled)
    }

    func makeNSView(context: Context) -> OverlayMouseMoveNSView {
        let view = OverlayMouseMoveNSView()
        view.coordinator = context.coordinator
        context.coordinator.attach(view: view)
        return view
    }

    func updateNSView(_ nsView: OverlayMouseMoveNSView, context: Context) {
        context.coordinator.onMove = onMove
        context.coordinator.screen = screen
        context.coordinator.isEnabled = isEnabled
        nsView.coordinator = context.coordinator
        nsView.updateTrackingAreas()
        // Re-emit immediately when re-enabled (e.g. after unlock) so the
        // proposal matches the live cursor without waiting for a move.
        if isEnabled {
            context.coordinator.emitCurrentPointerIfNeeded(force: true)
        }
    }

    static func dismantleNSView(_ nsView: OverlayMouseMoveNSView, coordinator: Coordinator) {
        coordinator.detach()
        nsView.coordinator = nil
    }

    final class Coordinator {
        var onMove: (CGPoint) -> Void
        var screen: NSScreen
        var isEnabled: Bool {
            didSet {
                if isEnabled {
                    startPolling()
                    emitCurrentPointerIfNeeded(force: true)
                }
            }
        }

        private weak var view: OverlayMouseMoveNSView?
        private var globalMonitor: Any?
        private var localMonitor: Any?
        private var pollTimer: Timer?
        private var lastEmittedPoint: CGPoint?

        init(onMove: @escaping (CGPoint) -> Void, screen: NSScreen, isEnabled: Bool) {
            self.onMove = onMove
            self.screen = screen
            self.isEnabled = isEnabled
        }

        func attach(view: OverlayMouseMoveNSView) {
            self.view = view
            installMonitorsIfNeeded()
            startPolling()
            emitCurrentPointerIfNeeded(force: true)
        }

        func detach() {
            stopPolling()
            if let globalMonitor {
                NSEvent.removeMonitor(globalMonitor)
                self.globalMonitor = nil
            }
            if let localMonitor {
                NSEvent.removeMonitor(localMonitor)
                self.localMonitor = nil
            }
            view = nil
            lastEmittedPoint = nil
        }

        func handleLocalMove(in view: NSView, event: NSEvent) {
            guard isEnabled else { return }
            let appKit = view.convert(event.locationInWindow, from: nil)
            // AppKit is bottom-left; overlay selection uses top-left.
            let topLeft = CGPoint(x: appKit.x, y: view.bounds.height - appKit.y)
            emit(topLeft)
        }

        func handleScreenLocalMove() {
            emitCurrentPointerIfNeeded(force: false)
        }

        func emitCurrentPointerIfNeeded(force: Bool) {
            // Do not require `view.window` — under SwiftUI the representable can
            // briefly lack a window while the overlay is already interactive;
            // SelectionOverlayView's HoverTicker is the primary driver anyway.
            guard isEnabled else { return }
            let cocoa = NSEvent.mouseLocation
            guard NSMouseInRect(cocoa, screen.frame, false) else { return }
            let topLeft = CaptureWindowSelection.screenLocalPoint(fromCocoaGlobal: cocoa, on: screen)
            if !force, let last = lastEmittedPoint,
               abs(last.x - topLeft.x) < 0.5, abs(last.y - topLeft.y) < 0.5 {
                return
            }
            emit(topLeft)
        }

        private func emit(_ topLeft: CGPoint) {
            lastEmittedPoint = topLeft
            onMove(topLeft)
        }

        private func startPolling() {
            guard pollTimer == nil else { return }
            // ~60 Hz is enough for WeChat-like continuous snap; cheap hit-test only.
            let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
                self?.emitCurrentPointerIfNeeded(force: false)
            }
            timer.tolerance = 1.0 / 120.0
            RunLoop.main.add(timer, forMode: .common)
            pollTimer = timer
        }

        private func stopPolling() {
            pollTimer?.invalidate()
            pollTimer = nil
        }

        private func installMonitorsIfNeeded() {
            if globalMonitor == nil {
                globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved]) { [weak self] _ in
                    // May be nil when events land on our own overlay; polling covers that.
                    DispatchQueue.main.async {
                        self?.handleScreenLocalMove()
                    }
                }
            }
            if localMonitor == nil {
                localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved]) { [weak self] event in
                    DispatchQueue.main.async {
                        self?.handleScreenLocalMove()
                    }
                    return event
                }
            }
        }
    }
}

final class OverlayMouseMoveNSView: NSView {
    weak var coordinator: OverlayMouseMoveMonitor.Coordinator?

    override var isFlipped: Bool { false }

    /// Let drag/click gestures on the SwiftUI canvas win hit-testing; we only
    /// need tracking areas + polling for hover proposals.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas {
            removeTrackingArea(area)
        }
        let options: NSTrackingArea.Options = [
            .activeAlways,
            .mouseMoved,
            .mouseEnteredAndExited,
            .inVisibleRect,
            .enabledDuringMouseDrag
        ]
        addTrackingArea(NSTrackingArea(rect: .zero, options: options, owner: self, userInfo: nil))
    }

    override func mouseMoved(with event: NSEvent) {
        coordinator?.handleLocalMove(in: self, event: event)
    }

    override func mouseEntered(with event: NSEvent) {
        coordinator?.handleLocalMove(in: self, event: event)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.acceptsMouseMovedEvents = true
        updateTrackingAreas()
        coordinator?.emitCurrentPointerIfNeeded(force: true)
    }
}
