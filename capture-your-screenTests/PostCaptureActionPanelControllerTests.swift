import XCTest
import AppKit
@testable import capture_your_screen

@MainActor
final class PostCaptureActionPanelControllerTests: XCTestCase {
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
