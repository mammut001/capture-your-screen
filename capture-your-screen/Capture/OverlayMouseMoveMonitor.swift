//
//  OverlayMouseMoveMonitor.swift
//  capture-your-screen
//
//  Reliable pointer tracking for the capture overlay. SwiftUI's
//  `onContinuousHover` often needs a priming click when the app is not
//  activated (we avoid NSApp.activate to keep menus alive). An NSTrackingArea
//  with `.activeAlways`, plus a global mouse-moved monitor, updates proposals
//  as soon as the pointer moves.
//

import AppKit
import SwiftUI

/// Full-view mouse-move sensor in screen-local **top-left** coordinates.
struct OverlayMouseMoveMonitor: NSViewRepresentable {
    /// When false, tracking areas/monitors stay installed but moves are ignored
    /// by the coordinator (finalized / dragging). Keeping the view alive avoids
    /// re-install lag after unlock.
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
    }

    static func dismantleNSView(_ nsView: OverlayMouseMoveNSView, coordinator: Coordinator) {
        coordinator.detach()
        nsView.coordinator = nil
    }

    final class Coordinator {
        var onMove: (CGPoint) -> Void
        var screen: NSScreen
        var isEnabled: Bool
        private weak var view: OverlayMouseMoveNSView?
        private var globalMonitor: Any?
        private var localMonitor: Any?

        init(onMove: @escaping (CGPoint) -> Void, screen: NSScreen, isEnabled: Bool) {
            self.onMove = onMove
            self.screen = screen
            self.isEnabled = isEnabled
        }

        func attach(view: OverlayMouseMoveNSView) {
            self.view = view
            installMonitorsIfNeeded()
        }

        func detach() {
            if let globalMonitor {
                NSEvent.removeMonitor(globalMonitor)
                self.globalMonitor = nil
            }
            if let localMonitor {
                NSEvent.removeMonitor(localMonitor)
                self.localMonitor = nil
            }
            view = nil
        }

        func handleLocalMove(in view: NSView, event: NSEvent) {
            guard isEnabled else { return }
            let appKit = view.convert(event.locationInWindow, from: nil)
            // AppKit is bottom-left; overlay selection uses top-left.
            let topLeft = CGPoint(x: appKit.x, y: view.bounds.height - appKit.y)
            onMove(topLeft)
        }

        func handleScreenLocalMove() {
            guard isEnabled, view?.window != nil else { return }
            let cocoa = NSEvent.mouseLocation
            guard NSMouseInRect(cocoa, screen.frame, false) else { return }
            let topLeft = CaptureWindowSelection.screenLocalPoint(fromCocoaGlobal: cocoa, on: screen)
            onMove(topLeft)
        }

        private func installMonitorsIfNeeded() {
            if globalMonitor == nil {
                // When we skip NSApp.activate, another app stays active — global
                // mouse-moved is the reliable signal (no priming click).
                globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved]) { [weak self] _ in
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
    /// need tracking areas + event monitors for hover proposals.
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
    }
}
