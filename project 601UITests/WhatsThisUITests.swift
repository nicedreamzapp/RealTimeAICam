//
//  WhatsThisUITests.swift
//  Drives the "What's this?" flow on a real device so the vision model can be
//  exercised without a person pressing the button: home → What's this? → capture,
//  then wait for the model to answer and assert the app is still alive.
//

import XCTest

final class WhatsThisUITests: XCTestCase {
    @MainActor
    func testWhatsThisDoesNotCrash() throws {
        let app = XCUIApplication()
        app.launch()

        // Home screen button that opens the reading mode.
        let home = app.buttons["What's this?"].firstMatch
        XCTAssertTrue(home.waitForExistence(timeout: 20), "home What's this? button not found")
        home.tap()

        // Capture button inside the mode (same label).
        let capture = app.buttons["What's this?"].firstMatch
        XCTAssertTrue(capture.waitForExistence(timeout: 20), "capture What's this? button not found")
        sleep(3) // let the camera settle
        capture.tap()

        // While the model works the label reads "Looking". Wait for it to come back.
        let looking = app.buttons["Looking"].firstMatch
        _ = looking.waitForExistence(timeout: 5)
        let back = app.buttons["What's this?"].firstMatch
        let answered = back.waitForExistence(timeout: 150)
        XCTAssertEqual(app.state, .runningForeground, "app is no longer in the foreground (crashed?)")
        XCTAssertTrue(answered, "capture button never returned; model still running or hung")

        // Second press: the repeated-request path that used to crash the library.
        sleep(2)
        back.tap()
        _ = looking.waitForExistence(timeout: 5)
        let answered2 = app.buttons["What's this?"].firstMatch.waitForExistence(timeout: 150)
        XCTAssertEqual(app.state, .runningForeground, "app died on the second press")
        XCTAssertTrue(answered2, "second answer never came back")
    }
}
