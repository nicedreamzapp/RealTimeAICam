//
//  DuoLiveFoldUITests.swift
//  The home screen through a live fold on the iPhone Duo (Matt, 2026-11-04: "test on
//  duo... always on any app"). Starts on whatever the sim is showing, then waits for the
//  window to change size twice (fold, unfold) and measures the home after each change.
//  The fold itself comes from outside: ~/Scripts/duo-fold/live-fold-test.sh drives the
//  hinge while this runs. Skipped unless the runner has DUO_LIVE_FOLD=1
//  (TEST_RUNNER_DUO_LIVE_FOLD=1 on the xcodebuild line).
//

import XCTest

final class DuoLiveFoldUITests: XCTestCase {
    private let tools = ["Read", "Object Detection", "What's this?", "Help Me Aim", "Live Cam, experimental"]

    private func keep(_ shot: XCUIScreenshot, _ name: String) {
        let a = XCTAttachment(screenshot: shot)
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }

    @MainActor
    private func measure(_ app: XCUIApplication, _ name: String) {
        sleep(3) // let the relayout settle
        keep(app.screenshot(), name)
        let screen = app.windows.firstMatch.frame
        let pills = ["Settings", "Info and guide"].map { app.buttons[$0].firstMatch.frame }
        let frames = tools.map { ($0, app.buttons[$0].firstMatch.frame) }
        let wide = screen.width > screen.height * 1.2 // unfolded: tools in a right-hand column
        let column = wide ? frames[0].1.midX : screen.midX
        for (n, f) in frames {
            XCTAssertEqual(f.midX, column, accuracy: 2, "\(name): \(n) not centered (\(f) in \(screen))")
            if wide { XCTAssertLessThanOrEqual(f.maxY, screen.maxY, "\(name): \(n) cut off at the bottom") }
            XCTAssertGreaterThanOrEqual(f.height, 56, "\(name): \(n) only \(f.height) pt tall")
            XCTAssertGreaterThanOrEqual(f.minX, screen.minX, "\(name): \(n) off the left edge")
            XCTAssertLessThanOrEqual(f.maxX, screen.maxX, "\(name): \(n) off the right edge")
        }
        for k in 1 ..< frames.count {
            XCTAssertGreaterThanOrEqual(frames[k].1.minY - frames[k - 1].1.maxY, 8,
                                        "\(name): \(frames[k - 1].0) to \(frames[k].0) gap")
        }
        let pillsMid = (pills[0].minX + pills[1].maxX) / 2
        if wide {
            XCTAssertEqual(pillsMid + column, screen.minX + screen.maxX, accuracy: 4, "\(name): columns not mirrored")
        } else {
            XCTAssertEqual(pillsMid, screen.midX, accuracy: 3, "\(name): top pills not centered")
        }
        XCTAssertFalse(pills[0].intersects(pills[1]), "\(name): top pills overlap")
        print("FOLDLAYOUT \(name) \(screen.size) " + frames.map { "\($0.0)=\(Int($0.1.minX))-\(Int($0.1.maxX))" }.joined(separator: " "))
    }

    @MainActor
    private func waitForSizeChange(_ app: XCUIApplication, from size: CGSize, _ what: String) -> CGSize {
        // The hinge animates through in-between sizes; wait until the new size
        // has held for 3 seconds.
        let deadline = Date().addingTimeInterval(120)
        var last = size, held = 0
        while Date() < deadline {
            let now = app.windows.firstMatch.frame.size
            if now == last { held += 1 } else { last = now; held = 0 }
            if now != size && held >= 3 { return now }
            sleep(1)
        }
        XCTFail("window never changed size for \(what)")
        return size
    }

    @MainActor
    func testHomeSurvivesLiveFold() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["DUO_LIVE_FOLD"] == "1", "only for the Duo live-fold script")
        let app = XCUIApplication()
        app.launchArguments += ["-hasShownInstructions", "YES"]
        app.launch()
        XCTAssertTrue(app.buttons[T("Settings")].firstMatch.waitForExistence(timeout: 20), "home did not load")
        sleep(4) // buttons animate in
        let start = app.windows.firstMatch.frame.size
        measure(app, "start")
        print("FOLDREADY") // the script folds once it sees the app up
        let mid = waitForSizeChange(app, from: start, "the first fold")
        measure(app, "after-fold-1")
        let end = waitForSizeChange(app, from: mid, "the second fold")
        XCTAssertEqual(end, start, "the second fold should bring back the starting size")
        measure(app, "after-fold-2")
    }
}
