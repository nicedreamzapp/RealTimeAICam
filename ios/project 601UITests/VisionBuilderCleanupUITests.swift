//
//  VisionBuilderCleanupUITests.swift
//  Presses Vision Builder's "Move N photos to Recently Deleted" and approves
//  Apple's prompt, at Matt's request (2026-09-16). Element taps only.
//

import XCTest

final class VisionBuilderCleanupUITests: XCTestCase {
    @MainActor
    func testRunCleanup() throws {
        let app = XCUIApplication(bundleIdentifier: "B9RA6QH559.Vision-Builder")
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        app.activate()
        let move = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Move '")).firstMatch
        XCTAssertTrue(move.waitForExistence(timeout: 120), "cleanup button never appeared")
        print("CLEANUP button: \(move.label)")
        for t in app.staticTexts.allElementsBoundByIndex.map(\.label) { print("CLEANUP text: \(t)") }
        guard app.state == .runningForeground else { return }
        move.tap()
        // Apple's own confirmation lives in SpringBoard or in the app's alert.
        let allow = NSPredicate(format: "label ==[c] 'Delete' OR label ==[c] 'Allow'")
        let sbButton = springboard.alerts.buttons.matching(allow).firstMatch
        let appButton = app.alerts.buttons.matching(allow).firstMatch
        if sbButton.waitForExistence(timeout: 15) { print("CLEANUP confirm: \(sbButton.label)"); sbButton.tap() }
        else if appButton.waitForExistence(timeout: 5) { print("CLEANUP confirm(app): \(appButton.label)"); appButton.tap() }
        else { print("CLEANUP no confirm found"); print(springboard.debugDescription.prefix(3000)) }
        let done = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Done.'")).firstMatch
        print("CLEANUP result: \(done.waitForExistence(timeout: 120) ? done.label : "no Done message")")
    }
}
