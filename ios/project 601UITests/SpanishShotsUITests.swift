import XCTest

/// Walks every main screen and saves a screenshot of each, plus every label VoiceOver would read,
/// for the Spanish review (2026-11-05). Only runs when the runner is given RTCAM_SHOTDIR
/// (`TEST_RUNNER_RTCAM_SHOTDIR=/tmp/... xcodebuild test ...`); the simulator's language decides
/// the language. Also fails if a button or text runs off the screen.
final class SpanishShotsUITests: XCTestCase {
    private var dir: URL!
    private var n = 0
    private var labels: [String] = []

    override func setUpWithError() throws {
        guard let d = ProcessInfo.processInfo.environment["RTCAM_SHOTDIR"], !d.isEmpty else {
            throw XCTSkip("only for the screenshot run")
        }
        dir = URL(fileURLWithPath: d)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        continueAfterFailure = true
    }

    private func save(_ app: XCUIApplication, _ name: String) {
        n += 1
        let file = String(format: "%02d-%@", n, name)
        try? XCUIScreen.main.screenshot().pngRepresentation.write(to: dir.appendingPathComponent(file + ".png"))
        // The unfolded Duo's inner display can't be shot from here: the runner script watches
        // this file and shoots the display itself.
        try? file.write(to: dir.appendingPathComponent("current.txt"), atomically: true, encoding: .utf8)
        if ProcessInfo.processInfo.environment["RTCAM_SLOWSHOT"] != nil { sleep(2) }
        let window = app.windows.firstMatch.frame
        labels.append("== \(file)")
        for kind in [XCUIElement.ElementType.button, .staticText, .switch, .textField] {
            for e in app.descendants(matching: kind).allElementsBoundByIndex.prefix(80) where e.exists {
                let f = e.frame
                let label = e.label
                guard !label.isEmpty, !f.isEmpty else { continue }
                labels.append("\(kind.rawValue)\t\(label)")
                // On screen means inside the window (a scroll view may hold more below: skip those).
                if f.minY >= window.minY, f.maxY <= window.maxY, e.isHittable {
                    XCTAssertTrue(f.minX >= window.minX - 1 && f.maxX <= window.maxX + 1,
                                  "LAYOUT \(file): '\(label)' runs off the side \(f) in \(window)")
                }
            }
        }
        try? labels.joined(separator: "\n").write(to: dir.appendingPathComponent("labels.txt"), atomically: true, encoding: .utf8)
    }

    private func tap(_ app: XCUIApplication, _ english: String, wait: TimeInterval = 6) -> Bool {
        // Exact label first: "Leer" must not hit "Leer la licencia".
        let b = app.buttons.matching(NSPredicate(format: "label == %@", T(english))).firstMatch
        guard b.waitForExistence(timeout: wait) else { return false }
        b.tap()
        return true
    }

    private func back(_ app: XCUIApplication) {
        for name in ["Back", "Done", "Close"] where tap(app, name, wait: 2) {
            sleep(2)
            return
        }
    }

    @MainActor
    func testWalkEveryScreen() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-rtcamFreshYourLanguage", "-rtcamFakeTranslator"]
        app.launch()
        sleep(4)
        save(app, "guide")
        let guide = app.scrollViews.firstMatch
        if guide.exists {
            guide.swipeUp(); sleep(1); save(app, "guide-more"); guide.swipeUp(); guide.swipeUp(); sleep(1); save(app, "guide-end")
            // Done scrolls with the guide: back to the top before closing it.
            for _ in 0..<5 { guide.swipeDown() }
            sleep(1)
        }
        back(app)
        save(app, "home")

        if tap(app, "Settings") {
            sleep(2)
            save(app, "settings")
            let sv = app.scrollViews.firstMatch
            for i in 1...2 where sv.exists { sv.swipeUp(); sleep(1); save(app, "settings-\(i)") }
            if !tap(app, "Close settings", wait: 3) { back(app) }
            sleep(2)
        }

        let voice = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", T("Voice, %@", "").trimmingCharacters(in: .whitespaces))).firstMatch
        if voice.waitForExistence(timeout: 3) { voice.tap(); sleep(2); save(app, "voices"); voice.tap(); sleep(1) }

        if tap(app, "Read") { sleep(4); save(app, "read"); back(app) }
        if tap(app, "Object Detection") { sleep(4); save(app, "object-detection"); back(app) }
        if tap(app, "What's this?") { sleep(4); save(app, "whats-this"); back(app) }
        if tap(app, "Help Me Aim") {
            sleep(3)
            save(app, "help-me-aim")
            if tap(app, "Something Else") { sleep(3); save(app, "help-me-aim-something-else"); back(app) }
            back(app)
        }
        if tap(app, "Live Cam, experimental") { sleep(4); save(app, "live-cam"); back(app) }
        sleep(1)
        save(app, "home-again")
    }
}
