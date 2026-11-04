//
//  YourLanguageUITests.swift
//  "Your language" (2026-11-04, Play reviews: everything was spoken in English).
//  The Simulator can't download Apple's translation languages, so these run with
//  -rtcamFakeTranslator (debug builds only): "downloads" take a moment and the
//  translations come from a small phrase list. What they prove is the app's own
//  part: the default follows the phone, nothing downloads before the tap, Read's
//  pill and output follow Your language, the object names are built once and then
//  read from the file, and Help Me Aim turns "taza" into a cup.
//

import XCTest

final class YourLanguageUITests: XCTestCase {
    private func keep(_ app: XCUIApplication, _ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot())
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }

    private func launch(_ extra: [String] = [], env: [String: String] = [:]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-hasShownInstructions", "YES", "-rtcamFakeTranslator"] + extra
        app.launchEnvironment.merge(env) { $1 }
        app.launch()
        return app
    }

    /// Leaves the Simulator the way the other suites expect it: English, nothing saved.
    private func cleanUp() {
        let app = launch(["-rtcamFreshYourLanguage"])
        sleep(2)
        app.terminate()
    }

    private func openSettings(_ app: XCUIApplication) -> XCUIElement {
        let settings = app.buttons["Settings"].firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 20), "no Settings on home")
        sleep(3)
        settings.tap()
        let picker = app.buttons["yourLanguagePicker"].firstMatch
        XCTAssertTrue(picker.waitForExistence(timeout: 10), "no Your language in Settings")
        return picker
    }

    private func objectNames(_ app: XCUIApplication) -> String {
        app.descendants(matching: .any)["yourLanguageObjectNames"].firstMatch.label
    }

    private func waitForObjectNames(_ app: XCUIApplication, containing text: String, _ seconds: Int) -> Bool {
        for _ in 0 ..< seconds {
            if objectNames(app).contains(text) { return true }
            sleep(1)
        }
        return objectNames(app).contains(text)
    }

    /// Phone in Spanish: Your language starts as Spanish, nothing downloads until the
    /// row is tapped, then the object names are built once and read from the file after.
    @MainActor
    func testSpanishPhoneDefaultsToSpanishAndDownloadsOnlyOnTap() throws {
        continueAfterFailure = false
        let spanishPhone = ["-AppleLanguages", "(es)", "-AppleLocale", "es_ES"]
        var app = launch(["-rtcamFreshYourLanguage"] + spanishPhone)
        var picker = openSettings(app)
        XCTAssertEqual(picker.value as? String, "Spanish", "default did not follow the phone")
        let row = app.buttons["yourLanguageDownload"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5), "no download row")
        XCTAssertEqual(row.label, "Download Spanish once, then it works offline")
        // Nothing downloads by itself: the row stays and no names are built.
        sleep(6)
        XCTAssertTrue(row.exists, "Spanish downloaded without a tap")
        XCTAssertTrue(objectNames(app).contains("English"), "object names built before the tap: \(objectNames(app))")
        keep(app, "settings-spanish-before-tap")

        row.tap()
        let gone = NSPredicate(format: "exists == false")
        expectation(for: gone, evaluatedWith: row)
        waitForExpectations(timeout: 20)
        XCTAssertTrue(waitForObjectNames(app, containing: "es 605 built", 30), "names not built: \(objectNames(app))")
        keep(app, "settings-spanish-ready")
        app.terminate()

        // Next launch: the names come from the file, no translating.
        app = launch(spanishPhone)
        picker = openSettings(app)
        XCTAssertEqual(picker.value as? String, "Spanish")
        XCTAssertFalse(app.buttons["yourLanguageDownload"].firstMatch.exists, "asked to download again")
        XCTAssertTrue(waitForObjectNames(app, containing: "es 605 from file", 15), "names not reused: \(objectNames(app))")
        print("YOURLANG_OBJECT_NAMES \(objectNames(app))")
        app.terminate()
        cleanUp()
    }

    /// English phone: English, no download row. Picking French offers the download.
    @MainActor
    func testEnglishPhoneThenPickFrench() throws {
        continueAfterFailure = false
        let app = launch(["-rtcamFreshYourLanguage", "-AppleLanguages", "(en)"])
        let picker = openSettings(app)
        XCTAssertEqual(picker.value as? String, "English")
        XCTAssertFalse(app.buttons["yourLanguageDownload"].firstMatch.exists, "English should never download")
        keep(app, "settings-english")
        picker.tap()
        let french = app.buttons["French"].firstMatch
        XCTAssertTrue(french.waitForExistence(timeout: 5), "French not in the list")
        french.tap()
        let row = app.buttons["yourLanguageDownload"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10), "no download row after picking French")
        XCTAssertEqual(row.label, "Download French once, then it works offline")
        XCTAssertEqual(app.buttons["yourLanguagePicker"].firstMatch.value as? String, "French")
        keep(app, "settings-french-picked")
        row.tap()
        XCTAssertTrue(waitForObjectNames(app, containing: "fr 605 built", 30), "French names not built: \(objectNames(app))")
        keep(app, "settings-french-ready")
        app.terminate()
        cleanUp()
    }

    /// Your language Spanish, an English page: the pill says English → Spanish and
    /// what's read comes out in Spanish.
    @MainActor
    func testReadTranslatesAnEnglishPageIntoSpanish() throws {
        continueAfterFailure = false
        let app = launch(["-userLanguage", "es", "-fakeTranslatorPacks", "(es)", "-readerLanguageMode", "english",
                          "-ocrReadMode", "auto"],
                         env: ["RTCAM_FAKE_OCR_TRANSLATE": "1.0::Exit||0.6::Exit||0.6::Exit||0.6::Exit"])
        let read = app.buttons["Read"].firstMatch
        XCTAssertTrue(read.waitForExistence(timeout: 20))
        sleep(3)
        read.tap()
        let pill = app.buttons["Language"].firstMatch
        XCTAssertTrue(pill.waitForExistence(timeout: 15), "no Language pill")
        XCTAssertEqual(pill.value as? String, "English, translated to Spanish")
        let salida = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'Salida'")).firstMatch
        XCTAssertTrue(salida.waitForExistence(timeout: 20), "English page not translated into Spanish")
        keep(app, "read-en-to-es")

        // A French page into Spanish: pick French on the pill.
        pill.tap()
        let fr = app.buttons["French → Spanish"].firstMatch
        XCTAssertTrue(fr.waitForExistence(timeout: 5), "no French → Spanish in the pill menu")
        fr.tap()
        let p = app.buttons["Language"].firstMatch
        let deadline = Date().addingTimeInterval(10)
        while (p.value as? String) != "French, translated to Spanish", Date() < deadline { sleep(1) }
        XCTAssertEqual(p.value as? String, "French, translated to Spanish")
        keep(app, "read-fr-to-es-pill")
        app.terminate()
    }

    /// Help Me Aim with Your language Spanish: typing "taza" looks for a cup.
    @MainActor
    func testHelpMeAimTazaIsACup() throws {
        let app = launch(["-userLanguage", "es", "-fakeTranslatorPacks", "(es)"])
        let home = app.buttons["Help Me Aim"].firstMatch
        XCTAssertTrue(home.waitForExistence(timeout: 20))
        sleep(3)
        home.tap()
        let other = app.buttons["Something Else"].firstMatch
        XCTAssertTrue(other.waitForExistence(timeout: 10))
        other.tap()
        let field = app.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        sleep(2)
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for label in ["Allow", "OK"] where springboard.buttons[label].exists { springboard.buttons[label].tap() }
        field.tap()
        field.typeText("taza")
        app.buttons["Find"].firstMatch.tap()
        let cup = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'Camera, looking for' AND label CONTAINS 'cup'")).firstMatch
        XCTAssertTrue(cup.waitForExistence(timeout: 15), "taza did not become a cup")
        print("YOURLANG_AIM \(cup.label)")
        keep(app, "aim-taza-cup")
        app.terminate()
    }
}
