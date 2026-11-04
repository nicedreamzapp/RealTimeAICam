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
        let settings = app.buttons["Settings"].firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 20), "Settings pill not on home")
        XCTAssertTrue(app.buttons["Translator"].firstMatch.exists, "Translate button missing")
        XCTAssertTrue(app.buttons["Live Cam"].firstMatch.exists, "Live Cam button missing")
        sleep(3)
        keep(app.screenshot(), "home")
        settings.tap()
        let models = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'Models'")).firstMatch
        XCTAssertTrue(models.waitForExistence(timeout: 10), "Models row not in Settings")
        keep(app.screenshot(), "settings")
    }
}
