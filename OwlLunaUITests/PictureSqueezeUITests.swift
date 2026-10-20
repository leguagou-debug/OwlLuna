import XCTest

/// Squeezing a placed photo from its side grips, then growing it from the corner, which keeps the new proportions.
@MainActor
final class PictureSqueezeUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Drags from the middle of an element by an offset, in window points looked up once.
    private func drag(_ element: XCUIElement, by offset: CGVector, in app: XCUIApplication) {
        let frame = element.frame, window = app.coordinate(withNormalizedOffset: .zero)
        window.withOffset(CGVector(dx: frame.midX, dy: frame.midY))
            .press(forDuration: 0.1, thenDragTo: window.withOffset(CGVector(dx: frame.midX + offset.dx, dy: frame.midY + offset.dy)),
                   withVelocity: 300, thenHoldForDuration: 0.2)
    }

    func testAPictureIsSqueezedFromASideAndGrowsEvenlyFromTheCorner() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-storageRoot", "squeeze", "-resetStorage", "-seedLibrary", "3", "-drawingInput", "anyInput"]
        app.launch()
        let notebook = app.buttons["notebook.Physics II 3"]
        XCTAssertTrue(notebook.waitForExistence(timeout: 30))
        notebook.tap()
        XCTAssertTrue(app.descendants(matching: .any)["page.canvas.1"].waitForExistence(timeout: 20))
        app.buttons["Add"].firstMatch.tap()
        app.buttons["Picture on This Page…"].firstMatch.tap()
        let photo = app.scrollViews.images.matching(NSPredicate(format: "label CONTAINS[c] %@", "photo")).firstMatch
        try XCTSkipUnless(photo.waitForExistence(timeout: 15), "this simulator's photo library is empty")
        photo.tap()
        let picture = app.images["Picture"]
        if !picture.waitForExistence(timeout: 20), photo.exists { photo.tap() }
        XCTAssertTrue(picture.waitForExistence(timeout: 30), "the photo is placed on the current page")
        XCTAssertTrue(app.buttons["editor.arrange.done"].waitForExistence(timeout: 5))
        sleep(1)
        let before = picture.frame

        let width = app.otherElements["page.grip.right"], height = app.otherElements["page.grip.bottom"]
        XCTAssertTrue(width.waitForExistence(timeout: 5), "a grip on the right side")
        XCTAssertTrue(height.exists, "and one on the bottom")
        XCTAssertEqual(width.label, "Change width")
        XCTAssertEqual(height.label, "Change height")
        drag(width, by: CGVector(dx: before.width * 0.2, dy: 0), in: app)
        let wider = picture.frame
        XCTAssertGreaterThan(wider.width, before.width * 1.12, "the right grip stretches it")
        XCTAssertEqual(wider.height, before.height, accuracy: 2, "and leaves its height")
        XCTAssertEqual(wider.minX, before.minX, accuracy: 2, "the left side stays where it was")

        drag(height, by: CGVector(dx: 0, dy: -before.height * 0.3), in: app)
        let squeezed = picture.frame
        XCTAssertLessThan(squeezed.height, before.height * 0.8, "the bottom grip squeezes it")
        XCTAssertEqual(squeezed.width, wider.width, accuracy: 2)
        XCTAssertEqual(squeezed.minY, before.minY, accuracy: 2, "the top stays where it was")
        attach(app, "squeezed")

        let handle = app.otherElements["Resize and rotate"].firstMatch
        XCTAssertTrue(handle.exists)
        let grip = handle.frame, window = app.coordinate(withNormalizedOffset: .zero)
        // Straight out from the middle, so the handle scales without turning.
        let corner = CGVector(dx: grip.midX - squeezed.midX, dy: grip.midY - squeezed.midY)
        window.withOffset(CGVector(dx: grip.midX, dy: grip.midY))
            .press(forDuration: 0.1, thenDragTo: window.withOffset(CGVector(dx: grip.midX + corner.dx * 0.15, dy: grip.midY + corner.dy * 0.15)),
                   withVelocity: 200, thenHoldForDuration: 0.2)
        let grown = picture.frame
        XCTAssertLessThan(grown.maxX, app.frame.maxX, "still all on the screen")
        XCTAssertGreaterThan(grown.width, squeezed.width * 1.08, "the corner grows it")
        XCTAssertEqual(grown.width / grown.height, squeezed.width / squeezed.height, accuracy: 0.03, "without changing its proportions")

        app.buttons["editor.undo"].tap()
        app.buttons["editor.undo"].tap()
        app.buttons["editor.undo"].tap()
        XCTAssertEqual(picture.frame.width, before.width, accuracy: 2, "Undo takes each change back")
        XCTAssertEqual(picture.frame.height, before.height, accuracy: 2)
    }
}
