import XCTest
@testable import capture_your_screen

@MainActor
final class AnnotationCanvasTests: XCTestCase {
    func testNewBlurUsesChosenRadiusAndRetainsItThroughUndoRedo() throws {
        let canvas = AnnotationCanvas()
        canvas.activeTool = .blur
        canvas.activeBlurRadius = 40
        let item = canvas.makeItem(from: CGPoint(x: 0.2, y: 0.3), to: CGPoint(x: 0.6, y: 0.7))
        canvas.addItem(item)

        XCTAssertEqual(try XCTUnwrap(canvas.selectedItem()).blurRadius, 40)

        canvas.undo()
        XCTAssertTrue(canvas.items.isEmpty)
        canvas.activeBlurRadius = 5
        canvas.redo()
        XCTAssertEqual(try XCTUnwrap(canvas.items.first).blurRadius, 40)
    }

    func testNewPixelateUsesChosenBlockSizeWithoutChangingPreviousAnnotation() {
        let canvas = AnnotationCanvas()
        canvas.activeTool = .pixelate
        canvas.activePixelSize = 30
        let first = canvas.makeItem(from: .zero, to: CGPoint(x: 0.3, y: 0.4))
        canvas.addItem(first)

        canvas.activePixelSize = 5
        let second = canvas.makeItem(from: CGPoint(x: 0.5, y: 0.5), to: CGPoint(x: 0.8, y: 0.9))
        canvas.addItem(second)

        XCTAssertEqual(canvas.items.map(\.pixelSize), [30, 5])
    }
}
