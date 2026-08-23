import XCTest
@testable import capture_your_screen

@MainActor
final class HotkeyManagerTests: XCTestCase {
    func testCaptureControlsRegisterAndReleaseAllGlobalKeys() {
        let manager = HotkeyManager()

        manager.beginCaptureKeyInterception { _ in }
        XCTAssertEqual(manager.captureKeyRegistrationCountForTesting, 5)

        manager.endCaptureKeyInterception()
        XCTAssertEqual(manager.captureKeyRegistrationCountForTesting, 0)
    }
}
