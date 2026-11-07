import XCTest
import AppKit
@testable import capture_your_screen

@MainActor
final class PostCaptureActionPanelControllerTests: XCTestCase {
    func testClosingOutgoingPanelDoesNotCancelItsReplacement() throws {
        let controller = PostCaptureActionPanelController()
        var cancellationCount = 0
        let handlers = PostCaptureActionHandlers(
            onCopy: {}, onAnnotate: {}, onShare: {},
            onCancel: { cancellationCount += 1 }
        )
        let session = PostCaptureSession(originalImage: NSImage(size: NSSize(width: 40, height: 30)))
        controller.present(session: session, handlers: handlers)
        let outgoing = try XCTUnwrap(controller.presentedWindow)
        controller.present(session: session, handlers: handlers)
        let replacement = try XCTUnwrap(controller.presentedWindow)
        defer {
            controller.dismiss()
            replacement.close()
        }

        // The outgoing window can still receive a native close event while
        // its fade is running. It must no longer own the active cancel handler.
        outgoing.close()

        XCTAssertEqual(cancellationCount, 0)
        XCTAssertTrue(controller.presentedWindow === replacement)
        XCTAssertTrue(controller.isPresenting)
    }

    func testDismissReleasesActivePanelBeforeAnimationCompletes() throws {
        let controller = PostCaptureActionPanelController()
        var cancellationCount = 0
        let handlers = PostCaptureActionHandlers(
            onCopy: {}, onAnnotate: {}, onShare: {},
            onCancel: { cancellationCount += 1 }
        )
        controller.present(
            session: PostCaptureSession(originalImage: NSImage(size: NSSize(width: 40, height: 30))),
            handlers: handlers
        )
        let panel = try XCTUnwrap(controller.presentedWindow)

        controller.dismiss()

        XCTAssertFalse(controller.isPresenting)
        XCTAssertNil(controller.presentedWindow)
        panel.close()
        XCTAssertEqual(cancellationCount, 0, "Programmatic dismissal must not invoke Cancel")
    }

    func testPresentingReplacementSurvivesPreviousPanelsDismissCompletion() async throws {
        let controller = PostCaptureActionPanelController()
        let handlers = PostCaptureActionHandlers(
            onCopy: {},
            onAnnotate: {},
            onShare: {},
            onCancel: {}
        )
        let image = NSImage(size: NSSize(width: 40, height: 30))

        controller.present(session: PostCaptureSession(originalImage: image), handlers: handlers)
        let firstWindow = try XCTUnwrap(controller.presentedWindow)

        controller.present(session: PostCaptureSession(originalImage: image), handlers: handlers)
        let replacementWindow = try XCTUnwrap(controller.presentedWindow)
        XCTAssertFalse(firstWindow === replacementWindow)

        // Let the first panel's 150 ms fade-out completion run. It must not
        // clear the controller state belonging to the replacement panel.
        try await Task.sleep(for: .milliseconds(250))

        XCTAssertTrue(controller.isPresenting)
        XCTAssertTrue(controller.presentedWindow === replacementWindow)

        controller.dismiss()
        try await Task.sleep(for: .milliseconds(250))
    }
}
