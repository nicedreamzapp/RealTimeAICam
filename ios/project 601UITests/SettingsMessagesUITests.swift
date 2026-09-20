//
//  SettingsMessagesUITests.swift
//  Drives the Settings app (not ours) on Matt's iPhone to delete every Messages
//  attachment. Matt, 2026-09-16: "Any attachments should all be deleted", texts stay.
//  Settings > General > iPhone Storage > Messages > Photos / Videos / GIFs / Other,
//  Edit, select what is on screen, Delete, repeat until the list is empty.
//

import XCTest

final class SettingsMessagesUITests: XCTestCase {
    let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")

    override func setUp() { continueAfterFailure = true }

    private func tapCell(_ label: String) {
        let c = settings.cells.containing(.staticText, identifier: label).firstMatch
        if !c.waitForExistence(timeout: 8) {
            for _ in 0..<8 where !c.exists { settings.swipeUp() }
        }
        XCTAssertTrue(c.waitForExistence(timeout: 20), "no cell \(label)")
        c.tap()
    }

    private func openMessagesStorage() {
        settings.launch()
        sleep(5) // the accessibility server needs a moment after a fresh launch
        tapCell("General")
        tapCell("iPhone Storage")
        let row = settings.buttons["ApplicationRow-com.apple.MobileSMS"]
        let sort = settings.buttons["ApplicationListSortingMenu"]
        _ = sort.waitForExistence(timeout: 60) // iOS measures every app first
        for _ in 0..<40 where !(row.exists && row.isHittable) { settings.swipeUp() }
        XCTAssertTrue(row.exists, "no Messages row")
        row.tap()
        sleep(4)
    }

    /// Row centers on screen, from one snapshot (querying elements one by one is slow).
    /// In Edit mode tapping a row selects it.
    private func visibleRows() -> [CGPoint] {
        guard let snap = try? settings.snapshot() else { return [] }
        let screen = snap.frame
        var pts: [CGPoint] = []
        func walk(_ e: XCUIElementSnapshot) {
            if e.elementType == .cell {
                let f = e.frame
                if f.height > 30 && f.minY > 120 && f.maxY < screen.maxY - 40 && f.width > 200 {
                    pts.append(CGPoint(x: f.midX, y: f.midY))
                }
                return
            }
            e.children.forEach(walk)
        }
        walk(snap)
        return pts
    }

    private func tap(_ p: CGPoint) {
        settings.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: p.x, dy: p.y)).tap()
    }

    private func clear(category: String) -> Int {
        let cat = settings.buttons[category].firstMatch
        for _ in 0..<4 where !(cat.exists && cat.isHittable) { settings.swipeUp() }
        guard cat.exists else { print("SKIP \(category): not listed"); return 0 }
        print("SIZE \(cat.label)")
        cat.tap()
        sleep(3)
        var deleted = 0
        var stuck = 0
        while stuck < 3 {
            let edit = settings.buttons["Edit"].firstMatch
            if edit.waitForExistence(timeout: 4) { edit.tap(); sleep(1) }
            // Coordinate taps hit whatever app is in front. If Matt picked the phone
            // up and opened something else, stop dead (Brave, 2026-09-16).
            guard settings.state == .runningForeground else {
                print("STOPPED: Settings is not in front")
                XCTFail("Settings left the foreground; stopping so no tap lands in another app")
                return deleted
            }
            let circles = visibleRows()
            if circles.isEmpty { stuck += 1; settings.buttons["Cancel"].firstMatch.tap(); sleep(1); continue }
            // One tap per row: a drag down the checkmark column looked right but selected nothing.
            for c in circles { tap(c) }
            settings.navigationBars.buttons["Delete"].firstMatch.tap()
            sleep(1)
            sleep(2) // iOS deletes without asking
            deleted += circles.count
            stuck = 0
            if deleted >= 48 { return deleted } // Settings stalls after ~50 deletes; the loop script relaunches it
            print("PROGRESS \(category) \(deleted)")
        }
        print("CLEARED \(category) \(deleted)")
        settings.navigationBars.buttons.element(boundBy: 0).tap()
        sleep(2)
        return deleted
    }

    /// One test that keeps going: relaunch Settings every 48 deletions (it stalls
    /// after ~50), skipping the per-run xcodebuild start-up the old loop paid.
    @MainActor
    func testSweepUntilEmpty() throws {
        var total = 0
        var emptyPasses = 0
        let started = Date()
        while emptyPasses < 2 && Date().timeIntervalSince(started) < 3 * 3600 {
            if settings.state != .runningForeground && total > 0 {
                print("SWEEP_STOPPED \(total)"); return
            }
            openMessagesStorage()
            var n = 0
            for cat in ["Videos", "Photos", "GIFs and Stickers", "Other"] {
                n = clear(category: cat)
                if n > 0 { break }
            }
            total += n
            emptyPasses = n == 0 ? emptyPasses + 1 : 0
            print("SWEEP total=\(total) minutes=\(Int(Date().timeIntervalSince(started) / 60))")
        }
        print("SWEEP_DONE \(total)")
    }

    @MainActor
    func testDeleteAllAttachments() throws {
        openMessagesStorage()
        // One short pass per run: stop after the first category that had anything.
        for cat in ["Videos", "Photos", "GIFs and Stickers", "Other"] {
            let n = clear(category: cat)
            if n > 0 { print("ALL_DONE \(n)"); return }
        }
        print("ALL_DONE 0")
    }

    @MainActor
    func testPing() throws {
        settings.launch()
        sleep(3)
        print("PING state=\(settings.state.rawValue)")
        print("SET_DUMP_START\n\(settings.debugDescription.prefix(1500))\nSET_DUMP_END")
    }
}
