@testable import RealTime_Ai_Cam
import CoreGraphics
import Foundation
import Testing

/// Regression tests for three review fixes in HelpMeAim.swift: "got it"
/// respects the speech gap, no "got it" on the frame right after a countdown
/// ends, and the thing before a preposition wins over the last word.
struct HelpMeAimFixTests {
    private let t0 = Date(timeIntervalSince1970: 2_000_000)
    private func at(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }
    private let framed = CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
    private let left = CGRect(x: 0.05, y: 0.25, width: 0.3, height: 0.5)

    private func coach() -> AimCoach {
        var c = AimCoach(subject: .page)
        c.reset(now: t0)
        return c
    }

    @Test func gotItWaitsForTheGapAfterASteeringPhrase() {
        var c = coach()
        _ = c.observe(box: left, now: at(0), voiceBusy: false)
        #expect(c.observe(box: left, now: at(0.1), voiceBusy: false) == [.say("move the phone left", .tick)])
        // Jump straight to a framed box (fresh coach state has no smoothing
        // memory issue: feed it until the smoothed box is framed).
        var said: [(TimeInterval, [AimCoach.Action])] = []
        for s in stride(from: 0.2, through: 1.2, by: 0.1) {
            said.append((s, c.observe(box: framed, now: at(s), voiceBusy: false)))
        }
        let gotIt = said.first { $0.1.contains(.say("got it, hold still", .success)) }
        #expect(gotIt != nil)
        #expect((gotIt?.0 ?? 0) >= 0.1 + c.minGap - 1e-9)
    }

    @Test func noGotItOnTheFrameRightAfterCountdownEnds() {
        var c = coach()
        _ = c.observe(box: framed, now: at(0), voiceBusy: false)
        _ = c.observe(box: framed, now: at(0.1), voiceBusy: false)
        #expect(c.observe(box: framed, now: at(0.7), voiceBusy: false) == [.startCountdown])
        c.countdownEnded()
        #expect(c.observe(box: framed, now: at(5.0), voiceBusy: false) == [])
        #expect(c.observe(box: framed, now: at(5.1), voiceBusy: false) == [.say("got it, hold still", .success)])
    }

    @Test func thingBeforeAPrepositionWins() throws {
        // "red" and "car" are real YOLOE classes; the thing asked for is the keys.
        let vocab = ["red", "car", "key", "house"]
        let a = try #require(AimVocabulary.match("keys to the car", classNames: vocab))
        #expect(a.spokenName == "key")
        let b = try #require(AimVocabulary.match("my red keys", classNames: vocab))
        #expect(b.spokenName == "key")
        let c = try #require(AimVocabulary.match("my house keys", classNames: vocab))
        #expect(c.spokenName == "house key")
    }

    @Test func realVocabularyHasTheCommonAsks() throws {
        // The bundled 4,585-name list, as shipped.
        let names = AimObjectFinder.loadClassNames()
        try #require(names.count == 4585)
        #expect(AimVocabulary.match("keys", classNames: names)?.classNames == ["key"])
        #expect(AimVocabulary.match("painting", classNames: names)?.classNames.contains("picture frame") == true)
        #expect(AimVocabulary.match("cell phone", classNames: names)?.classNames.contains("phone") == true)
        #expect(AimVocabulary.match("remote control", classNames: names)?.classNames.contains("remote") == true)
        #expect(AimVocabulary.match("wallet", classNames: names) == nil)
    }
}
