//
//  ReadLanguageSwitchUITests.swift
//  One Read button since 2026-11-03: the Language pill turns English reading
//  into translating and back, and Read reopens the way it was left.
//

import XCTest

final class ReadLanguageSwitchUITests: XCTestCase {
    @MainActor
    func testEnglishToFrenchAndBack() throws {
        let app = XCUIApplication()
        // No -readerLanguageMode here: a launch argument would override what
        // the app remembers for the whole run.
        app.launchArguments += ["-hasShownInstructions", "YES"]
        app.launch()
        let read = app.buttons["Read"].firstMatch
        XCTAssertTrue(read.waitForExistence(timeout: 20), "no Read on home")
        sleep(3)
        read.tap()

        let pill = app.buttons["Language"].firstMatch
        XCTAssertTrue(pill.waitForExistence(timeout: 15), "no Language pill in Read")

        func pick(_ item: String, expect: String) {
            for _ in 0 ..< 3 {
                pill.tap()
                let b = app.buttons[item].firstMatch
                if b.waitForExistence(timeout: 4) { b.tap(); break }
            }
            let p = app.buttons["Language"].firstMatch
            XCTAssertTrue(p.waitForExistence(timeout: 15), "pill gone after picking \(item)")
            let deadline = Date().addingTimeInterval(10)
            while (p.value as? String) != expect, Date() < deadline { sleep(1) }
            XCTAssertEqual(p.value as? String, expect, "after picking \(item)")
        }
        if (pill.value as? String) != "English" { pick("English", expect: "English") }
        pick("French → English", expect: "French, translated to English")
        pick("English", expect: "English")
        pick("Spanish → English", expect: "Spanish, translated to English")

        // Back home, then Read opens translating, the way it was left.
        app.buttons["Back"].firstMatch.tap()
        XCTAssertTrue(read.waitForExistence(timeout: 10))
        sleep(2)
        read.tap()
        XCTAssertTrue(pill.waitForExistence(timeout: 15))
        XCTAssertEqual(pill.value as? String, "Spanish, translated to English", "Read did not reopen translating")
    }
}
