import Combine
import Foundation
import AppKit
import SwiftUI
import UserNotifications
import os

private let logger = Logger(subsystem: "com.captureyourscreen.core", category: "CaptureCoordinator")

@MainActor
final class CaptureCoordinator: ObservableObject {
    /// Explicit workflow state machine.
    enum CaptureState: Equatable {
        /// Nothing in flight; hotkey starts a new capture.
        case idle
        /// Selection overlay visible or region capture in flight.
        case capturing
        /// Post-capture action panel visible; image held in memory only.
        case reviewing
        /// Annotation editor open for the active session.
        case annotating
        /// Share flow in progress for the active session.
        case sharing
        /// Persisting to clipboard/disk (Copy, annotation save, Quick Save).
        case saving
    }

    @Published private(set) var state: CaptureState = .idle
    @Published var lastError: Error?
    @Published private(set) var permissionStatus: PermissionStatus = .notDetermined

    /// The single active post-capture session (image held in memory).
    private(set) var activeSession: PostCaptureSession?
    /// True while an action (copy/share/save) is running — blocks duplicates.
    private(set) var isProcessingAction = false
    /// Latest in-flight action task; tests await this for determinism.
    private(set) var actionTask: Task<Void, Never>?
    /// Delay before the panel auto-dismisses after an inline success message.
    var successDismissDelay: TimeInterval = 0.7

    private var overlayWindow: OverlayWindow?
    /// Full-display freeze-frame captured *before* the overlay appears so
    /// transient UI (menus / popovers) survives confirm clicks.
    private var frozenCaptureImage: NSImage?
    /// Screen whose logical size matches `frozenCaptureImage`.
    private var frozenCaptureScreen: NSScreen?
    /// Current screen-local selection shared with the global key handler.
    private var currentCaptureSelection: CGRect?
    /// Front-to-back window geometry sampled with the freeze-frame.
    private var frozenWindowCandidates: [CaptureWindowCandidate] = []
    /// Monotonic token that invalidates in-flight capture tasks when a
    /// capture is cancelled or a new one starts.
    private var captureGeneration: UInt64 = 0

    private let screenshotStore: ScreenshotStore
    private let hotkeyManager: HotkeyManager
    private let clipboard: ClipboardWriting
    private let persistence: ScreenshotPersisting
    private let sharingService: ScreenshotSharing
    private let panelPresenter: PostCapturePanelPresenting
    private let annotationPresenter: AnnotationEditorPresenting
    private let notifier: UserNotifying
    let permissionManager = PermissionManager()

    init(
        screenshotStore: ScreenshotStore,
        hotkeyManager: HotkeyManager,
        clipboard: ClipboardWriting? = nil,
        persistence: ScreenshotPersisting? = nil,
        sharingService: ScreenshotSharing? = nil,
        panelPresenter: PostCapturePanelPresenting? = nil,
        annotationPresenter: AnnotationEditorPresenting? = nil,
        notifier: UserNotifying? = nil
    ) {
        self.screenshotStore = screenshotStore
        self.hotkeyManager = hotkeyManager
        self.clipboard = clipboard ?? SystemClipboardService()
        self.persistence = persistence ?? screenshotStore
        self.sharingService = sharingService ?? NativeScreenshotSharingService()
        self.panelPresenter = panelPresenter ?? PostCaptureActionPanelController()
        self.annotationPresenter = annotationPresenter ?? AnnotationEditorPresenter()
        self.notifier = notifier ?? SystemUserNotificationService()
        self.permissionStatus = permissionManager.screenRecordingStatus
    }

    /// Re-check TCC Screen Recording state (e.g. after returning from System Settings).
    @discardableResult
    func refreshPermissionStatus() -> PermissionStatus {
        let status = permissionManager.refresh()
        if permissionStatus != status {
            permissionStatus = status
        }
        return status
    }

    // MARK: - Public API

    func startCapture() {
        // A capture is already waiting for a decision — surface its panel
        // instead of silently dropping the hotkey press.
        if state == .reviewing {
            if let session = activeSession {
                if panelPresenter.isPresenting {
                    panelPresenter.presentedWindow?.makeKeyAndOrderFront(nil)
                } else {
                    presentPanel(for: session)
                }
            }
            // Do NOT activate — the panel just needs to be visible/key.
            return
        }
        guard state == .idle else { return }
        lastError = nil

        guard screenshotStore.resolver.hasValidFolder else {
            lastError = StorageError.folderNotSelected
            // Hotkey captures have no visible panel to show lastError in.
            notifier.postNotification(
                title: "Choose a Screenshot Folder",
                body: StorageError.folderNotSelected.localizedDescription
            )
            return
        }

        var status = refreshPermissionStatus()
        if status != .granted {
            _ = permissionManager.requestScreenRecordingAccess()
            status = refreshPermissionStatus()
            if status != .granted {
                permissionManager.showPermissionAlert()
                return
            }
        }

        guard let screen = activeCaptureScreen() else { return }

        captureGeneration &+= 1
        let generation = captureGeneration
        state = .capturing
        clearFrozenCapture()
        currentCaptureSelection = nil
        hotkeyManager.beginCaptureKeyInterception { [weak self] command in
            Task { @MainActor in
                self?.handleCaptureKeyCommand(command, screen: screen)
            }
        }

        // Freeze the live display *before* showing the overlay. Confirm /
        // Quick Save clicks would otherwise dismiss menus/popovers before a
        // second live capture could see them.
        // Snapshot window geometry immediately after the freeze so candidates
        // match the frozen pixels; mouse moves only hit-test that list.
        Task { [weak self] in
            do {
                let frozen = try await ScreenCapture.captureFullDisplay(displayID: screen.directDisplayID)
                guard let self, self.captureGeneration == generation, self.state == .capturing else { return }
                self.frozenWindowCandidates = CaptureWindowSelection.snapshot(on: screen)
                let localPointer = CaptureWindowSelection.screenLocalPoint(
                    fromCocoaGlobal: NSEvent.mouseLocation,
                    on: screen
                )
                self.currentCaptureSelection = CaptureWindowSelection.selectionRect(
                    at: localPointer,
                    candidates: self.frozenWindowCandidates,
                    screenSize: screen.frame.size
                )
                self.presentSelectionOverlay(screen: screen, frozenImage: frozen)
            } catch {
                guard let self, self.captureGeneration == generation else { return }
                logger.error("Freeze-frame capture failed: \(error.localizedDescription, privacy: .public)")
                self.lastError = error
                self.clearFrozenCapture()
                self.hotkeyManager.endCaptureKeyInterception()
                self.currentCaptureSelection = nil
                self.notifier.postNotification(
                    title: PostCaptureStrings.captureFailedNotificationTitle,
                    body: error.localizedDescription
                )
                self.state = .idle
            }
        }
    }

    func cancelCapture() {
        guard case .capturing = state else { return }
        captureGeneration &+= 1
        closeOverlayWindow()
        clearFrozenCapture()
        hotkeyManager.endCaptureKeyInterception()
        currentCaptureSelection = nil
        state = .idle
    }

    // MARK: - Selection overlay (on frozen frame)

    private func presentSelectionOverlay(screen: NSScreen, frozenImage: NSImage) {
        frozenCaptureImage = frozenImage
        frozenCaptureScreen = screen

        let window = OverlayWindow(screen: screen)
        let overlayView = SelectionOverlayView(
            frozenImage: frozenImage,
            initialSelection: currentCaptureSelection,
            windowCandidates: frozenWindowCandidates,
            onConfirm: { [weak self] rect in
                self?.finishCapture(selectionRect: rect, screen: screen)
            },
            onQuickSave: { [weak self] rect in
                self?.quickSaveCapture(selectionRect: rect, screen: screen)
            },
            onCancel: { [weak self] in
                self?.cancelCapture()
            },
            onSelectionChanged: { [weak self] rect in
                self?.currentCaptureSelection = rect
            },
            screen: screen,
            hotkeyConfig: hotkeyManager.currentConfig
        )
        let hostingView = NSHostingView(rootView: overlayView)
        hostingView.frame = window.contentRect(forFrameRect: window.frame)
        window.contentView = hostingView
        window.makeKeyAndOrderFront(nil)
        // Freeze-frame already preserved menus/popovers in `frozenImage`, so
        // activating is safe for the final crop. Becoming active makes local
        // mouse/key delivery reliable; hover still primarily tracks via the
        // overlay pointer poller (see OverlayMouseMoveMonitor).
        NSApp.activate(ignoringOtherApps: true)

        self.overlayWindow = window
    }

    // MARK: - Selection → crop frozen frame (no second live capture)

    private func finishCapture(selectionRect: CGRect, screen: NSScreen) {
        guard case .capturing = state else { return }
        hotkeyManager.endCaptureKeyInterception()
        currentCaptureSelection = nil
        closeOverlayWindow()

        let captureRect = selectionRect.integral
        guard let image = croppedImageFromFrozenFrame(rect: captureRect, screen: screen) else {
            logger.error("Failed to crop freeze-frame for confirm")
            lastError = ScreenCaptureError.captureFailed
            clearFrozenCapture()
            notifier.postNotification(
                title: PostCaptureStrings.captureFailedNotificationTitle,
                body: ScreenCaptureError.captureFailed.localizedDescription
            )
            state = .idle
            return
        }

        lastError = nil
        clearFrozenCapture()
        beginReview(image: image, sourceDisplayID: screen.directDisplayID, selectionRect: captureRect)
    }

    // MARK: - Review session

    /// Entry point into the post-capture workflow: retains the captured
    /// image in memory and shows the action panel. Nothing is copied or
    /// saved until the user picks an action.
    func beginReview(
        image: NSImage,
        sourceDisplayID: CGDirectDisplayID? = nil,
        selectionRect: CGRect? = nil
    ) {
        // Only one active session at a time.
        guard activeSession == nil else { return }

        let session = PostCaptureSession(
            originalImage: image,
            sourceDisplayID: sourceDisplayID,
            selectionRect: selectionRect
        )
        activeSession = session
        isProcessingAction = false
        state = .reviewing
        presentPanel(for: session)
    }

    private func presentPanel(for session: PostCaptureSession) {
        let id = session.id
        panelPresenter.present(
            session: session,
            handlers: PostCaptureActionHandlers(
                onCopy: { [weak self] in self?.handleCopy(sessionID: id) },
                onAnnotate: { [weak self] in self?.handleAnnotate(sessionID: id) },
                onShare: { [weak self] in self?.handleShare(sessionID: id) },
                onCancel: { [weak self] in self?.handleCancel(sessionID: id) }
            )
        )
    }

    // MARK: - Panel actions

    func handleCopy(sessionID: UUID) {
        guard let session = activeSession, session.id == sessionID,
              state == .reviewing, !isProcessingAction else { return }
        isProcessingAction = true
        state = .saving
        panelPresenter.showStatus(.processing(PostCaptureStrings.savingStatus))

        actionTask = Task { [weak self] in
            await self?.completeSession(
                id: sessionID,
                image: session.originalImage,
                copyToClipboard: true,
                feedback: .panelStatus(PostCaptureStrings.copiedAndSaved)
            )
        }
    }

    func handleAnnotate(sessionID: UUID) {
        guard let session = activeSession, session.id == sessionID,
              state == .reviewing, !isProcessingAction else { return }
        panelPresenter.dismiss()
        state = .annotating
        presentAnnotationEditor(for: session)
    }

    func handleShare(sessionID: UUID) {
        guard let session = activeSession, session.id == sessionID,
              state == .reviewing, !isProcessingAction else { return }
        isProcessingAction = true
        state = .sharing

        guard sharingService.isAvailable else {
            failAction(
                sessionID: sessionID,
                message: PostCaptureStrings.sharingUnavailable,
                error: ScreenshotSharingError.unavailable
            )
            return
        }

        panelPresenter.showStatus(.processing(PostCaptureStrings.preparingShareStatus))
        actionTask = Task { [weak self] in
            await self?.performShare(session: session)
        }
    }

    func handleCancel(sessionID: UUID) {
        guard let session = activeSession, session.id == sessionID,
              !isProcessingAction else { return }
        _ = session
        cancelActiveSession()
    }

    /// Discards the active session and all workflow windows. Terminal.
    func cancelActiveSession() {
        panelPresenter.dismiss()
        annotationPresenter.dismiss()
        clearSessionToIdle()
    }

    // MARK: - Annotation flow

    private func presentAnnotationEditor(for session: PostCaptureSession) {
        let id = session.id
        annotationPresenter.present(
            image: session.originalImage,
            handlers: AnnotationEditorHandlers(
                onSave: { [weak self] annotated in
                    self?.handleAnnotationSave(sessionID: id, annotatedImage: annotated)
                },
                onSkip: { [weak self] in
                    self?.handleAnnotationSkip(sessionID: id)
                },
                onCancel: { [weak self] in
                    self?.handleAnnotationCancel(sessionID: id)
                }
            )
        )
    }

    func handleAnnotationSave(sessionID: UUID, annotatedImage: NSImage) {
        guard let session = activeSession, session.id == sessionID,
              state == .annotating, !isProcessingAction else { return }
        _ = session
        isProcessingAction = true
        state = .saving
        annotationPresenter.dismiss()

        actionTask = Task { [weak self] in
            await self?.completeSession(
                id: sessionID,
                image: annotatedImage,
                copyToClipboard: true,
                feedback: .notification(title: PostCaptureStrings.savedNotificationTitle)
            )
        }
    }

    func handleAnnotationSkip(sessionID: UUID) {
        guard let session = activeSession, session.id == sessionID,
              state == .annotating, !isProcessingAction else { return }
        isProcessingAction = true
        state = .saving
        annotationPresenter.dismiss()

        actionTask = Task { [weak self] in
            await self?.completeSession(
                id: sessionID,
                image: session.originalImage,
                copyToClipboard: true,
                feedback: .notification(title: PostCaptureStrings.savedNotificationTitle)
            )
        }
    }

    /// Cancelling annotation returns to the action panel with the original
    /// image; the screenshot is NOT discarded.
    func handleAnnotationCancel(sessionID: UUID) {
        guard let session = activeSession, session.id == sessionID,
              state == .annotating, !isProcessingAction else { return }
        annotationPresenter.dismiss()
        isProcessingAction = false
        state = .reviewing
        presentPanel(for: session)
    }

    // MARK: - Share flow

    private func performShare(session: PostCaptureSession) async {
        do {
            try await sharingService.share(
                image: session.originalImage,
                from: panelPresenter.presentedWindow
            )
        } catch ScreenshotSharingError.cancelled {
            // User backed out of the share picker — return to reviewing.
            guard activeSession?.id == session.id else { return }
            isProcessingAction = false
            state = .reviewing
            panelPresenter.showStatus(.ready)
            return
        } catch {
            failAction(
                sessionID: session.id,
                message: PostCaptureStrings.shareFailed,
                error: error
            )
            return
        }

        guard activeSession?.id == session.id else { return }
        // Share flow started successfully — persist exactly once, then finish.
        await completeSession(
            id: session.id,
            image: session.originalImage,
            copyToClipboard: false,
            feedback: .panelStatus(PostCaptureStrings.sharedAndSaved)
        )
    }

    // MARK: - Quick Save (power-user bypass; never shows the panel)

    private func quickSaveCapture(selectionRect: CGRect, screen: NSScreen) {
        guard case .capturing = state else { return }
        state = .saving
        hotkeyManager.endCaptureKeyInterception()
        currentCaptureSelection = nil
        closeOverlayWindow()

        let captureRect = selectionRect.integral
        guard let image = croppedImageFromFrozenFrame(rect: captureRect, screen: screen) else {
            logger.error("Failed to crop freeze-frame for quick save")
            lastError = ScreenCaptureError.captureFailed
            clearFrozenCapture()
            notifier.postNotification(
                title: PostCaptureStrings.saveFailedNotificationTitle,
                body: ScreenCaptureError.captureFailed.localizedDescription
            )
            state = .idle
            return
        }

        clearFrozenCapture()
        actionTask = Task { [weak self] in
            await self?.performQuickSaveCompletion(image: image)
        }
    }

    /// Crops the pre-captured freeze-frame. Never performs a second live capture.
    private func croppedImageFromFrozenFrame(rect: CGRect, screen: NSScreen) -> NSImage? {
        guard let frozen = frozenCaptureImage else { return nil }
        let logicalSize = (frozenCaptureScreen ?? screen).frame.size
        return ScreenshotCropping.crop(
            image: frozen,
            toScreenLocalRect: rect,
            logicalScreenSize: logicalSize
        )
    }

    private func clearFrozenCapture() {
        frozenCaptureImage = nil
        frozenCaptureScreen = nil
        frozenWindowCandidates = []
    }

    /// Copy + save + notify, bypassing the review panel entirely.
    func performQuickSaveCompletion(image: NSImage) async {
        do {
            try clipboard.writeImage(image)
            let record = try await persistence.persistScreenshot(image)
            lastError = nil
            logger.info("Quick-saved screenshot to \(record.url.path, privacy: .public)")
            notifier.postNotification(
                title: PostCaptureStrings.savedNotificationTitle,
                body: PostCaptureStrings.savedNotificationBody(filename: record.url.lastPathComponent)
            )
        } catch {
            logger.error("Quick save failed: \(error.localizedDescription, privacy: .public)")
            lastError = error
            notifier.postNotification(
                title: PostCaptureStrings.saveFailedNotificationTitle,
                body: error.localizedDescription
            )
        }
        state = .idle
    }

    // MARK: - Centralized completion

    private enum SessionCompletionFeedback {
        /// Show an inline success status in the panel, then dismiss it.
        case panelStatus(String)
        /// Panel/editor already closed — post a user notification instead.
        case notification(title: String)
    }

    /// Single terminal path for Copy / Annotate-Save / Skip / Share.
    /// Session-ID guarded so stale callbacks can never double-save or
    /// finish a newer session.
    private func completeSession(
        id: UUID,
        image: NSImage,
        copyToClipboard: Bool,
        feedback: SessionCompletionFeedback
    ) async {
        guard activeSession?.id == id else { return }

        if copyToClipboard {
            do {
                try clipboard.writeImage(image)
            } catch {
                failAction(
                    sessionID: id,
                    message: PostCaptureStrings.copyFailed,
                    error: error
                )
                return
            }
        }

        let record: ScreenshotRecord
        do {
            record = try await persistence.persistScreenshot(image)
        } catch {
            let message = copyToClipboard
                ? PostCaptureStrings.copiedButSaveFailed
                : PostCaptureStrings.saveFailed
            failAction(sessionID: id, message: message, error: error)
            return
        }

        guard activeSession?.id == id else { return }
        logger.info("Saved screenshot to \(record.url.path, privacy: .public)")

        switch feedback {
        case .notification(let title):
            notifier.postNotification(
                title: title,
                body: PostCaptureStrings.savedNotificationBody(filename: record.url.lastPathComponent)
            )
            clearSessionToIdle()

        case .panelStatus(let status):
            panelPresenter.showStatus(.success(status))
            if successDismissDelay > 0, panelPresenter.isPresenting {
                try? await Task.sleep(nanoseconds: UInt64(successDismissDelay * 1_000_000_000))
                guard activeSession?.id == id else { return }
            }
            panelPresenter.dismiss()
            clearSessionToIdle()
        }
    }

    /// Non-terminal failure: keep the session alive so the user can retry
    /// or cancel, and surface the error in the panel (re-presenting it if
    /// it was closed, e.g. after an annotation save failure).
    private func failAction(sessionID: UUID, message: String, error: Error) {
        guard let session = activeSession, session.id == sessionID else { return }
        logger.error("Action failed: \(error.localizedDescription, privacy: .public)")
        lastError = error
        isProcessingAction = false
        state = .reviewing
        if !panelPresenter.isPresenting {
            presentPanel(for: session)
        }
        panelPresenter.showStatus(.failure(message))
    }

    // MARK: - Lifecycle helpers

    private func closeOverlayWindow() {
        overlayWindow?.close()
        overlayWindow = nil
    }

    private func clearSessionToIdle() {
        activeSession = nil
        isProcessingAction = false
        clearFrozenCapture()
        hotkeyManager.endCaptureKeyInterception()
        currentCaptureSelection = nil
        state = .idle
    }

    // MARK: - Misc helpers

    private func activeCaptureScreen() -> NSScreen? {
        let pointerLocation = NSEvent.mouseLocation
        return NSScreen.screens.first(where: { NSMouseInRect(pointerLocation, $0.frame, false) })
            ?? NSScreen.main
            ?? NSScreen.screens.first
    }

    private func handleCaptureKeyCommand(_ command: CaptureKeyCommand, screen: NSScreen) {
        guard state == .capturing else { return }
        switch command {
        case .cancel:
            cancelCapture()
        case .confirm:
            guard let rect = validCaptureSelection else {
                cancelCapture()
                return
            }
            finishCapture(selectionRect: rect, screen: screen)
        case .quickSave:
            guard let rect = validCaptureSelection else { return }
            quickSaveCapture(selectionRect: rect, screen: screen)
        }
    }

    private var validCaptureSelection: CGRect? {
        guard let rect = currentCaptureSelection,
              rect.width >= 10,
              rect.height >= 10 else { return nil }
        return rect
    }

}
