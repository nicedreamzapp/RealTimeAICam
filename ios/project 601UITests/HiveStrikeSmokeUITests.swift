//
//  HiveStrikeSmokeUITests.swift
//  Lives in this runner only because it is already signed for Matt's iPhone:
//  XCUIApplication(bundleIdentifier:) drives any installed app. Hive Strike is a
//  canvas game, so this taps its way in and plays blind, checking it stays alive.
//  Written 2026-09-16 after build 5 (1.4.0) crashed at launch on iOS 27.
//

import XCTest

final class HiveStrikeSmokeUITests: XCTestCase {
    @MainActor
    func testHiveStrikeLaunchPlayBackground() throws {
        let app = XCUIApplication(bundleIdentifier: "com.nicedreamz.hivestrike")
        app.launch()
        sleep(8)
        XCTAssertEqual(app.state, .runningForeground, "died on launch")
        let win = app.windows.firstMatch
        func tap(_ x: CGFloat, _ y: CGFloat) {
            win.coordinate(withNormalizedOffset: CGVector(dx: x, dy: y)).tap()
        }
        // Title screen, then play: tap around the middle and lower third, drag to steer.
        for i in 0..<30 {
            tap(0.5, i % 2 == 0 ? 0.55 : 0.75)
            if i % 3 == 0 {
                let a = win.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.8))
                let b = win.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.8))
                a.press(forDuration: 0.05, thenDragTo: b)
            }
            sleep(2)
            XCTAssertEqual(app.state, .runningForeground, "died during play, step \(i)")
        }
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.lifetime = .keepAlways; add(shot)
        XCUIDevice.shared.press(.home)
        sleep(3)
        app.activate()
        sleep(4)
        XCTAssertEqual(app.state, .runningForeground, "did not come back from background")
    }
}
