//
//  HelpMeAimVoiceUITests.swift
//  Live scenario runs of Help Me Aim on Matt's phone (dev install). Each test
//  is run on its own with -only-testing while the Mac says a word out loud
//  nearby (`say`), timed from the shell. Phrases and timing are checked
//  afterwards in Documents/HelpMeAimShots/speech-log.txt (dev-only log).
//

import XCTest

final class HelpMeAimVoiceUITests: XCTestCase {
    private let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = true
        app = XCUIApplication()
        app.launchArguments += ["-hasShownInstructions", "YES"]
    }

    private func log(_ s: String) { print("VOICE-TEST: \(s) at \(Date())") }

    private func allowAlerts() {
        for label in ["Allow Full Access", "Allow Access", "Allow", "OK"] {
            let b = springboard.buttons[label].firstMatch
            if b.exists { b.tap(); return }
        }
    }

    private func snap(_ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot())
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }

    /// Polls once a second (tapping through permission alerts).
    @discardableResult
    private func waitFor(_ e: XCUIElement, _ seconds: Int) -> Bool {
        for _ in 0 ..< seconds {
            allowAlerts()
            if e.exists { return true }
            sleep(1)
        }
        return e.exists
    }

    private func idle(_ seconds: Int) {
        for _ in 0 ..< seconds { allowAlerts(); sleep(1) }
    }

    private func camera(_ name: String) -> XCUIElement {
        app.descendants(matching: .any)["Camera, looking for \(name)"].firstMatch
    }

    private var listening: XCUIElement { app.buttons["Listening, tap to stop"].firstMatch }
    private var retry: XCUIElement { app.buttons["Tap to speak"].firstMatch }
    private var takeAnother: XCUIElement { app.buttons["Take Another"].firstMatch }

    private func openHelpMeAim() {
        app.launch()
        let home = app.buttons["Help Me Aim"].firstMatch
        XCTAssertTrue(home.waitForExistence(timeout: 20), "Help Me Aim home button not found")
        sleep(3)
        home.tap()
        log("opened Help Me Aim")
    }

    private func openSomethingElse() {
        openHelpMeAim()
        let other = app.buttons["Something Else"].firstMatch
        XCTAssertTrue(other.waitForExistence(timeout: 10), "Something Else not found")
        other.tap()
        log("tapped Something Else")
    }

    /// Speaks-in scenario: wait for listening, then for the steering screen.
    private func expectSteering(for name: String, listenTimeout: Int = 25, steerTimeout: Int = 15) -> Bool {
        let heard = waitFor(listening, listenTimeout)
        log("listening seen = \(heard)")
        let steering = waitFor(camera(name), steerTimeout)
        snap("after listening (\(name))")
        log("steering for \(name) = \(steering), retry visible = \(retry.exists)")
        return steering
    }

    private func waitForShot(_ seconds: Int) -> Bool {
        let shot = waitFor(takeAnother, seconds)
        snap("end")
        log("shot taken = \(shot)")
        return shot
    }

    // A) Mac says "dog".
    @MainActor
    func testA_sayDog() throws {
        openSomethingElse()
        XCTAssertTrue(expectSteering(for: "a dog"), "no steering for a dog")
        _ = waitForShot(60)
        XCTAssertEqual(app.state, .runningForeground)
    }

    // B) Silence first, then Tap to Speak and "dog".
    @MainActor
    func testB_silenceThenRetry() throws {
        openSomethingElse()
        XCTAssertTrue(waitFor(listening, 25), "never listened")
        log("first listen started (should hear nothing)")
        let gaveUp = waitFor(retry, 15)
        log("retry button after silence = \(gaveUp)")
        snap("after silence")
        XCTAssertTrue(gaveUp, "no retry state after silence")
        sleep(4) // let "I didn't hear anything…" finish
        retry.tap()
        log("tapped Tap to Speak")
        XCTAssertTrue(expectSteering(for: "a dog"), "retry did not reach steering for a dog")
        idle(5)
    }

    // C) "wallet" is not in the vocabulary.
    @MainActor
    func testC_sayWallet() throws {
        openSomethingElse()
        let heard = waitFor(listening, 25)
        log("listening seen = \(heard)")
        XCTAssertTrue(heard, "never listened")
        idle(12)
        snap("after wallet")
        let steering = app.descendants(matching: .any).matching(
            NSPredicate(format: "label BEGINSWITH 'Camera, looking for'")).firstMatch.exists
        log("steering = \(steering), retry visible = \(retry.exists)")
        XCTAssertFalse(steering, "should not steer for wallet")
        XCTAssertTrue(retry.exists, "should be back on the ask screen")
    }

    // D) "umbrella", not in the room: expect the "I can see" line by ~15 s.
    @MainActor
    func testD_sayUmbrella() throws {
        openSomethingElse()
        XCTAssertTrue(expectSteering(for: "an umbrella"), "no steering for an umbrella")
        idle(24)
        snap("umbrella after 24s")
        log("shot taken = \(takeAnother.exists)")
    }

    // E) "the dogs".
    @MainActor
    func testE_sayTheDogs() throws {
        openSomethingElse()
        XCTAssertTrue(expectSteering(for: "a dog"), "no steering for a dog from 'the dogs'")
        idle(5)
    }

    // F) Type "laptop".
    @MainActor
    func testF_typeLaptop() throws {
        openSomethingElse()
        // Typing stops the listening; the prompt may still be speaking.
        let field = app.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        sleep(2)
        field.tap()
        field.typeText("laptop")
        app.buttons["Find"].firstMatch.tap()
        log("typed laptop")
        let steering = waitFor(camera("a laptop"), 10)
        log("steering for a laptop = \(steering)")
        XCTAssertTrue(steering)
        _ = waitForShot(30)
    }

    // G) Face, front camera.
    @MainActor
    func testG_faceFrontCamera() throws {
        openHelpMeAim()
        let face = app.buttons["Face"].firstMatch
        XCTAssertTrue(face.waitForExistence(timeout: 10))
        face.tap()
        let steering = waitFor(camera("a face"), 10)
        log("steering for a face = \(steering)")
        XCTAssertTrue(steering)
        let flip = app.buttons["Switch to front camera"].firstMatch
        if waitFor(flip, 5) { flip.tap(); log("switched to front camera") } else { log("no camera switch button") }
        _ = waitForShot(30)
    }

    // H) Background and back mid-steering.
    @MainActor
    func testH_backgroundAndBack() throws {
        openSomethingElse()
        let field = app.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        sleep(2)
        field.tap()
        field.typeText("umbrella")
        app.buttons["Find"].firstMatch.tap()
        XCTAssertTrue(waitFor(camera("an umbrella"), 10), "no steering before backgrounding")
        idle(4)
        XCUIDevice.shared.press(.home)
        log("pressed home")
        sleep(4)
        app.activate()
        log("activated, state \(app.state.rawValue)")
        idle(10)
        snap("after return")
        let steering = camera("an umbrella").exists
        log("steering after return = \(steering), state \(app.state.rawValue)")
        XCTAssertTrue(steering, "steering screen not back")
    }
}
