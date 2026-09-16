//
//  InfoGuideUITests.swift
//  Build 27 crash check: Dennis Long's TestFlight crash on build 26 fired when the
//  INFO GUIDE screen opened from home. Open it, play the audio tutorial, close it,
//  and repeat, asserting the app stays alive each time.
//

import XCTest

final class InfoGuideUITests: XCTestCase {
    @MainActor
    func testInfoGuideDoesNotCrash() throws {
        let app = XCUIApplication()
        app.launch()

        for round in 1...3 {
            let info = app.buttons["Info and guide"].firstMatch
            XCTAssertTrue(info.waitForExistence(timeout: 20), "round \(round): info button not found")
            info.tap()

            let play = app.buttons["Play full audio tutorial"].firstMatch
            XCTAssertTrue(play.waitForExistence(timeout: 10), "round \(round): guide did not open")
            XCTAssertEqual(app.state, .runningForeground, "round \(round): crashed opening the guide")
            play.tap()
            sleep(4)
            app.swipeUp()
            sleep(1)
            XCTAssertEqual(app.state, .runningForeground, "round \(round): crashed during the tutorial")

            let done = app.buttons["Done"].firstMatch
            XCTAssertTrue(done.waitForExistence(timeout: 5), "round \(round): no Done button")
            done.tap()
            sleep(2)
            XCTAssertEqual(app.state, .runningForeground, "round \(round): crashed closing the guide")
        }
    }
}
