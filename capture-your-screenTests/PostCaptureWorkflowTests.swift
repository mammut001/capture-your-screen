//
//  PostCaptureWorkflowTests.swift
//  capture-your-screenTests
//
//  State and action-routing tests for the post-capture workflow.
//  All AppKit windows are replaced by lightweight spy presenters.
//

import XCTest
import AppKit
@testable import capture_your_screen

// MARK: - Test doubles

@MainActor
private final class MockClipboard: ClipboardWriting {
    var writeCount = 0
    var attemptCount = 0
    var errorToThrow: Error?
    var lastImage: NSImage?

    func writeImage(_ image: NSImage) throws {
        attemptCount += 1
        if let errorToThrow { throw errorToThrow }
        writeCount += 1
        lastImage = image
    }
}

@MainActor
private final class MockPersistence: ScreenshotPersisting {
    var saveCount = 0
    var attemptCount = 0
    var errorToThrow: Error?
    var lastImage: NSImage?

    func persistScreenshot(_ image: NSImage) async throws -> ScreenshotRecord {
        attemptCount += 1
        if let errorToThrow { throw errorToThrow }
        saveCount += 1
        lastImage = image
        return ScreenshotRecord(
            url: URL(fileURLWithPath: "/tmp/post-capture-tests/Screenshot_mock_\(saveCount).png"),
            date: Date()
        )
    }
}

@MainActor
private final class SpyPanelPresenter: PostCapturePanelPresenting {
    var presentCount = 0
    var dismissCount = 0
    var statuses: [PostCapturePanelStatus] = []
    var handlers: PostCaptureActionHandlers?
    private(set) var presenting = false

    var isPresenting: Bool { presenting }
    var presentedWindow: NSWindow? { nil }

    func present(session: PostCaptureSession, handlers: PostCaptureActionHandlers) {
        presentCount += 1
        presenting = true
        self.handlers = handlers
    }

    func showStatus(_ status: PostCapturePanelStatus) {
        statuses.append(status)
    }

    func dismiss() {
        if presenting { dismissCount += 1 }
        presenting = false
    }
}

@MainActor
private final class SpyAnnotationPresenter: AnnotationEditorPresenting {
    var presentCount = 0
    var dismissCount = 0
    var handlers: AnnotationEditorHandlers?
    var lastImage: NSImage?
    private(set) var presenting = false

    func present(image: NSImage, handlers: AnnotationEditorHandlers) {
        presentCount += 1
        presenting = true
        lastImage = image
        self.handlers = handlers
    }

    func dismiss() {
        if presenting { dismissCount += 1 }
        presenting = false
    }
}

@MainActor
private final class MockSharingService: ScreenshotSharing {
    var available = true
    var errorToThrow: Error?
    var shareCount = 0
    var lastImage: NSImage?

    var isAvailable: Bool { available }

    func share(image: NSImage, from sourceWindow: NSWindow?) async throws {
        if let errorToThrow { throw errorToThrow }
        shareCount += 1
        lastImage = image
    }
}

@MainActor
private final class SpyNotifier: UserNotifying {
    var notifications: [(title: String, body: String)] = []
    func postNotification(title: String, body: String) {
        notifications.append((title, body))
    }
}

private struct DummyError: Error {}

// MARK: - Tests

@MainActor
final class PostCaptureWorkflowTests: XCTestCase {

    private var clipboard: MockClipboard!
    private var persistence: MockPersistence!
    private var panel: SpyPanelPresenter!
    private var annotation: SpyAnnotationPresenter!
    private var sharing: MockSharingService!
    private var notifier: SpyNotifier!
    private var coordinator: CaptureCoordinator!

    override func setUp() async throws {
        try await super.setUp()
        clipboard = MockClipboard()
        persistence = MockPersistence()
        panel = SpyPanelPresenter()
        annotation = SpyAnnotationPresenter()
        sharing = MockSharingService()
        notifier = SpyNotifier()
        coordinator = CaptureCoordinator(
            screenshotStore: ScreenshotStore(),
            hotkeyManager: HotkeyManager(),
            clipboard: clipboard,
            persistence: persistence,
            sharingService: sharing,
            panelPresenter: panel,
            annotationPresenter: annotation,
            notifier: notifier
        )
        coordinator.successDismissDelay = 0
    }

    override func tearDown() async throws {
        coordinator = nil
        try await super.tearDown()
    }

    // MARK: Helpers

    private func makeImage(width: CGFloat = 24, height: CGFloat = 16) -> NSImage {
        NSImage(size: NSSize(width: width, height: height))
    }

    @discardableResult
    private func beginReview(image: NSImage? = nil) -> UUID {
        coordinator.beginReview(image: image ?? makeImage())
        guard let id = coordinator.activeSession?.id else {
            XCTFail("beginReview did not create an active session")
            return UUID()
        }
        return id
    }

    private func awaitAction() async {
        await coordinator.actionTask?.value
    }

    private func assertCleanIdle(file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(coordinator.state, .idle, "state should be idle", file: file, line: line)
        XCTAssertNil(coordinator.activeSession, "session should be cleared", file: file, line: line)
        XCTAssertFalse(coordinator.isProcessingAction, "processing flag should be reset", file: file, line: line)
        XCTAssertFalse(panel.presenting, "panel should be closed", file: file, line: line)
        XCTAssertFalse(annotation.presenting, "annotation editor should be closed", file: file, line: line)
    }

    // MARK: - Normal capture

    func testNormalCapture_entersReviewingState() {
        beginReview()
        XCTAssertEqual(coordinator.state, .reviewing)
        XCTAssertNotNil(coordinator.activeSession)
        XCTAssertEqual(panel.presentCount, 1)
    }

    func testNormalCapture_doesNotImmediatelySaveCopyOrAnnotate() {
        beginReview()
        XCTAssertEqual(persistence.attemptCount, 0, "must not save on capture")
        XCTAssertEqual(clipboard.attemptCount, 0, "must not copy on capture")
        XCTAssertEqual(annotation.presentCount, 0, "must not auto-open annotation")
    }

    func testNormalCapture_retainsImageInSession() {
        let image = makeImage()
        coordinator.beginReview(image: image)
        XCTAssertIdentical(coordinator.activeSession?.originalImage, image)
    }

    func testOnlyOneActiveSessionAtATime() {
        beginReview()
        let firstID = coordinator.activeSession?.id
        coordinator.beginReview(image: makeImage())
        XCTAssertEqual(coordinator.activeSession?.id, firstID, "second beginReview must be ignored")
        XCTAssertEqual(panel.presentCount, 1)
    }

    // MARK: - Copy

    func testCopy_copiesOnceSavesOnceAndReturnsToIdle() async {
        let image = makeImage()
        coordinator.beginReview(image: image)
        let id = coordinator.activeSession!.id

        coordinator.handleCopy(sessionID: id)
        await awaitAction()

        XCTAssertEqual(clipboard.writeCount, 1)
        XCTAssertIdentical(clipboard.lastImage, image)
        XCTAssertEqual(persistence.saveCount, 1)
        XCTAssertIdentical(persistence.lastImage, image)
        assertCleanIdle()
    }

    func testCopy_repeatedTapsDoNotSaveTwice() async {
        let id = beginReview()

        coordinator.handleCopy(sessionID: id)
        coordinator.handleCopy(sessionID: id) // fast second click
        coordinator.handleCopy(sessionID: id)
        await awaitAction()

        XCTAssertEqual(clipboard.writeCount, 1)
        XCTAssertEqual(persistence.saveCount, 1)
        assertCleanIdle()
    }

    func testCopy_clipboardFailureKeepsSessionRecoverable() async {
        let id = beginReview()
        clipboard.errorToThrow = DummyError()

        coordinator.handleCopy(sessionID: id)
        await awaitAction()

        XCTAssertEqual(persistence.saveCount, 0, "must not save when copy failed")
        XCTAssertEqual(coordinator.state, .reviewing)
        XCTAssertNotNil(coordinator.activeSession)
        XCTAssertFalse(coordinator.isProcessingAction)
        guard case .failure = panel.statuses.last else {
            return XCTFail("expected failure status, got \(String(describing: panel.statuses.last))")
        }
    }

    func testCopy_saveFailureReportsPartialSuccessAndAllowsRetryWithoutDuplicates() async {
        let id = beginReview()
        persistence.errorToThrow = DummyError()

        coordinator.handleCopy(sessionID: id)
        await awaitAction()

        XCTAssertEqual(clipboard.writeCount, 1, "clipboard succeeded")
        XCTAssertEqual(persistence.saveCount, 0)
        XCTAssertEqual(coordinator.state, .reviewing, "session stays recoverable")
        guard case .failure(let message) = panel.statuses.last else {
            return XCTFail("expected failure status")
        }
        XCTAssertTrue(message.lowercased().contains("copied"), "must tell the user copy succeeded but save failed")

        // Retry succeeds and creates exactly one record.
        persistence.errorToThrow = nil
        coordinator.handleCopy(sessionID: id)
        await awaitAction()
        XCTAssertEqual(persistence.saveCount, 1)
        assertCleanIdle()
    }

    // MARK: - Annotate

    func testAnnotate_opensEditorWithoutSaving() {
        let image = makeImage()
        coordinator.beginReview(image: image)
        let id = coordinator.activeSession!.id

        coordinator.handleAnnotate(sessionID: id)

        XCTAssertEqual(coordinator.state, .annotating)
        XCTAssertEqual(annotation.presentCount, 1)
        XCTAssertIdentical(annotation.lastImage, image)
        XCTAssertFalse(panel.presenting, "panel must close when the editor opens")
        XCTAssertEqual(persistence.attemptCount, 0)
        XCTAssertEqual(clipboard.attemptCount, 0)
        XCTAssertNotNil(coordinator.activeSession, "session stays alive during annotation")
    }

    func testAnnotationSave_savesAnnotatedImageExactlyOnce() async {
        let id = beginReview()
        coordinator.handleAnnotate(sessionID: id)

        let annotated = makeImage(width: 99, height: 77)
        coordinator.handleAnnotationSave(sessionID: id, annotatedImage: annotated)
        await awaitAction()

        XCTAssertEqual(persistence.saveCount, 1)
        XCTAssertIdentical(persistence.lastImage, annotated, "the annotated image must be saved")
        XCTAssertEqual(clipboard.writeCount, 1)
        XCTAssertIdentical(clipboard.lastImage, annotated, "the annotated image must be copied")
        XCTAssertEqual(notifier.notifications.count, 1, "exactly one success notification")
        assertCleanIdle()
    }

    func testAnnotationSkip_savesOriginalImageExactlyOnce() async {
        let original = makeImage()
        coordinator.beginReview(image: original)
        let id = coordinator.activeSession!.id
        coordinator.handleAnnotate(sessionID: id)

        coordinator.handleAnnotationSkip(sessionID: id)
        await awaitAction()

        XCTAssertEqual(persistence.saveCount, 1)
        XCTAssertIdentical(persistence.lastImage, original)
        XCTAssertEqual(clipboard.writeCount, 1)
        XCTAssertIdentical(clipboard.lastImage, original)
        assertCleanIdle()
    }

    func testAnnotationCancel_returnsToReviewingWithPanelAndSavesNothing() {
        let id = beginReview()
        coordinator.handleAnnotate(sessionID: id)

        coordinator.handleAnnotationCancel(sessionID: id)

        XCTAssertEqual(coordinator.state, .reviewing)
        XCTAssertEqual(panel.presentCount, 2, "panel is restored")
        XCTAssertTrue(panel.presenting)
        XCTAssertFalse(annotation.presenting)
        XCTAssertEqual(persistence.attemptCount, 0)
        XCTAssertEqual(clipboard.attemptCount, 0)
        XCTAssertEqual(coordinator.activeSession?.id, id, "same session survives")
        XCTAssertEqual(annotation.presentCount, 1, "no duplicate editors created")
    }

    func testAnnotationCancel_thenCopyStillWorks() async {
        let id = beginReview()
        coordinator.handleAnnotate(sessionID: id)
        coordinator.handleAnnotationCancel(sessionID: id)

        coordinator.handleCopy(sessionID: id)
        await awaitAction()

        XCTAssertEqual(persistence.saveCount, 1)
        XCTAssertEqual(clipboard.writeCount, 1)
        assertCleanIdle()
    }

    // MARK: - Share

    func testShare_callsServiceWithSessionImageAndSavesOnce() async {
        let image = makeImage()
        coordinator.beginReview(image: image)
        let id = coordinator.activeSession!.id

        coordinator.handleShare(sessionID: id)
        XCTAssertEqual(coordinator.state, .sharing)
        await awaitAction()

        XCTAssertEqual(sharing.shareCount, 1)
        XCTAssertIdentical(sharing.lastImage, image)
        XCTAssertEqual(persistence.saveCount, 1, "share persists exactly once")
        XCTAssertEqual(clipboard.attemptCount, 0, "share does not require clipboard")
        assertCleanIdle()
    }

    func testShare_failureKeepsSessionRecoverable() async {
        let id = beginReview()
        sharing.errorToThrow = ScreenshotSharingError.failed("boom")

        coordinator.handleShare(sessionID: id)
        await awaitAction()

        XCTAssertEqual(persistence.saveCount, 0)
        XCTAssertEqual(coordinator.state, .reviewing)
        XCTAssertNotNil(coordinator.activeSession)
        XCTAssertFalse(coordinator.isProcessingAction)
        guard case .failure = panel.statuses.last else {
            return XCTFail("expected failure status")
        }
    }

    func testShare_cancellationReturnsToReviewingWithoutErrorOrSave() async {
        let id = beginReview()
        sharing.errorToThrow = ScreenshotSharingError.cancelled

        coordinator.handleShare(sessionID: id)
        await awaitAction()

        XCTAssertEqual(persistence.saveCount, 0)
        XCTAssertEqual(coordinator.state, .reviewing)
        XCTAssertNotNil(coordinator.activeSession)
        XCTAssertEqual(panel.statuses.last, .ready, "no error shown for user cancellation")
    }

    func testShare_unavailableServiceProducesClearError() {
        let id = beginReview()
        sharing.available = false

        coordinator.handleShare(sessionID: id)

        XCTAssertEqual(sharing.shareCount, 0)
        XCTAssertEqual(persistence.attemptCount, 0)
        XCTAssertEqual(coordinator.state, .reviewing)
        XCTAssertNotNil(coordinator.activeSession)
        guard case .failure = panel.statuses.last else {
            return XCTFail("expected failure status for unavailable sharing")
        }
    }

    // MARK: - Cancel

    func testCancel_discardsSessionWithoutSavingOrCopying() {
        let id = beginReview()

        coordinator.handleCancel(sessionID: id)

        XCTAssertEqual(persistence.attemptCount, 0)
        XCTAssertEqual(clipboard.attemptCount, 0)
        XCTAssertEqual(notifier.notifications.count, 0)
        assertCleanIdle()
    }

    func testCancelActiveSession_cleansAllWindowsAndState() {
        let id = beginReview()
        coordinator.handleAnnotate(sessionID: id)

        coordinator.cancelActiveSession()

        assertCleanIdle()
        XCTAssertEqual(persistence.attemptCount, 0)
        XCTAssertEqual(clipboard.attemptCount, 0)
    }

    // MARK: - Quick Save regression

    func testQuickSave_copiesOnceSavesOnceAndSkipsPanel() async {
        let image = makeImage()

        await coordinator.performQuickSaveCompletion(image: image)

        XCTAssertEqual(clipboard.writeCount, 1)
        XCTAssertEqual(persistence.saveCount, 1)
        XCTAssertIdentical(persistence.lastImage, image)
        XCTAssertEqual(panel.presentCount, 0, "quick save must not open the post-capture panel")
        XCTAssertEqual(annotation.presentCount, 0)
        XCTAssertEqual(notifier.notifications.count, 1, "existing success notification preserved")
        XCTAssertEqual(coordinator.state, .idle)
        XCTAssertNil(coordinator.activeSession)
    }

    // MARK: - Session safety

    func testStaleCallback_cannotFinishNewerSession() async {
        beginReview()
        let staleHandlers = panel.handlers
        coordinator.cancelActiveSession()

        // New capture session.
        coordinator.beginReview(image: makeImage())
        let newID = coordinator.activeSession!.id

        // Old panel's Copy callback fires late.
        staleHandlers?.onCopy()
        await awaitAction()

        XCTAssertEqual(persistence.saveCount, 0, "stale callback must not save")
        XCTAssertEqual(clipboard.writeCount, 0, "stale callback must not copy")
        XCTAssertEqual(coordinator.state, .reviewing, "new session unaffected")
        XCTAssertEqual(coordinator.activeSession?.id, newID)
    }

    func testStaleAnnotationCallback_isRejected() async {
        let id = beginReview()
        coordinator.handleAnnotate(sessionID: id)
        let staleHandlers = annotation.handlers
        coordinator.cancelActiveSession()

        coordinator.beginReview(image: makeImage())
        let newID = coordinator.activeSession!.id

        staleHandlers?.onSave(makeImage())
        await awaitAction()

        XCTAssertEqual(persistence.saveCount, 0)
        XCTAssertEqual(coordinator.activeSession?.id, newID)
        XCTAssertEqual(coordinator.state, .reviewing)
    }

    func testSecondActionCannotRunWhileFirstIsProcessing() async {
        let id = beginReview()

        coordinator.handleCopy(sessionID: id)
        coordinator.handleShare(sessionID: id)      // must be rejected
        coordinator.handleAnnotate(sessionID: id)   // must be rejected
        await awaitAction()

        XCTAssertEqual(sharing.shareCount, 0)
        XCTAssertEqual(annotation.presentCount, 0)
        XCTAssertEqual(persistence.saveCount, 1)
        assertCleanIdle()
    }

    func testEveryTerminalPathAllowsANewSession() async {
        // Copy terminal
        var id = beginReview()
        coordinator.handleCopy(sessionID: id)
        await awaitAction()
        assertCleanIdle()

        // Cancel terminal
        id = beginReview()
        coordinator.handleCancel(sessionID: id)
        assertCleanIdle()

        // Share terminal
        id = beginReview()
        coordinator.handleShare(sessionID: id)
        await awaitAction()
        assertCleanIdle()

        // Annotate → Save terminal
        id = beginReview()
        coordinator.handleAnnotate(sessionID: id)
        coordinator.handleAnnotationSave(sessionID: id, annotatedImage: makeImage())
        await awaitAction()
        assertCleanIdle()

        XCTAssertEqual(persistence.saveCount, 3)
    }
}
