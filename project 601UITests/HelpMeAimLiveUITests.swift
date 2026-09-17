//
//  HelpMeAimLiveUITests.swift
//  Drives Help Me Aim on Matt's phone while he holds it: home → Help Me Aim →
//  Something Else → type "dog" → Find, then lets the app steer and auto-shoot
//  on its own, then Take Another once. Test-build aid for the Pixel Guided
//  Frame work Dennis Long asked for; shots land in Documents/HelpMeAimShots.
//

import XCTest

final class HelpMeAimLiveUITests: XCTestCase {
    private let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")

    /// Waits `seconds`, tapping through any permission alert (Photos add,
    /// camera) so the saved picture is not blocked.
    private func wait(_ seconds: Int) {
        for _ in 0 ..< seconds {
            for label in ["Allow Full Access", "Allow Access", "Allow", "OK"] {
                let b = springboard.buttons[label].firstMatch
                if b.exists { b.tap(); break }
            }
            sleep(1)
        }
    }

    @MainActor
    func testHelpMeAimDogLive() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-hasShownInstructions", "YES"]
        app.launch()

        let home = app.buttons["Help Me Aim"].firstMatch
        XCTAssertTrue(home.waitForExistence(timeout: 20), "Help Me Aim home button not found")
        sleep(3) // buttons animate in
        home.tap()

        let other = app.buttons["Something Else"].firstMatch
        XCTAssertTrue(other.waitForExistence(timeout: 10), "Something Else not found")
        other.tap()

        let field = app.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10), "text field not found")
        field.tap()
        field.typeText("dog")
        let find = app.buttons["Find"].firstMatch
        XCTAssertTrue(find.waitForExistence(timeout: 5), "Find not found")
        find.tap()

        // The app steers and shoots on its own.
        wait(45)
        XCTAssertEqual(app.state, .runningForeground, "app left the foreground")

        let again = app.buttons["Take Another"].firstMatch
        if again.exists {
            again.tap()
        } else {
            print("HelpMeAimLive: no Take Another after 45s (no shot yet)")
        }
        wait(30)
        XCTAssertEqual(app.state, .runningForeground, "app left the foreground")
    }
}
