//
//  ReadLanguageSwitchUITests.swift
//  One Read button since 2026-11-03: the Language pill turns English reading
//  into translating and back, and Read reopens the way it was left.
//

import XCTest

/// A language's name as the app shows it: English, or the Spanish name ("Francés") in a Spanish run.
private func langName(_ english: String, _ code: String) -> String {
    guard TestLanguage.isSpanish, let local = Locale(identifier: "es").localizedString(forIdentifier: code) else { return english }
    return local.prefix(1).uppercased() + local.dropFirst()
}
/// "French → English" menu item in the run's language (Spanish pill form: "Francés → Ing").
private func fromItem(_ english: String, _ code: String) -> String {
    TestLanguage.isSpanish ? T("%@ → Eng", langName(english, code)) : "\(english) → English"
}
/// What VoiceOver hears for the pill after picking `english` to English.
private func translatedValue(_ english: String, _ code: String) -> String {
    TestLanguage.isSpanish ? T("%@, translated to %@", langName(english, code), langName("English", "en").lowercased())
                           : "\(english), translated to English"
}

final class ReadLanguageSwitchUITests: XCTestCase {
    @MainActor
    func testEnglishToFrenchAndBack() throws {
        let app = XCUIApplication()
        // No -readerLanguageMode here: a launch argument would override what
        // the app remembers for the whole run.
        app.launchArguments += ["-hasShownInstructions", "YES"]
        app.launch()
        let read = app.buttons[T("Read")].firstMatch
        XCTAssertTrue(read.waitForExistence(timeout: 20), "no Read on home")
        sleep(3)
        read.tap()

        let pill = app.buttons[T("Language")].firstMatch
        XCTAssertTrue(pill.waitForExistence(timeout: 15), "no Language pill in Read")

        func pick(_ item: String, expect: String) {
            for _ in 0 ..< 3 {
                pill.tap()
                let b = app.buttons[item].firstMatch
                if b.waitForExistence(timeout: 4) { b.tap(); break }
            }
            let p = app.buttons[T("Language")].firstMatch
            XCTAssertTrue(p.waitForExistence(timeout: 15), "pill gone after picking \(item)")
            let deadline = Date().addingTimeInterval(10)
            while (p.value as? String) != expect, Date() < deadline { sleep(1) }
            XCTAssertEqual(p.value as? String, expect, "after picking \(item)")
        }
        let en = langName("English", "en")
        if (pill.value as? String) != en { pick(en, expect: en) }
        pick(fromItem("French", "fr"), expect: translatedValue("French", "fr"))
        pick(en, expect: en)
        pick(fromItem("Spanish", "es"), expect: translatedValue("Spanish", "es"))

        // Back home, then Read opens translating, the way it was left.
        app.buttons[T("Back")].firstMatch.tap()
        XCTAssertTrue(read.waitForExistence(timeout: 10))
        sleep(2)
        read.tap()
        XCTAssertTrue(pill.waitForExistence(timeout: 15))
        XCTAssertEqual(pill.value as? String, translatedValue("Spanish", "es"), "Read did not reopen translating")
    }
}
