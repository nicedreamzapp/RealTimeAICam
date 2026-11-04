//
//  GuideUITests.swift
//  INFO GUIDE matches the home screen (2026-11-03): every tool is a heading.
//

import XCTest

final class GuideUITests: XCTestCase {
    private func keep(_ shot: XCUIScreenshot, _ name: String) {
        let a = XCTAttachment(screenshot: shot)
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }

    @MainActor
    func testGuideHasEveryTool() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-hasShownInstructions", "YES"]
        app.launch()
        let info = app.buttons["Info and guide"].firstMatch
        XCTAssertTrue(info.waitForExistence(timeout: 20))
        sleep(3)
        info.tap()
        XCTAssertTrue(app.buttons["Play full audio tutorial"].firstMatch.waitForExistence(timeout: 10))
        keep(app.screenshot(), "guide-1")
        let headers = app.staticTexts.matching(NSPredicate(format: "label IN %@",
            ["Read", "Object Detection", "What's this?", "Help Me Aim", "Live Cam", "Settings"]))
        app.swipeUp(); keep(app.screenshot(), "guide-2")
        app.swipeUp(); keep(app.screenshot(), "guide-3")
        app.swipeUp(); keep(app.screenshot(), "guide-4")
        // The home screen behind the sheet has the same words, so count only
        // elements VoiceOver treats as headings.
        let found = Set(headers.allElementsBoundByIndex.filter(\.isHeader).map(\.label))
        XCTAssertEqual(found, ["Read", "Object Detection", "What's this?", "Help Me Aim", "Live Cam", "Settings"],
                       "tool headings in the guide")
    }
}

private extension XCUIElement {
    var isHeader: Bool { (value(forKey: "traits") as? UInt64).map { $0 & UIAccessibilityTraits.header.rawValue != 0 } ?? false }
}
