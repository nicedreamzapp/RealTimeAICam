import XCTest

/// Settings > Models gives the person control (Matt 11/8, redesigned 11/9): every model row
/// says in plain words whether it is on this phone, nothing downloads without a "Download?" yes,
/// a running download has a Stop that asks first, and a downloaded model can be deleted (asks
/// first). No real download: a stand-in folder (`-rtcamFakeInstalled`) plays the downloaded model.
final class ModelControlsUITests: XCTestCase {
    private let shots = "/tmp/rtcam-models-shots"

    private func shoot(_ app: XCUIApplication, _ name: String) {
        try? FileManager.default.createDirectory(atPath: shots, withIntermediateDirectories: true)
        try? app.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: "\(shots)/\(name).png"))
    }

    private func launch(_ extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-hasShownInstructions", "YES", "-rtcamShowModels", "YES",
                                "-modelLevelChoice", "auto", "-modelLevelsRemoved", "(quick)"] + extra
        app.launch()
        return app
    }

    /// The one VoiceOver stop for a model: "Quick, not downloaded, 736.6 MB, Download".
    private func row(_ app: XCUIApplication, _ name: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", name + ", ")).firstMatch
    }

    /// The summary at the top (read together with the line under it).
    private func text(_ app: XCUIApplication, _ start: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", start)).firstMatch
    }

    private func label(_ el: XCUIElement) -> String { el.exists ? el.label : "" }

    /// Small screens put the row below the fold: scroll until it can be tapped.
    private func reach(_ app: XCUIApplication, _ el: XCUIElement) {
        var tries = 0
        while !(el.exists && el.isHittable) && tries < 6 { app.swipeUp(); tries += 1 }
    }

    /// The row's one button sits at its top right.
    private func tapRowButton(_ row: XCUIElement) {
        row.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: row.frame.width - 50, dy: 22)).tap()
    }

    private func waitFor(_ el: XCUIElement, labelContains text: String, timeout: TimeInterval = 10) -> Bool {
        let p = NSPredicate(format: "label CONTAINS %@", text)
        return XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: p, object: el)], timeout: timeout) == .completed
    }

    func testAskStopAndDelete() {
        var app = launch()
        XCTAssertTrue(text(app, "Only the built-in Balanced model is on this phone.").waitForExistence(timeout: 15),
                      "no plain summary of what is on the phone")
        let quick = row(app, "Quick")
        reach(app, quick)
        XCTAssertTrue(quick.label.hasPrefix("Quick, not downloaded"), quick.label)
        XCTAssertTrue(quick.label.hasSuffix("Download"), quick.label)
        shoot(app, "1-built-in-only")

        // Download asks first; Cancel downloads nothing.
        tapRowButton(quick)
        XCTAssertTrue(app.alerts["Download Quick?"].waitForExistence(timeout: 5))
        shoot(app, "2-ask-first")
        app.alerts.buttons["Cancel"].tap()
        sleep(1)
        XCTAssertTrue(label(quick).hasPrefix("Quick, not downloaded"), label(quick))

        // Yes starts it; Stop asks first, then throws it away.
        tapRowButton(quick)
        app.alerts["Download Quick?"].buttons["Download"].tap()
        let started = NSPredicate(format: "NOT (label BEGINSWITH 'Quick, not downloaded')")
        XCTAssertEqual(XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: started, object: quick)], timeout: 10),
                       .completed, "Quick did not start: \(label(quick))")
        XCTAssertFalse(label(quick).hasSuffix("Download"), "a downloading row must not offer a double-tap action")
        shoot(app, "3-downloading")
        tapRowButton(quick)
        XCTAssertTrue(app.alerts["Stop downloading Quick?"].waitForExistence(timeout: 5), "Stop did not ask first")
        shoot(app, "4-ask-stop")
        app.alerts.buttons["Stop download"].tap()
        XCTAssertTrue(waitFor(quick, labelContains: "not downloaded"), "still downloading: \(label(quick))")
        app.terminate()

        // A downloaded model: listed in the summary, Use this on the row, Delete asks first.
        app = launch(["-rtcamFakeInstalled", "quick"])
        XCTAssertTrue(text(app, "On this phone: Balanced (built in), Quick").waitForExistence(timeout: 15),
                      "summary does not list the downloaded model")
        let installed = row(app, "Quick")
        reach(app, installed)
        XCTAssertTrue(installed.label.hasPrefix("Quick, on this phone"), installed.label)
        shoot(app, "5-installed")
        installed.swipeLeft()
        let delete = app.buttons["Delete"].firstMatch
        XCTAssertTrue(delete.waitForExistence(timeout: 5), "no Delete on swipe")
        delete.tap()
        XCTAssertTrue(app.alerts["Delete Quick?"].waitForExistence(timeout: 5))
        shoot(app, "6-ask-delete")
        app.alerts["Delete Quick?"].buttons["Delete"].tap()
        XCTAssertTrue(waitFor(installed, labelContains: "not downloaded"), "not deleted: \(label(installed))")
        shoot(app, "7-deleted")
        app.terminate()

        // Deleted stays deleted: a relaunch must not start downloading Quick again.
        let again = XCUIApplication()
        again.launchArguments += ["-hasShownInstructions", "YES", "-rtcamShowModels", "YES"]
        again.launch()
        let after = row(again, "Quick")
        reach(again, after)
        sleep(5)
        XCTAssertTrue(label(after).hasPrefix("Quick, not downloaded"), "Quick came back: \(label(after))")
        shoot(again, "8-relaunch-still-gone")
    }
}
