//
//  OwlLunaUITestsLaunchTests.swift
//  OwlLunaUITests
//
//  Created by Khan, Owais on 6/7/24.
//

import XCTest

@MainActor
final class OwlLunaUITestsLaunchTests: XCTestCase {

    override class var runsForEachTargetApplicationUIConfiguration: Bool {
        true
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
        // Each configuration turns the iPad and changes its appearance; the tests after these expect it upright and light.
        addTeardownBlock { @MainActor in
            XCUIDevice.shared.orientation = .portrait
            XCUIDevice.shared.appearance = .light
        }
    }

    func testLaunch() throws {
        let app = XCUIApplication()
        app.launch()

        // Insert steps here to perform after app launch but before taking a screenshot,
        // such as logging into a test account or navigating somewhere in the app

        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Launch Screen"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
