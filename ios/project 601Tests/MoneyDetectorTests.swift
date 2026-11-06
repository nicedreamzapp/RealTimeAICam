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
