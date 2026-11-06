@testable import RealTime_Ai_Cam
import CoreGraphics
import Foundation
import Testing

/// The on-device money detector's decode (MoneyDetector.swift, a port of the trainer's decode2.py). These pin the
/// plain logic: box geometry, which bill a corner numeral belongs to, and the rule that a bill gets a value only
/// when its numerals and its look agree (unknown is better than wrong).
struct MoneyDetectorDecodeTests {
    typealias D = MoneyDetector
    static func det(_ cls: Int, _ conf: Float, _ cx: CGFloat, _ cy: CGFloat, _ w: CGFloat, _ h: CGFloat, _ r: CGFloat = 0) -> D.Det {
        D.Det(cls: cls, conf: conf, poly: D.corners(cx, cy, w, h, r), box: (cx, cy, w, h, r))
    }

    @Test func boxGeometry() {
        let a = D.corners(100, 100, 40, 20, 0)
        #expect(abs(D.area(a) - 800) < 0.01)
        #expect(abs(D.iou(a, a) - 1) < 1e-6)
        #expect(D.iou(a, D.corners(300, 100, 40, 20, 0)) == 0)
        // Half of it shifted across: overlap 400 of a union of 1200.
        #expect(abs(D.iou(a, D.corners(120, 100, 40, 20, 0)) - 1.0 / 3.0) < 1e-6)
        // A quarter turn swaps width and height but keeps the area.
        let t = D.corners(100, 100, 40, 20, .pi / 2)
        #expect(abs(D.area(t) - 800) < 0.01)
        #expect(abs(D.iou(t, D.corners(100, 100, 20, 40, 0)) - 1) < 1e-4)
    }

    @Test func aCornerNumeralGoesToTheFanStripNotTheBillUnderIt() {
        let top = Self.det(0, 0.9, 300, 260, 312, 132)          // a whole bill
        let strip = Self.det(0, 0.8, 300, 220, 312, 30)          // the strip of the bill behind it, fully over the top bill's box
        let numeral = Self.det(5, 0.9, 170, 220, 30, 20)         // a "20" corner inside both boxes
        let b = D.bills([top, strip, numeral], D.Config())
        #expect(b.count == 2)
        #expect(b.first { $0.det.box.h == 30 }?.votes[20] != nil)
        #expect(b.first { $0.det.box.h == 132 }?.votes.isEmpty == true)
    }

    @Test func neighbouringFanStripsAtDifferentAnglesAreTwoBills() {
        // Two strips that overlap a lot but lie 10 degrees apart: two bills, never merged.
        let a = Self.det(0, 0.9, 300, 300, 312, 60, 0), b = Self.det(0, 0.8, 300, 300, 312, 60, 10 * .pi / 180)
        #expect(D.bills([a, b], D.Config()).count == 2)
    }

    @Test func duplicateBillBoxesAreOneBill() {
        let b = D.bills([Self.det(0, 0.9, 300, 300, 312, 132), Self.det(0, 0.5, 302, 301, 310, 130)], D.Config())
        #expect(b.count == 1)
    }

    @Test func aValueNeedsTheNumeralsAndTheLookToAgree() {
        let c = D.Config()
        // Numerals say 20, the look says 20: a $20.
        #expect(D.value(votes: [20: 1.8], probs: ["d20": 0.95, "d100": 0.03, "none": 0.0], c).value == 20)
        // Numerals say 100 (a $100 corner read onto the $20 under it), the look says 20: unread, never "$100".
        #expect(D.value(votes: [100: 0.9], probs: ["d20": 0.95, "d100": 0.03, "none": 0.0], c).value == nil)
        // The look alone is not enough.
        #expect(D.value(votes: [:], probs: ["d20": 0.99, "none": 0.0], c).value == nil)
        // A $100 needs the stricter look threshold.
        var strict = c; strict.clsConf = 0.8; strict.clsConf100 = 0.95
        #expect(D.value(votes: [100: 2], probs: ["d100": 0.9, "none": 0.0], strict).value == nil)
        #expect(D.value(votes: [100: 2], probs: ["d100": 0.97, "none": 0.0], strict).value == 100)
    }

    @Test func somethingThatIsNotMoneyIsDropped() {
        // A phone's bezel boxed as a bill: the classifier says "none".
        let r = D.value(votes: [:], probs: ["none": 0.97, "d1": 0.02], D.Config())
        #expect(r.keep == false)
    }

    @Test func overlappingDetectedBillsAreNotADoubt() {
        let a = LiveMoneyGroupingTests.bill(300, 300, scale: 2), b = LiveMoneyGroupingTests.bill(330, 310, scale: 2)
        let bills = [LiveMoney.Bill(quad: a, value: 20, cutOff: false), LiveMoney.Bill(quad: b, value: 100, cutOff: false)]
        #expect(LiveMoney.count(bills).doubts.contains(.overlapping))
        let boxed = LiveMoney.count(bills, boxed: true)
        #expect(!boxed.doubts.contains(.overlapping))
        #expect(boxed.sure && boxed.total == 120)
        // Two frames that agree keep the detector's say on overlap.
        #expect(LiveMoney.fuse([boxed, boxed])?.sure == true)
    }

    static func bills(_ values: [Int?]) -> [LiveMoney.Bill] {
        values.enumerated().map { i, v in LiveMoney.Bill(quad: LiveMoneyGroupingTests.bill(200 + CGFloat(i) * 40, 300, scale: 2), value: v, cutOff: false) }
    }

    @Test func theTotalIsSaidOnlyWhenEveryCountedBillIsRead() {
        let all = LiveMoney.count(Self.bills([100, 20, 5, 1, 1, 1, 1]), boxed: true)
        #expect(LiveMoney.sentence(all) == "7 bills. I can read a $100, a $20, a $5 and four $1s. That's $129.")
        let one = LiveMoney.count(Self.bills([100, 20, nil, 1, 1, 1, 1]), boxed: true)
        #expect(!one.sure)
        #expect(LiveMoney.sentence(one) == "7 bills. I can read a $100, a $20 and four $1s. One I can't read. Fan them out a little so I can see it.")
        let two = LiveMoney.count(Self.bills([100, nil, nil, 1, 1, 1, 1]), boxed: true)
        #expect(LiveMoney.sentence(two) == "7 bills. I can read a $100 and four $1s. Two I can't read. Fan them out a little so I can see them.")
        #expect(!LiveMoney.sentence(two).contains("That's"))
    }

    @Test func steadyLooksAgreeOnTheCountAndNameOnlyWhatTwoLooksRead() {
        let a = LiveMoney.count(Self.bills([100, 20, 5, 1, 1, 1, 1]), boxed: true)
        let b = LiveMoney.count(Self.bills([100, nil, 5, 1, 1, 1, 1]), boxed: true)
        let odd = LiveMoney.count(Self.bills([100, 20, 5, 1, 1, 1, 1, 1]), boxed: true)   // one look saw an eighth bill
        let s = LiveMoney.steady([a, odd, b])
        #expect(s.bills.count == 7)
        #expect(s.values.sorted() == [1, 1, 1, 1, 5, 100])   // the $20 was read in one look only: unread
        #expect(!s.sure)
        let sure = LiveMoney.steady([a, a, b])
        #expect(sure.sure && sure.total == 129)
        // One look alone never gives a total.
        #expect(!LiveMoney.steady([a]).sure)
    }

    @Test func anUnsureCountIsAFloorNeverANumber() {
        // One bill the detector isn't sure is one bill: "at least", no total, even with every bill read.
        var b = Self.bills([100, 20, 5, 1, 1, 1, 1]); b[6].sure = false
        let c = LiveMoney.count(b, boxed: true)
        #expect(c.doubts.contains(.countUnsure) && !c.sure)
        // Looks that disagree on the count: the floor is the fewest bills any look was sure of.
        var a = LiveMoney.count(Self.bills([100, 1, 1, 1, 1, nil, nil]), boxed: true); a.atLeast = 7
        var d = LiveMoney.count(Self.bills([100, 1, 1, 1, 1, nil]), boxed: true); d.atLeast = 6
        let s = LiveMoney.steady([a, d, a])
        #expect(LiveMoney.sentence(s) == "At least 6 bills. I can read a $100 and four $1s. There may be more I can't make out. Fan them out a little so I can see each one.")
        #expect(!LiveMoney.sentence(s).contains("That's"))
    }
}

/// The 11/6 review fixes: what follow-ups may answer from memory, receipts, ties, Spanish, a paused camera, and a
/// missing or broken model pack.
struct MoneyReviewFixTests {
    static func bills(_ v: [Int?]) -> [LiveMoney.Bill] { MoneyDetectorDecodeTests.bills(v) }
    static let sure = LiveMoney.count(bills([100, 20, 5, 1, 1, 1, 1]), boxed: true)
    static let unsure = LiveMoney.count(bills([100, nil, 5, 1, 1, 1, 1]), boxed: true)

    @Test func onlyADenominationAfterASureCountComesFromMemory() {
        #expect(Self.sure.sure && !Self.unsure.sure)
        #expect(LiveMoney.route("how many twenties", last: Self.sure) == .fromLastCount)
        #expect(LiveMoney.route("how many twenties", last: Self.unsure) == .countAgain)
        #expect(LiveMoney.route("how many twenties now", last: Self.sure) == .countAgain)
        for q in ["what's the total", "how much is that", "are you sure", "count them"] {
            #expect(LiveMoney.route(q, last: Self.sure) == .countAgain, "\(q)")
        }
        #expect(LiveMoney.route("what color is the cup", last: Self.sure) == .notMoney)
        #expect(LiveMoney.route("are you sure", last: nil) == .notMoney)
    }

    @Test func aRestaurantCheckIsNotCash() {
        #expect(!LiveMoney.isMoneyQuestion("how much is this bill at the restaurant"))
        #expect(!LiveMoney.isMoneyQuestion("how much is the check"))
        #expect(!LiveMoney.isMoneyQuestion("what's the tip on this bill"))
        #expect(LiveMoney.route("how much do I owe on this bill", last: Self.sure) == .notMoney)
        #expect(!LiveMoney.isMoneyQuestion("¿Cuánto es la cuenta del restaurante?"))
        #expect(LiveMoney.isMoneyQuestion("how much money is this"))
    }

    @Test func aNumeralTieIsNoReading() {
        #expect(LiveMoney.ocrVotes(["2 5 2 5"]).numeral == nil)
        #expect(LiveMoney.ocrVotes(["10 2 10 2 1"]).numeral == nil)
        #expect(LiveMoney.ocrVotes(["20 20 5"]).numeral == 20)
    }

    @Test func dollarSignDenominations() {
        #expect(LiveMoney.askedDenomination("how many $20 bills") == 20)
        #expect(LiveMoney.askedDenomination("how many $100 bills are there") == 100)
        #expect(LiveMoney.askedDenomination("¿Cuántos billetes de veinte hay?") == 20)
    }

    @Test func spanishQuestionsAndAnswers() {
        #expect(LiveMoney.isMoneyQuestion("¿Cuánto dinero hay?"))
        #expect(LiveMoney.isMoneyQuestion("cuántos billetes ves"))
        #expect(LiveMoney.sentence(Self.sure, lang: .es) == "7 billetes. Puedo leer uno de $100, uno de $20, uno de $5 y cuatro de $1. Son $129 en total.")
        #expect(LiveMoney.sentence(Self.unsure, lang: .es) == "7 billetes. Puedo leer uno de $100, uno de $5 y cuatro de $1. Uno no lo puedo leer. Ábrelos un poco en abanico para que lo vea.")
        #expect(LiveMoney.followUp("¿cuántos de veinte?", last: Self.sure, lang: .es) == "Uno de $20, de siete billetes que suman $129.")
        #expect(MoneyLang.from("es-MX") == .es && MoneyLang.from("en") == .en)
    }

    @Test func aPausedCameraIsNotNoBills() {
        let c = LiveMoney.countBurst(frame: { nil }, ask: nil)
        #expect(c.doubts.contains(.noCamera))
        #expect(LiveMoney.sentence(c) == LiveMoney.cameraPaused)
        #expect(!LiveMoney.sentence(c).contains("don't see any bills"))
    }

    @Test func aMissingOrBrokenModelPackLoadsNothing() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("money-pack-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        #expect(MoneyDetector.load(from: [root.appendingPathComponent("missing")]) == nil)
        // A stamped folder whose "models" are junk.
        let bad = root.appendingPathComponent("bad")
        for n in ["MoneyOBB-v3.mlmodelc", "MoneyDenom-v3.mlmodelc"] {
            try fm.createDirectory(at: bad.appendingPathComponent(n), withIntermediateDirectories: true)
            try Data("not a model".utf8).write(to: bad.appendingPathComponent(n).appendingPathComponent("model.mil"))
        }
        try Data(#"{"version": "money-v3"}"#.utf8).write(to: bad.appendingPathComponent(MoneyDetector.stampName))
        #expect(MoneyDetector.load(from: [bad]) == nil)
        // The wrong stamp: never loaded even before the models are opened.
        try Data(#"{"version": "money-v2"}"#.utf8).write(to: bad.appendingPathComponent(MoneyDetector.stampName))
        #expect(MoneyDetector.load(from: [bad]) == nil)
        #expect(MoneyDetector.validShape([1, 300, 7]) && MoneyDetector.validShape([1, 20, 8400]))
        #expect(!MoneyDetector.validShape([1, 300, 6]) && !MoneyDetector.validShape([1, 20, 2100]))
    }
}

/// Review round 2 (11/6): whole words, follow-ups that aren't about money, Spanish floors, too many bills.
struct MoneyReviewRound2Tests {
    static let sure = MoneyReviewFixTests.sure

    @Test func theModelsWordsAreWholeWords() {
        for (said, v) in [("None", nil), ("Money", nil), ("often", nil), ("ninguno", nil), ("nothing on it", nil),
                          ("One", 1), ("It's a twenty", 20), ("one hundred", 100), ("Cien dólares", 100), ("veinte", 20),
                          ("uno", 1), ("5", 5), ("one or five", nil)] as [(String, Int?)] {
            #expect(LiveMoney.modelVote(said) == v, "\(said)")
        }
        #expect(LiveMoney.isYes("Yes.") && LiveMoney.isYes("Sí") && !LiveMoney.isYes("Yesterday") && !LiveMoney.isYes("no"))
    }

    @Test func onlyAMoneyQuestionWithADenominationAnswersFromMemory() {
        #expect(LiveMoney.route("which ones are ripe", last: Self.sure) == .notMoney)
        #expect(LiveMoney.route("a menos de 2 metros", last: Self.sure) == .notMoney)
        #expect(LiveMoney.route("are the tens of ants gone", last: Self.sure) == .notMoney)
        #expect(LiveMoney.route("how many twenties", last: Self.sure) == .fromLastCount)
        #expect(LiveMoney.route("¿cuántos de veinte?", last: Self.sure) == .fromLastCount)
        #expect(LiveMoney.route("how many $20 bills", last: Self.sure) == .fromLastCount)
        #expect(LiveMoney.route("how many twenties", last: nil) == .countAgain)
    }

    @Test func spanishOverlapIsAFloor() {
        var c = LiveMoney.count(MoneyDetectorDecodeTests.bills([100, nil]), pile: [20, 100])
        c.atLeast = 3
        let s = LiveMoney.sentence(c, lang: .es)
        #expect(s.contains("al menos"))
        #expect(s.contains("Hay al menos tres billetes"))
    }

    @Test func tooManyBillsHasItsOwnLine() {
        let c = LiveMoney.count(MoneyDetectorDecodeTests.bills(Array(repeating: 1, count: 13)), boxed: true)
        #expect(c.doubts.contains(.tooMany))
        #expect(LiveMoney.sentence(c) == "That's a lot of bills; I can count up to 12 at a time. Split them into smaller piles.")
        #expect(LiveMoney.sentence(c, lang: .es) == MoneyWordsES.tooMany)
        let old = LiveMoney.count(MoneyDetectorDecodeTests.bills(Array(repeating: 1, count: 13)))
        #expect(LiveMoney.sentence(old) == LiveMoney.tooMany)
    }

    @Test func theDetectorPathHonorsMaxFrames() {
        // No camera frame: "camera paused", never "no bills".
        let none = LiveMoney.countBurst(maxFrames: 2, frame: { nil }, ask: nil)
        #expect(none.doubts.contains(.noCamera))
        // Detector looks (boxed): exactly maxFrames looks, then the steady answer.
        let img = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 32, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!.makeImage()!
        for n in [2, 3] {
            var frames = 0, looks = 0
            let c = LiveMoney.countBurst(maxFrames: n, frame: { frames += 1; return img }, ask: nil, look: { _ in
                looks += 1
                return (MoneyReviewFixTests.sure, [])
            })
            #expect(looks == n && frames == n, "maxFrames \(n)")
            #expect(c.boxed && c.sure && c.total == 129)
        }
    }

    @Test func aRecountForgetsTheOldCountAtOnce() {
        var m = MoneyMemory()
        m.note(Self.sure)
        #expect(LiveMoney.route("how many twenties", last: m.recent()) == .fromLastCount)
        m.countStarted()   // "count again" starts a recount
        #expect(m.recent() == nil)
        #expect(LiveMoney.route("how many twenties", last: m.recent()) == .countAgain)
    }

    @Test func serialsAreReadOnTheWholeFrameWhenTheBillsCoverLittleOfIt() {
        let W: CGFloat = 1000, H: CGFloat = 800
        let small = [MoneyDetectorDecodeTests.bills([1])[0].quad]   // one bill, a small part of the frame
        #expect(LiveMoney.serialArea(small, width: W, height: H) == nil)
        let big = LiveMoney.Quad(corners: [CGPoint(x: 20, y: 780), CGPoint(x: 980, y: 780), CGPoint(x: 980, y: 20), CGPoint(x: 20, y: 20)])
        #expect(LiveMoney.serialArea([big], width: W, height: H) != nil)
        #expect(LiveMoney.serialArea([], width: W, height: H) == nil)
    }

    @Test func spanishDistancesAreNotADenomination() {
        #expect(LiveMoney.route("¿cuántos árboles hay a menos de 2 metros?", last: Self.sure) == .notMoney)
        #expect(LiveMoney.route("¿cuántos árboles hay a menos de 2 metros?", last: nil) == .notMoney)
        #expect(LiveMoney.askedDenomination("¿Cuántos billetes de 20 hay?") == 20)
        #expect(LiveMoney.askedDenomination("¿cuántos de veinte?") == 20)
    }
}

/// The published money pack (https://ineedhemp.com/models/rtcam/money/money-v3/), downloaded for real: every file
/// checked against its size and SHA-256, the version stamp checked, and both models loaded by the real loader.
struct MoneyPackLiveTests {
    @Test func thePublishedPackDownloadsAndLoads() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("money-live-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let dir = try await MoneyPack.install(into: root)
        #expect(MoneyPack.isComplete(dir))
        #expect(MoneyDetector.load(from: [dir]) != nil)
        // A wrong stamp is refused even with good models beside it.
        let stamp = dir.appendingPathComponent(MoneyDetector.stampName)
        let good = try Data(contentsOf: stamp)
        try Data(#"{"version": "money-v0"}"#.utf8).write(to: stamp)
        #expect(MoneyDetector.load(from: [dir]) == nil)
        try good.write(to: stamp)
        #expect(MoneyDetector.load(from: [dir]) != nil)
    }

    @Test func aBadPackURLInstallsNothing() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("money-bad-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        await #expect(throws: (any Error).self) { try await MoneyPack.install(from: URL(string: "https://ineedhemp.com/models/rtcam/money/nope/")!, into: root) }
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("money-v3").path))
    }
}
