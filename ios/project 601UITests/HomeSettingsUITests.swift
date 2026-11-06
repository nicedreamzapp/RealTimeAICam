//
//  HomeSettingsUITests.swift
//  Settings opens from the home screen and shows Models (Matt, 2026-11-03).
//

import XCTest

final class HomeSettingsUITests: XCTestCase {
    private func keep(_ shot: XCUIScreenshot, _ name: String) {
        let a = XCTAttachment(screenshot: shot)
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }

    @MainActor
    func testSettingsOpensFromHome() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-hasShownInstructions", "YES"]
        app.launch()
        let settings = app.buttons[T("Settings")].firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 20), "Settings pill not on home")
        sleep(4) // the buttons animate in
        XCTAssertTrue(app.buttons[T("Read")].firstMatch.exists, "Read button missing")
        XCTAssertTrue(app.buttons[T("Live Cam, experimental")].firstMatch.waitForExistence(timeout: 5), "Live Cam button missing")
        keep(app.screenshot(), "home")
        settings.tap()
        let models = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", T("Models"))).firstMatch
        XCTAssertTrue(models.waitForExistence(timeout: 10), "Models row not in Settings")
        keep(app.screenshot(), "settings")
    }
}
