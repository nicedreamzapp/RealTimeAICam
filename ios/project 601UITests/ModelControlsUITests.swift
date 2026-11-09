import XCTest

/// Settings > Models gives the person control (Matt 11/8): nothing downloads
/// without a "Download?" yes, a running download has a visible Stop button,
/// and "On this phone" lists every model with a Delete button.
final class ModelControlsUITests: XCTestCase {
    private let shots = "/tmp/rtcam-models-shots"

    private func shoot(_ app: XCUIApplication, _ name: String) {
        try? FileManager.default.createDirectory(atPath: shots, withIntermediateDirectories: true)
        try? app.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: "\(shots)/\(name).png"))
    }

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-hasShownInstructions", "YES", "-rtcamShowModels", "YES",
                                "-modelLevelChoice", "auto", "-modelLevelsRemoved", "(quick)"]
        app.launch()
        return app
    }

    /// Small screens put the row below the fold: scroll until it can be tapped.
    private func reach(_ app: XCUIApplication, _ el: XCUIElement, up: Bool = true) {
        var tries = 0
        while !(el.exists && el.isHittable) && tries < 6 { up ? app.swipeUp() : app.swipeDown(); tries += 1 }
    }

    private func row(_ app: XCUIApplication, _ name: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", name + ".")).firstMatch
    }

    func testAskStopAndDelete() {
        let app = launch()
        XCTAssertTrue(app.staticTexts["On this phone"].waitForExistence(timeout: 15) ||
                      app.staticTexts["ON THIS PHONE"].exists)
        shoot(app, "1-on-this-phone")

        // Start clean: if an earlier run left Quick here, delete it (asks first).
        let delete = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Delete Quick to free'")).firstMatch
        if delete.exists {
            delete.tap()
            XCTAssertTrue(app.alerts["Delete Quick?"].waitForExistence(timeout: 5))
            shoot(app, "1b-ask-delete")
            app.alerts["Delete Quick?"].buttons["Delete"].tap()
            XCTAssertFalse(delete.waitForExistence(timeout: 3))
            shoot(app, "1c-deleted")
        }

        // Tapping a model that isn't here asks first; Cancel downloads nothing.
        let quick = row(app, "Quick")
        reach(app, quick)
        quick.tap()
        XCTAssertTrue(app.alerts["Download Quick?"].waitForExistence(timeout: 5))
        shoot(app, "2-ask-first")
        app.alerts.buttons["Cancel"].tap()
        XCTAssertFalse(app.buttons["Stop downloading Quick"].waitForExistence(timeout: 3))

        // Yes starts it, and a visible Stop button appears and works.
        quick.tap()
        app.alerts["Download Quick?"].buttons["Download"].tap()
        let stop = app.buttons["Stop downloading Quick"]
        _ = stop.waitForExistence(timeout: 5)
        reach(app, stop)
        XCTAssertTrue(stop.waitForExistence(timeout: 10))
        shoot(app, "3-downloading-stop")
        stop.tap()
        XCTAssertFalse(stop.waitForExistence(timeout: 3))
        shoot(app, "4-stopped")

        // Download it for real, then delete it from "On this phone".
        reach(app, quick)
        quick.tap()
        app.alerts["Download Quick?"].buttons["Download"].tap()
        // The Stop row goes away once Quick is installed; "On this phone" is at the top.
        let stopping = NSPredicate(format: "exists == false")
        expectation(for: stopping, evaluatedWith: stop)
        waitForExpectations(timeout: 900)
        reach(app, delete, up: false)
        XCTAssertTrue(delete.waitForExistence(timeout: 10), "Quick finished but has no Delete button")
        shoot(app, "5-installed")
        delete.tap()
        XCTAssertTrue(app.alerts["Delete Quick?"].waitForExistence(timeout: 5))
        shoot(app, "6-ask-delete")
        app.alerts["Delete Quick?"].buttons["Delete"].tap()
        XCTAssertFalse(delete.waitForExistence(timeout: 3))
        shoot(app, "7-deleted")
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS 'tap it below to download it'")).firstMatch.waitForExistence(timeout: 5))

        // Deleted stays deleted: a relaunch must not start downloading Quick again.
        app.terminate()
        let again = XCUIApplication()
        again.launchArguments += ["-hasShownInstructions", "YES", "-rtcamShowModels", "YES"]
        again.launch()
        XCTAssertTrue(again.staticTexts["On this phone"].waitForExistence(timeout: 15))
        XCTAssertFalse(again.buttons["Stop downloading Quick"].waitForExistence(timeout: 15))
        shoot(again, "8-relaunch-still-gone")
    }
}
