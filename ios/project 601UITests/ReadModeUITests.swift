//
//  ReadModeUITests.swift
//  Tap to read / Auto read / Mute (Matt, 2026-10-23). Cycles the small button
//  next to Speak through all three, checks the choice survives a relaunch, then
//  feeds the reader and the translator scripted, wobbling text (the simulator
//  has no camera) so Auto read can be judged from Documents/speak_log.txt.
//

import XCTest

final class ReadModeUITests: XCTestCase {
    private func openReader(_ app: XCUIApplication, _ name: String) -> XCUIElement {
        let home = app.buttons[name].firstMatch
        XCTAssertTrue(home.waitForExistence(timeout: 30), "no \(name) on home")
        home.tap()
        let button = app.buttons["readModeButton"].firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 15), "no read mode button in \(name)")
        return button
    }

    private func launch(_ env: [String: String] = [:]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-hasShownInstructions", "YES"]
        app.launchEnvironment.merge(env) { $1 }
        app.launch()
        return app
    }

    @MainActor
    func testCyclesPersistsAndAutoReads() throws {
        continueAfterFailure = false

        // 1. Cycle through all three, in order, label stays "Read mode".
        var app = launch()
        var button = openReader(app, "English Text to Speech")
        XCTAssertEqual(button.label, "Read mode")
        let order = ["Tap to read", "Auto read", "Mute"]
        var seen: [String] = [button.value as? String ?? ""]
        for _ in 0..<3 {
            button.tap()
            sleep(2)
            seen.append(button.value as? String ?? "")
        }
        print("READMODE_CYCLE \(seen)")
        let start = order.firstIndex(of: seen[0]) ?? -1
        XCTAssertNotEqual(start, -1, "unknown start value \(seen[0])")
        for i in 0..<4 { XCTAssertEqual(seen[i], order[(start + i) % 3], "step \(i)") }
        // Leave it on Auto read.
        while (button.value as? String) != "Auto read" { button.tap(); sleep(2) }

        // 2. Persists across a relaunch.
        app.terminate()
        app = launch()
        button = openReader(app, "English Text to Speech")
        XCTAssertEqual(button.value as? String, "Auto read", "mode did not survive relaunch")
        print("READMODE_PERSISTED \(button.value ?? "")")
        app.terminate()

        // 3. Auto read in the text reader, on wobbling scripted text.
        let wobble = [
            "0.5::Exit only, no parking", "0.6::Exit only no parking", "0.6::Exit only, no parkin",
            "0.6::no parking Exit only", "0.6::Exit only, no parking", "0.6::Exit only, no parking",
            "0.6::Restrooms downstairs on the left", "0.6::Restrooms downstairs on the left",
            "0.6::Restrooms downstair on the left", "0.6::Restrooms downstairs on the left",
            "0.3::Push to open", "0.3::Restrooms downstairs on the left", "0.3::Push to open",
            "0.3::Restrooms downstairs on the left", "0.3::Push to open", "0.3::Restrooms downstairs on the left",
            "0.6::Please wait here until your number is called. The pharmacist will help you at the counter on the right.",
            "0.6::Please wait here until your number is called. The pharmacist will help you at the counter on the right.",
            "0.6::Please wait here until your number is called. The pharmacist will help you at the counter on the right",
            "0.6::Thank you for shopping with us", "0.6::Thank you for shopping with us",
            "0.6::Thank you for shopping with us", "0.6::Thank you for shopping with us",
            "0.6::Thank you for shopping with us", "0.6::Thank you for shopping with us",
        ].joined(separator: "||")
        app = launch(["RTCAM_FAKE_OCR": wobble])
        _ = openReader(app, "English Text to Speech")
        sleep(30)
        XCTAssertEqual(app.state, .runningForeground)
        app.terminate()

        // 4. Auto read in the translator: the English is what gets said.
        let spanish = [
            "0.5::Salida de emergencia", "0.6::Salida de emergencia", "0.6::Salida de emergenc",
            "0.6::Salida de emergencia", "0.6::Salida de emergencia",
        ].joined(separator: "||") + "||" + Array(repeating: "0.6::Prohibido fumar", count: 10).joined(separator: "||")
        app = launch(["RTCAM_FAKE_OCR_TRANSLATE": spanish])
        _ = openReader(app, "Translator")
        sleep(25)
        XCTAssertEqual(app.state, .runningForeground)

        // 5. Back to Tap to read for whoever uses this simulator next.
        button = app.buttons["readModeButton"].firstMatch
        while (button.value as? String) != "Tap to read" { button.tap(); sleep(2) }
        app.terminate()
    }
}
