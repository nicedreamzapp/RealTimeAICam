//
//  LaunchAndModesUITests.swift
//  Dennis Long's build 26 crash (TestFlight, 2026-09-15, "on launch a crash")
//  died in CameraViewModel.pauseCameraAndProcessing 70s after launch. That
//  pause runs when the instructions sheet opens, which a fresh install shows
//  on first launch, and when a camera screen is left. This drives both, plus
//  What's this, the mode the AppleVis testers use most.
//

import XCTest

final class LaunchAndModesUITests: XCTestCase {
    private func alive(_ app: XCUIApplication, _ step: String) {
        XCTAssertEqual(app.state, .runningForeground, "crashed at: \(step)")
    }

    private func back(_ app: XCUIApplication, _ step: String) {
        // Lying flat, Object Detection uses its landscape Back, whose label is "Back, Back".
        let b = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Back'")).firstMatch
        if !b.waitForExistence(timeout: 10) { print("TREE_DUMP_START\n\(app.debugDescription)\nTREE_DUMP_END") }
        XCTAssertTrue(b.exists, "\(step): no Back button")
        b.tap()
        sleep(2)
        alive(app, "\(step) back to home")
        // The launch argument keeps "first launch" true, so home re-opens the
        // guide every time it appears. Close it; that is one more pause call.
        let d = app.buttons["Done"].firstMatch
        if d.waitForExistence(timeout: 4) { sleep(2); d.tap(); sleep(2) }
        alive(app, "\(step) guide closed again")
    }

    @MainActor
    func testFirstLaunchAndEveryModeDoesNotCrash() throws {
        let app = XCUIApplication()
        // Pretend this is a fresh install so the first-launch guide opens.
        app.launchArguments += ["-hasShownInstructions", "NO"]
        app.launch()

        let done = app.buttons["Done"].firstMatch
        XCTAssertTrue(done.waitForExistence(timeout: 20), "first-launch guide did not open")
        sleep(10)
        alive(app, "first-launch guide open")
        done.tap()
        sleep(3)
        alive(app, "first-launch guide closed")

        for round in 1...2 {
            // What's this: open, capture, wait for the answer, leave.
            let wt = app.buttons["What's this?"].firstMatch
            XCTAssertTrue(wt.waitForExistence(timeout: 20), "round \(round): no What's this? on home")
            wt.tap()
            let capture = app.buttons["What's this?"].firstMatch
            XCTAssertTrue(capture.waitForExistence(timeout: 20), "round \(round): no capture button")
            sleep(3)
            capture.tap()
            _ = app.buttons["Looking"].firstMatch.waitForExistence(timeout: 5)
            _ = app.buttons["What's this?"].firstMatch.waitForExistence(timeout: 150)
            alive(app, "round \(round) what's this answered")
            back(app, "round \(round) what's this")

            // Object detection: run the camera for a bit, leave.
            let od = app.buttons["Object Detection"].firstMatch
            XCTAssertTrue(od.waitForExistence(timeout: 10), "round \(round): no Object Detection")
            od.tap()
            sleep(15)
            alive(app, "round \(round) object detection running")
            back(app, "round \(round) object detection")

            // Reading mode.
            let tts = app.buttons["English Text to Speech"].firstMatch
            XCTAssertTrue(tts.waitForExistence(timeout: 10), "round \(round): no Text to Speech")
            tts.tap()
            sleep(8)
            alive(app, "round \(round) reading running")
            back(app, "round \(round) reading")

            // Guide from home again.
            app.buttons["Info and guide"].firstMatch.tap()
            let d2 = app.buttons["Done"].firstMatch
            XCTAssertTrue(d2.waitForExistence(timeout: 10), "round \(round): guide did not open")
            sleep(3)
            d2.tap()
            sleep(2)
            alive(app, "round \(round) guide from home")

            // Background and come back.
            XCUIDevice.shared.press(.home)
            sleep(4)
            app.activate()
            sleep(4)
            alive(app, "round \(round) back from background")
        }
    }
}
