@testable import RealTime_Ai_Cam
import CoreGraphics
import Foundation
import Testing

// "I don't see a key. I can see a dog, a laptop and a mirror." (Matt, 2026-09-16)

private func seen(_ name: String, _ conf: Float, x: CGFloat = 0.1, y: CGFloat = 0.1) -> AimElsewhere.Seen {
    AimElsewhere.Seen(name: name, conf: conf, box: CGRect(x: x, y: y, width: 0.2, height: 0.2))
}

private let key = AimSubject.object(AimVocabulary.Match(spokenName: "key", classNames: ["key"], classIDs: [7]))
private let dog = AimSubject.object(AimVocabulary.Match(spokenName: "dog", classNames: ["dog"], classIDs: [3]))

struct AimElsewhereTimingTests {
    private let t0 = Date(timeIntervalSince1970: 4_000_000)
    private let line = "I don't see a key. I can see a dog."

    private func run(_ c: inout AimCoach, to end: TimeInterval, elsewhere: String?) -> [(TimeInterval, String)] {
        var out: [(TimeInterval, String)] = []
        var i = 0
        while Double(i) * 0.1 <= end + 1e-9 {
            let t = Double(i) * 0.1
            for a in c.observe(box: nil, now: t0.addingTimeInterval(t), voiceBusy: false, elsewhere: elsewhere) {
                if case let .say(s, _) = a { out.append((t, s)) }
            }
            i += 1
        }
        return out
    }

    @Test func firstMissAtFiveThenElsewhereAtFifteenThenEveryTwenty() {
        var c = AimCoach(subject: key)
        c.reset(now: t0)
        let out = run(&c, to: 40, elsewhere: line)
        let miss = AimPhrases.phrase(for: .notFound, subject: key)
        #expect(miss == "I don't see a key yet, move the phone slowly")
        let expected: [(TimeInterval, String)] = [
            (5, miss), (11, miss), (15, line), (21, miss), (27, miss), (33, miss), (36, line),
        ]
        #expect(out.count == expected.count)
        for (got, want) in zip(out, expected) {
            #expect(abs(got.0 - want.0) < 1e-6, "at \(got.0) expected \(want.0)")
            #expect(got.1 == want.1)
        }
    }

    @Test func noElsewhereSentenceWhenNothingWasLookedFor() {
        var c = AimCoach(subject: .face)
        c.reset(now: t0)
        let out = run(&c, to: 40, elsewhere: nil)
        #expect(out.allSatisfy { $0.1 == "I don't see a face yet, move the phone slowly" })
        #expect(out.map(\.0).first.map { abs($0 - 5) < 1e-6 } == true)
        #expect(out.count == 6) // 5, 11, 17, 23, 29, 35
    }

    @Test func seeingTheTargetRestartsTheClock() {
        var c = AimCoach(subject: key)
        c.reset(now: t0)
        let box = CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2)
        _ = c.observe(box: box, now: t0.addingTimeInterval(10), voiceBusy: false, elsewhere: line)
        // Lost again at 10 s: nothing until 15 s (5 s later), and no
        // "I can see" sentence until 15 s after it was last seen.
        #expect(c.observe(box: nil, now: t0.addingTimeInterval(14.9), voiceBusy: false, elsewhere: line).isEmpty)
        let first = c.observe(box: nil, now: t0.addingTimeInterval(15.1), voiceBusy: false, elsewhere: line)
        #expect(first == [.say(AimPhrases.phrase(for: .notFound, subject: key), .none)])
    }
}

struct AimElsewhereSentenceTests {
    @Test func topThreeWithArticlesAndFilters() {
        let frames: [[AimElsewhere.Seen]] = [
            [seen("dog", 0.90, x: 0.0), seen("laptop", 0.80, x: 0.3), seen("mirror", 0.70, x: 0.6),
             seen("home interior", 0.95, x: 0.0, y: 0.6), seen("extinguisher", 0.99, x: 0.3, y: 0.6)],
            [seen("samoyed", 0.95, x: 0.0), seen("laptop", 0.75, x: 0.3), seen("mirror", 0.72, x: 0.6),
             seen("tv genre", 0.9, x: 0.3, y: 0.6)],
        ]
        let things = AimElsewhere.pick(frames, excluding: AimElsewhere.targetNames(for: key))
        #expect(things == ["dog", "laptop", "mirror"])
        #expect(AimElsewhere.sentence(subject: key, things: things)
            == "I don't see a key. I can see a dog, a laptop and a mirror.")
    }

    @Test func twoAndOneAndNone() {
        #expect(AimElsewhere.sentence(subject: key, things: ["dog", "umbrella"])
            == "I don't see a key. I can see a dog and an umbrella.")
        #expect(AimElsewhere.sentence(subject: key, things: ["glasses"])
            == "I don't see a key. I can see glasses.")
        #expect(AimElsewhere.sentence(subject: key, things: [])
            == "I don't see a key, and nothing else stands out. Try another direction.")
        #expect(AimElsewhere.sentence(subject: .page, things: ["cup"])
            == "I don't see a picture or page. I can see a cup.")
    }

    @Test func needsTwoFramesAndSixtyPercent() {
        let frames: [[AimElsewhere.Seen]] = [
            [seen("cup", 0.9), seen("lamp", 0.59, x: 0.5)],
            [seen("lamp", 0.59, x: 0.5), seen("bottle", 0.8, x: 0.7)],
            [seen("lamp", 0.59, x: 0.5)],
        ]
        #expect(AimElsewhere.pick(frames, excluding: []).isEmpty)
    }

    @Test func onlyTheLastFiveFramesCount() {
        let old = [seen("cup", 0.9)]
        let frames: [[AimElsewhere.Seen]] = [old, old, [], [], [], [], []]
        #expect(AimElsewhere.pick(frames, excluding: []).isEmpty)
        let recent: [[AimElsewhere.Seen]] = [[], [], [], [], [], old, old]
        #expect(AimElsewhere.pick(recent, excluding: []) == ["cup"])
    }

    @Test func overlappingBoxesKeepTheMostConfident() {
        let frame = [seen("samoyed", 0.7), seen("poodle", 0.9), seen("rug", 0.8, x: 0.12, y: 0.12)]
        let kept = AimElsewhere.dedupe(frame)
        #expect(kept.map(\.name) == ["poodle"])
    }

    @Test func breedsCollapseAndTheTargetIsNotOffered() {
        #expect(AimElsewhere.spokenName("Persian Cat") == "cat")
        #expect(AimElsewhere.spokenName("golden retriever") == "dog")
        #expect(AimElsewhere.spokenName("grandfather") == "person")
        let frames = [[seen("samoyed", 0.9), seen("cup", 0.8, x: 0.6)], [seen("poodle", 0.9), seen("cup", 0.8, x: 0.6)]]
        #expect(AimElsewhere.pick(frames, excluding: AimElsewhere.targetNames(for: dog)) == ["cup"])
    }

    @Test func placesAndGenresAreNeverSaid() {
        for name in ["home interior", "playroom", "veterinarians office", "hospital room", "tv genre",
                     "waste", "garment", "laundry room", "barber shop", "science fiction film", "entrance hall"] {
            #expect(AimElsewhere.spokenName(name) == nil, "\(name) should be filtered")
        }
        #expect(AimElsewhere.spokenName("laptop") == "laptop")
        #expect(AimElsewhere.spokenName("closet") == "closet")
    }

    @Test func tiesAreAlphabeticalAndCappedAtThree() {
        let f = [seen("a1", 0.8, x: 0), seen("c1", 0.8, x: 0.3), seen("b1", 0.8, x: 0.6), seen("d1", 0.8, y: 0.6)]
        #expect(AimElsewhere.pick([f, f], excluding: []) == ["a1", "b1", "c1"])
    }
}
