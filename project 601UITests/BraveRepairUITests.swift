//
//  BraveRepairUITests.swift
//  Matt's Brave lost its top address bar and favorites on 2026-09-16, most likely
//  from stray taps by the Settings sweep. Step one only reads the screen.
//

import XCTest

final class BraveRepairUITests: XCTestCase {
    let brave = XCUIApplication(bundleIdentifier: "com.brave.ios.browser")

    @MainActor
    func testDumpBrave() throws {
        brave.activate() // bring it forward as it is; launch() would reset it
        sleep(3)
        print("BRAVE_DUMP_START\n\(brave.debugDescription)\nBRAVE_DUMP_END")
    }
}

extension BraveRepairUITests {
    func dump(_ tag: String) {
        print("BRAVE_\(tag)_START\n\(brave.debugDescription)\nBRAVE_\(tag)_END")
    }

    @MainActor
    func testOpenSettings() throws {
        brave.activate()
        sleep(2)
        XCTAssertEqual(brave.state, .runningForeground)
        brave.buttons["Menu"].firstMatch.tap()
        sleep(2)
        dump("MENU")
        let s = brave.buttons["All Settings"].firstMatch
        if s.waitForExistence(timeout: 5) { s.tap(); sleep(2) } else {
            let s2 = brave.staticTexts["Settings"].firstMatch
            if s2.waitForExistence(timeout: 3) { s2.tap(); sleep(2) }
        }
        dump("SETTINGS")
    }
}

extension BraveRepairUITests {
    private func openSettings() {
        brave.activate()
        sleep(2)
        // Already somewhere inside Settings: back out to its first page.
        for _ in 0..<4 {
            let back = brave.buttons["BackButton"].firstMatch
            guard back.exists, back.label == "Settings" || back.label == "Back" else { break }
            back.tap(); sleep(1)
        }
        if brave.staticTexts["Display"].exists || brave.staticTexts["Shields & Privacy"].exists { return }
        brave.buttons["Menu"].firstMatch.tap()
        let s = brave.buttons["All Settings"].firstMatch
        XCTAssertTrue(s.waitForExistence(timeout: 5))
        s.tap()
        sleep(2)
    }

    private func scrollTo(_ el: XCUIElement) {
        for _ in 0..<12 where !(el.exists && el.isHittable) {
            guard brave.state == .runningForeground else { return }
            brave.swipeUp()
        }
    }

    @MainActor
    func testTopBarAndNTP() throws {
        openSettings()
        let top = brave.staticTexts["Top Bar"].firstMatch
        scrollTo(top)
        guard brave.state == .runningForeground else { return XCTFail("Brave not in front") }
        top.tap()
        sleep(2)
        dump("AFTERTOP")
        let ntp = brave.staticTexts["New Tab Page"].firstMatch
        for _ in 0..<12 where !(ntp.exists && ntp.isHittable) { brave.swipeDown() }
        ntp.tap()
        sleep(2)
        dump("NTP")
    }
}

extension BraveRepairUITests {
    @MainActor
    func testShowBookmarks() throws {
        brave.activate()
        sleep(1)
        for _ in 0..<4 {
            let back = brave.buttons["BackButton"].firstMatch
            guard back.exists else { break }
            back.tap(); sleep(1)
        }
        let done = brave.buttons["Done"].firstMatch
        if done.exists { done.tap(); sleep(1) } // close Settings
        brave.buttons["Menu"].firstMatch.tap()
        sleep(1)
        let all = brave.buttons["Show All…"].firstMatch
        if all.waitForExistence(timeout: 3) { all.tap(); sleep(2) }
        dump("ALLMENU")
        let bm = brave.buttons.matching(NSPredicate(format: "label ==[c] 'Bookmarks'")).firstMatch
        if bm.waitForExistence(timeout: 3) { bm.tap(); sleep(2) }
        dump("BOOKMARKS")
    }
}
