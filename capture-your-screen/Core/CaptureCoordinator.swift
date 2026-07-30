import Combine
import Foundation
import AppKit
import SwiftUI
import UserNotifications

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
            panelPresenter.presentedWindow?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        guard state == .idle else { return }
        lastError = nil

        guard screenshotStore.resolver.hasValidFolder else {
            lastError = StorageError.folderNotSelected
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
        state = .capturing

        let window = OverlayWindow(screen: screen)
        let overlayView = SelectionOverlayView(
            onConfirm: { [weak self] rect in
                self?.finishCapture(selectionRect: rect, screen: screen)
            },
            onQuickSave: { [weak self] rect in
                self?.quickSaveCapture(selectionRect: rect, screen: screen)
            },
            onCancel: { [weak self] in
                self?.cancelCapture()
            },
            screen: screen,
            hotkeyConfig: hotkeyManager.currentConfig
        )
        let hostingView = KeyboardAcceptingHostingView(rootView: overlayView)
        hostingView.frame = window.contentRect(forFrameRect: window.frame)
        window.contentView = hostingView
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(hostingView)
        NSApp.activate(ignoringOtherApps: true)

        self.overlayWindow = window
    }

    func cancelCapture() {
        guard case .capturing = state else { return }
        captureGeneration &+= 1
        closeOverlayWindow()
        state = .idle
    }

    // MARK: - Selection → capture

    private func finishCapture(selectionRect: CGRect, screen: NSScreen) {
        guard case .capturing = state else { return }
        closeOverlayWindow()

        let captureRect = selectionRect.integral
        performCapture(rect: captureRect, screen: screen)
    }

    private func performCapture(rect: CGRect, screen: NSScreen) {
        let generation = captureGeneration
        let displayID = screen.directDisplayID

        Task { [weak self] in
            do {
                let image = try await ScreenCapture.captureRegion(rect, displayID: displayID)
                guard let self, self.captureGeneration == generation, self.state == .capturing else { return }
                self.lastError = nil
                self.beginReview(image: image, sourceDisplayID: displayID, selectionRect: rect)
            } catch {
                guard let self, self.captureGeneration == generation else { return }
                print("CaptureCoordinator: ERROR during capture: \(error.localizedDescription)")
                self.lastError = error
                self.notifier.postNotification(
                    title: PostCaptureStrings.captureFailedNotificationTitle,
                    body: error.localizedDescription
                )
                self.state = .idle
            }
        }
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
        closeOverlayWindow()

        let generation = captureGeneration
        let displayID = screen.directDisplayID

        Task { [weak self] in
            do {
                let image = try await ScreenCapture.captureRegion(
                    selectionRect.integral,
                    displayID: displayID
                )
                guard let self, self.captureGeneration == generation else { return }
                await self.performQuickSaveCompletion(image: image)
            } catch {
                guard let self, self.captureGeneration == generation else { return }
                print("CaptureCoordinator: ERROR during quick save: \(error.localizedDescription)")
                self.lastError = error
                self.notifier.postNotification(
                    title: PostCaptureStrings.saveFailedNotificationTitle,
                    body: error.localizedDescription
                )
                self.state = .idle
            }
        }
    }

    /// Copy + save + notify, bypassing the review panel entirely.
    func performQuickSaveCompletion(image: NSImage) async {
        do {
            try clipboard.writeImage(image)
            let record = try await persistence.persistScreenshot(image)
            lastError = nil
            print("CaptureCoordinator: Quick-saved as \(record.url.path)")
            notifier.postNotification(
                title: PostCaptureStrings.savedNotificationTitle,
                body: PostCaptureStrings.savedNotificationBody(filename: record.url.lastPathComponent)
            )
        } catch {
            print("CaptureCoordinator: ERROR during quick save: \(error.localizedDescription)")
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
        print("CaptureCoordinator: Saved as \(record.url.path)")

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
        print("CaptureCoordinator: action failed: \(error)")
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
        state = .idle
    }

    // MARK: - Misc helpers

    private func activeCaptureScreen() -> NSScreen? {
        let pointerLocation = NSEvent.mouseLocation
        return NSScreen.screens.first(where: { NSMouseInRect(pointerLocation, $0.frame, false) })
            ?? NSScreen.main
            ?? NSScreen.screens.first
    }
}
