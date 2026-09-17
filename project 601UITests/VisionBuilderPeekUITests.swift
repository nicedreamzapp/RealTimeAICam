//
//  VisionBuilderPeekUITests.swift
//  Read-only: what is on Vision Builder's screen right now. Never taps.
//

import XCTest

final class VisionBuilderPeekUITests: XCTestCase {
    @MainActor
    func testPeek() throws {
        let app = XCUIApplication(bundleIdentifier: "B9RA6QH559.Vision-Builder")
        print("PEEK state=\(app.state.rawValue)")
        for e in app.staticTexts.allElementsBoundByIndex.prefix(12) { print("PEEK text: \(e.label)") }
        for e in app.buttons.allElementsBoundByIndex.prefix(12) { print("PEEK button: \(e.label)") }
    }
}
