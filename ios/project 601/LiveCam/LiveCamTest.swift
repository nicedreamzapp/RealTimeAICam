// Live Cam test aids and its own words. Debug builds only for the aids:
//   -liveCamOpen      open Live Cam straight from launch (screenshots, Duo runs)
//   -liveCamTest      no camera and no mic: a still photo stands in for the camera (Documents/live-cam/frame.jpg,
//                     else the bundled SpeedCheckPhoto.jpg) and questions are typed into a box on screen
//   -liveCamMute      the voice runs its whole queue and timing with no sound (a real phone on a desk)
//   RTCAM_FAKE_LIVE_ANSWER (environment) stands in for the model's answer, for a Simulator that can't run it
// Debug builds also write a timing log (Documents/live-cam/log.jsonl, a new file each visit). Release builds
// write nothing anywhere: no log, no recording.
import Foundation
import UIKit

enum LiveCamWords {
    static let permissionLine = "Live Cam listens for your questions, so your phone will ask to use the microphone and speech recognition. Everything stays on this phone."
    static let notAllowed = "Live Cam needs the microphone and speech recognition to hear you. Allow them in Settings, then open Live Cam again."
    static let noOfflineSpeech = "Speech recognition on this phone can't work offline yet, so Live Cam can't hear you here."
}

enum LiveCamTest {
    #if DEBUG
    static var args: [String] { ProcessInfo.processInfo.arguments }
    static var active: Bool { args.contains("-liveCamTest") }
    static var mute: Bool { args.contains("-liveCamMute") }
    static var openAtLaunch: Bool { args.contains("-liveCamOpen") }
    static var fakeAnswer: String? { ProcessInfo.processInfo.environment["RTCAM_FAKE_LIVE_ANSWER"] }
    #else
    static let active = false
    static let mute = false
    static let openAtLaunch = false
    #endif

    #if DEBUG
    private static let lock = NSLock()
    private static var start = Date()
    static var folder: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("live-cam", isDirectory: true)
    }

    static func beginSession() {
        lock.lock(); defer { lock.unlock() }
        start = Date()
        try? FileManager.default.removeItem(at: folder.appendingPathComponent("log.jsonl"))
    }

    static func log(_ o: [String: Any]) {
        var o = o
        o["t"] = (Date().timeIntervalSince(start) * 1000).rounded() / 1000
        guard let d = try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys]),
              let line = String(data: d, encoding: .utf8) else { return }
        lock.lock(); defer { lock.unlock() }
        let url = folder.appendingPathComponent("log.jsonl")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let bytes = Data((line + "\n").utf8)
        if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(bytes); try? h.close() } else { try? bytes.write(to: url) }
    }

    /// The photo that stands in for the camera.
    static var stillPhoto: CGImage? {
        let custom = folder.appendingPathComponent("frame.jpg").path
        if let ui = UIImage(contentsOfFile: custom) { return ui.cgImage }
        guard let url = Bundle.main.url(forResource: "SpeedCheckPhoto", withExtension: "jpg") else { return nil }
        return UIImage(contentsOfFile: url.path)?.cgImage
    }
    #else
    static func beginSession() {}
    static func log(_: [String: Any]) {}
    #endif
}

extension LiveCallController {
    func configureTest() {
        #if DEBUG
        voice.muted = LiveCamTest.mute
        guard LiveCamTest.active else { return }
        typedOnly = true
        camera.stillFrame = LiveCamTest.stillPhoto
        log(["event": "test", "still": camera.stillFrame != nil, "fake_answer": LiveCamTest.fakeAnswer != nil])
        #endif
    }
}
