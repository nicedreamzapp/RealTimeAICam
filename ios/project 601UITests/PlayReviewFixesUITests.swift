//
//  PlayReviewFixesUITests.swift
//  Two fixes from a Play review (2026-11-04): a new install opens Read in Auto read,
//  and a phone with its volume all the way down says so on screen.
//

import XCTest

final class PlayReviewFixesUITests: XCTestCase {
    private func launch(_ extra: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-hasShownInstructions", "YES", "-readerLanguageMode", "english"] + extra
        app.launch()
        return app
    }

    private func screenshot(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    @MainActor
    func testFreshInstallReadsAuto() throws {
        continueAfterFailure = false
        let app = launch(["-rtcamFreshReadMode"])
        let read = app.buttons["Read"].firstMatch
        XCTAssertTrue(read.waitForExistence(timeout: 30), "no Read on home")
        read.tap()
        let button = app.buttons["readModeButton"].firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 15), "no read mode button")
        XCTAssertEqual(button.value as? String, "Auto read", "a new install should start in Auto read")
        screenshot(app, "fresh-install-read-auto")
        app.terminate()
    }

    @MainActor
    func testVolumeZeroShowsNote() throws {
        continueAfterFailure = false
        let app = launch(["-rtcamFakeVolumeZero"])
        let note = app.buttons["volumeOffNote"].firstMatch
        XCTAssertTrue(note.waitForExistence(timeout: 20), "no volume note with the volume at 0")
        XCTAssertEqual(note.label, "Volume is off. Turn it up to hear the app.")
        screenshot(app, "volume-off-note-home")
        // Still there on the Read screen, and the camera screen still works under it.
        let read = app.buttons["Read"].firstMatch
        if read.waitForExistence(timeout: 10), read.isHittable {
            read.tap()
            XCTAssertTrue(app.buttons["readModeButton"].firstMatch.waitForExistence(timeout: 15))
            XCTAssertTrue(app.buttons["volumeOffNote"].firstMatch.exists)
            screenshot(app, "volume-off-note-read")
        }
        // Tapping the note hides it.
        app.buttons["volumeOffNote"].firstMatch.tap()
        XCTAssertFalse(app.buttons["volumeOffNote"].firstMatch.waitForExistence(timeout: 3))
        app.terminate()
    }

    @MainActor
    func testNoNoteWithVolumeUp() throws {
        let app = launch([])
        XCTAssertTrue(app.buttons["Read"].firstMatch.waitForExistence(timeout: 30))
        XCTAssertFalse(app.buttons["volumeOffNote"].firstMatch.exists)
        app.terminate()
    }
}
