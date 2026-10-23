//
//  TranslatePhotoUITests.swift
//  Translate mode, walked the way a user does it: open Translator, check the
//  "Spanish → Eng" pill sits fully on screen below the Dynamic Island, pick a
//  language from it, pick a sign from the photo library, read the English.
//  Set TEST_RUNNER_PROBE_OUT / TEST_RUNNER_SHOTS_DIR to keep lines and screenshots.
//

import XCTest

final class TranslatePhotoUITests: XCTestCase {
    private let env = ProcessInfo.processInfo.environment

    private func probe(_ line: String) {
        print(line)
        guard let path = env["PROBE_OUT"] else { return }
        let url = URL(fileURLWithPath: path)
        if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write((line + "\n").data(using: .utf8)!); try? h.close() }
        else { try? (line + "\n").write(to: url, atomically: true, encoding: .utf8) }
    }

    private func shot(_ name: String) {
        let png = XCUIScreen.main.screenshot().pngRepresentation
        let a = XCTAttachment(data: png, uniformTypeIdentifier: "public.png"); a.name = name; a.lifetime = .keepAlways; add(a)
        if let dir = env["SHOTS_DIR"] { try? png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png")) }
    }

    /// Signs added with simctl addmedia in this order (es first); the picker lists newest first.
    private let languages = ["Spanish", "French", "German", "Italian", "Portuguese"]

    @MainActor
    func testTranslateLibraryPhotoEveryLanguage() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments += ["-hasShownInstructions", "YES", "-translateFromLanguage", "es"]
        app.launch()

        let translator = app.buttons["Translator"].firstMatch
        XCTAssertTrue(translator.waitForExistence(timeout: 20), "no Translator on home")
        translator.tap()

        let pill = app.buttons["Translate from"].firstMatch
        XCTAssertTrue(pill.waitForExistence(timeout: 15), "no Translate from pill")
        sleep(2)
        let screen = app.windows.firstMatch.frame
        probe("PILL frame=\(pill.frame) screen=\(screen) label=\(pill.label) value=\(pill.value ?? "")")
        XCTAssertTrue(screen.contains(pill.frame), "pill runs off screen")
        XCTAssertGreaterThan(pill.frame.minY, 54, "pill is up in the Dynamic Island / status bar")
        shot("00-translate-mode-pill")

        for (index, name) in languages.enumerated() {
            // Pick the language from the pill's menu.
            let item = app.buttons[name].firstMatch
            for _ in 0..<3 {
                pill.tap()
                if item.waitForExistence(timeout: 4) { break }
            }
            XCTAssertTrue(item.exists, "\(name) missing from the From menu")
            shot(String(format: "%02d-menu-%@", index + 2, name))
            item.tap()
            sleep(1)
            if (pill.value as? String) != name {
                pill.tap(); if app.buttons[name].firstMatch.waitForExistence(timeout: 5) { app.buttons[name].firstMatch.tap() }; sleep(1)
            }
            if (pill.value as? String) != name { probe("MENU_TREE \(name)\n\(app.debugDescription)") }
            XCTAssertEqual(pill.value as? String, name, "From pill did not switch to \(name)")
            probe("LANG \(name) pillValue=\(pill.value ?? "")")

            // Pick the sign from the library.
            let picker = app.buttons["Translate a photo from my library"].firstMatch
            XCTAssertTrue(picker.waitForExistence(timeout: 5), "no library button in Translate mode")
            picker.tap()
            sleep(3)
            let photos = app.images.matching(NSPredicate(format: "label BEGINSWITH 'Photo'"))
            if index == 0 {
                for p in photos.allElementsBoundByIndex { probe("PHOTO \(p.label) \(p.frame)") }
                shot("01b-picker")
            }
            if photos.count < languages.count {
                probe("PICKER_TREE\n\(app.debugDescription)")
            }
            XCTAssertGreaterThanOrEqual(photos.count, languages.count, "picker shows \(photos.count) photos")
            // Newest first: Portuguese was added last, Spanish first.
            let photo = photos.element(boundBy: languages.count - 1 - index)
            for _ in 0..<10 where !photo.isHittable { usleep(500_000) }
            photo.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            // Wait for the English: the result card is one element labelled "Translation".
            let card = app.descendants(matching: .any).matching(NSPredicate(format: "label == 'Translation'")).firstMatch
            var english = ""
            if card.waitForExistence(timeout: 40) { english = (card.value as? String) ?? "" }
            probe("RESULT \(name) => \(english)")
            shot(String(format: "%02d-%@", index + 2, name))
            if english.isEmpty { probe("TREE \(name)\n\(app.debugDescription)") }
            // Back to a clean live screen for the next language.
            let stop = app.buttons["Stop reading"].firstMatch
            if stop.exists { stop.tap() }
        }
    }
}
