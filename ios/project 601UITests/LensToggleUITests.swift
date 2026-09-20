//
//  LensToggleUITests.swift
//  The wide angle button only does something on a phone with a second rear
//  lens. Matt on AppleVis (iPhone 16e, comment 215716, 2026-09-17) tapped it,
//  heard the label change and got the same picture, because the app quietly
//  fell back to the one lens the phone has.
//
//  Nobody here owns a single-rear-camera phone — but the simulator is one:
//  it reports no ultra-wide device at all. So these tests ask the hardware
//  they are running on and then demand the matching interface. Green on the
//  simulator proves the button and its descriptions disappear; green on
//  Matt's iPhone proves they are still there for everyone else.
//

import AVFoundation
import XCTest

final class LensToggleUITests: XCTestCase {
    private var hasUltraWide: Bool {
        AVCaptureDevice.default(.builtInUltraWideCamera, for: .video, position: .back) != nil
    }

    private func lensText(_ app: XCUIApplication) -> XCUIElement {
        app.staticTexts.containing(
            NSPredicate(format: "label CONTAINS[c] 'ultra-wide' OR label CONTAINS[c] 'Lens Toggle'")
        ).firstMatch
    }

    /// The guide is where a blind user learns which controls exist, so it must
    /// never list one this phone does not have.
    @MainActor
    func testGuideListsTheLensToggleOnlyWhenThePhoneHasOne() throws {
        let app = XCUIApplication()
        app.launch()

        let info = app.buttons["Info and guide"].firstMatch
        XCTAssertTrue(info.waitForExistence(timeout: 30), "no info button on home")
        info.tap()
        XCTAssertTrue(
            app.buttons["Play full audio tutorial"].firstMatch.waitForExistence(timeout: 15),
            "the guide did not open"
        )

        // An absence only means something once the list is on screen, so anchor
        // on the line next to it first.
        let torchLine = app.staticTexts.containing(
            NSPredicate(format: "label CONTAINS[c] 'Torch'")
        ).firstMatch
        XCTAssertTrue(torchLine.waitForExistence(timeout: 10), "the Controls list never rendered")

        if hasUltraWide {
            XCTAssertTrue(
                lensText(app).waitForExistence(timeout: 5),
                "this phone has an ultra-wide lens, so the guide should still list the toggle"
            )
        } else {
            XCTAssertFalse(
                lensText(app).exists,
                "one rear lens: the guide must not promise a lens toggle that isn't there"
            )
        }

        let done = app.buttons["Done"].firstMatch
        if done.waitForExistence(timeout: 5) { done.tap() }
    }

    /// The button itself, in Object Detection — the only screen that has it.
    @MainActor
    func testObjectDetectionShowsTheLensButtonOnlyWhenThePhoneHasOne() throws {
        let app = XCUIApplication()
        app.launch()

        let od = app.buttons["Object Detection"].firstMatch
        XCTAssertTrue(od.waitForExistence(timeout: 30), "no Object Detection button on home")
        od.tap()
        sleep(5)

        let wide = app.buttons.matching(
            NSPredicate(format: "label CONTAINS[c] 'wide angle camera' OR label CONTAINS[c] 'Switch to normal camera'")
        ).firstMatch

        // The lens button sits next to the camera flip in the same bar. If the
        // flip is there, the bar drew, and a missing lens button is a decision
        // rather than a screen that never appeared.
        let flip = app.buttons["Switch Camera"].firstMatch
        XCTAssertTrue(flip.waitForExistence(timeout: 20), "the control bar never rendered")

        if hasUltraWide {
            XCTAssertTrue(wide.waitForExistence(timeout: 10), "an ultra-wide phone should still get the lens button")
        } else {
            XCTAssertFalse(wide.exists, "one rear lens: VoiceOver must not find a lens button at all")
        }
    }

    /// The tips inside the What's this? settings sheet. That screen has no lens
    /// control on any phone, which is what sent Matt looking for one.
    @MainActor
    func testWhatsThisSettingsTipsNeverMentionTheLens() throws {
        let app = XCUIApplication()
        app.launch()

        let wt = app.buttons["What's this?"].firstMatch
        XCTAssertTrue(wt.waitForExistence(timeout: 30), "no What's this? button on home")
        wt.tap()

        let settings = app.buttons["Settings"].firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 20), "no Settings button on the What's this? screen")
        settings.tap()
        sleep(2)

        let tipsAnchor = app.staticTexts.containing(
            NSPredicate(format: "label CONTAINS[c] 'flashlight' OR label CONTAINS[c] 'Pinch'")
        ).firstMatch
        XCTAssertTrue(tipsAnchor.waitForExistence(timeout: 10), "the tips list never rendered")

        XCTAssertFalse(
            lensText(app).exists,
            "the What's this? tips listed a lens toggle this screen does not have"
        )
    }
}
