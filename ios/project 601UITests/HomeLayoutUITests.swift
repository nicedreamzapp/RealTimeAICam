//
//  HomeLayoutUITests.swift
//  The home screen, measured instead of eyeballed (Matt, 2026-11-03: "buttons
//  cross over each other, did you look at all"). On every phone size: no two
//  controls overlap, every gap is at least 8 pt, every control is centered and
//  on screen (or reachable by scrolling), and VoiceOver's swipe order runs top
//  to bottom: Settings, Info, the five tools, the voice.
//

import XCTest

final class HomeLayoutUITests: XCTestCase {
    private let order = ["Settings", "Info and guide", "Read", "Object Detection", "What's this?",
                         "Help Me Aim", "Live Cam, experimental"].map { T($0) }

    private func keep(_ shot: XCUIScreenshot, _ name: String) {
        let a = XCTAttachment(screenshot: shot)
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }

    @MainActor
    func testHomeNeverOverlapsAndIsCentered() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-hasShownInstructions", "YES"]
        app.launch()
        let first = app.buttons[T("Settings")].firstMatch
        XCTAssertTrue(first.waitForExistence(timeout: 20), "home did not load")
        sleep(4) // buttons animate in
        keep(app.screenshot(), "home")
        let screen = app.windows.firstMatch.frame

        let items = order.map { app.buttons[$0].firstMatch }
        for (name, el) in zip(order, items) { XCTAssertTrue(el.exists, "\(name) missing") }
        let voice = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", TestLanguage.isSpanish ? "voz" : "voice")).firstMatch
        var frames = zip(order, items).map { ($0, $1.frame) }
        if voice.exists { frames.append(("Voice", voice.frame)) }

        // No overlaps, real gaps between the stacked tools.
        for i in 0 ..< frames.count {
            for j in (i + 1) ..< frames.count {
                let (a, fa) = frames[i], (b, fb) = frames[j]
                XCTAssertFalse(fa.insetBy(dx: 1, dy: 1).intersects(fb.insetBy(dx: 1, dy: 1)),
                               "\(a) \(fa) overlaps \(b) \(fb)")
            }
        }
        let tools = frames.filter { order.dropFirst(2).contains($0.0) || $0.0 == "Voice" }
        for k in 1 ..< tools.count {
            let gap = tools[k].1.minY - tools[k - 1].1.maxY
            XCTAssertGreaterThanOrEqual(gap, 8, "\(tools[k - 1].0) to \(tools[k].0) gap is \(gap) pt")
        }
        // Centered, equal width, big enough to land a finger on.
        // Wide screens (unfolded iPhone Duo): pills + title on the left, tools on
        // the right, the two columns mirror each other and nothing needs a scroll.
        let wide = screen.width > screen.height * 1.2
        let toolFrames = tools.filter { $0.0 != "Voice" }
        let column = wide ? toolFrames[0].1.midX : screen.midX
        for (name, f) in toolFrames {
            XCTAssertEqual(f.midX, column, accuracy: 2, "\(name) not centered")
            XCTAssertGreaterThanOrEqual(f.height, 56, "\(name) only \(f.height) pt tall")
            XCTAssertEqual(f.width, toolFrames[0].1.width, accuracy: 1, "\(name) width differs")
        }
        let pills = frames.prefix(2).map(\.1)
        let pillsMid = (pills[0].minX + pills[1].maxX) / 2
        if wide {
            XCTAssertEqual(pillsMid + column, screen.minX + screen.maxX, accuracy: 4, "columns not mirrored")
            XCTAssertLessThan(pills[1].maxX, toolFrames[0].1.minX, "pills run into the tools")
            for (name, f) in tools { XCTAssertLessThanOrEqual(f.maxY, screen.maxY, "\(name) cut off at the bottom") }
        } else {
            XCTAssertEqual(pillsMid, screen.midX, accuracy: 3, "top pills not centered")
        }

        // Swipe order: top to bottom, in the same order as on screen.
        // Settings and Info share the top row (left, then right); the rest stack.
        XCTAssertLessThan(frames[0].1.midX, frames[1].1.midX, "Settings should be left of Info")
        if !wide {
            XCTAssertLessThan(max(frames[0].1.maxY, frames[1].1.maxY), frames[2].1.minY, "top row must sit above Read")
        }
        let ys = frames.dropFirst(2).map(\.1.minY)
        XCTAssertEqual(ys, ys.sorted(), "on-screen order is not \(frames.map(\.0))")
        let treeOrder = app.buttons.allElementsBoundByIndex.map(\.label).filter { order.contains($0) }
        XCTAssertEqual(treeOrder, order, "VoiceOver order")
        print("LAYOUT \(screen.size) " + frames.map { "\($0.0)=\(Int($0.1.minY))-\(Int($0.1.maxY))" }.joined(separator: " "))
    }
}
