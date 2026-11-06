//
//  HelpMeAimTakenScrollUITests.swift
//  Picture Taken must scroll so a long description is never cut to "..."
//  (Matt, 2026-11-03). Runs in the simulator: -aimPreviewTaken opens the
//  screen with a long description, no camera needed.
//

import XCTest

final class HelpMeAimTakenScrollUITests: XCTestCase {
    private func keep(_ shot: XCUIScreenshot) {
        let a = XCTAttachment(screenshot: shot)
        a.lifetime = .keepAlways
        add(a)
    }

    @MainActor
    func testLongDescriptionScrolls() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-hasShownInstructions", "YES", "-aimPreviewTaken"]
        app.launch()
        let home = app.buttons[T("Help Me Aim")].firstMatch
        XCTAssertTrue(home.waitForExistence(timeout: 20), "Help Me Aim home button not found")
        sleep(3)
        home.tap()

        let text = app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'END OF DESCRIPTION'")).firstMatch
        XCTAssertTrue(text.waitForExistence(timeout: 10), "description not shown")
        XCTAssertFalse(text.label.hasSuffix("…"), "description was cut off")
        keep(app.screenshot())

        app.swipeUp()
        app.swipeUp()
        sleep(1)
        keep(app.screenshot())
        let back = app.buttons[T("Back")].firstMatch
        XCTAssertTrue(back.exists && back.isHittable, "Back button not reachable after scrolling")
        let frame = text.frame
        let screen = app.windows.firstMatch.frame
        XCTAssertLessThanOrEqual(frame.maxY, screen.maxY + 1, "end of the description is off screen")
    }
}
