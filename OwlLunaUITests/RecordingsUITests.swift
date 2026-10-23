import XCTest

/// A recording is named, moved along, played faster and shared from the Recordings list, and its replay keeps the speed.
/// Deleting it asks first, and Undo brings it back.
@MainActor
final class RecordingsUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// The seconds a position slider reads, from "0:07 of 0:20".
    private func seconds(_ slider: XCUIElement) -> Int {
        let clock = (slider.value as? String ?? "").split(separator: " ").first ?? ""
        let parts = clock.split(separator: ":").compactMap { Int($0) }
        return parts.count == 2 ? parts[0] * 60 + parts[1] : -1
    }

    func testARecordingIsNamedScrubbedPlayedFasterAndShared() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-storageRoot", "recordings", "-resetStorage", "-seedLibrary", "2", "-seedReplay", "-drawingInput", "anyInput"]
        app.launch()
        let notebook = app.buttons["notebook.Lecture Replay"]
        XCTAssertTrue(notebook.waitForExistence(timeout: 30))
        notebook.tap()
        XCTAssertTrue(app.descendants(matching: .any)["page.canvas.1"].waitForExistence(timeout: 20))

        app.buttons["Recordings"].firstMatch.tap()
        let options = app.buttons["recording.options.1"]
        XCTAssertTrue(options.waitForExistence(timeout: 10))
        XCTAssertEqual(options.label, "Recording Options")
        options.tap()
        let rename = app.buttons["recording.rename"]
        XCTAssertTrue(rename.waitForExistence(timeout: 5))
        rename.tap()
        let field = app.textFields["recording.rename.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.typeText("Cell membranes")
        app.buttons["Save"].tap()
        let named = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'Cell membranes'")).firstMatch
        XCTAssertTrue(named.waitForExistence(timeout: 5), "the row is called by its new name")
        attach(app, "recording-named")

        app.buttons["recording.play.1"].tap()
        let position = app.sliders["recording.position.1"]
        XCTAssertTrue(position.waitForExistence(timeout: 10), "a playing recording has its scrubber under it")
        XCTAssertEqual(position.label, "Position")
        position.adjust(toNormalizedSliderPosition: 0.25)
        let dragged = seconds(position)
        XCTAssertTrue((4...9).contains(dragged), "dragged a quarter of the way into 20 seconds: \(String(describing: position.value))")

        let speed = app.buttons["recording.speed.1"]
        XCTAssertEqual(speed.label, "Playback speed")
        XCTAssertTrue(["0.75×", "1×", "1.25×", "1.5×", "2×"].contains(speed.value as? String ?? ""), "the speed last chosen: \(String(describing: speed.value))")
        speed.tap()
        let twice = app.buttons["2×"]
        XCTAssertTrue(twice.waitForExistence(timeout: 5), "every speed is on the card")
        XCTAssertTrue(app.buttons["0.75×"].exists)
        attach(app, "recording-speeds")
        twice.tap()
        XCTAssertEqual(speed.value as? String, "2×")
        XCTAssertTrue(position.waitForNonExistence(timeout: 15), "at twice the speed it is soon over")

        options.tap()
        let share = app.buttons["recording.share.audio"]
        XCTAssertTrue(share.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["recording.share.transcript"].exists, "there is no transcript to share yet")
        share.tap()
        let files = app.descendants(matching: .any).matching(NSPredicate(format: "label == 'Save to Files'")).firstMatch
        XCTAssertTrue(files.waitForExistence(timeout: 10), "the share sheet offers the audio")
        attach(app, "recording-share")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.04, dy: 0.5)).tap()
        XCTAssertTrue(files.waitForNonExistence(timeout: 10))

        app.buttons["recording.replay.1"].tap()
        let replaySpeed = app.buttons["editor.replay.speed"]
        XCTAssertTrue(replaySpeed.waitForExistence(timeout: 10))
        XCTAssertEqual(replaySpeed.value as? String, "2×", "the replay plays at the speed last chosen")
        replaySpeed.tap()
        app.buttons["1×"].tap()
        XCTAssertEqual(replaySpeed.value as? String, "1×")
        app.buttons["editor.replay.done"].tap()

        app.buttons["Recordings"].firstMatch.tap()
        XCTAssertTrue(options.waitForExistence(timeout: 10))
        options.tap()
        app.buttons["recording.delete"].tap()
        let asking = app.staticTexts["Delete “Cell membranes”?"]
        XCTAssertTrue(asking.waitForExistence(timeout: 5), "deleting asks first")
        XCTAssertTrue(app.staticTexts["You can undo this."].exists)
        attach(app, "recording-delete")
        app.buttons["Cancel"].tap()
        XCTAssertTrue(asking.waitForNonExistence(timeout: 5))
        XCTAssertTrue(named.exists, "Cancel keeps it")
        options.tap()
        app.buttons["recording.delete"].tap()
        XCTAssertTrue(asking.waitForExistence(timeout: 5))
        app.buttons["Delete Recording"].tap()
        XCTAssertTrue(app.staticTexts["No Recordings"].firstMatch.waitForExistence(timeout: 5))
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.04, dy: 0.5)).tap()
        let undo = app.buttons["editor.undo"]
        XCTAssertTrue(undo.waitForExistence(timeout: 5))
        undo.tap()
        app.buttons["Recordings"].firstMatch.tap()
        XCTAssertTrue(named.waitForExistence(timeout: 5), "Undo brings it back with its name")

        // A swipe's buttons are hidden from VoiceOver, so Delete is tapped where it stands.
        let edge = options.frame.maxX
        named.swipeLeft()
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: edge - 16, dy: options.frame.midY)).tap()
        XCTAssertTrue(asking.waitForExistence(timeout: 5), "a swipe asks first too")
        app.buttons["Cancel"].tap()
        XCTAssertTrue(asking.waitForNonExistence(timeout: 5))
        XCTAssertTrue(named.exists)
    }
}
