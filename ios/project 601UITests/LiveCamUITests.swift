//
//  LiveCamUITests.swift
//  Live Cam from Home: open it, ask "What is in front of me?", get a spoken answer
//  (asserted on the words shown), then Back to Home. -liveCamTest (debug builds) puts
//  the bundled school-hallway photo in front of the camera and a typed box in place
//  of the mic, so nothing asks for permission and nothing is heard. The Simulator is
//  silent (SimulatorSilence); the Mac's volume is never touched.
//
//  testRealModelAnswers runs the real model the phone has (bundled Balanced, CPU in the
//  Simulator). The stand-in tests use RTCAM_FAKE_LIVE_ANSWER for the model so the rest
//  (Your language, layout, Back) is checked fast on every device.
//

import XCTest

final class LiveCamUITests: XCTestCase {
    private func keep(_ app: XCUIApplication, _ name: String) {
        let shot = app.screenshot()
        let a = XCTAttachment(screenshot: shot)
        a.name = name
        a.lifetime = .keepAlways
        add(a)
        // Also straight to the Mac for the report (Simulator only; the folder is the host's /tmp).
        let dir = ProcessInfo.processInfo.environment["LIVECAM_SHOTS"] ?? "/tmp/livecam"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let device = ProcessInfo.processInfo.environment["SIMULATOR_DEVICE_NAME"] ?? "device"
        try? shot.pngRepresentation.write(to: URL(fileURLWithPath: "\(dir)/\(device.replacingOccurrences(of: " ", with: "_"))-\(name).png"))
    }

    private func launch(_ extra: [String] = [], env: [String: String] = [:]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-hasShownInstructions", "YES", "-liveCamTest", "-rtcamFakeTranslator"] + extra
        app.launchEnvironment.merge(env) { $1 }
        app.launch()
        return app
    }

    private func caption(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "liveCamCaption").firstMatch
    }

    private func captionText(_ app: XCUIApplication) -> String {
        let c = caption(app)
        guard c.exists else { return "" }
        return (c.value as? String) ?? c.label
    }

    /// Opens Live Cam from Home and waits for the greeting.
    private func openLiveCam(_ app: XCUIApplication, greeting: String = TestLanguage.isSpanish ? "¡Hola!" : "Hey there",
                             spanish: Bool = TestLanguage.isSpanish) {
        let button = app.buttons[spanish ? TestLanguage.spanish("Live Cam, experimental") : "Live Cam, experimental"].firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 20), "no Live Cam button on Home")
        sleep(3) // buttons animate in
        if !button.isHittable { app.swipeUp() }
        button.tap()
        let greeted = NSPredicate { _, _ in self.captionText(app).contains(greeting) }
        expectation(for: greeted, evaluatedWith: NSObject())
        waitForExpectations(timeout: 180)
    }

    private func ask(_ app: XCUIApplication, _ q: String) {
        let field = app.textFields[T("liveCamTyped")].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10), "no typed question box")
        field.tap()
        field.typeText(q + "\n")
    }

    private func goBack(_ app: XCUIApplication, spanish: Bool = TestLanguage.isSpanish) {
        let l = { (e: String) in spanish ? TestLanguage.spanish(e) : e }
        let back = app.buttons[l("Back")].firstMatch
        XCTAssertTrue(back.waitForExistence(timeout: 10), "no Back button")
        XCTAssertGreaterThanOrEqual(back.frame.width, 56, "Back is smaller than 56 pt")
        back.tap()
        XCTAssertTrue(app.buttons[l("Live Cam, experimental")].firstMatch.waitForExistence(timeout: 15), "Back did not return Home")
    }

    /// Every control big enough, on screen, and not on top of another.
    private func checkLayout(_ app: XCUIApplication) {
        let screen = app.windows.firstMatch.frame
        let names = ["Back", "Mute microphone", "Flip camera"].map { T($0) }
        var frames: [(String, CGRect)] = []
        for n in names {
            let b = app.buttons[n].firstMatch
            XCTAssertTrue(b.exists, "\(n) missing")
            XCTAssertGreaterThanOrEqual(min(b.frame.width, b.frame.height), 56, "\(n) under 56 pt: \(b.frame)")
            XCTAssertTrue(screen.contains(b.frame), "\(n) off screen: \(b.frame) in \(screen)")
            frames.append((n, b.frame))
        }
        let mode = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", T("Mode"))).firstMatch
        XCTAssertTrue(mode.exists, "Mode missing")
        XCTAssertGreaterThanOrEqual(mode.frame.height, 56)
        XCTAssertTrue(screen.contains(mode.frame), "Mode off screen")
        frames.append(("Mode", mode.frame))
        for i in 0 ..< frames.count {
            for j in (i + 1) ..< frames.count {
                XCTAssertFalse(frames[i].1.intersects(frames[j].1), "\(frames[i].0) overlaps \(frames[j].0)")
            }
        }
    }

    /// The real model, the real photo: an answer that isn't the greeting.
    @MainActor
    func testRealModelAnswers() throws {
        continueAfterFailure = false
        let app = launch()
        openLiveCam(app)
        let greeting = captionText(app)
        ask(app, "What is in front of me?")
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "liveCamHeard").firstMatch.waitForExistence(timeout: 10),
                      "the question was not shown")
        let acks = ["Let me look.", "Okay.", "Hmm, one sec.", "Sure, looking.", "One moment.", "Let me see."].map { T($0) }
        let answered = NSPredicate { _, _ in
            let t = self.captionText(app)
            return !t.isEmpty && t != greeting && !acks.contains(t)
        }
        expectation(for: answered, evaluatedWith: NSObject())
        waitForExpectations(timeout: 600)
        sleep(4) // the rest of the answer
        let said = captionText(app)
        print("LIVECAM ANSWER: \(said)")
        XCTAssertGreaterThan(said.split(separator: " ").count, 2, "answer too short: \(said)")
        keep(app, "livecam-real-answer")
        goBack(app)
        app.terminate()
    }

    /// Model stood in: open, layout, ask, answer shown, Back. Screenshots for every device.
    @MainActor
    func testOpenAskAndBack() throws {
        continueAfterFailure = false
        let app = launch(env: ["RTCAM_FAKE_LIVE_ANSWER": "I see a blue double door with an exit sign above it."])
        openLiveCam(app)
        checkLayout(app)
        keep(app, "livecam-open")
        ask(app, "What is in front of me?")
        let answered = NSPredicate { _, _ in self.captionText(app).contains("blue double door") }
        expectation(for: answered, evaluatedWith: NSObject())
        waitForExpectations(timeout: 120)
        keep(app, "livecam-answer")
        // The mode menu opens, shows the four modes and the two switches, and closes on a pick.
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", T("Mode"))).firstMatch.tap()
        XCTAssertTrue(app.buttons[T("Funny mode")].firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.switches[T("Speak up when quiet")].firstMatch.exists)
        keep(app, "livecam-modes")
        app.buttons[T("Normal mode")].firstMatch.tap()
        checkLayout(app)
        goBack(app)
        app.terminate()
    }

    /// 11/04 review: speech recognition that keeps failing stops retrying, says so, and shows a note and a typing
    /// box. Both must be on screen and clear of the controls on every size.
    @MainActor
    func testCantHearNoteAndTypingBox() throws {
        continueAfterFailure = false
        let app = launch(["-liveCamCantHear"])
        openLiveCam(app, greeting: TestLanguage.isSpanish ? "no te oigo" : "can't hear you")
        let screen = app.windows.firstMatch.frame
        let note = app.descendants(matching: .any).matching(identifier: "liveCamCantHear").firstMatch
        XCTAssertTrue(note.waitForExistence(timeout: 10), "no can't-hear note")
        XCTAssertTrue(screen.contains(note.frame), "note off screen: \(note.frame) in \(screen)")
        let field = app.textFields[T("liveCamTyped")].firstMatch
        XCTAssertTrue(field.exists, "no typing box")
        XCTAssertTrue(screen.contains(field.frame), "typing box off screen: \(field.frame)")
        XCTAssertFalse(note.frame.intersects(field.frame), "note overlaps the typing box")
        for n in ["Back", "Mute microphone", "Flip camera"].map({ T($0) }) {
            let b = app.buttons[n].firstMatch
            XCTAssertFalse(note.frame.intersects(b.frame), "note overlaps \(n)")
            XCTAssertFalse(field.frame.intersects(b.frame), "typing box overlaps \(n)")
        }
        checkLayout(app)
        keep(app, "livecam-cant-hear")
        goBack(app)
        app.terminate()
    }

    /// Your language Spanish: the question goes to the model in English, the answer is shown and said in Spanish.
    @MainActor
    func testAnswerInYourLanguage() throws {
        continueAfterFailure = false
        let app = launch(["-userLanguage", "es", "-fakeTranslatorPacks", "(es)"],
                         env: ["RTCAM_FAKE_LIVE_ANSWER": "The cup is white."])
        // Your language Spanish makes the app Spanish: the greeting is the bundled Spanish line.
        openLiveCam(app, greeting: "¡Hola!", spanish: true)
        ask(app, "De que color es la taza")
        let answered = NSPredicate { _, _ in self.captionText(app).contains("La taza es blanca") }
        expectation(for: answered, evaluatedWith: NSObject())
        waitForExpectations(timeout: 120)
        keep(app, "livecam-spanish")
        goBack(app, spanish: true)
        app.terminate()
    }
}
