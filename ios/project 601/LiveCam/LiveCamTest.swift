// Live Cam test aids and its own words. Debug builds only for the aids:
//   -liveCamOpen      open Live Cam straight from launch (screenshots, Duo runs)
//   -liveCamTest      no camera and no mic: a still photo stands in for the camera (Documents/live-cam/frame.jpg,
//                     else the bundled SpeedCheckPhoto.jpg) and questions are typed into a box on screen
//   -liveCamMute      the voice runs its whole queue and timing with no sound (a real phone on a desk)
//   -liveCamCantHear  acts as if speech recognition kept failing (the "can't hear you" note and typing box)
//   RTCAM_FAKE_LIVE_ANSWER (environment) stands in for the model's answer, for a Simulator that can't run it
//   RTCAM_FAKE_LIVE_DELAY (environment) seconds the stand-in "thinks" before answering
//   RTCAM_FAKE_THING_BOX (environment) "x,y,w,h": the box when the Simulator's detector finds nothing
// Debug builds also write a timing log (Documents/live-cam/log.jsonl, a new file each visit). Release builds
// write nothing anywhere: no log, no recording.
import Foundation
import UIKit

enum LiveCamWords {
    static let notAllowed = "Live Cam needs the microphone and speech recognition to hear you. Allow them in Settings, then open Live Cam again."
    static let cantHear = "I can't hear you right now. Speech recognition on this phone keeps stopping. You can type your question in the box, or go back."
    static let cantHearNote = "Can't hear you: speech recognition keeps stopping. Type a question below, or tap Back."
    static let noOfflineSpeech = "Speech recognition on this phone can't work offline yet, so Live Cam can't hear you here."

    // The app's own lines in LiveCallController (English keys; said in the app language).
    static let needsCamera = "Live Cam needs the camera. Allow it in Settings, then open Live Cam again."
    static let modelFailed = "I couldn't start the vision model. Go back and try Live Cam again."
    static let noModel = "The picture model isn't on this phone. Open Settings, then Models, to download one."
    static let sayAgain = "Sorry, say that again?"
    static let lostTrack = "I lost track of that part. Ask me the whole question again?"
    static let bye = "Okay, bye for now."
    static let gotIt = "Got it."
    static let coachGoalSet = "Coach mode on. Let's work on %@. Show me, or ask me anything about it."
    static let nothingSaidYet = "I haven't said anything yet."
    static let coachGoalHeard = "Got it, %@. Show me what you're doing, or ask me anything about it."
    static let flipToSeeYou = "Flip the camera to face you and I'll take a look."
    static let stillGettingReady = "I'm still getting ready. Ask me again in a second."
    static let cantSeeInBackground = "I can't see while the phone is locked or another app is open. Open RealTime AI Cam again and ask me."
    static let cameraPaused = "My camera paused, I'm restarting it. Ask me again in a second."
    static let newThing = "I see %@. Anything I can help with?"
    /// After the one help offer of the visit (Matt 11/6): just the thing.
    static let newThingPlain = "I see %@."
    static let newThingThere = "There's %@."
    /// The one help offer of the visit, after the opening look (Matt 11/6: never asked of the model every time).
    static let helpOffer = "Anything I can help with?"
    /// An answer whose every sentence was already said this visit (Matt 11/6: never the same words twice).
    static let sameAsBefore = "Same as before."
    /// The torch didn't do what was asked (review 11/6).
    static let lightFailed = "The flashlight isn't working right now."
    /// Said while it counts money, taking turns (Matt 11/6: never the same words twice in a row).
    static let countingLines = ["Let me count.", "Counting now.", "One sec, counting."]
    /// A goal finished ("done") or swapped ("new thing"), Matt 11/6.
    static let goalDone = "Nice work."
    static let goalNew = "Okay. What's the new thing?"
    static let notFullySure = "I'm not fully sure on that one."
    static let takeBack = "Actually, I'm not sure about the %@."
    static let lostAnswer = "Sorry, I lost that. Ask me again?"

    /// Every line Live Cam says or shows through a constant rather than an L("...") literal (2026-11-05, Spanish UI).
    /// es-strings.py only finds L("...") literals, so `missing` can't see these and `stale` lists them: keep them in the
    /// catalog. LiveCamSpanishTests checks each one has its Spanish.
    static var indirectKeys: [String] {
        [notAllowed, cantHear, cantHearNote, noOfflineSpeech,
         needsCamera, modelFailed, noModel, sayAgain, lostTrack, bye, gotIt, coachGoalSet, nothingSaidYet, coachGoalHeard,
         flipToSeeYou, stillGettingReady, cantSeeInBackground, cameraPaused, newThing, newThingPlain, newThingThere, helpOffer, sameAsBefore, lightFailed, goalDone, goalNew, notFullySure, takeBack, lostAnswer]
            + LiveWords.checkIns + LiveWords.acks + LiveGoal.checkIns
            + LiveMode.allCases.flatMap { [$0.label, $0.confirm] } + ["Light's on.", "Light's off."] + countingLines
    }
}

enum LiveCamTest {
    #if DEBUG
    static var args: [String] { ProcessInfo.processInfo.arguments }
    static var active: Bool { args.contains("-liveCamTest") }
    static var mute: Bool { args.contains("-liveCamMute") }
    static var openAtLaunch: Bool { args.contains("-liveCamOpen") }
    /// -liveCamHitch: log screen refreshes and camera frames that come late (is the picture freezing while it looks?).
    static var hitch: Bool { args.contains("-liveCamHitch") }
    /// Acts as if speech recognition kept failing, right after the greeting (layout of the "can't hear you" note).
    static var forceCantHear: Bool { args.contains("-liveCamCantHear") }
    static var fakeAnswer: String? { ProcessInfo.processInfo.environment["RTCAM_FAKE_LIVE_ANSWER"] }
    static var fakeDelay: Double { Double(ProcessInfo.processInfo.environment["RTCAM_FAKE_LIVE_DELAY"] ?? "") ?? 0 }
    #else
    static let active = false
    static let mute = false
    static let openAtLaunch = false
    static let hitch = false
    static let forceCantHear = false
    #endif

    #if DEBUG
    private static let lock = NSLock()
    private static var start = Date()
    static var folder: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("live-cam", isDirectory: true)
    }

    private static var hitchLink: CADisplayLink?
    private final class HitchTarget: NSObject {
        var last: CFTimeInterval = 0
        @objc func tick(_ link: CADisplayLink) {
            if last > 0 {
                let ms = (link.timestamp - last) * 1000
                if ms > 50 { LiveCamTest.log(["event": "ui_gap", "ms": Int(ms)]) }
            }
            last = link.timestamp
        }
    }
    private static let hitchTarget = HitchTarget()

    static func beginSession() {
        if hitch, hitchLink == nil {
            DispatchQueue.main.async {
                let link = CADisplayLink(target: hitchTarget, selector: #selector(HitchTarget.tick(_:)))
                link.add(to: .main, forMode: .common)
                hitchLink = link
            }
        }
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
