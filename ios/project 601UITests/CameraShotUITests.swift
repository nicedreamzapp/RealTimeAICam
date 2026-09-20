//
//  CameraShotUITests.swift
//  Takes a few photos with the system Camera app for the room-recognition test
//  (Matt set the phone down in a room and asked for it, 2026-09-16).
//  Element taps on the shutter only.
//

import XCTest

final class CameraShotUITests: XCTestCase {
    @MainActor
    func testTakeThreePhotos() throws {
        let camera = XCUIApplication(bundleIdentifier: "com.apple.camera")
        camera.launch()
        sleep(3)
        let shutter = camera.buttons["PhotoCapture"].firstMatch
        if !shutter.waitForExistence(timeout: 8) {
            print("SHOT tree: \(camera.debugDescription.prefix(3000))")
            XCTFail("no shutter button"); return
        }
        for i in 1...3 {
            guard camera.state == .runningForeground else { return }
            shutter.tap()
            print("SHOT taken \(i)")
            sleep(2)
        }
    }
}
