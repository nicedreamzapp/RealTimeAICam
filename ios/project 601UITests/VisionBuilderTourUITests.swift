//
//  VisionBuilderTourUITests.swift
//  Screenshots every Vision Builder tab on Matt's iPhone for a UI review.
//  Element taps only, inside Vision Builder; stops if the app leaves the front.
//  Never presses the cleanup sheet's delete button, only "Not now".
//

import XCTest

final class VisionBuilderTourUITests: XCTestCase {
    @MainActor
    func testTourTabs() throws {
        let app = XCUIApplication(bundleIdentifier: "B9RA6QH559.Vision-Builder")
        app.launch()
        sleep(4)
        func shot(_ name: String) {
            let a = XCTAttachment(screenshot: app.screenshot()); a.name = name; a.lifetime = .keepAlways; add(a)
        }
        shot("00-launch")
        let notNow = app.buttons["Not now"].firstMatch
        if notNow.exists { notNow.tap(); sleep(2) }
        let tabs = app.tabBars.buttons
        for n in tabs.allElementsBoundByIndex.map({ $0.label }) {
            guard app.state == .runningForeground else { return }
            tabs[n].tap(); sleep(3)
            shot("tab-\(n)")
        }
        tabs["My Things"].tap(); sleep(2)
        let card = app.staticTexts["Theo"].firstMatch
        if card.waitForExistence(timeout: 5) { card.tap(); sleep(3); shot("folder-Theo") }
    }
}
