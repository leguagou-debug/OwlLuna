import XCTest

/// A recording is transcribed, its lines lead the replay, and search finds what was said.
@MainActor
final class TranscriptUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Whole seconds into the recording, from a position such as "0:11 of 0:20".
    private func seconds(_ slider: XCUIElement) -> Int? {
        let clock = (slider.value as? String ?? "").components(separatedBy: " of ").first ?? ""
        let parts = clock.split(separator: ":").compactMap { Int($0) }
        return parts.count == 2 ? parts[0] * 60 + parts[1] : nil
    }

    func testARecordingIsTranscribedAndItsLinesLeadTheReplay() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-storageRoot", "transcript", "-resetStorage", "-seedLibrary", "2", "-seedReplay", "-fakeTranscript", "-drawingInput", "anyInput"]
        app.launch()
        let notebook = app.buttons["notebook.Lecture Replay"]
        XCTAssertTrue(notebook.waitForExistence(timeout: 30))
        notebook.tap()
        XCTAssertTrue(app.descendants(matching: .any)["page.canvas.1"].waitForExistence(timeout: 20))

        app.buttons["Recordings"].firstMatch.tap()
        let open = app.buttons["recording.transcript.1"]
        XCTAssertTrue(open.waitForExistence(timeout: 10))
        XCTAssertEqual(open.value as? String, "Not transcribed")
        open.tap()
        let start = app.buttons["transcript.start"]
        XCTAssertTrue(start.waitForExistence(timeout: 5))
        attach(app, "transcript-offer")
        start.tap()
        let second = app.buttons["transcript.line.2"]
        XCTAssertTrue(second.waitForExistence(timeout: 15), "the recording is written down")
        XCTAssertEqual(app.buttons["transcript.line.1"].label, "0:01, Today we cover the cell membrane.")
        attach(app, "transcript-written")

        // The last line, said from 0:11 to the end, so it is still the one being said however long the pause takes to land.
        let started = Date.now
        app.buttons["transcript.line.3"].tap()
        let bar = app.descendants(matching: .any)["editor.replay.bar"]
        XCTAssertTrue(bar.waitForExistence(timeout: 10), "a line starts the replay")
        let play = app.buttons["editor.replay.play"]
        play.tap()
        let played = Date.now.timeIntervalSince(started)
        XCTAssertEqual(play.label, "Play", "paused")
        let position = app.sliders["editor.replay.position"]
        let at = try XCTUnwrap(seconds(position), "\(String(describing: position.value))")
        XCTAssertGreaterThanOrEqual(at, 11, "from that line's moment: \(String(describing: position.value))")
        XCTAssertGreaterThan(Double(at), played,
                             "not from the start, which \(played.formatted(.number.precision(.fractionLength(1)))) s of playing can't have passed")
        let panel = app.descendants(matching: .any)["replay.transcript"]
        XCTAssertTrue(panel.waitForExistence(timeout: 5), "what was said sits beside the page")
        XCTAssertTrue(app.buttons["transcript.line.3"].isSelected, "with the line being said marked")
        sleep(1)
        attach(app, "replay-with-transcript")

        second.tap()
        XCTAssertTrue((position.value as? String ?? "").hasPrefix("0:06"), "a tap on a line jumps the sound there: \(String(describing: position.value))")
        XCTAssertTrue(second.isSelected)
        XCTAssertEqual(bar.value as? String, "2 of 5 strokes written", "and the ink follows")

        app.buttons["editor.replay.transcript"].tap()
        XCTAssertTrue(panel.waitForNonExistence(timeout: 5))
        app.buttons["editor.replay.done"].tap()
        let back = app.buttons["editor.back"]
        XCTAssertTrue(back.waitForExistence(timeout: 5))
        back.tap()

        XCTAssertTrue(notebook.waitForExistence(timeout: 20))
        let field = app.openLibrarySearch()
        field.typeText("membrane")
        let hit = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Lecture Replay, recording '")).firstMatch
        XCTAssertTrue(hit.waitForExistence(timeout: 15), "search finds what was said")
        attach(app, "transcript-search")
    }
}
