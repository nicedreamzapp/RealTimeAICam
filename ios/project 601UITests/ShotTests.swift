//
//  ShotTests.swift
//  Drives the app on an iPad so App Store screenshots show the real UI in use.
//  Not a correctness test: every step is best effort and the run keeps going so
//  one missing control never costs the rest of the shots.
//

import XCTest

final class ShotTests: XCTestCase {
    private var shotIndex = 0

    private func save(_ name: String) {
        shotIndex += 1
        let png = XCUIScreen.main.screenshot().pngRepresentation
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let url = dir.appendingPathComponent(String(format: "%02d-%@.png", shotIndex, name))
        try? png.write(to: url)
        print("SHOT \(url.path)")
    }

    @MainActor
    func testCaptureStoreShots() throws {
        let app = XCUIApplication()
        app.launch()
        sleep(4)

        // First launch shows the instructions sheet.
        let done = app.buttons["Done"].firstMatch
        if done.waitForExistence(timeout: 8) {
            done.tap()
            sleep(2)
        }

        save("home")

        // The voice list: every English voice the iPad has, which is what
        // build 26 fixed.
        let voice = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'voice'")).firstMatch
        if voice.waitForExistence(timeout: 5) {
            voice.tap()
            sleep(2)
            save("voices")
            voice.tap()
            sleep(1)
        }

        // English reader, fed from a picture already on the iPad.
        let english = app.buttons["English Text to Speech"].firstMatch
        if english.waitForExistence(timeout: 8) {
            english.tap()
            sleep(4)
            let library = app.buttons["Describe a photo from my library"].firstMatch
            if library.waitForExistence(timeout: 8) {
                library.tap()
                sleep(5)
                pickPhoto(app, index: 1)
                sleep(12)
                save("reading-a-page")
            } else {
                save("english-reader")
            }
            let back = app.buttons["Back"].firstMatch
            if back.waitForExistence(timeout: 5) { back.tap(); sleep(3) }
        }

        // Spanish to English on a Spanish menu.
        let spanish = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'Spanish'")).firstMatch
        if spanish.waitForExistence(timeout: 8) {
            spanish.tap()
            sleep(4)
            let library = app.buttons["Describe a photo from my library"].firstMatch
            if library.waitForExistence(timeout: 8) {
                library.tap()
                sleep(5)
                pickPhoto(app, index: 0)
                sleep(12)
                save("spanish-menu")
            }
            let back = app.buttons["Back"].firstMatch
            if back.waitForExistence(timeout: 5) { back.tap(); sleep(3) }
        }

        // "What's this?" — the mode that puts the answer on screen as well as
        // speaking it, so the shot shows the app having read something.
        let whats = app.buttons["What's this?"].firstMatch
        if whats.waitForExistence(timeout: 8) {
            whats.tap()
            sleep(4)
            let library = app.buttons["Describe a photo from my library"].firstMatch
            if library.waitForExistence(timeout: 8) {
                library.tap()
                sleep(5)
                pickPhoto(app, index: 1)
                sleep(14)
                save("whats-this")
            }
            let back = app.buttons["Back"].firstMatch
            if back.waitForExistence(timeout: 5) { back.tap(); sleep(3) }
        }

        // The guide, which is the app explaining itself.
        let info = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'info' OR label CONTAINS[c] 'guide'")).firstMatch
        if info.waitForExistence(timeout: 5) {
            info.tap()
            sleep(3)
            save("guide")
        }
    }

    /// The photo picker runs in its own process; try the app's own tree first,
    /// then springboard-level queries, then a plain coordinate tap.
    private func pickFirstPhoto(_ app: XCUIApplication) { pickPhoto(app, index: 0) }

    /// The picker is a remote view, so its cells are not in the app's element
    /// tree. The thumbnails land on a fixed grid in the sheet; tap the slot.
    private func pickPhoto(_ app: XCUIApplication, index: Int) {
        let columns: [CGFloat] = [0.449, 0.537, 0.625, 0.713, 0.801]
        let x = columns[min(index, columns.count - 1)]
        app.coordinate(withNormalizedOffset: CGVector(dx: x, dy: 0.447)).tap()
    }
}
