import XCTest

@MainActor
final class TempReplayProbeUITests: XCTestCase {
    private func shot(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testReplayDoneWithTranscriptShowing() throws {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["-storageRoot", "probe", "-resetStorage", "-seedLibrary", "6", "-seedReplay", "-fakeTranscript", "-drawingInput", "anyInput", "-appearance", "light"]
        app.launch()
        let lecture = app.buttons["notebook.Lecture Replay"]
        XCTAssertTrue(lecture.waitForExistence(timeout: 60))
        lecture.tap()
        XCTAssertTrue(app.buttons["editor.ribbon"].waitForExistence(timeout: 20))
        if app.buttons["Recordings"].firstMatch.exists {
            app.buttons["Recordings"].firstMatch.tap()
        } else {
            app.buttons["More"].firstMatch.tap()
            app.buttons["Recordings"].firstMatch.tap()
        }
        let transcript = app.buttons["recording.transcript.1"]
        XCTAssertTrue(transcript.waitForExistence(timeout: 10))
        transcript.tap()
        let transcribe = app.buttons["transcript.start"]
        XCTAssertTrue(transcribe.waitForExistence(timeout: 5))
        transcribe.tap()
        let line = app.buttons["transcript.line.2"]
        XCTAssertTrue(line.waitForExistence(timeout: 15))
        line.tap()
        let play = app.buttons["editor.replay.play"]
        XCTAssertTrue(play.waitForExistence(timeout: 10))
        play.tap()
        sleep(1)
        shot(app, "playing")
        let done = app.buttons["editor.replay.done"]
        print("PROBE done frame \(done.frame) hittable \(done.isHittable) window \(app.windows.firstMatch.frame)")
        XCTAssertLessThanOrEqual(done.frame.maxX, app.windows.firstMatch.frame.maxX, "Done is on screen")
        sleep(30)
        shot(app, "after-wait")
        print("PROBE after wait: done exists \(done.exists) hittable \(done.exists && done.isHittable) frame \(done.exists ? done.frame : .zero) play label \(play.exists ? play.label : "-")")
        done.tap()
        let back = app.buttons["editor.ribbon"].waitForExistence(timeout: 5)
        shot(app, "after-done")
        print("PROBE ribbon after done: \(back)")
        XCTAssertTrue(back)
    }
}
